"""Versioned projections for native clients. Mutations retain existing guards."""
import re
from urllib.parse import parse_qs, urlsplit
from bridge.store import StoreUnavailable
from bridge.remote import RemoteUnavailable
from .history_catalog import HistoryUnavailable

ROOT = '/api/native/v1'
THREAD = re.compile(r'^/api/native/v1/threads/([0-9a-f-]{36})/(timeline|changes|detail)$')


def capabilities(row):
    control = not row.get('readOnly', True)
    return {'readOnly': not control, 'send': control, 'stop': control, 'respond': control,
            'attachments': control, 'rename': control, 'threadSettings': control,
            'archive': control and row.get('host') == 'local', 'pin': True, 'hide': True,
            'fullLog': row.get('host') == 'local' and row.get('historyReadable', False)}


def handle(handler, write, path):
    if not path.startswith('/api/native/'):
        return False
    try:
        handler.check_request(write)
        if not handler.authorized(write): return True
        if write:
            handler.close_connection = True
            handler.output(405, {'error': '此版本原生投影接口只接受 GET；写操作使用已认证的会话接口'})
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
            match = THREAD.fullmatch(path)
            if not match:
                handler.output(404, {'error': '原生接口不存在'}); return True
            query = parse_qs(urlsplit(handler.path).query)
            value = lambda k, default='': query.get(k, [default])[0]
            key, action = match.groups()
            row = library.metadata(key, value('host', 'local'))
            explicit_log = value('view') == 'log'
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
    except PermissionError as exc:
        handler.close_connection = True; handler.output(403, {'error': str(exc)})
    except KeyError:
        handler.close_connection = True; handler.output(404, {'error': '找不到会话'})
    except (HistoryUnavailable, StoreUnavailable, RemoteUnavailable, OSError):
        handler.close_connection = True; handler.output(409, {'error': '会话暂不可读，请重新载入'})
    except (ValueError, TypeError) as exc:
        handler.close_connection = True; handler.output(400, {'error': str(exc) or '参数无效'})
    return True
