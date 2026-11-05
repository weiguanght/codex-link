"""Authenticated discovery/read routes and a fail-closed read-only boundary."""
import re
import time
from urllib.parse import parse_qs, urlsplit
from bridge.remote import RemoteUnavailable
from bridge.store import StoreUnavailable
from .history_catalog import HistoryUnavailable, public

THREAD = re.compile(r'^/api/sessions/([0-9a-f-]{36})(?:/(.*))?$')
HISTORY = re.compile(r'^/api/history/([0-9a-f-]{36})/(timeline|changes|detail)$')
METADATA = re.compile(r'^/api/session-meta/([0-9a-f-]{36})$')


def handle(handler, write, path):
    library = handler.server.reading
    if library is None:
        return False
    thread, history, metadata = THREAD.fullmatch(path), HISTORY.fullmatch(path), METADATA.fullmatch(path)
    listing = not write and path == '/api/sessions'
    if not (listing or thread or history or metadata):
        return False
    try:
        handler.check_request(write)
        if not handler.authorized(write):
            return True
        query = parse_qs(urlsplit(handler.path).query)
        def value(name, default=''):
            return query.get(name, [default])[0]
        if listing:
            scope = value('scope', 'all')
            if scope not in ('all', 'desktop'):
                raise ValueError('未知会话范围')
            sort = value('sort', 'updated')
            if sort not in ('updated', 'title'):
                raise ValueError('未知排序方式')
            result = library.list(query=value('q')[:200], limit=max(1, min(100, int(value('limit', '100')))),
                offset=max(0, int(value('offset', '0'))), archived=value('archived') == 'true', scope=scope,
                include_internal=value('internal') == 'true', project=value('project') or None, force=value('refresh') == 'true', hidden=value('hidden') == 'true', sort=sort)
        else:
            key = (metadata or history or thread)[1]
            host = value('host', 'local')
            if thread and thread[2] == 'convert':
                if not write:
                    handler.close_connection = True
                    handler.output(405, {'error': '会话转换需要已认证的写请求'})
                    return True
                result = library.convert_cli_to_desktop(key, host)
                handler.output(200, public(result))
                return True
            row = library.metadata(key, host)
            if metadata:
                if write:
                    raise PermissionError('会话元信息接口只允许读取')
                result = public(row)
            elif history or row.get('readOnly'):
                if host != 'local':
                    raise PermissionError('远程日志只读视图尚未支持')
                action = (history or thread)[2]
                if write or action not in (None, 'timeline', 'changes', 'detail', 'notifications'):
                    handler.close_connection = True
                    handler.output(403, {'error': '此会话仅可读取历史，不能恢复、发送、审批、上传或修改设置。', 'code': 'read_only'})
                    return True
                if action == 'notifications':
                    result = {'available': False, 'watching': False, 'notifyOnCompletion': False, 'readOnly': True}
                elif action == 'detail':
                    result = library.timeline(key, 'detail', cursor=value('key'), offset=int(value('offset', '0')), version=value('version'))
                elif action == 'changes':
                    time.sleep(.75)  # Bound polling CPU; no desktop subscription.
                    result = library.timeline(key, 'changes', after=int(value('after', '-1')), epoch=value('epoch'), start=value('start'))
                else:
                    result = library.timeline(key, limit=int(value('limit', '20')), before=value('before') or None)
                    if action is None:
                        result = result['meta']
            else:
                # The original store and owner checks still protect every
                # eligible desktop operation. No source whitelist is relaxed.
                return False
        handler.output(200, result)
    except PermissionError as exc:
        handler.close_connection = True
        handler.output(403, {'error': str(exc)})
    except KeyError:
        handler.close_connection = True
        handler.output(404, {'error': '找不到这个会话'})
    except (HistoryUnavailable, StoreUnavailable, RemoteUnavailable, OSError):
        handler.close_connection = True
        handler.output(409, {'error': '历史日志不可读、已变化或路径不安全；请刷新，或在 Mac 检查原始日志。', 'code': 'history_unavailable'})
    except (ValueError, TypeError) as exc:
        handler.close_connection = True
        handler.output(400, {'error': str(exc) or '历史请求参数无效'})
    return True
