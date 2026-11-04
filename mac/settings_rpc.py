"""Bounded, allowlisted app-server RPC for settings; never owns a conversation."""
import json
import os
from pathlib import Path
import queue
import selectors
import subprocess
import tempfile
import threading
import time


class SettingsError(Exception):
    def __init__(self, message='Codex 设置服务不可用，请检查 Mac 运行时后重试。', code='unavailable', status=409):
        super().__init__(message)
        self.code, self.status = code, status


METHODS = {'initialize', 'config/read', 'config/batchWrite', 'configRequirements/read',
           'model/list', 'skills/list', 'skills/config/write', 'permissionProfile/list', 'mcpServerStatus/list'}


class SettingsRPC:
    MAX_LINE = 8 * 1024 * 1024

    def __init__(self, home, executable, cwd=None, env=None, timeout=25):
        self.home, self.executable = Path(home), executable
        self.cwd, self.env, self.timeout = str(cwd or home), env, timeout
        self.process = None
        self.reader = None
        self.messages = queue.Queue(maxsize=128)
        self.failed = threading.Event()
        self.counter = 0

    def __enter__(self):
        if not self.executable:
            raise SettingsError('找不到桌面附带的 Codex 运行时。')
        try:
            self.process = subprocess.Popen([str(self.executable), 'app-server', '--listen', 'stdio://'],
                cwd=self.cwd, env={**(os.environ if self.env is None else self.env), 'CODEX_HOME': str(self.home)},
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            os.set_blocking(self.process.stdin.fileno(), False)
            self.reader = threading.Thread(target=self._read, daemon=True)
            self.reader.start()
            self.request('initialize', {'clientInfo': {'name': 'codex_link_settings', 'version': '0.1.0'},
                                       'capabilities': {'experimentalApi': False}})
            self._send({'method': 'initialized'})
            return self
        except Exception:
            self.__exit__(None, None, None)
            raise SettingsError('无法初始化 Codex 设置服务；未向会话发送任务。') from None

    def _read(self):
        try:
            while True:
                line = self.process.stdout.readline(self.MAX_LINE + 1)
                if not line or len(line) > self.MAX_LINE:
                    break
                try:
                    value = json.loads(line)
                except (ValueError, RecursionError):
                    continue
                if isinstance(value, dict) and 'id' in value:
                    self.messages.put_nowait(value)
        except (OSError, ValueError, queue.Full):
            pass
        finally:
            self.failed.set()

    def _send(self, value):
        payload = memoryview((json.dumps(value, ensure_ascii=False) + '\n').encode('utf-8'))
        deadline = time.monotonic() + self.timeout
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdin, selectors.EVENT_WRITE)
            while payload:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise TimeoutError('Settings write timeout')
                try:
                    size = os.write(self.process.stdin.fileno(), payload)
                except BlockingIOError:
                    continue
                if not size: raise OSError('Settings pipe closed')
                payload = payload[size:]

    def request(self, method, params=None):
        if method not in METHODS:
            raise SettingsError('设置通道不允许此 RPC。', 'forbidden', 403)
        self.counter += 1
        try:
            self._send({'id': self.counter, 'method': method, 'params': params or {}})
            deadline = time.monotonic() + self.timeout
            while time.monotonic() < deadline:
                try:
                    value = self.messages.get(timeout=min(.2, max(.01, deadline - time.monotonic())))
                except queue.Empty:
                    if self.failed.is_set():
                        break
                    continue
                if value.get('id') != self.counter:
                    continue
                if 'error' in value:
                    error = value['error'] if isinstance(value['error'], dict) else {}
                    if error.get('code') == -32601:
                        raise SettingsError('此 Codex 版本未提供该设置接口。', 'unsupported', 409)
                    # Error messages can include configuration values or tokens.
                    # Never forward raw app-server errors to the phone or logs.
                    raise SettingsError('Codex 拒绝或未确认设置请求；请重新读取配置检查版本、策略及生效范围。', 'rpc_rejected')
                if not isinstance(value.get('result'), dict):
                    raise SettingsError('设置响应格式不兼容。', 'unsupported')
                return value['result']
        except (OSError, ValueError):
            pass
        raise SettingsError('设置请求超时或连接中断；写入可能已发生，请重新读取后再决定是否重试。', 'unconfirmed')

    def __exit__(self, *_):
        if not self.process:
            return
        try:
            self.process.stdin.close()
        except OSError:
            pass
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait()
        if self.reader:
            self.reader.join(timeout=1)
        self.process.stdout.close()


class SettingsSchema:
    """Inspect installed protocol definitions in an empty HOME, not user data."""
    def __init__(self, executable):
        self.executable = executable
        self.lock = threading.RLock()
        self.fingerprint = None
        self.value = None

    def get(self):
        with self.lock:
            if not self.executable:
                raise SettingsError('找不到 Codex 运行时。')
            try:
                stat = Path(self.executable).stat()
                fingerprint = (str(self.executable), stat.st_size, stat.st_mtime_ns, stat.st_ino)
                if fingerprint == self.fingerprint:
                    return self.value
                with tempfile.TemporaryDirectory(prefix='codex-link-settings-schema-') as folder:
                    root = Path(folder); (root / 'home').mkdir(); (root / 'codex').mkdir()
                    env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(root / 'home'), 'CODEX_HOME': str(root / 'codex')}
                    command = [str(self.executable), 'app-server', 'generate-json-schema', '--out', str(root / 'schema')]
                    subprocess.run(command, cwd=root, env=env, check=True, timeout=40, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    version = subprocess.check_output([str(self.executable), '--version'], cwd=root, env=env, timeout=5, stderr=subprocess.DEVNULL).decode().strip()[:120]
                    files = {p.stem: json.loads(p.read_text(encoding='utf-8')) for p in (root / 'schema').rglob('*.json')}
                methods = set()
                def visit(v):
                    if isinstance(v, dict):
                        field = v.get('properties', {}).get('method', {})
                        methods.update(field.get('enum', []))
                        if 'const' in field:
                            methods.add(field['const'])
                        for child in v.values(): visit(child)
                    elif isinstance(v, list):
                        for child in v: visit(child)
                visit(files.get('ClientRequest', {}))
                self.value = {'methods': methods, 'files': files, 'version': version}
                self.fingerprint = fingerprint
                return self.value
            except (OSError, ValueError, subprocess.SubprocessError):
                raise SettingsError('无法验证当前运行时的设置协议，已禁用写入。', 'unsupported') from None


def enum_values(schema, definitions, seen=None):
    if not isinstance(schema, dict):
        return []
    seen = set() if seen is None else set(seen)
    ref = schema.get('$ref', '').removeprefix('#/definitions/')
    if ref and ref not in seen:
        return enum_values(definitions.get(ref, {}), definitions, seen | {ref})
    values = [v for v in schema.get('enum', []) if isinstance(v, str)]
    for key in ('anyOf', 'oneOf', 'allOf'):
        for child in schema.get(key, []):
            values.extend(enum_values(child, definitions, seen))
    return list(dict.fromkeys(values))


def allows_string(schema, definitions, seen=None):
    if not isinstance(schema, dict): return False
    seen = set() if seen is None else set(seen)
    ref = schema.get('$ref', '').removeprefix('#/definitions/')
    if ref:
        return ref not in seen and allows_string(definitions.get(ref, {}), definitions, seen | {ref})
    return schema.get('type') == 'string' or 'string' in (schema.get('type') if isinstance(schema.get('type'), list) else []) or any(
        allows_string(v, definitions, seen) for key in ('anyOf', 'oneOf') for v in schema.get(key, []))
