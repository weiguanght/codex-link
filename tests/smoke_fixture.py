"""Disposable loopback-only bridge; every Codex operation is synthetic."""
import copy
import struct
import zlib
import hashlib
import json
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import uuid

from test_link import Interfaces, LoopbackV4Server, LinkServer, UPSTREAM, ipaddress
from test_history import SpyBridge, database, log, message, uid, record
from test_settings import FakeRuntime, FakeSchema
from mac.settings import CodexSettings
from bridge.uploads import Uploads
from bridge.service import LiveSession
from mac import workspace_http

directory = tempfile.TemporaryDirectory()
root = Path(directory.name).resolve()
home = root / 'codex'; home.mkdir()
project = root / 'sample-project'; project.mkdir()
(project / 'Sources').mkdir()
(project / 'Sources/example.swift').write_text('let workspaceValue = "baseline"\n')
subprocess.run(['/usr/bin/git', 'init', '-q', str(project)], check=True)
subprocess.run(['/usr/bin/git', '-C', str(project), 'add', '--', 'Sources/example.swift'], check=True)
subprocess.run(['/usr/bin/git', '-C', str(project), '-c', 'user.name=Synthetic', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'Synthetic workspace baseline'], check=True)
(project / 'Sources/example.swift').write_text('let workspaceValue = "staged"\n')
subprocess.run(['/usr/bin/git', '-C', str(project), 'add', '--', 'Sources/example.swift'], check=True)
(project / 'Sources/example.swift').write_text('let workspaceValue = "working"\n')
(project / 'README.txt').write_text('Synthetic workspace preview\n')
for relative in ('apps/client', 'apps/tools/worker'):
    folder = project / relative; folder.mkdir(parents=True)
    (folder / 'tracked.txt').write_text('baseline\n')
    subprocess.run(['/usr/bin/git', 'init', '-q', str(folder)], check=True)
    subprocess.run(['/usr/bin/git', '-C', str(folder), 'add', '.'], check=True)
    subprocess.run(['/usr/bin/git', '-C', str(folder), '-c', 'user.name=Synthetic', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'Nested baseline'], check=True)
    (folder / 'tracked.txt').write_text('staged\n')
    subprocess.run(['/usr/bin/git', '-C', str(folder), 'add', '.'], check=True)
    (folder / 'tracked.txt').write_text('working nested\n')

artifact_path = project / '新版 IPA.ipa'
artifact_path.write_bytes(b'Synthetic IPA download fixture\n')
artifact_id = hashlib.sha256(str(artifact_path).encode()).hexdigest()
preview_text = project / 'short.txt'
preview_text.write_text('Native preview text fixture\n')
preview_markdown = project / 'longest-conversation-document.md'
preview_markdown.write_text('# 文件预览\n\n| 项目 | 状态 |\n| --- | --- |\n| 文本 | **已完成** |\n')
preview_image = project / 'image.png'
def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
preview_image.write_bytes(b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0))
    + png_chunk(b'IDAT', zlib.compress(b'\x00\x00\x80\xff\x00\x80\xff' * 2)) + png_chunk(b'IEND', b''))
ARTIFACTS = {hashlib.sha256(str(path).encode()).hexdigest(): path for path in (artifact_path, preview_text, preview_markdown, preview_image)}
ARTIFACT_ROWS = [{'id': key, 'reference': str(path), 'name': path.name, 'image': path.suffix == '.png'} for key, path in ARTIFACTS.items()]

DB = database(home, [{'number': 1, 'cwd': str(project)}, {'number': 2, 'cwd': str(project), 'originator': 'Codex Desktop'}])
log(home, 1, message('user', 'Synthetic smoke fixture') + message('assistant', '这是来自本机日志的只读历史。'), cwd=str(project))
log(home, 2, message('user', '请完善远程会话的原生界面。')
    + record('turn_context', {'model': 'gpt-5.4', 'service_tier': 'default'})
    + record('event_msg', {'type': 'token_count', 'info': {
        'total_token_usage': {'input_tokens': 1000000, 'cached_input_tokens': 400000,
                              'output_tokens': 250000, 'reasoning_output_tokens': 100000, 'total_tokens': 1250000},
        'last_token_usage': {'total_tokens': 24000}, 'model_context_window': 128000}}), cwd=str(project))


TOOL_COMMAND = 'printf "%s\\n" "中文 command with a long argument to verify wrapping and horizontal scrolling on narrow screens"\necho second-command'
TOOL_PATCH = 'apps/client/Sources/example.swift\n@@ -1,2 +1,2 @@\n-let workspaceValue = "before"\n+let workspaceValue = "after"\n let same = 3\n\napps/client/README.md\n@@ -1 +1 @@\n-old docs\n+new docs'
TOOL_DETAILS = {
    't1': 'rg --files ios/CodexLink\n\n\x1b[32mNativeChat.swift\x1b[0m\n' + 'Synthetic tool output\n' * 40 + 'Synthetic output final page',
    't2': TOOL_COMMAND + '\n\nSynthetic second output',
    'f1': TOOL_PATCH,
}


