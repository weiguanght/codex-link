"""Project the shared App Server's thread events onto the gateway timeline."""
import logging
import re
import unicodedata
import uuid

from bridge.accounts import operation
from bridge.create import CreationError, persist_empty_metadata
from bridge.ipc import IPCError
from bridge.remote import AppHosts
from bridge.service import Bridge
from bridge.timeline import timestamp_ms
from .shared_rpc import RPCRejected, SharedRPC

LOG = logging.getLogger(__name__)
DELTAS = {
    'item/agentMessage/delta': 'text',
    'item/commandExecution/outputDelta': 'aggregatedOutput',
    'item/plan/delta': 'text',
}

class LocalHosts(AppHosts):
    def hosts(self):
        return {}


def as_turn(raw):
    return {**raw, 'turnId': raw['id'], 'items': list(raw['items']),
            'turnStartedAtMs': timestamp_ms(raw.get('startedAt')),
            'turnCompletedAtMs': timestamp_ms(raw.get('completedAt'))}


def thread_state(thread, history):
    return {
        'id': thread['id'], 'title': thread.get('name') or thread.get('preview'),
        'cwd': thread.get('cwd'), 'latestModel': thread.get('model'),
        'latestReasoningEffort': thread.get('reasoningEffort'),
        'modelProvider': thread.get('modelProvider'),
        'threadRuntimeStatus': thread.get('status') or {'type': 'notLoaded'},
        'turns': [as_turn(row) for row in reversed(history['data'])],
        'turnsPagination': {'hasLoadedOldest': not history.get('nextCursor')},
    }


def update_turn(state, raw):
    turn = as_turn(raw)
    for index, prior in enumerate(state['turns']):
        if prior['turnId'] == turn['turnId']:
            if prior['status'] != 'inProgress' and turn['status'] == 'inProgress':
                return
            # Completion can carry just the assistant output. Keep user and
            # tool items already delivered separately by item notifications.
            merged = {item['id']: item for item in prior['items']}
            merged.update({item['id']: item for item in turn['items']})
            turn['items'] = list(merged.values())
            state['turns'][index] = turn
            return
    state['turns'].append(turn)


def update_event(state, method, params):
    if method == 'thread/status/changed':
        state['threadRuntimeStatus'] = params['status']
    elif method == 'thread/name/updated':
        state['title'] = params.get('threadName')
    elif method == 'thread/settings/updated':
        settings = params['threadSettings']
        state['latestThreadSettings'] = settings
        if 'model' in settings:
            state['latestModel'] = settings['model']
        if 'effort' in settings:
            state['latestReasoningEffort'] = settings['effort']
    elif method in ('turn/started', 'turn/completed'):
        update_turn(state, params['turn'])
    elif method in ('item/started', 'item/completed', 'turn/diff/updated') or method in DELTAS:
        turn = next((row for row in reversed(state['turns']) if row['turnId'] == params.get('turnId')), None)
        if turn is None or turn['status'] != 'inProgress':
            return False
        if method == 'turn/diff/updated':
            turn['diff'] = params.get('diff')
            return True
        item_id = params.get('itemId') or params['item']['id']
        items = turn['items']
        index = next((i for i, row in enumerate(items) if row['id'] == item_id), None)
        if method in DELTAS:
            if index is None:
                return False
            field = DELTAS[method]
            item = items[index]
            item[field] = (item.get(field) or '') + params['delta']
        elif index is None:
            items.append(params['item'])
        else:
            items[index] = params['item']
    else:
        return False
    return True


