"""Versioned projections for native clients. Mutations retain existing guards."""
import re
from urllib.parse import parse_qs, urlsplit
from bridge.store import StoreUnavailable
from bridge.remote import RemoteUnavailable
from .history_catalog import HistoryUnavailable
from .workspace_reader import WorkspaceReader, WorkspaceConflictError

ROOT = '/api/native/v1'
THREAD = re.compile(r'^/api/native/v1/threads/([0-9a-f-]{36})/(timeline|changes|detail|usage)$')
WORKSPACE = re.compile(r'^/api/native/v1/threads/([0-9a-f-]{36})/workspace/(tree|search|file|import|repositories|changes|patch)$')


def capabilities(row):
    control = not row.get('readOnly', True)
    return {'readOnly': not control, 'send': control, 'stop': control, 'respond': control,
            'attachments': control, 'rename': control, 'threadSettings': control,
            'archive': control and row.get('host') == 'local', 'pin': True, 'hide': True,
            'permanentDelete': control and row.get('host') == 'local',
            'fullLog': row.get('host') == 'local' and row.get('historyReadable', False),
            'workspaceRead': control and row.get('host') == 'local' and bool(row.get('cwd')),
            'workspaceWrite': control and row.get('host') == 'local' and bool(row.get('cwd'))}


def handle(handler, write, path):
    if not path.startswith('/api/native/'):
        return False
    try:
        handler.check_request(write)
        if not handler.authorized(write): return True
        writable_file = WORKSPACE.fullmatch(path)
        if write and not (writable_file and writable_file.group(2) in ('file', 'import')):
            handler.close_connection = True
            handler.output(405, {'error': '此版本原生投影接口只接受 GET；工作区编辑与导入使用专用受限接口'})
            return True
        library = handler.server.reading
        if library is None: raise HistoryUnavailable('未配置本机历史服务')
        if path == ROOT + '/bootstrap':
            result = {'apiVersion': 1, 'client': 'codex-link-native',
                      'features': {'workspace': True, 'timeline': True, 'codexSettings': handler.server.codex_settings is not None},
                      'limits': {'sessionPage': 100, 'timelinePage': 100, 'attachmentBytes': 20 * 1024 * 1024},
                      'transport': 'cursor-poll', 'threadWrites': '/api/sessions/{id}/{action}',
                      'settings': '/api/codex-settings', 'projects': '/api/workspace/projects'}
        else:
            workspace_match = WORKSPACE.fullmatch(path)
            match = workspace_match or THREAD.fullmatch(path)
            if not match:
                handler.output(404, {'error': '原生接口不存在'}); return True
            query = parse_qs(urlsplit(handler.path).query)
            value = lambda k, default='': query.get(k, [default])[0]
            key, action = match.groups()
            row = library.metadata(key, value('host', 'local'))
            explicit_log = value('view') == 'log'
            if workspace_match:
                if row.get('readOnly', True) or row['host'] != 'local' or explicit_log:
                    raise PermissionError('此视图不支持读取当前工作区；请打开本机桌面会话')
                reader = WorkspaceReader(row.get('cwd'))
                if write:
                    if action == 'import':
                        if handler.headers.get('Transfer-Encoding') or handler.headers.get_content_type() != 'application/octet-stream':
                            raise ValueError('导入请求格式无效')
                        lengths = handler.headers.get_all('Content-Length', [])
                        if len(lengths) != 1 or not lengths[0].isdigit() or not 0 < int(lengths[0]) <= 20 * 1024 * 1024:
                            raise ValueError('导入文件需为 1 字节至 20 MiB')
                        data = handler.rfile.read(int(lengths[0]))
                        if len(data) != int(lengths[0]): raise ValueError('导入文件传输不完整')
                        result = reader.import_file(value('directory'), value('name'), data)
                    else:
                        body = handler.read_json()
                        result = reader.save(body.get('path'), body.get('text'), body.get('revision'))
                elif action == 'tree': result = reader.tree(value('path'), int(value('offset', '0')), value('hidden') == 'true', value('sort', 'name'), value('descending') == 'true')
                elif action == 'search': result = reader.search(value('q'), value('hidden') == 'true')
                elif action == 'file': result = reader.file(value('path'))
                elif action == 'repositories': result = reader.repositories()
                elif action == 'changes': result = reader.changes(value('source', 'unstaged'), repository_path=value('repository'))
                else: result = reader.patch(value('path'), value('source', 'unstaged'), repository_path=value('repository'))
                handler.output(200, result)
                return True
            if action == 'usage':
                if row['host'] != 'local':
                    result = {'usage': None, 'context': None, 'unavailable': '远程会话日志未提供 token 用量记录'}
                else:
                    snapshot = library.reader.read(row, 'page', limit=1)
                    result = {'usage': snapshot.get('meta', {}).get('usage'), 'context': snapshot.get('meta', {}).get('context'), 'unavailable': None}
                handler.output(200, result)
                return True
            if explicit_log and row['host'] != 'local': raise PermissionError('远程日志视图尚未支持')
            read_only = row.get('readOnly') or explicit_log
            if action == 'detail':
                mode, options = 'detail', {'cursor': value('key'), 'offset': int(value('offset', '0')), 'version': value('version')}
            elif action == 'changes':
                mode, options = 'changes', {'after': int(value('after', '-1')), 'epoch': value('epoch'), 'start': value('start')}
            else:
                mode, options = 'page', {'limit': max(1, min(100, int(value('limit', '30')))), 'before': value('before') or None}
            if read_only:
                result = library.timeline(key, mode, **options)
            else:
                result = library.bridge.for_host(row['host']).timeline_read(key, mode, **options)
            # Native clients never infer execution ability from originator or UI.
            result = dict(result, apiVersion=1, capabilities=capabilities(dict(row, readOnly=bool(read_only))))
            if 'meta' in result:
                result['meta'] = dict(result['meta'], readOnly=bool(read_only), host=row['host'],
                                      projectName=row.get('projectName', ''), cwd=row.get('cwd', ''))
                if read_only:
                    result['meta'].update(connected=False, requests=[], submissions=[])
        handler.output(200, result)
    except WorkspaceConflictError as exc:
        handler.close_connection = True; handler.output(409, {'error': str(exc), 'code': 'conflict'})
    except PermissionError as exc:
        handler.close_connection = True; handler.output(403, {'error': str(exc)})
    except KeyError:
        handler.close_connection = True; handler.output(404, {'error': '找不到会话'})
    except (HistoryUnavailable, StoreUnavailable, RemoteUnavailable, OSError):
        handler.close_connection = True; handler.output(409, {'error': '会话暂不可读，请重新载入'})
    except (ValueError, TypeError) as exc:
        handler.close_connection = True; handler.output(400, {'error': str(exc) or '参数无效'})
    return True
