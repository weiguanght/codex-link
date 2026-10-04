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
    parser.add_argument('--data', type=Path, default=ROOT / '.local')
    parser.add_argument('--codex-home', type=Path, default=Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))))
    parser.add_argument('--port', type=int, default=18443)
    parser.add_argument('--list-devices', action='store_true')
    parser.add_argument('--revoke', metavar='DEVICE_ID')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error('端口必须为 1–65535')
    if args.check_runtime:
        try:
            runtime = activate_bridge(args.bridge)
            from bridge.service import Bridge
            from bridge.httpd import GatewayServer
            from bridge.notifications import Notifications
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
    from bridge.service import Bridge
    from bridge.notifications import Notifications
    from mac.network import discover, origin
    from mac.server import LinkServer

    bridge = Bridge(args.codex_home, args.data / 'bridge')
    server = None
    publisher = None
    notifications = None
    stopped = threading.Event()
    try:
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
        def stop(*_):
            stopped.set()
            threading.Thread(target=server.shutdown, daemon=True).start()
        signal.signal(signal.SIGINT, stop)
        signal.signal(signal.SIGTERM, stop)
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
        bridge.close()
        lock.close()


if __name__ == '__main__':
    main()