class SharedDesktopBridge(Bridge):
    shared_desktop = True

    def __init__(self, codex_home, data_dir, desktop):
        super().__init__(codex_home, data_dir, codex_bin=desktop.runtime)
        self.hosts = LocalHosts(codex_home)
        self.ipc = SharedRPC(desktop.socket, codex_home, self._shared_event,
                             self._disconnected, desktop.running)

    def _shared_event(self, message):
        # Server-initiated approvals and input requests are handled in the GUI.
        if 'id' in message:
            return
        method, params = message['method'], message.get('params') or {}
        with self.lock:
            session = self.live.get(params.get('threadId'))
        if session is None:
            return
        with session.condition:
            if session.discovering:
                # The snapshot may already include these chunks. Complete
                # items carry their full text and can safely be applied twice.
                if method not in DELTAS:
                    session.shared_events.append((method, params))
            elif session.connected:
                if method in ('thread/closed', 'thread/archived', 'thread/deleted'):
                    self._invalidate(session, '会话已关闭、归档或删除。')
                elif update_event(session.state, method, params):
                    session.changed()

    def _snapshot(self, thread_id, *, resume=False, limit=20):
        params = {'threadId': thread_id}
        if resume:
            reply = self.ipc.request('thread/resume', {**params, 'excludeTurns': True})
        else:
            reply = self.ipc.request('thread/read', params)
        try:
            history = self.ipc.request('thread/turns/list', {
                **params, 'limit': limit, 'itemsView': 'full', 'sortDirection': 'desc',
            })
        except RPCRejected as exc:
            # The verified runtime creates metadata before the first turn index.
            if not exc.empty_history or reply['thread'].get('preview'):
                raise
            history = {'data': []}
        state = thread_state(reply['thread'], history)
        if resume:
            state['latestModel'] = reply.get('model') or state['latestModel']
            state['latestReasoningEffort'] = reply.get('reasoningEffort') or state['latestReasoningEffort']
            state['latestThreadSettings'] = {key: reply[key] for key in ('serviceTier',) if key in reply}
        return state

    def _attach(self, session, timeout=1.5):
        # List and notification observers use timeout=0. Opening a chat is the
        # first operation that requests its history and attaches a subscription.
        if timeout:
            self._subscribe(session, explicit=False)

    def _subscribe(self, session, *, explicit):
        with session.attach_lock:
            if session.connected or self.closed.is_set():
                return
            with session.condition:
                session.discovering = True
                session.shared_events = []
            try:
                self.ipc.connect()
                connection = self.ipc.socket
                params = {'threadId': session.id}
                thread = self.ipc.request('thread/read', params)['thread']
                if thread.get('status', {}).get('type') == 'notLoaded' and not explicit:
                    return
                state = self._snapshot(session.id, resume=True)
                with session.condition:
                    if self.ipc.socket is not connection or self.closed.is_set():
                        raise IPCError('共享 App Server 已断开。')
                    for method, payload in session.shared_events:
                        if method in ('thread/closed', 'thread/archived', 'thread/deleted'):
                            raise IPCError('会话已关闭、归档或删除。')
                        update_event(state, method, payload)
                    session.state = state
                    session.connected = True
                    session.activity_only = False
                    session.owner = self.ipc.client_id
                    session.error = None
            except IPCError as exc:
                with session.condition:
                    session.error = str(exc)
                if explicit:
                    raise
            finally:
                with session.condition:
                    session.discovering = False
                    session.shared_events = []
                    session.changed()

    @operation
    def activate(self, thread_id):
        session = self.session(thread_id, attach=False, background=True)
        self._subscribe(session, explicit=True)
        return session

    @operation
    def _call(self, session, method, params, timeout=30):
        args = {'threadId': session.id}
        if self.accounts.index.get('activeId'):
            row = self.accounts.row(self.accounts.index['activeId'])
            allowed = ('openai',) if row['kind'] == 'chatgpt' else ('openai', 'bridge_api')
            if session.view().get('provider') not in allowed:
                raise ValueError('此聊天保留了原提供商，请切回对应接入或新建聊天')
        if method == 'thread-follower-start-turn':
            payload = params['turnStart']
            request = dict(payload['request'])
            attachments = payload['context'].get('fileAttachments', [])
            request['input'] = self._inputs(request['input'], attachments)
            method = 'turn/start'
            args.update(request)
        elif method == 'thread-follower-steer-turn':
            with session.condition:
                current = next((t for t in reversed(session.state['turns']) if t['status'] == 'inProgress'), None)
            if current is None:
                raise IPCError('未取得当前任务的标识，请刷新后再补充消息。')
            method = 'turn/steer'
            attachments = params['restoreMessage']['context'].get('fileAttachments', [])
            args.update(expectedTurnId=current['turnId'], clientUserMessageId=params['clientUserMessageId'],
                        input=self._inputs(params['input'], attachments))
        elif method == 'thread-follower-interrupt-turn':
            method = 'turn/interrupt'
            args['turnId'] = params['expectedTurnId']
        elif method == 'thread-follower-update-thread-settings':
            method = 'thread/settings/update'
            args.update(params['threadSettings'])
        else:
            raise IPCError('此操作请在 Mac 桌面端完成。')
        result = self.ipc.request(method, args, timeout=timeout)
        # An empty update response signals acceptance. Confirmation comes from
        # thread/settings/updated, as it does for the legacy snapshot stream.
        return {'applied': True} if method == 'thread/settings/update' else result

    @staticmethod
    def _inputs(inputs, attachments):
        paths = {row['path'] for row in inputs if row['type'] == 'localImage'}
        files = [row['path'] for row in attachments if row['path'] not in paths]
        if files:
            refs = '\n'.join('- ' + name for name in files)
            text = f'# Files mentioned by the user:\n{refs}\n\n## My request:\n' + inputs[0]['text']
            return [dict(inputs[0], text=text), *inputs[1:]]
        return inputs

    @operation
    def send(self, thread_id, text, submission_id, mode='send', skills=None, **options):
        if options.get('work_mode') not in (None, 'default'):
            raise ValueError('当前共享桌面模式的计划与目标操作请在 Mac 完成。')
        # The shipped iOS composer explicitly sends "default" for normal
        # messages. Omit its desktop-only collaboration override on this wire.
        options.pop('work_mode', None)
        session = self._target(thread_id)
        with session.action_lock:
            with session.condition:
                if not session.connected or session.state['threadRuntimeStatus']['type'] not in ('idle', 'active'):
                    raise IPCError('尚未取得桌面任务状态，请刷新后再发送。')
            return super().send(thread_id, text, submission_id, mode, skills, **options)

    def _goal_runtime_available(self):
        return False

    def _send_queued(self, session, key, entry):
        if entry.get('workMode') in (None, 'default') and not entry.get('goalActivation'):
            return super()._send_queued(session, key, entry)

    def _goal_call(self, method, *args):
        raise IPCError('共享桌面模式请在 Mac 管理目标。')

    def respond(self, thread_id, request_id, response):
        raise IPCError('共享桌面模式请在 Mac 处理审批和问题。')

    def message_action(self, thread_id, body):
        raise IPCError('共享桌面模式请在 Mac 编辑消息或创建分支。')

    def full_history(self, thread_id):
        session = self.session(thread_id, background=True, attach=False)
        saved = self.store.history(thread_id)
        with session.condition:
            session.set_history(saved)
        return {'ok': True}

    @operation
    def rename(self, thread_id, title):
        uuid.UUID(thread_id)
        if not isinstance(title, str) or not title.strip() or len(title) > 120 or any(
                unicodedata.category(char) in ('Cc', 'Zl', 'Zp') for char in title):
            raise ValueError('聊天名称需为 1–120 个字符，不能包含换行或控制字符')
        self.store.get(thread_id)
        self.ipc.request('thread/name/set', {'threadId': thread_id, 'name': title.strip()})
        return {'id': thread_id, 'host': 'local', 'title': title.strip()}

    def archive_shared(self, thread_id, archived):
        state = self.ipc.request('thread/read', {'threadId': thread_id})['thread']['status']
        if state.get('type') not in ('idle', 'notLoaded'):
            raise ValueError('请先在桌面确认任务结束后再归档。')
        return self.ipc.request('thread/archive' if archived else 'thread/unarchive',
                                {'threadId': thread_id})

    @operation
    def create_chat(self, project_key, title, request_id, settings=None):
        if not isinstance(request_id, str):
            raise ValueError('创建请求标识无效')
        uuid.UUID(request_id)
        if title is not None and (not isinstance(title, str) or len(title) > 120 or any(
                unicodedata.category(char) in ('Cc', 'Zl', 'Zp') for char in title)):
            raise ValueError('聊天名称需为 1–120 个字符，不能包含换行或控制字符')
        title = (title or '').strip()
        project_key = project_key or None
        project = next((row for row in self.hosts.projects() if row['key'] == project_key), None) if project_key else None
        if project_key and (project is None or project['host'] != 'local'):
            raise ValueError('请选择此 Mac 上的项目')
        settings = {} if settings is None else settings
        if not isinstance(settings, dict) or set(settings) - {'model', 'effort', 'approvalPolicy', 'sandbox'}:
            raise ValueError('新会话设置无效')
        settings = {key: value for key, value in settings.items() if value not in (None, '')}
        for key in ('model', 'effort'):
            if key in settings and (not isinstance(settings[key], str) or
                    not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_./:@+-]{0,199}', settings[key])):
                raise ValueError('新会话模型或推理强度无效')
        if ('approvalPolicy' in settings and settings['approvalPolicy'] not in ('untrusted', 'on-request', 'on-failure', 'never')
                or 'sandbox' in settings and settings['sandbox'] not in ('read-only', 'workspace-write', 'danger-full-access')):
            raise ValueError('新会话权限无效')
        identity = {'project': project_key, 'title': title, 'settings': settings, 'host': 'local'}
        with self.create_lock:
            entry = self.creations.get(request_id)
            if entry is not None:
                if any(entry.get(key) != value for key, value in identity.items()):
                    raise ValueError('同一创建请求不能用于不同内容')
                if 'id' not in entry:
                    raise CreationError('上次创建结果尚不确定，请先刷新聊天列表。')
            else:
                self.ipc.connect()
                self.creations[request_id] = entry = identity
                self._save_creations()
                params = {'cwd': project['cwd'] if project else str(self.codex_home.parent),
                          **{key: settings[key] for key in ('model', 'approvalPolicy', 'sandbox') if key in settings}}
                if 'effort' in settings:
                    params['config'] = {'model_reasoning_effort': settings['effort']}
                reply = self.ipc.request('thread/start', params)
                entry['id'] = reply['thread']['id']
                uuid.UUID(entry['id'])
                self._save_creations()
            thread_id = entry['id']
            if not entry.get('materialized'):
                try:
                    self.ipc.request('thread/read', {'threadId': thread_id, 'includeTurns': True})
                except RPCRejected as exc:
                    if not exc.empty_history:
                        raise
                    persist_empty_metadata(self.ipc.request, thread_id)
                entry['materialized'] = True
                self._save_creations()
            if title and not entry.get('named'):
                self.ipc.request('thread/name/set', {'threadId': thread_id, 'name': title})
                entry['named'] = True
                self._save_creations()
        self.activate(thread_id)
        return {'id': thread_id, 'host': 'local', 'opened': True, 'message': '已创建并连接共享桌面会话'}
