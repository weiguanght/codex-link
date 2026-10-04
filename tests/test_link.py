"""Real loopback TLS + fake Codex. No real dialogs, LAN exposure or model calls."""
import hashlib
import http.client
import ipaddress
import json
from pathlib import Path
import secrets
import shutil
import socket
import ssl
import sys
import tempfile
import threading
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from mac.runtime import activate_bridge
UPSTREAM = activate_bridge()

from bridge.httpd import GatewayServer
from mac.devices import Devices, identity
from mac.network import Interfaces, parse_interfaces, origin
from mac.server import LinkServer, certificate

IFCONFIG = '''lo0: flags=8049<UP,LOOPBACK,RUNNING> mtu 16384
    inet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,RUNNING> mtu 1500
    inet 192.168.31.200 netmask 0xffffff00 broadcast 192.168.31.255
    inet6 fe80::abcd%en0 prefixlen 64
    inet6 2408:1234::2 prefixlen 64 autoconf temporary
    inet6 2408:1234::1 prefixlen 64 autoconf secured
    inet6 2408:1234::3 prefixlen 64 deprecated
    status: active
en1: flags=8863<UP,BROADCAST,RUNNING> mtu 1500
    inet 10.0.0.1 netmask 0xffffff00
    status: inactive
utun0: flags=8051<UP,POINTOPOINT,RUNNING> mtu 1380
    inet 198.18.0.1 netmask 0xfffe0000
    inet6 2408:ffff::1 prefixlen 64
'''


def credentials():
    return {'deviceId': str(uuid.uuid4()), 'secret': secrets.token_hex(32), 'name': '测试 iPhone'}


def eventually(check, timeout=2):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.01)
    raise AssertionError('condition did not become true')


class NetworkTests(unittest.TestCase):
    def test_stable_ipv6_first_ignore_vpn_inactive_and_link_local(self):
        net = parse_interfaces(IFCONFIG)
        self.assertEqual(net.ipv4, ('192.168.31.200',))
        self.assertEqual(net.ipv6, ('2408:1234::1', '2408:1234::2'))

    def test_only_direct_ipv4_subnet_may_pair(self):
        net = parse_interfaces(IFCONFIG)
        self.assertTrue(net.local_peer('192.168.31.15'))
        self.assertTrue(net.local_peer('::ffff:192.168.31.15'))
        for peer in ('192.168.32.15', '10.0.0.1', '127.0.0.1', '2408:1234::42', '::1'):
            self.assertFalse(net.local_peer(peer), peer)

    def test_literal_ipv6_url(self):
        self.assertEqual(origin('2408:1234::1', 18443), 'https://[2408:1234::1]:18443')
        self.assertEqual(origin('192.168.1.2', 18443), 'https://192.168.1.2:18443')


class DeviceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def test_approval_persists_hash_only_and_revoke_survives_restart(self):
        devices = Devices(self.temp.name, confirm=lambda *_: True)
        value = credentials()
        self.assertEqual(devices.pair(value, '192.168.1.2'), 'pending')
        eventually(lambda: devices.state(value) == 'approved')
        self.assertNotIn(value['secret'], devices.path.read_text())
        self.assertEqual(devices.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(Devices(self.temp.name).state(value), 'approved')
        (devices.revoked / value['deviceId']).touch()
        self.assertEqual(devices.state(value), 'revoked')
        self.assertEqual(Devices(self.temp.name).state(value), 'revoked')

    def test_denial_and_wrong_secret(self):
        devices = Devices(self.temp.name, confirm=lambda *_: False)
        value = credentials()
        devices.pair(value, '192.168.1.2')
        eventually(lambda: devices.state(value) == 'denied')
        altered = {**value, 'secret': secrets.token_hex(32)}
        self.assertEqual(devices.pair(altered, '192.168.1.2'), 'denied')
        self.assertFalse(devices.path.exists())

    def test_pending_expiry_fails_closed(self):
        now = [10.0]
        wait = threading.Event()
        devices = Devices(self.temp.name, confirm=lambda *_: wait.wait(2), clock=lambda: now[0])
        value = credentials()
        devices.pair(value, '192.168.1.2')
        now[0] += 91
        self.assertEqual(devices.state(value), 'expired')
        wait.set()
        time.sleep(.02)
        self.assertFalse(devices.active(value['deviceId']))

    def test_only_one_confirmation_at_a_time(self):
        wait = threading.Event()
        devices = Devices(self.temp.name, confirm=lambda *_: wait.wait(2))
        devices.pair(credentials(), '192.168.1.2')
        with self.assertRaises(PermissionError):
            devices.pair(credentials(), '192.168.1.3')
        wait.set()
        eventually(lambda: not any(p['state'] == 'pending' for p in devices.pending.values()))

    def test_invalid_credentials(self):
        for value in (None, {}, {'deviceId': '../escape', 'secret': 'a' * 64},
                      {'deviceId': str(uuid.uuid4()), 'secret': 'password'}):
            with self.assertRaises(ValueError):
                identity(value)


class FakeBridge:
    host_errors = []
    def __init__(self):
        self.sent = []
    def list(self, **_):
        return [{'id': '00000000-0000-0000-0000-000000000001', 'title': 'Synthetic test only'}]
    def for_host(self, _):
        return self
    def send(self, *args, **kwargs):
        self.sent.append((args, kwargs))
        return {'ok': True}


class LoopbackV4Server(LinkServer):
    address_family = socket.AF_INET
    def server_bind(self):
        GatewayServer.server_bind(self)


class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.certs = tempfile.TemporaryDirectory()
        certificate(cls.certs.name)

    @classmethod
    def tearDownClass(cls):
        cls.certs.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        for name in ('server.crt', 'server.key'):
            shutil.copy(Path(self.certs.name) / name, Path(self.temp.name) / name)
        self.bridge = FakeBridge()
        # ONLY this test fixture permits loopback pairing; production never does.
        net = Interfaces(('127.0.0.1',), ('2408:1234::1',), (ipaddress.ip_network('127.0.0.0/8'),))
        self.server = LoopbackV4Server(('127.0.0.1', 0), self.bridge, UPSTREAM / 'web', self.temp.name, net, confirm=lambda *_: True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = origin('127.0.0.1', self.server.server_port)
        self.headers = {'X-Codex-Link': '1'}
        self.value = credentials()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temp.cleanup()

    def request(self, path, value=None, headers=None):
        # Test pins the generated leaf explicitly before any credential is sent.
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        conn = http.client.HTTPSConnection('127.0.0.1', self.server.server_port, context=context, timeout=3)
        try:
            conn.connect()
            self.assertEqual(hashlib.sha256(conn.sock.getpeercert(binary_form=True)).hexdigest(), self.server.pin)
            body = json.dumps(value).encode() if value is not None else None
            headers = {**self.headers, **({'Content-Type': 'application/json'} if body else {}), **(headers or {})}
            conn.request('POST' if body else 'GET', path, body, headers)
            response = conn.getresponse()
            data = response.read()
            parsed = json.loads(data) if response.getheader('Content-Type', '').startswith('application/json') else data
            return response.status, parsed, dict(response.getheaders())
        finally:
            conn.close()

    def login(self):
        code, _, _ = self.request('/link/pair', self.value)
        self.assertEqual(code, 202)
        eventually(lambda: self.server.devices.state(self.value) == 'approved')
        code, data, headers = self.request('/link/session', self.value)
        self.assertEqual(code, 200)
        self.cookie = headers['Set-Cookie'].split(';')[0]
        return data

    def test_pair_session_cookie_and_upstream_chat_list(self):
        data = self.login()
        self.assertEqual(data['info']['ipv6'], ['2408:1234::1'])
        code, auth, headers = self.request('/api/auth', headers={'Cookie': self.cookie})
        self.assertEqual(code, 200)
        self.assertTrue(auth['authenticated'])
        self.assertFalse(auth['passwordless'])  # legacy anonymous login stays OFF
        self.assertIn('HttpOnly', headers['Set-Cookie'])
        self.assertIn('Secure', headers['Set-Cookie'])
        code, data, _ = self.request('/api/sessions', headers={'Cookie': self.cookie})
        self.assertEqual(code, 200)
        self.assertEqual(len(data['sessions']), 1)

    def test_anonymous_and_legacy_login_cannot_access_codex(self):
        self.assertEqual(self.request('/api/sessions')[0], 401)
        self.assertEqual(self.request('/api/login', {'username': '', 'password': ''})[0], 403)
        self.assertEqual(self.request('/api/pair', {'token': 'anything'})[0], 403)
        self.assertEqual(self.request('/link/session', self.value)[0], 403)
        self.assertEqual(self.bridge.sent, [])

    def test_browser_and_bad_host_pairing_blocked(self):
        self.assertEqual(self.request('/link/pair', self.value, {'Origin': self.base})[0], 403)
        self.assertEqual(self.request('/link/pair', self.value, {'X-Codex-Link': ''})[0], 403)
        self.assertEqual(self.request('/link/pair', self.value, {'Host': 'attacker.example'})[0], 403)

    def test_remote_pairing_blocked_even_with_forwarded_lan_address(self):
        self.server.refresh(parse_interfaces(IFCONFIG))
        self.assertEqual(self.request('/link/pair', self.value, {'X-Forwarded-For': '192.168.31.12'})[0], 403)

    def test_csrf_and_origin_still_required_for_codex_actions(self):
        self.login()
        path = '/api/sessions/00000000-0000-0000-0000-000000000001/send'
        body = {'text': 'SYNTHETIC ONLY', 'id': str(uuid.uuid4())}
        headers = {'Cookie': self.cookie, 'Origin': self.base}
        self.assertEqual(self.request(path, body, headers)[0], 403)
        _, auth, _ = self.request('/api/auth', headers={'Cookie': self.cookie})
        headers['X-CSRF-Token'] = auth['csrf']
        self.assertEqual(self.request(path, body, {**headers, 'Origin': 'https://evil.test'})[0], 403)
        self.assertEqual(self.request(path, body, headers)[0], 200)
        self.assertEqual(len(self.bridge.sent), 1)

    def test_revoke_invalidates_both_device_and_existing_cookie(self):
        self.login()
        (self.server.devices.revoked / self.value['deviceId']).touch()
        self.assertEqual(self.request('/link/session', self.value)[0], 403)
        self.assertEqual(self.request('/link/status', self.value)[0], 403)
        self.assertEqual(self.request('/api/sessions', headers={'Cookie': self.cookie})[0], 401)

    def test_wrong_secret_does_not_authenticate(self):
        self.login()
        altered = {**self.value, 'secret': secrets.token_hex(32)}
        self.assertEqual(self.request('/link/session', altered)[0], 403)

    def test_status_does_not_issue_new_session_and_refreshes_addresses(self):
        self.login()
        count = len(self.server.auth.sessions)
        self.server.refresh(Interfaces(('127.0.0.1',), ('2408:1234::99',), ()))
        code, data, _ = self.request('/link/status', self.value)
        self.assertEqual(code, 200)
        self.assertEqual(data['info']['ipv6'], ['2408:1234::99'])
        self.assertEqual(len(self.server.auth.sessions), count)

    def test_session_count_bounded(self):
        self.login()
        for _ in range(8):
            self.assertEqual(self.request('/link/session', self.value)[0], 200)
        self.assertLessEqual(len(self.server.auth.sessions), 4)

    def test_ipv6_loopback_tls_and_unpaired_ipv6_rejection(self):
        # Separate real IPv6-only loopback listener, no public interface binding.
        v6 = LinkServer(('::1', 0), self.bridge, UPSTREAM / 'web', self.temp.name,
                        Interfaces(), confirm=lambda *_: True)
        thread = threading.Thread(target=v6.serve_forever, daemon=True)
        thread.start()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        conn = http.client.HTTPSConnection('::1', v6.server_port, context=context, timeout=3)
        try:
            conn.connect()
            self.assertEqual(hashlib.sha256(conn.sock.getpeercert(binary_form=True)).hexdigest(), v6.pin)
            conn.request('POST', '/link/pair', json.dumps(self.value), {'Content-Type': 'application/json', 'X-Codex-Link': '1'})
            response = conn.getresponse()
            self.assertEqual(response.status, 403)
            response.read()
        finally:
            conn.close()
            v6.shutdown()
            v6.server_close()
            thread.join(timeout=2)


if __name__ == '__main__':
    unittest.main()
