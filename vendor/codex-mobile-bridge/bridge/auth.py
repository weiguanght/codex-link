import hashlib
import hmac
import ipaddress
import json
import math
import os
import secrets
import threading
import time
from pathlib import Path


def session_hours(value):
    if type(value) is not int or not 0 <= value <= 87600:
        raise ValueError('登录有效期必须为 0–87600 的整数小时')
    return value


def canonical_ip(value):
    address = ipaddress.ip_address(value)
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    return str(address)


def access_policy(value):
    if not isinstance(value, dict) or type(value.get('allowlistEnabled', False)) is not bool:
        raise ValueError('IP 访问规则格式不正确')
    result = {'allowlistEnabled': value.get('allowlistEnabled', False)}
    for key in ('allowlist', 'blocklist', 'trustedProxies'):
        entries = value.get(key, [])
        if not isinstance(entries, list) or len(entries) > 256:
            raise ValueError('IP 列表最多允许 256 个地址')
        try:
            if any(not isinstance(item, str) or '%' in item for item in entries):
                raise ValueError()
            result[key] = list(dict.fromkeys(canonical_ip(item.strip()) for item in entries))
        except ValueError:
            raise ValueError('请填写有效的 IPv4 或 IPv6 地址，每行一个') from None
    if result['allowlistEnabled'] and not result['allowlist']:
        raise ValueError('启用白名单前，请至少添加一个允许访问的 IP')
    return result


def password_record(password):
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 600000, dklen=32)
    return {"algorithm": "pbkdf2-sha256", "iterations": 600000, "salt": salt.hex(), "hash": digest.hex()}


