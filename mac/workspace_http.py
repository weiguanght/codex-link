"""Authenticated explicit workspace mutations; no generic filesystem writes."""
from urllib.parse import parse_qs, urlsplit
from bridge.create import _runtime_operation, CreationError
from bridge.store import StoreUnavailable
from bridge.remote import RemoteUnavailable
from bridge.accounts import operation
from bridge.model import ordered_turns, async_requests
from bridge.account import AccountError
from bridge.ipc import IPCError


@operation
def archive(bridge, key, archived):
    # Retain the upstream source gate. No resume, turn/start, stop, or raw DB
    # mutation is used. The short-lived app-server performs one lifecycle RPC.
    bridge.store.get(key)
    session = bridge.session(key, attach=False, background=True)
    with session.action_lock:
        with bridge.lock:
            queued = any(k.startswith(key + ':') and v.get('status') in ('queued', 'unknown') for k, v in getattr(bridge, 'submissions', {}).items())
        if session.activating or queued or async_requests(session.state or {}) or any(t.get('status') == 'inProgress' for t in ordered_turns(session.state or {})):
            raise ValueError('会话正在执行，请先在对话中确认任务结束后再归档')
        result = _runtime_operation(bridge.catalog_reader.executable, bridge.codex_home, str(bridge.codex_home),
            lambda request: request('thread/archive' if archived else 'thread/unarchive', {'threadId': key}))
    return result


def handle(handler, write, path):
    workspace = handler.server.workspace
    library = handler.server.reading
    if workspace is None or not (path.startswith('/api/workspace/') or path == '/api/projects'):
        return False
    try:
        handler.check_request(write)
        if not handler.authorized(write):
            return True
        query = parse_qs(urlsplit(handler.path).query)
        value = lambda key, default='': query.get(key, [default])[0]
        if not write and path == '/api/projects':
            result = {'projects': workspace.projects()}
        elif not write and path == '/api/workspace/directories':
            result = workspace.browse(value('path') or None, max(0, int(value('offset', '0'))), value('q')[:200])
        elif not write and path == '/api/workspace/agents':
            result = workspace.agents(value('project'))
        elif write and path in ('/api/workspace/projects', '/api/workspace/preferences', '/api/workspace/archive'):
            body = handler.read_json()
            if not isinstance(body, dict):
                raise ValueError('请求格式无效')
            if path.endswith('/projects'):
                if body.get('action') == 'create':
                    result = {'project': workspace.create(body)}
                elif body.get('action') == 'update':
                    result = {'project': workspace.update_project(body.get('key'), body.get('changes', {}))}
                else:
                    raise ValueError('未知项目操作')
            elif path.endswith('/preferences'):
                refs = body.get('sessions')
                if not isinstance(refs, list) or not 1 <= len(refs) <= 100:
                    raise ValueError('一次请选择 1–100 条会话')
                keys = []
                for ref in refs:
                    row = library.metadata(ref['id'], ref.get('host', 'local'))
                    keys.append(row['host'] + '|' + row['id'])
                workspace.preferences(keys, body.get('changes', {}))
                result = {'ok': True, 'count': len(keys)}
            else:
                if body.get('confirmed') is not True or type(body.get('archived')) is not bool:
                    raise ValueError('请确认归档／取消归档操作')
                row = library.metadata(body.get('id'), body.get('host', 'local'))
                if row.get('readOnly') or row['host'] != 'local':
                    raise PermissionError('仅本机桌面会话支持归档；其他历史可使用“隐藏”整理列表')
                archive(library.bridge, row['id'], body['archived'])
                library.catalog.expires = 0
                result = {'ok': True, 'archived': body['archived']}
        else:
            handler.output(404, {'error': '接口不存在'})
            return True
        handler.output(200, result)
    except PermissionError as exc:
        handler.close_connection = True
        handler.output(403, {'error': str(exc)})
    except (KeyError, FileNotFoundError):
        handler.close_connection = True
        handler.output(404, {'error': '项目、会话或 AGENTS.md 不存在'})
    except (ValueError, TypeError, AttributeError) as exc:
        handler.close_connection = True
        handler.output(400, {'error': str(exc)})
    except (CreationError, StoreUnavailable, RemoteUnavailable, AccountError, IPCError, OSError) as exc:
        handler.close_connection = True
        handler.output(409, {'error': '操作未确认，请刷新列表检查后再决定是否重试。' + str(exc)})
    return True
