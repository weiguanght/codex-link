"""Authenticated explicit workspace mutations; no generic filesystem writes."""
from urllib.parse import parse_qs, urlsplit
from bridge.create import _runtime_operation, CreationError
from bridge.store import StoreUnavailable
from bridge.remote import RemoteUnavailable
from bridge.accounts import operation
from bridge.model import ordered_turns, async_requests
from bridge.account import AccountError
from bridge.ipc import IPCError
from .session_delete import permanently_delete
from bridge.service import LiveSession


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


@operation
def delete_conversation(bridge, key, backup_root, read_only=False):
    if not read_only:
        bridge.store.get(key)
        session = bridge.session(key, attach=False, background=True)
    else:
        # The HTTP caller has resolved this exact local ID through the history
        # catalog. Never activate a read-only session just to delete its files.
        with bridge.lock:
            session = bridge.live.get(key) or LiveSession(key)
    with session.action_lock:
        with bridge.lock:
            queued = any(k.startswith(key + ':') and v.get('status') in ('queued', 'unknown')
                         for k, v in getattr(bridge, 'submissions', {}).items())
            pending_goal = any(k.startswith(key + ':') and v.get('state') in ('pending', 'sent', 'unknown')
                               for k, v in getattr(bridge, 'goal_commands', {}).items())
            uncertain_action = any(v.get('source') == key and v.get('status') == 'unknown'
                                   for v in getattr(bridge, 'message_actions', {}).values())
        with session.condition:
            state = session.state or {}
            active = session.activating or session.connecting or session.discovering or session.viewers > 0
            running = any(t.get('status') == 'inProgress' for t in ordered_turns(state))
            requests = state.get('requests') or async_requests(state)
            runtime_active = state.get('threadRuntimeStatus', {}).get('type') == 'active'
        if active or running or requests or queued or pending_goal or uncertain_action or runtime_active:
            raise ValueError('会话正在查看、执行或有待确认的操作，请先结束任务并关闭手机详情后再永久删除')
        result = permanently_delete(bridge.codex_home, backup_root, key, confirmed=True)
        with bridge.lock:
            bridge.live.pop(key, None)
            bridge.listed.discard(key)
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
            result = workspace.browse(value('path') or None, max(0, int(value('offset', '0'))), value('q')[:200],
                                      value('sort', 'name'), value('descending') == 'true', value('hidden') == 'true')
        elif not write and path == '/api/workspace/agents':
            result = workspace.agents(value('project'))
        elif write and path in ('/api/workspace/projects', '/api/workspace/preferences', '/api/workspace/archive', '/api/workspace/delete'):
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
            elif path.endswith('/delete'):
                if body.get('confirmed') is not True:
                    raise PermissionError('永久删除需要显式确认')
                row = library.metadata(body.get('id'), body.get('host', 'local'))
                if row['host'] != 'local':
                    raise PermissionError('仅支持永久删除本机会话')
                result = delete_conversation(library.bridge, row['id'], library.bridge.data_dir / 'deletion-backups', read_only=bool(row.get('readOnly')))
                library.catalog.expires = 0
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
