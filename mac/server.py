"""TLS listener reusing upstream HTTP/SSE, CSRF and Codex IPC unchanged."""
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import threading
import uuid
from urllib.parse import urlsplit

from bridge.auth import Auth
from bridge.httpd import GatewayServer, Handler
from .devices import Devices, identity, save_private
from .network import origin


def certificate(directory):
    directory = Path(directory)
    cert, key = directory / 'server.crt', directory / 'server.key'
    if cert.exists() != key.exists():
        raise RuntimeError('TLS 证书或私钥缺失；请从备份恢复，不能静默更换已配对的身份')
    if not cert.exists():
        subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-sha256',
                        '-nodes', '-days', '3650', '-subj', '/CN=Codex Link Local Identity',
                        '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    key.chmod(0o600)
    cert.chmod(0o600)
    der = ssl.PEM_cert_to_DER_cert(cert.read_text())
    pin = hashlib.sha256(der).hexdigest()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    return context, pin


class DeviceAuth(Auth):
    def __init__(self, directory, devices):
        self.devices = devices
        super().__init__({'mode': 'device', 'sessionHours': 12}, directory)

    def login(self, *args, **kwargs):
        raise PermissionError('请使用已配对的 iOS 客户端')

    def get(self, token, client=None, user_agent=''):
        result = super().get(token, client, user_agent)
        if result and self.devices.active(result.get('deviceId', '')):
            return result
        return None

    def issue(self, value, client):
        identifier, _ = identity(value)
        if self.devices.state(value) != 'approved':
            raise PermissionError('设备尚未配对或已撤销')
        with self.lock:
            # Bound the number of outstanding web sessions per device.
            prior = sorted(((k, s) for k, s in self.sessions.items() if s.get('deviceId') == identifier),
                           key=lambda row: row[1]['created'])
            for key, _ in prior[:-3]:
                self.sessions.pop(key, None)
            token, session = self.new_session(client['ip'], 'CodexLink/iOS', client)
            session['deviceId'] = identifier
            self.persist()
            return token


class LinkHandler(Handler):
    def client(self):
        # Direct TLS only. Never honor spoofed X-Forwarded-For / CF headers.
        ip = ipaddress.ip_address(self.client_address[0])
        ip = getattr(ip, 'ipv4_mapped', None) or ip
        return {'ip': str(ip), 'peer': str(ip), 'source': 'direct'}

    def handle_method(self, write):
        path = urlsplit(self.path).path
        if path in ('/api/login', '/api/pair'):
            self.close_connection = True
            return self.output(403, {'error': '此入口仅支持设备配对，不接受密码或二维码登录'})
        if not path.startswith('/link/'):
            return super().handle_method(write)
        try:
            # Native requests have no Origin. Reject browser-initiated pairing,
            # duplicate Hosts and unrecognized addresses (DNS rebinding).
            self.check_request(False)
            if self.headers.get('Origin') or self.headers.get('X-Codex-Link') != '1':
                raise PermissionError('仅允许原生客户端设备请求')
            if path == '/link/identity' and not write:
                return self.output(200, {'serverId': self.server.identity['id'], 'protocol': 1})
            if not write or path not in ('/link/pair', '/link/session', '/link/status'):
                return self.output(404, {'error': '接口不存在'})
            # The original body reader enforces JSON, lengths, and no chunking.
            if int(self.headers.get('Content-Length', '0')) > 2048:
                raise ValueError('设备请求过大')
            value = self.read_json()
            identity(value)
            if path == '/link/pair':
                if not self.server.interfaces.local_peer(self.client()['ip']):
                    raise PermissionError('首次配对仅允许 Mac 所在的 IPv4 局域网')
                state = self.server.devices.pair(value, self.client()['ip'])
                return self.output(202 if state == 'pending' else 200, {'state': state})
            state = self.server.devices.state(value)
            if state != 'approved':
                return self.output(202 if state == 'pending' else 403, {'state': state, 'error': '等待 Mac 确认，或设备尚未授权'})
            info = self.server.info()
            if path == '/link/status':
                return self.output(200, {'info': info, 'state': state})
            token = self.server.auth.issue(value, self.client())
            return self.output(200, {'state': state, 'info': info,
                                    'cookie': {'name': Auth.COOKIE, 'value': token, 'maxAge': 43200}},
                               cookie=self.cookie(token))
        except (ValueError, TypeError, AttributeError) as exc:
            self.close_connection = True
            self.output(400, {'error': '设备请求格式无效'})
        except PermissionError as exc:
            self.close_connection = True
            self.output(403, {'error': str(exc)})


class LinkServer(GatewayServer):
    address_family = socket.AF_INET6

    def __init__(self, address, bridge, web_dir, directory, interfaces, confirm=None):
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        identity_path = directory / 'identity.json'
        self.identity = json.loads(identity_path.read_text()) if identity_path.exists() else {
            'id': str(uuid.uuid4()), 'name': socket.gethostname().split('.')[0]}
        if not identity_path.exists():
            save_private(identity_path, self.identity)
        self.context, self.pin = certificate(directory)
        self.interfaces = interfaces
        self.devices = Devices(directory, **({'confirm': confirm} if confirm else {}))
        super().__init__(address, bridge, {'auth': {'mode': 'device'}, 'origins': []}, web_dir)
        self.auth = DeviceAuth(directory, self.devices)
        self.RequestHandlerClass = LinkHandler
        self.refresh(interfaces)

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()

    def process_request_thread(self, request, client_address):
        # Handshake inside a bounded worker, not accept(): one silent connection
        # cannot block the listener. GatewayServer releases the worker slot.
        try:
            request.settimeout(5)
            request = self.context.wrap_socket(request, server_side=True)
        except (OSError, ssl.SSLError):
            request.close()
            self.slots.release()
            return
        super().process_request_thread(request, client_address)

    def refresh(self, interfaces):
        self.interfaces = interfaces
        origins = {origin(ip, self.server_port) for ip in ('127.0.0.1', '::1', *interfaces.ipv4, *interfaces.ipv6)}
        self.origins = origins
        self.hosts = {urlsplit(o).netloc for o in origins}
        self.secure_hosts = set(self.hosts)

    def info(self):
        return {'serverId': self.identity['id'], 'name': self.identity['name'], 'port': self.server_port,
                'ipv4': list(self.interfaces.ipv4), 'ipv6': list(self.interfaces.ipv6),
                'certificateSHA256': self.pin}