class Auth:
    COOKIE = "codex_mobile_session"

    def __init__(self, config, data_dir=None):
        self.config = config
        self.hours = session_hours(config.get('sessionHours', 12))
        identity = {k: config.get(k) for k in ('mode', 'username', 'salt', 'hash', 'iterations')}
        identity['sessionHours'] = self.hours
        self.identity = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        self.path = Path(data_dir) / 'auth-sessions.json' if data_dir is not None else None
        self.sessions = {}
        self.policy = access_policy({})
        self.failures = {}
        self.lock = threading.RLock()
        if self.path and self.path.exists():
            saved = json.loads(self.path.read_text(encoding='utf-8'))
            self.policy = access_policy(saved['policy'])
            if saved['identity'] == self.identity:
                self.sessions = {k: v for k, v in saved['sessions'].items() if self.valid(v)}
            else:
                self.persist()

    @staticmethod
    def valid(session):
        return session['expires'] == 0 or session['expires'] > time.time()

    @staticmethod
    def key(token):
        return hashlib.sha256(token.encode()).hexdigest()

    def persist(self):
        if self.path is None:
            return
        temporary = self.path.with_name(self.path.name + '.' + secrets.token_hex(8) + '.tmp')
        try:
            with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w', encoding='utf-8') as stream:
                json.dump({'identity': self.identity, 'policy': self.policy, 'sessions': self.sessions}, stream)
            temporary.replace(self.path)
        finally:
            temporary.unlink(missing_ok=True)

    def permitted(self, address):
        with self.lock:
            return (address not in self.policy['blocklist'] and
                    (not self.policy['allowlistEnabled'] or address in self.policy['allowlist']))

    def client(self, peer, headers, secure=False):
        """Only trust forwarded IPs from a configured proxy or local HTTPS tunnel."""
        peer = canonical_ip(peer)
        with self.lock:
            trusted = set(self.policy['trustedProxies']) | {'127.0.0.1', '::1'}
        if secure and peer in trusted:
            # A trusted proxy must append or overwrite X-Forwarded-For. Walk from
            # the immediate proxy backwards, never trust the user-controlled left end.
            raw = headers.get('CF-Connecting-IP') if headers.get('Host', '').endswith('.trycloudflare.com') else None
            raw = raw or headers.get('X-Forwarded-For', '')
            try:
                chain = [canonical_ip(part.strip()) for part in raw.split(',')]
                address = peer
                for candidate in reversed(chain):
                    if address not in trusted:
                        break
                    address = candidate
                return {'ip': address, 'peer': peer, 'source': 'forwarded'}
            except ValueError:
                return {'ip': peer, 'peer': peer, 'source': 'proxy'}
        return {'ip': peer, 'peer': peer, 'source': 'proxy' if secure else 'direct'}

    def login(self, username, password, address, user_agent='', client=None):
        now = time.time()
        with self.lock:
            recent = [t for t in self.failures.get(address, []) if now - t < 300]
            self.failures[address] = recent
            if len(recent) >= 8:
                raise PermissionError("尝试次数过多，请 5 分钟后再试")
            # Reserve the attempt before hashing, so parallel attempts cannot bypass the limit.
            recent.append(now)
        if self.config.get("mode", "password") != "none":
            digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(self.config["salt"]), self.config["iterations"], dklen=32)
            valid = hmac.compare_digest(digest.hex(), self.config["hash"]) and hmac.compare_digest(username.encode(), self.config["username"].encode())
            if not valid:
                raise PermissionError("账号或密码不正确")
        with self.lock:
            self.failures.pop(address, None)
        return self.new_session(address, user_agent, client)

    def new_session(self, address='', user_agent='', client=None):
        with self.lock:
            if address and not self.permitted(address):
                raise PermissionError('此 IP 已被访问规则禁止')
            now = time.time()
            self.sessions = {k: v for k, v in self.sessions.items() if self.valid(v)}
            token = secrets.token_urlsafe(32)
            session = {"csrf": secrets.token_urlsafe(32), "expires": now + self.hours * 3600 if self.hours else 0,
                       'created': now, 'lastSeen': now, 'userAgent': user_agent[:512],
                       **(client or {'ip': address, 'peer': address, 'source': 'direct'})}
            self.sessions[self.key(token)] = session
            self.persist()
            return token, session

    def get(self, token, client=None, user_agent=''):
        with self.lock:
            session = self.sessions.get(self.key(token))
            if client and not self.permitted(client['ip']):
                return None
            if session and self.valid(session):
                if client:
                    changed = session['ip'] != client['ip'] or time.time() - session['lastSeen'] >= 60
                    session.update(client, userAgent=user_agent[:512], lastSeen=time.time() if changed else session['lastSeen'])
                    if changed:
                        self.persist()
                return session
            if self.sessions.pop(self.key(token), None):
                self.persist()
            return None

    def cookie_age(self, token):
        session = self.get(token)
        if not session:
            return 0
        # Browsers cap persistent cookie lifetimes. Refresh on /api/auth without
        # extending the server's absolute expiry; 0 has no server-side deadline.
        return min(400 * 86400, max(1, math.ceil(session['expires'] - time.time()))) if session['expires'] else 400 * 86400

    def logout(self, token):
        with self.lock:
            if self.sessions.pop(self.key(token), None):
                self.persist()

    def manage(self, value):
        """Local desktop control only; never exposed as a public HTTP endpoint."""
        with self.lock:
            action = value.get('action', 'list')
            if action == 'save':
                self.policy = access_policy(value.get('policy'))
                self.sessions = {k: v for k, v in self.sessions.items() if self.permitted(v['ip'])}
                self.persist()
            elif action in ('revoke', 'block'):
                session = self.sessions.get(value.get('id'))
                if session and action == 'block':
                    address = canonical_ip(session['ip'])
                    self.policy = access_policy({**self.policy, 'blocklist': list(dict.fromkeys(self.policy['blocklist'] + [address]))})
                    self.sessions = {k: v for k, v in self.sessions.items() if v['ip'] != address}
                else:
                    self.sessions.pop(value.get('id'), None)
                self.persist()
            elif action != 'list':
                raise ValueError('未知设备管理操作')
            return {'policy': {k: list(v) if isinstance(v, list) else v for k, v in self.policy.items()},
                    'sessions': sorted([{'id': k, **{field: val for field, val in v.items() if field != 'csrf'}}
                                        for k, v in self.sessions.items() if self.valid(v)],
                                       key=lambda row: row['lastSeen'], reverse=True)}
