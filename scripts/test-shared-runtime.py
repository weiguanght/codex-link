#!/usr/bin/env python3
"""Exercise the iOS HTTPS workflow against a disposable real App Server.

No production home, authentication, desktop, or model service is used. The first
client is deliberately codex-tui to reproduce shared-daemon originator drift.
"""
import argparse
from contextlib import suppress
import http.server
import ipaddress
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / 'tests')]
from mac.runtime import activate_bridge
activate_bridge()
from mac.network import Interfaces, origin
from mac.shared_bridge import SharedDesktopBridge
from mac.shared_rpc import unix_connect
from bridge.create import persist_empty_metadata
from test_link import HTTPTests, LoopbackV4Server, UPSTREAM, credentials


def wait(predicate, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError('fixture state timeout')


class Provider(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.server.requests += 1
        self.server.release.wait(15)
        message = {'id': 'msg_' + str(self.server.requests), 'type': 'message', 'role': 'assistant',
                   'content': [{'type': 'output_text', 'text': 'GATEWAY_TEST_OK', 'annotations': []}]}
        events = [('response.created', {'response': {'id': 'resp_' + str(self.server.requests)}}),
                  ('response.output_item.added', {'item': dict(message, content=[]), 'output_index': 0}),
                  ('response.output_text.delta', {'item_id': message['id'], 'delta': 'GATEWAY_TEST_OK',
                                                  'output_index': 0, 'content_index': 0}),
                  ('response.output_item.done', {'item': message, 'output_index': 0}),
                  ('response.completed', {'response': {'id': 'resp_' + str(self.server.requests),
                                                       'usage': {'input_tokens': 10, 'output_tokens': 2, 'total_tokens': 12}}})]
        with suppress(BrokenPipeError, ConnectionResetError):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            for kind, fields in events:
                self.wfile.write(('data: ' + json.dumps({'type': kind, **fields}) + '\n\n').encode())
                self.wfile.flush()

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/shared-runtime-check')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    runtime = args.runtime.expanduser().resolve(strict=True)
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix='clrt-', dir='/private/tmp') as folder, \
            http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider) as provider:
        provider.requests = 0
        provider.release = threading.Event(); provider.release.set()
        threading.Thread(target=provider.serve_forever, daemon=True).start()
        root = Path(folder); home = root / 'home'; home.mkdir()
        (home / 'config.toml').write_text(f'''model = "gpt-5.4"
model_provider = "probe"
approval_policy = "never"
check_for_update_on_startup = false
[model_providers.probe]
name = "Local Test Only"
base_url = "http://127.0.0.1:{provider.server_port}/v1"
wire_api = "responses"
supports_websockets = false
env_key = "CODEX_LINK_TEST_API_KEY"
''')
        log = (root / 'runtime.log').open('wb')
        process = subprocess.Popen([str(runtime), 'app-server', '--listen', 'unix://'],
            env={**os.environ, 'CODEX_HOME': str(home), 'CODEX_LINK_TEST_API_KEY': 'local-test-only'},
            cwd=root, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        bridge = server = primary = None
        try:
            control = home / 'app-server-control/app-server-control.sock'
            wait(lambda: control.exists() or process.poll() is not None)
            assert process.poll() is None, (root / 'runtime.log').read_text()
            primary = unix_connect(control)
            counter = 0
            def owner(method, params):
                nonlocal counter
                counter += 1
                primary.send(json.dumps({'id': counter, 'method': method, 'params': params}))
                while True:
                    value = json.loads(primary.recv(timeout=15))
                    if value.get('id') == counter and 'method' not in value:
                        assert 'error' not in value, value
                        return value['result']
            owner('initialize', {'clientInfo': {'name': 'codex-tui', 'version': '0.171.0'},
                                  'capabilities': {'experimentalApi': True}})
            primary.send('{"method":"initialized"}')
            desktop = SimpleNamespace(runtime=runtime, socket=control, running=lambda: process.poll() is None)
            bridge = SharedDesktopBridge(home, root / 'bridge', desktop)
            bridge.ipc.connect()
            net = Interfaces(('127.0.0.1',), (), (ipaddress.ip_network('127.0.0.0/8'),))
            server = LoopbackV4Server(('127.0.0.1', 0), bridge, UPSTREAM / 'web', root / 'link', net, confirm=lambda *_: True)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            client = HTTPTests(); client.server = server
            client.base = origin('127.0.0.1', server.server_port)
            client.headers = {'X-Codex-Link': '1'}; client.value = credentials(); client.login()
            headers = {'Cookie': client.cookie, 'Origin': client.base}
            _, auth, _ = client.request('/api/auth', headers=headers); headers['X-CSRF-Token'] = auth['csrf']
            def request(path, body=None, expected=200):
                code, reply, _ = client.request(path, body, headers)
                assert code == expected, (path, code, reply)
                return reply

            payload = {'id': str(uuid.uuid4()), 'title': '', 'settings': {'model': 'gpt-5.4', 'effort': 'low'}}
            thread_id = request('/api/sessions', payload)['id']
            assert request('/api/sessions', payload)['id'] == thread_id
            metadata = request('/api/session-meta/' + thread_id)
            assert metadata['originator'] == 'codex-tui', metadata
            assert not metadata['readOnly'], metadata
            page_path = '/api/native/v1/threads/' + thread_id + '/timeline?projection=turns'
            page = request(page_path)
            assert page['meta']['connected'] and page['capabilities']['permanentDelete'], page
            send = {'id': str(uuid.uuid4()), 'text': 'Local test only', 'mode': 'send', 'workMode': 'default'}
            path = '/api/sessions/' + thread_id
            assert request(path + '/send', send)['status'] == 'accepted'
            assert request(path + '/send', send)['duplicate']
            wait(lambda: bridge.view(thread_id)['turns'] and bridge.view(thread_id)['turns'][-1]['status'] == 'completed')
            assert bridge.view(thread_id)['turns'][-1]['messages'][-1]['text'] == 'GATEWAY_TEST_OK'
            assert len(bridge.view(thread_id)['turns']) == 1
            print('PASS start-task: create -> metadata -> connected timeline -> send -> completed reply; retries deduplicated', flush=True)

            # A pre-existing TUI/legacy chat remains read-only until conversion.
            legacy = owner('thread/start', {'cwd': str(root), 'ephemeral': False, 'historyMode': 'legacy'})['thread']['id']
            owner('turn/start', {'threadId': legacy, 'input': [{'type': 'text', 'text': 'Legacy fixture'}]})
            wait(lambda: owner('thread/read', {'threadId': legacy})['thread']['status']['type'] == 'idle')
            server.reading.catalog.expires = 0
            assert request('/api/session-meta/' + legacy)['readOnly']
            assert not request('/api/sessions/' + legacy + '/convert', {})['readOnly']
            assert request('/api/sessions/' + legacy + '/reconnect', {'activate': True})['connected']
            assert bridge.view(legacy)['turns'][-1]['messages'][-1]['text'] == 'GATEWAY_TEST_OK'
            print('PASS existing-legacy-chat: history contract read correctly; unrelated history not implicitly activated', flush=True)

            # Simulate another client running a thread unknown to the gateway.
            other = owner('thread/start', {'cwd': str(root), 'ephemeral': False, 'historyMode': 'paginated'})['thread']['id']
            persist_empty_metadata(owner, other)
            provider.release.clear()
            owner('turn/start', {'threadId': other, 'input': [{'type': 'text', 'text': 'Pause local fixture'}]})
            wait(lambda: owner('thread/read', {'threadId': other})['thread']['status']['type'] == 'active')
            server.reading.catalog.expires = 0
            request('/api/workspace/delete', {'id': other, 'confirmed': True}, expected=400)
            assert owner('thread/read', {'threadId': other})['thread']['status']['type'] == 'active'
            provider.release.set()
            wait(lambda: owner('thread/read', {'threadId': other})['thread']['status']['type'] == 'idle')
            print('PASS deletion guard: task started by another client is not interrupted or deleted', flush=True)

            request('/api/workspace/archive', {'id': thread_id, 'confirmed': True, 'archived': True})
            request('/api/workspace/archive', {'id': thread_id, 'confirmed': True, 'archived': False})
            result = request('/api/workspace/delete', {'id': thread_id, 'confirmed': True})
            assert result['deleted']
            backup = Path(result['backup'])
            manifest = json.loads((backup / 'manifest.json').read_text())
            assert manifest['status'] == 'deleted' and manifest['engine'] == 'app-server'
            with sqlite3.connect((home / 'state_5.sqlite').as_uri() + '?mode=ro', uri=True) as db:
                assert db.execute('SELECT 1 FROM threads WHERE id=?', (thread_id,)).fetchone() is None
                assert db.execute('SELECT 1 FROM threads WHERE id=?', (other,)).fetchone()
            request('/api/session-meta/' + thread_id, expected=404)
            assert owner('thread/read', {'threadId': other})['thread']['id'] == other
            assert not bridge.created_thread_ids() & {thread_id}
            shutil.copytree(backup, args.output / 'deletion-backup', dirs_exist_ok=True)
            print('PASS permanent-delete: authenticated owner RPC, recovery backup, list/DB removal, other thread preserved', flush=True)
            print('ALL SHARED RUNTIME CHECKS PASSED', flush=True)
        finally:
            provider.release.set()
            if server: server.shutdown(); server.server_close()
            if bridge: bridge.close()
            if primary: primary.close()
            process.terminate()
            try: process.wait(timeout=8)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
            log.close()
            shutil.copy2(root / 'runtime.log', args.output / 'runtime.log')
            provider.shutdown()


if __name__ == '__main__':
    main()
