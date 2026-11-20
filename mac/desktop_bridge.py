"""Compatibility for verified desktop IPC revisions, outside the vendor copy."""
import errno
import logging
import subprocess

from bridge.accounts import operation
from bridge.desktop_app import DesktopApp
from bridge.ipc import DesktopIPC, IPCError
from bridge.model import ordered_turns
from bridge.service import Bridge
from .settings_rpc import SettingsRPC

LOG = logging.getLogger(__name__)
STREAM_VERSIONS = (11, 13)


class DesktopEndpointUnavailable(IPCError):
    def __init__(self, reason):
        self.reason = reason
        super().__init__('Mac 网关已连接，桌面实时接口不可用。可以阅读已保存的历史。请在 Mac 打开 Codex 后重试。')


class LocalDesktopIPC(DesktopIPC):
    def connect(self):
        try:
            super().connect()
        except IPCError as exc:
            cause = exc.__cause__
            reason = {
                errno.ENOENT: 'socket_missing',
                errno.ECONNREFUSED: 'socket_refused',
            }.get(cause.errno) if isinstance(cause, OSError) else None
            if reason:
                raise DesktopEndpointUnavailable(reason) from exc
            raise


class DesktopBridge(Bridge):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.ipc = LocalDesktopIPC(self.ipc.path, self._event, self._disconnected)

    def _desktop_running(self):
        executable = DesktopApp.discover(self.catalog_reader.executable)
        if not executable:
            return False
        try:
            return bool(DesktopApp(executable, self.codex_home).processes())
        except (OSError, subprocess.SubprocessError):
            return False

    @operation
    def activate(self, thread_id):
        session = self.session(thread_id, attach=False, background=True)
        if not session.connected and not self.ipc.client_id:
            try:
                self.ipc.connect()
            except DesktopEndpointUnavailable as exc:
                if self._desktop_running():
                    LOG.warning('Running Codex Desktop IPC unavailable (%s)', exc.reason)
                    raise
                # On older builds the deep link can start the closed desktop.
            except IPCError:
                # Let the existing activation handle IPC startup and recovery.
                pass
        return super().activate(thread_id)

    def _creation_model_settings(self, entry, session):
        with SettingsRPC(self.codex_home, self.catalog_reader.executable) as rpc:
            config = rpc.request('config/read', {'cwd': session.state['cwd'], 'includeLayers': False})['config']
            models, cursor = [], None
            for _ in range(10):
                page = rpc.request('model/list', {'cursor': cursor, 'limit': 100, 'includeHidden': False})
                models.extend(page.get('data', []))
                cursor = page.get('nextCursor')
                if not cursor:
                    break
        selected = entry.get('settings', {})
        default = next((row for row in models if row.get('isDefault')), {})
        model = selected.get('model') or config.get('model') or default.get('model') or default.get('id')
        row = next((row for row in models if (row.get('model') or row.get('id')) == model), {})
        effort = selected.get('effort') or config.get('model_reasoning_effort') or row.get('defaultReasoningEffort')
        return {'model': model, 'effort': effort}

    @operation
    def create_chat(self, project_key, title, request_id, settings=None):
        result = super().create_chat(project_key, title, request_id, settings)
        if result['host'] != 'local':
            return result
        with self.create_lock:
            entry = self.creations[request_id]
            if entry.get('desktopSettingsApplied'):
                return result
            session = self._target(result['id'])
            with session.action_lock:
                # Reopening an older creation must not reset settings chosen later.
                with session.condition:
                    if ordered_turns(session.state):
                        return result
                desired = entry.get('desktopSettings') or self._creation_model_settings(entry, session)
                entry['desktopSettings'] = desired
                self._save_creations()
                # thread/start settings do not survive the desktop taking ownership
                # of an empty rollout. Confirm them on its owner before iOS can send.
                applied = self.settings(session.id, desired['model'], desired['effort'])
                if not applied.get('confirmed'):
                    raise IPCError('桌面尚未确认新会话模型和推理强度，请重试创建；不会重复创建会话。')
                entry['desktopSettingsApplied'] = True
                self._save_creations()
            return result

    def _event(self, message):
        if message.get('method') == 'thread-stream-state-changed':
            version = message.get('version')
            if version not in STREAM_VERSIONS:
                LOG.warning('Unsupported desktop stream version %r; supported versions: %s',
                            version, STREAM_VERSIONS)
            elif version == 13:
                # Verified against desktop 26.1111.21308: snapshot, canonical
                # turnHistory and revisioned patches retain the v11 envelope.
                # Only adapt the upstream version gate; preserve its owner,
                # host, revision and patch validation, and all write versions.
                message = dict(message, version=11)
        return super()._event(message)