class NativeFixture(SpyBridge):
    def __init__(self, home):
        super().__init__(home)
        self.sequence = 1; self.attempts = {}; self.submissions = {}; self.responses = []; self.uploads = Uploads(root / 'uploads')
        self.accounts = SimpleNamespace(public=lambda: {'accounts': [], 'canSwitch': False}, gate=threading.RLock(), check_ready=lambda: None)
        self.data_dir = root
        self.live = {}
        self.message_actions = {}
        self.connected = True
        self.scroll_started = None
        self.pagination = False
        self.scroll_stage = 0
        self.model = 'gpt-5.4'
        self.effort = 'high'
        self.last_send_mode = None
    def session(self, key, **_):
        self.store.get(key)
        return self.live.setdefault(key, LiveSession(key))
    def message_action(self, key, body):
        identifier = body['id']
        if identifier not in self.message_actions:
            project_key = self.hosts.projects()[0]['key']
            self.message_actions[identifier] = dict(self.create_chat(project_key, 'Synthetic branch', identifier), status='created')
        return self.message_actions[identifier]
    def activity(self, _): return []
    def timeline_read(self, key, mode='page', **options):
        rows = [dict(key='u1', role='user', kind='userMessage', text='请完善远程会话的原生界面。', order=0, version='v1', truncated=False, editable=True),
                dict(key='t1', role='activity', kind='commandExecution', title='检查项目结构', text='rg --files ios/CodexLink', inputLength=len('rg --files ios/CodexLink'), status='completed', exitCode=0, durationMs=125, order=1, version='v1', truncated=True),
                dict(key='a1', role='assistant', kind='agentMessage', text='已经梳理了项目、会话与输入区的交互。\n\n## 本次调整\n- 项目和任务分组\n- 原生消息流与执行状态\n- 输入区和审批操作\n\n```swift\nlet client = NativeAPI()\n```\n\n```diff\n--- a/example.swift\n+++ b/example.swift\n@@ -1 +1 @@\n-oldValue\n+newValueWithAnIntentionallyLongLineForNativeDiffWrappingInTheIOSConversation\n```', order=2, version='v1', truncated=False, forkable=True)]
        rows[2]['text'] += f'\n\n[新版 IPA](<{artifact_path}>)'
        rows[2]['text'] += '\n\n| 文件 | 状态 |\n| :--- | ---: |\n| **Native table** | rendered |\n'
        rows[2]['text'] += f'\n[文本预览](<{preview_text}>) · [图片预览](<{preview_image}>)'

        rows[2:2] = [
            dict(key='t2', role='activity', kind='commandExecution', title='执行命令', text=TOOL_COMMAND, inputLength=len(TOOL_COMMAND), status='failed', exitCode=17, order=1, version='v1', truncated=True),
            dict(key='f1', role='activity', kind='fileChange', title='文件变更', text=TOOL_PATCH[:80], inputLength=len(TOOL_PATCH), status='completed', order=1, version='v1', truncated=True),
        ]
        if self.scroll_started is not None:
            stage = sum(time.monotonic() - self.scroll_started >= seconds for seconds in (18, 22))
            if stage != self.scroll_stage:
                self.scroll_stage = stage
                self.sequence += 1
            rows = [dict(key=f'history-{i}', role='user', kind='userMessage',
                         text=f'History entry {i:02d}: ' + 'Earlier discussion for reading and reviewing. ' * 5,
                         order=i - 24, version='v1', truncated=False) for i in range(24)] + rows
            rows.append(dict(key='scroll-baseline', role='assistant', kind='agentMessage', text='History reading baseline', order=3, version='v1', truncated=False))
            if stage:
                rows.append(dict(key='scroll-background', role='assistant', kind='agentMessage',
                                 text='Synthetic background update' if stage == 1 else 'Synthetic background update complete',
                                 order=4, version=f'v{stage}', truncated=False))
        meta = {'id': key, 'title': '优化 Codex Remote 交互', 'cwd': str(project), 'host': 'local', 'model': self.model, 'effort': self.effort, 'provider': 'synthetic', 'connected': self.connected, 'status': 'idle', 'historyComplete': True,
                'requests': [{'id': 'request-1', 'supported': True, 'method': 'item/commandExecution/requestApproval', 'params': {'command': 'echo synthetic-only', 'reason': '测试原生审批组件'}}], 'submissions': []}
        if mode == 'detail':
            row_key = options['cursor'].split('.')[-1]
            text = TOOL_DETAILS[row_key]
            offset = options.get('offset', 0)
            end = min(len(text), offset + 256)
            return {'key': row_key, 'version': 'v1', 'text': text[offset:end], 'offset': offset, 'next': end if end < len(text) else None}
        if self.pagination:
            cursor = options.get('before') if mode == 'page' else options.get('start')
            start = int(cursor.split('page-')[-1]) if cursor and 'page-' in cursor else 12
            if mode == 'page' and cursor and 'page-' in cursor:
                start = max(0, start - 6)
            last = start + 6 if mode == 'page' and cursor and 'page-' in cursor else 36
            history = [dict(key=f'page-{i}', role='user', kind='userMessage',
                            text=f'Auto history {i:02d}: ' + 'Earlier message for automatic pagination. ' * 4,
                            order=i - 30, version='v1', truncated=False) for i in range(start, last)]
            initial_reset = mode == 'changes' and not (cursor and 'page-' in cursor)
            return {'epoch': 'synthetic', 'sequence': self.sequence, 'rows': history if mode == 'page' or options.get('after') != self.sequence else [],
                    'reset': initial_reset, 'before': f'synthetic.page-{start}', 'hasMore': start > 0, 'meta': meta}
        return {'epoch': 'synthetic', 'sequence': self.sequence, 'rows': rows if mode == 'page' or options.get('after') != self.sequence else [], 'before': 'synthetic.u1', 'hasMore': False, 'meta': meta, 'files': ARTIFACT_ROWS}
    def send(self, thread, text, identifier, mode="send", *_, **__):
        self.last_send_mode = mode
        if text == 'Synthetic pagination regression':
            self.pagination = True
            self.scroll_started = None
        if text == 'Synthetic scroll regression':
            self.pagination = False
            self.scroll_started = time.monotonic()
            self.scroll_stage = 0
        self.attempts[identifier] = self.attempts.get(identifier, 0) + 1
        self.submissions.setdefault(identifier, text)
        if text == 'Synthetic retry' and self.attempts[identifier] == 1: return {'status': 'unknown', 'confirmed': False}
        self.sequence += 1
        return {'status': 'accepted', 'confirmed': True}
    def interrupt(self, key): self.sequence += 1; return {'ok': True}
    def respond(self, key, request, response): self.responses.append((key, request, response)); return {'ok': True}
    def catalog(self, key, refresh=False):
        return {'models': [{'id': 'gpt-5.4', 'name': 'GPT-5.4', 'efforts': ['low', 'medium', 'high'], 'defaultEffort': 'medium'}, {'id': 'synthetic-restricted', 'name': 'Synthetic Restricted', 'efforts': ['minimal', 'high'], 'defaultEffort': 'high'}], 'skills': [], 'sendCount': len(self.submissions), 'lastAttemptCount': list(self.attempts.values())[-1] if self.attempts else 0, 'lastSendMode': self.last_send_mode}
    def upload(self, key, identifier, name, data): return self.uploads.put(key, identifier, name, data)
    def settings(self, key, model, effort, **kwargs):
        self.model, self.effort = model, effort
        self.sequence += 1
        return {'ok': True}
    def artifact(self, key, identifier):
        path = ARTIFACTS.get(identifier)
        if path is None: raise KeyError('Unknown synthetic artifact')
        return {'path': path, 'name': path.name, 'image': path.suffix == '.png'}
    def rename(self, key, title):
        with sqlite3.connect(DB) as conn: conn.execute('UPDATE threads SET title=? WHERE id=?', (title, key))
        for server in servers: server.reading.catalog.expires = 0
        return {'ok': True}
    def create_chat(self, project_key, title, request):
        key = str(uuid.uuid5(uuid.NAMESPACE_URL, request))
        folder = self.hosts.workspace.project(project_key)['cwd']
        with sqlite3.connect(DB) as conn:
            conn.execute('INSERT OR IGNORE INTO threads(id,title,cwd,originator,source,updated_at,archived) VALUES (?,?,?,?,?,?,?)', (key,title,folder,'Codex Desktop','vscode',1900000000,0))
        for server in servers: server.reading.catalog.expires = 0
        return {'id': key, 'host': 'local', 'message': 'Synthetic conversation created'}


