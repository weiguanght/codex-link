#!/usr/bin/env python3
"""Launch the adapter; never changes router/firewall or the original B install."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import uuid
from mac.runtime import DEFAULT_BRIDGE, activate_bridge

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description='codex-link：局域网配对 + IPv4/IPv6 自动连接')
    parser.add_argument('--bridge', type=Path, default=DEFAULT_BRIDGE,
                        help='开发者可选：覆盖内置网关路径；正常使用无需指定')
    parser.add_argument('--check-runtime', action='store_true', help='只检查内置运行时，不启动网关或读取配对数据')
    parser.add_argument('--check-desktop', action='store_true', help='只检查桌面 IPC 握手，不启动网关或打开会话')
    parser.add_argument('--shared-desktop', type=Path, metavar='CHATGPT.APP',
                        help='启动所选新版桌面，并让网关和桌面共用本地 App Server')
    shared_options = parser.add_mutually_exclusive_group()
    shared_options.add_argument('--shared-use-daemon', action='store_true',
                                help='共享模式使用当前 Codex 数据目录已在运行的 App Server daemon')
    shared_options.add_argument('--shared-background', action='store_true',
                                help='为状态栏网关启用共享启动，并等待已打开的桌面退出')
    parser.add_argument('--data', type=Path, default=ROOT / '.local')
    parser.add_argument('--codex-home', type=Path, default=Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))))
    parser.add_argument('--port', type=int, default=18443)
    parser.add_argument('--list-devices', action='store_true')
    parser.add_argument('--revoke', metavar='DEVICE_ID')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error('端口必须为 1–65535')
    if args.shared_desktop and (args.check_desktop or args.check_runtime or args.list_devices or args.revoke):
        parser.error('--shared-desktop 需要单独启动网关')
    if args.shared_use_daemon and not args.shared_desktop:
        parser.error('--shared-use-daemon 需要 --shared-desktop')
    if args.shared_background and not args.shared_desktop:
        parser.error('--shared-background 需要 --shared-desktop')
    if args.check_desktop:
        try:
            activate_bridge(args.bridge)
        except (ValueError, ImportError) as exc:
            parser.error(str(exc))
        from bridge.ipc import IPCError
        from bridge.transport import ipc_endpoint
        from mac.desktop_bridge import DesktopEndpointUnavailable, LocalDesktopIPC
        ipc = LocalDesktopIPC(ipc_endpoint(args.codex_home))
        try:
            ipc.connect()
            print('桌面 IPC 握手成功')
        except DesktopEndpointUnavailable as exc:
            print(f'桌面 IPC 不可用（{exc.reason}）', file=sys.stderr)
            return 1
        except (IPCError, KeyError, TypeError):
            print('桌面 IPC 握手未完成', file=sys.stderr)
            return 1
        finally:
            ipc.close()
        return 0
    if args.check_runtime:
        try:
            runtime = activate_bridge(args.bridge)
            from bridge.service import Bridge
            from bridge.httpd import GatewayServer
            from bridge.notifications import Notifications
            from mac import web_ui
            web_ui.validate()
            web_ui.page(runtime / 'web')
        except (ValueError, ImportError) as exc:
            parser.error(str(exc))
        print('运行时检查通过：', runtime)
        return
    os.umask(0o077)
    args.data.mkdir(parents=True, exist_ok=True, mode=0o700)
    if args.list_devices:
        path = args.data / 'devices.json'
        rows = json.loads(path.read_text()) if path.exists() else {}
        for identifier, row in rows.items():
            state = '已撤销' if (args.data / 'revoked' / identifier).exists() else '已授权'
            print(identifier, row['name'], state)
        return
    if args.revoke:
        identifier = str(uuid.UUID(args.revoke))
        (args.data / 'revoked').mkdir(exist_ok=True, mode=0o700)
        (args.data / 'revoked' / identifier).touch(mode=0o600)
        print('已撤销设备；新请求立即失效。已开始的响应可能继续到结束。')
        return
    if sys.platform != 'darwin':
        parser.error('此启动器需要 macOS（Bonjour、网卡发现及首次确认弹窗）')
    try:
        runtime = activate_bridge(args.bridge)
    except ValueError as exc:
        parser.error(str(exc))
    # Prevent simultaneous writers to this identity/device/session directory.
    lock = open(args.data / 'run.lock', 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error('这个数据目录已有网关在运行')
    from mac.desktop_bridge import DesktopBridge
    from bridge.notifications import Notifications
    from mac.network import discover, origin
    from mac.server import LinkServer

    bridge = None
    desktop = None
    waiting_for_desktop = None
    server = None
    publisher = None
    notifications = None
    stopped = threading.Event()

    def stop(*_):
        if not stopped.is_set():
            stopped.set()
            if server is not None:
                threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        if args.shared_desktop:
            from bridge.ipc import IPCError
            from mac.shared_bridge import SharedDesktopBridge
            from mac.shared_launch import SharedDesktop
            try:
                selected = SharedDesktop(args.shared_desktop, args.codex_home, args.data, args.shared_use_daemon,
                                         prefer_daemon=args.shared_background)
                if args.shared_background and selected.desktop_in_use() and not selected.attach_existing():
                    waiting_for_desktop = selected
                    print('桌面已打开。网关将在桌面退出后切换到共享模式。', flush=True)
                else:
                    desktop = selected
                    if desktop.attached_pid is None:
                        desktop.start(stopped.is_set)
                    else:
                        print('已重新连接正在运行的共享桌面；无需退出桌面或重新配对。', flush=True)
                    if stopped.is_set():
                        return
                    bridge = SharedDesktopBridge(desktop.home, args.data / 'bridge', desktop)
                    bridge.ipc.connect()
            except (IPCError, OSError, ValueError, subprocess.SubprocessError) as exc:
                parser.error(str(exc))
        if stopped.is_set():
            return
        if bridge is None:
            bridge = DesktopBridge(args.codex_home, args.data / 'bridge',
                                   waiting_for_shared_desktop=waiting_for_desktop is not None)
        server = LinkServer(('::', args.port), bridge, runtime / 'web', args.data, discover())
        notifications = Notifications(bridge, args.data / 'bridge', origins=lambda: list(server.origins))
        server.notifications = notifications
        notifications.start()
        # TXT only publishes public identity, never credentials or cookies.
        publisher = subprocess.Popen(['/usr/bin/dns-sd', '-R', server.identity['name'] + ' Codex',
                                      '_codexlink._tcp', 'local.', str(args.port), 'v=1',
                                      'id=' + server.identity['id'], 'pin=' + server.pin],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def refresh():
            while not stopped.wait(30):
                try:
                    server.refresh(discover())
                except (OSError, subprocess.SubprocessError):
                    print('网卡刷新失败，暂保留上次地址', flush=True)
                if publisher.poll() is not None:
                    print('Bonjour 广播已退出；请重启启动器', flush=True)
                    return
        threading.Thread(target=refresh, daemon=True).start()
        if desktop:
            def watch_desktop():
                while not stopped.wait(1):
                    if not desktop.running():
                        print('共享桌面或 App Server 已退出。请重新启动共享网关。', flush=True)
                        stop()
                        return
            threading.Thread(target=watch_desktop, daemon=True).start()
        if waiting_for_desktop:
            def watch_for_desktop_exit():
                while not stopped.wait(3):
                    if waiting_for_desktop.ready_to_switch():
                        message = ('已检测到共享桌面，状态栏将重新连接共享网关。'
                                   if waiting_for_desktop.attached_pid is not None
                                   else '桌面已退出，状态栏将重启共享网关。')
                        print(message, flush=True)
                        stop()
                        return
            threading.Thread(target=watch_for_desktop_exit, daemon=True).start()
        if stopped.is_set():
            return
        print('codex-link 已启动；在同一 Wi-Fi 打开 iOS App，首次在 Mac 点“允许”。', flush=True)
        print('HTTPS 端口：', args.port, '；不修改系统或路由器防火墙。', flush=True)
        for ip in server.interfaces.ipv4 + server.interfaces.ipv6:
            print('地址：', origin(ip, args.port), flush=True)
        if not server.interfaces.ipv6:
            print('当前未发现公网 IPv6；本次只能局域网连接。', flush=True)
        server.serve_forever()
    finally:
        stopped.set()
        if publisher:
            publisher.terminate()
            publisher.wait(timeout=5)
        if notifications:
            notifications.close()
        if server:
            server.server_close()
        if bridge:
            bridge.close()
        if desktop:
            desktop.close()
        lock.close()


if __name__ == '__main__':
    sys.exit(main())
