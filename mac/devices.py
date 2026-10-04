"""Local-confirmation pairing, random device credentials, and local revocation."""
import hashlib
import hmac
import json
import os
import re
import subprocess
import threading
import time
import uuid
from pathlib import Path


def save_private(path, value):
    path = Path(path)
    temp = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        with os.fdopen(os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'w') as f:
            json.dump(value, f, ensure_ascii=False, indent=2)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def identity(value):
    if not isinstance(value, dict):
        raise ValueError('需要设备信息')
    identifier, secret = value.get('deviceId'), value.get('secret')
    if not isinstance(identifier, str) or str(uuid.UUID(identifier)) != identifier:
        raise ValueError('设备 ID 无效')
    if not isinstance(secret, str) or not re.fullmatch(r'[a-f0-9]{64}', secret):
        raise ValueError('设备凭据无效')
    return identifier, hashlib.sha256(secret.encode()).hexdigest()


def mac_confirm(name, address):
    # argv, not interpolated AppleScript: a device name can never become code.
    script = '''on run argv
set answer to display dialog ("设备：" & item 1 of argv & return & "局域网地址：" & item 2 of argv & return & return & "允许它控制本机 Codex？请确认这是你刚打开的 iPhone。以后无需密码。") with title "codex-link · 首次配对" buttons {"拒绝", "允许"} default button "拒绝" giving up after 60
return (button returned of answer)
end run'''
    try:
        result = subprocess.run(['/usr/bin/osascript', '-e', script, name, address],
                                capture_output=True, text=True, timeout=65)
        return result.returncode == 0 and result.stdout.strip() == '允许'
    except (OSError, subprocess.SubprocessError):
        return False


class Devices:
    def __init__(self, directory, confirm=mac_confirm, clock=time.time):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.directory / 'devices.json'
        self.revoked = self.directory / 'revoked'
        self.revoked.mkdir(exist_ok=True, mode=0o700)
        self.rows = json.loads(self.path.read_text()) if self.path.exists() else {}
        self.pending = {}
        self.attempts = []
        self.lock = threading.RLock()
        self.confirm, self.clock = confirm, clock

    def active(self, identifier):
        with self.lock:
            return identifier in self.rows and not (self.revoked / identifier).exists()

    def state(self, value):
        identifier, digest = identity(value)
        with self.lock:
            if (self.revoked / identifier).exists():
                return 'revoked'
            row = self.rows.get(identifier)
            if row:
                return 'approved' if hmac.compare_digest(row['hash'], digest) else 'denied'
            pending = self.pending.get(identifier)
            if pending and hmac.compare_digest(pending['hash'], digest):
                return pending['state'] if self.clock() < pending['expires'] else 'expired'
            return 'unknown'

    def pair(self, value, peer):
        identifier, digest = identity(value)
        name = value.get('name', 'iPhone')
        if not isinstance(name, str) or not 1 <= len(name) <= 80 or any(not c.isprintable() for c in name):
            raise ValueError('设备名称无效')
        with self.lock:
            state = self.state(value)
            if state != 'unknown':
                return state
            # Do not let a second secret replace a pending request for the same ID.
            if identifier in self.pending:
                return 'denied'
            now = self.clock()
            self.attempts = [t for t in self.attempts if now - t < 300]
            self.pending = {k: v for k, v in self.pending.items() if v['expires'] > now}
            if len(self.attempts) >= 3 or any(v['state'] == 'pending' for v in self.pending.values()):
                raise PermissionError('Mac 正在确认其他设备，或配对过于频繁；请稍后重试')
            if len(self.rows) >= 32:
                raise PermissionError('设备数量已达上限')
            self.attempts.append(now)
            self.pending[identifier] = {'hash': digest, 'state': 'pending', 'expires': now + 90}

        def approve():
            try:
                allowed = self.confirm(name, peer)
            except Exception:
                allowed = False
            with self.lock:
                pending = self.pending.get(identifier)
                if not pending or pending['expires'] <= self.clock():
                    return
                if allowed and not (self.revoked / identifier).exists():
                    rows = {**self.rows, identifier: {'name': name, 'hash': digest, 'created': self.clock()}}
                    try:
                        save_private(self.path, rows)
                        self.rows = rows
                        pending['state'] = 'approved'
                    except OSError:
                        pending['state'] = 'denied'
                else:
                    pending['state'] = 'denied'

        threading.Thread(target=approve, daemon=True).start()
        return 'pending'