def synthetic_archive(bridge, key, archived):
    bridge.store.get(key)
    with sqlite3.connect(DB) as connection:
        connection.execute('UPDATE threads SET archived=? WHERE id=?', (int(archived), key))
    return {'ok': True}


workspace_http.archive = synthetic_archive
bridge = NativeFixture(home)
net = Interfaces(('127.0.0.1',), (), (ipaddress.ip_network('127.0.0.0/8'),))
v4 = LoopbackV4Server(('127.0.0.1', 0), bridge, UPSTREAM / 'web', root, net, confirm=lambda *_: True)
v6 = LinkServer(('::1', v4.server_port), bridge, UPSTREAM / 'web', root, net)
servers = (v4, v6)
v6.auth, v6.devices = v4.auth, v4.devices
v4.workspace.create({'id': uid(900), 'name': 'codex-link', 'cwd': str(project)})
runtime = FakeRuntime(home)
v4.codex_settings = CodexSettings(bridge, v4.workspace, rpc_factory=lambda: runtime, schema=FakeSchema())
v6.codex_settings = v4.codex_settings
for server in servers: threading.Thread(target=server.serve_forever, daemon=True).start()
Path(sys.argv[1]).write_text(json.dumps({'port': v4.server_port, 'pin': v4.pin, 'id': v4.identity['id'], 'project': str(project)}))
stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
signal.signal(signal.SIGINT, lambda *_: stop.set())
try: stop.wait()
finally:
    for server in servers: server.shutdown(); server.server_close()
    directory.cleanup()
