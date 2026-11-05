"""Disposable loopback-only bridge; every Codex operation is synthetic."""
import copy
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
from test_history import SpyBridge, database, log, message, uid
from test_settings import FakeRuntime, FakeSchema
from mac.settings import CodexSettings
from bridge.uploads import Uploads

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
artifact_path = project / '新版 IPA.ipa'
artifact_path.write_bytes(b'Synthetic IPA download fixture\n')
artifact_id = hashlib.sha256(str(artifact_path).encode()).hexdigest()
DB = database(home, [{'number': 1, 'cwd': str(project)}, {'number': 2, 'cwd': str(project), 'originator': 'Codex Desktop'}])
log(home, 1, message('user', 'Synthetic smoke fixture') + message('assistant', '这是来自本机日志的只读历史。'), cwd=str(project))
log(home, 2, message('user', '请完善远程会话的原生界面。'), cwd=str(project))


class NativeFixture(SpyBridge):
    def __init__(self, home):
        super().__init__(home)
        self.sequence = 1; self.attempts = {}; self.submissions = {}; self.responses = []; self.uploads = Uploads(root / 'uploads')
        self.accounts = SimpleNamespace(public=lambda: {'accounts': [], 'canSwitch': False})
        self.connected = True
        self.scroll_started = None
        self.scroll_stage = 0
        self.model = 'gpt-5.4'
        self.effort = 'high'
    def activity(self, _): return []
    def timeline_read(self, key, mode='page', **options):
        rows = [dict(key='u1', role='user', kind='userMessage', text='请完善远程会话的原生界面。', order=0, version='v1', truncated=False, editable=True),
                dict(key='t1', role='activity', kind='commandExecution', title='检查项目结构', text='rg --files ios/CodexLink', inputLength=len('rg --files ios/CodexLink'), status='completed', exitCode=0, durationMs=125, order=1, version='v1', truncated=True),
                dict(key='a1', role='assistant', kind='agentMessage', text='已经梳理了项目、会话与输入区的交互。\n\n## 本次调整\n- 项目和任务分组\n- 原生消息流与执行状态\n- 输入区和审批操作\n\n```swift\nlet client = NativeAPI()\n```\n\n```diff\n--- a/example.swift\n+++ b/example.swift\n@@ -1 +1 @@\n-oldValue\n+newValueWithAnIntentionallyLongLineForNativeDiffWrappingInTheIOSConversation\n```', order=2, version='v1', truncated=False, forkable=True)]
        rows[2]['text'] += f'\n\n[新版 IPA](<{artifact_path}>)'
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
            return {'key': 't1', 'version': 'v1', 'text': 'rg --files ios/CodexLink\n\n\x1b[32mNativeChat.swift\x1b[0m\nSynthetic tool output', 'offset': 0, 'next': None}
        return {'epoch': 'synthetic', 'sequence': self.sequence, 'rows': rows if mode == 'page' or options.get('after') != self.sequence else [], 'before': 'synthetic.u1', 'hasMore': False, 'meta': meta, 'files': [{'id': artifact_id, 'reference': str(artifact_path), 'name': artifact_path.name, 'image': False}]}
    def send(self, thread, text, identifier, *_, **__):
        if text == 'Synthetic scroll regression':
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
        return {'models': [{'id': 'gpt-5.4', 'name': 'GPT-5.4', 'efforts': ['low', 'medium', 'high'], 'defaultEffort': 'medium'}, {'id': 'synthetic-restricted', 'name': 'Synthetic Restricted', 'efforts': ['minimal', 'high'], 'defaultEffort': 'high'}], 'skills': [], 'sendCount': len(self.submissions), 'lastAttemptCount': list(self.attempts.values())[-1] if self.attempts else 0}
    def upload(self, key, identifier, name, data): return self.uploads.put(key, identifier, name, data)
    def settings(self, key, model, effort, **kwargs):
        self.model, self.effort = model, effort
        self.sequence += 1
        return {'ok': True}
    def artifact(self, key, identifier):
        if identifier != artifact_id: raise KeyError('Unknown synthetic artifact')
        return {'path': artifact_path, 'name': artifact_path.name, 'image': False}
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
