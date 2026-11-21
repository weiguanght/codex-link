"""Launch the selected app and its bundled runtime as a single local session."""
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import time

from bridge.desktop_app import DesktopApp
from bridge.ipc import IPCError
from .shared_rpc import private_socket, unix_connect


class SharedDesktop:
    def __init__(self, bundle, home, data, use_daemon=False, prefer_daemon=False):
        self.bundle, self.home = bundle.expanduser().resolve(), home.expanduser().resolve()
        self.data = data
        self.use_daemon = use_daemon
        self.prefer_daemon = prefer_daemon
        self.control = self.home / 'app-server-control/app-server-control.sock'
        try:
            info = plistlib.loads((self.bundle / 'Contents/Info.plist').read_bytes())
            self.gui = self.bundle / 'Contents/MacOS' / info['CFBundleExecutable']
        except (OSError, KeyError, ValueError) as exc:
            raise ValueError('无法读取所选 ChatGPT.app。') from exc
        self.runtime = self.bundle / 'Contents/Resources/codex-cli/bin/codex'
        DesktopApp(self.gui, self.home).validate(self.runtime)
        if not os.access(self.runtime, os.X_OK):
            raise ValueError('所选 ChatGPT.app 缺少内置 Codex 运行时。')
        self.server = self.desktop = None

    def desktop_in_use(self):
        candidates = {self.gui, Path('/Applications/ChatGPT.app/Contents/MacOS/ChatGPT')}
        return (self.home == (Path.home() / '.codex').resolve()
                and any(DesktopApp(path, self.home).processes() for path in candidates))

    def start(self, stopping=lambda: False):
        profile = os.environ.get('CODEX_ELECTRON_USER_DATA_PATH')
        if not profile and self.home != (Path.home() / '.codex').resolve():
            raise ValueError('独立 Codex 数据目录需要同时指定独立的 CODEX_ELECTRON_USER_DATA_PATH。')
        if self.desktop_in_use():
            raise ValueError('请先在 Mac 退出已打开的 Codex 桌面，再启动共享模式。')
        self.home.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.control.exists() and not (self.use_daemon or self.prefer_daemon):
            resolved = private_socket(self.control)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.settimeout(1)
                try:
                    sock.connect(str(resolved))
                except ConnectionRefusedError:
                    pass
                else:
                    raise ValueError('该 Codex 数据目录已有 App Server 在运行。可以加 --shared-use-daemon 共用它。')
        env = {**os.environ, 'CODEX_HOME': str(self.home)}
        env.pop('CODEX_APP_SERVER_FORCE_CLI', None)
        env.pop('CODEX_APP_SERVER_WS_URL', None)
        if self.use_daemon or self.prefer_daemon:
            try:
                self.socket = private_socket(self.control)
                with unix_connect(self.socket):
                    pass
                self.use_daemon = True
            except (FileNotFoundError, ConnectionRefusedError) as exc:
                if self.use_daemon:
                    raise IPCError('没有可用的本地 App Server daemon。') from exc
            except (OSError, TimeoutError) as exc:
                raise IPCError('没有可用的本地 App Server daemon。') from exc
        if not self.use_daemon and not stopping():
            self._start_server(env, stopping)
        if stopping():
            return
        env['CODEX_APP_SERVER_WS_URL'] = f'ws+unix://localhost{self.socket}:/rpc'
        args = [str(self.gui)]
        if profile:
            args.append('--user-data-dir=' + str(Path(profile).expanduser().resolve()))
        log_path = self.data / 'shared-desktop.log'
        with log_path.open('ab') as log:
            start_offset = log.tell()
            self.desktop = subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL,
                stdout=log, stderr=log, start_new_session=True)
        # Confirm this desktop instance adopted the shared transport before
        # exposing the gateway, including when Electron hands off to another app.
        with log_path.open('rb') as log:
            log.seek(start_offset)
            deadline = time.monotonic() + 25
            local_transport = False
            while not stopping() and self.running() and time.monotonic() < deadline:
                for line in log:
                    if b'Starting app-server connection hostId=local' in line:
                        local_transport = b'transport=websocket' in line
                    if (local_transport and b'initialize_handshake_result' in line
                            and b'outcome=success transportKind=websocket' in line):
                        return
                time.sleep(.1)
        if not stopping():
            raise IPCError('新版桌面未连接共享 App Server，请查看 shared-desktop.log。')

    def _start_server(self, env, stopping):
        with (self.data / 'shared-app-server.log').open('ab') as log:
            self.server = subprocess.Popen([str(self.runtime), 'app-server', '--listen', 'unix://'],
                cwd=self.home, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                start_new_session=True)
        deadline = time.monotonic() + 10
        while not stopping() and self.server.poll() is None and time.monotonic() < deadline:
            try:
                with unix_connect(self.control):
                    self.socket = private_socket(self.control)
                return
            except OSError:
                time.sleep(.1)
        if not stopping():
            raise IPCError('共享 App Server 启动失败，请查看 shared-app-server.log。')

    def running(self):
        return (self.desktop is not None and self.desktop.poll() is None
                and (self.use_daemon or (self.server is not None and self.server.poll() is None)))

    def close(self):
        for process in (self.desktop, self.server):
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
