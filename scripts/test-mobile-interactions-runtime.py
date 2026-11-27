#!/usr/bin/env python3
"""Mobile response routes against a disposable real multi-client App Server.

Uses a private home/socket inside build/, a loopback model fixture and echo only.
Does not connect to the production desktop, account or model service.
"""
import argparse
from contextlib import suppress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import shutil
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
from test_link import HTTPTests, LoopbackV4Server, UPSTREAM, credentials


def wait(predicate, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError('Mobile interaction fixture timed out')


class Provider(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        scenario = self.server.scenario
        phase = self.server.phases.get(scenario, 0)
        self.server.phases[scenario] = phase + 1
        tools = {row.get('name'): row for row in body.get('tools', [])}
        if '<send_user_message_question_reply>' in json.dumps(body):
            self.server.question_replies[scenario] = body['input']
        if phase == 0:
            if scenario.startswith('async'):
                name = 'request_user_input_async'
                arguments = {'questions': [{'title': 'Choose a fixture option', 'options': ['A', 'B']},
                                           {'title': 'Provide a custom reply'}]}
            elif scenario == 'input':
                name = 'request_user_input'
                arguments = {'questions': [
                    {'id': 'choice', 'header': 'Choice', 'question': 'Choose a fixture option',
                     'options': [{'label': 'A', 'description': 'First'}, {'label': 'B', 'description': 'Second'}]},
                    {'id': 'notes', 'header': 'Notes', 'question': 'Provide a custom reply',
                     'options': [{'label': 'Example A', 'description': 'First'}, {'label': 'Example B', 'description': 'Second'}]},
                ]}
            else:
                name = next((name for name in ('exec_command', 'shell_command', 'shell') if name in tools), None)
                arguments = {'sandbox_permissions': 'require_escalated', 'justification': 'Synthetic mobile approval only'}
                if name == 'exec_command':
                    arguments.update(cmd='/bin/echo MOBILE_INTERACTION_OK', yield_time_ms=1000, max_output_tokens=256)
                elif name == 'shell_command':
                    arguments.update(command='/bin/echo MOBILE_INTERACTION_OK', workdir=str(self.server.workspace))
                else:
                    arguments.update(command=['/bin/echo', 'MOBILE_INTERACTION_OK'], workdir=str(self.server.workspace))
            if name not in tools:
                self.server.error = ('Expected tool was not advertised: ' + str(name)
                                     + '; tools=' + str(sorted(n for n in tools if n))
                                     + '; path=' + self.path + '; fields=' + str(sorted(body)))
                self.send_error(500)
                return
            item = {'id': 'fc_' + scenario, 'type': 'function_call', 'call_id': 'call_' + scenario,
                    'name': name, 'arguments': json.dumps(arguments)}
            delta = ('response.function_call_arguments.delta', {
                'item_id': item['id'], 'delta': item['arguments'], 'output_index': 0,
            })
            initial = dict(item, arguments='')
        else:
            if scenario == 'async-active' and phase == 1:
                self.server.release.wait(20)
            text = 'MOBILE_INTERACTION_COMPLETE:' + scenario
            item = {'id': 'msg_' + scenario, 'type': 'message', 'role': 'assistant',
                    'content': [{'type': 'output_text', 'text': text, 'annotations': []}]}
            delta = ('response.output_text.delta', {'item_id': item['id'], 'delta': text,
                                                   'output_index': 0, 'content_index': 0})
            initial = dict(item, content=[])
            self.server.tool_results[scenario] = [row for row in body.get('input', [])
                                                 if row.get('type') == 'function_call_output']
        response_id = 'resp_' + scenario + '_' + str(phase)
        events = [
            ('response.created', {'response': {'id': response_id}}),
            ('response.output_item.added', {'item': initial, 'output_index': 0}),
            delta,
            ('response.output_item.done', {'item': item, 'output_index': 0}),
            ('response.completed', {'response': {'id': response_id, 'output': [item],
                                                'usage': {'input_tokens': 10, 'output_tokens': 2, 'total_tokens': 12}}}),
        ]
        with suppress(BrokenPipeError, ConnectionResetError):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            for method, params in events:
                self.wfile.write(('data: ' + json.dumps({'type': method, **params}) + '\n\n').encode())
                self.wfile.flush()

    def log_message(self, *_):
        pass


class Desktop:
    def __init__(self, socket):
        self.socket, self.counter, self.events = socket, 0, []

    def request(self, method, params):
        self.counter += 1
        self.socket.send(json.dumps({'id': self.counter, 'method': method, 'params': params}))
        while True:
            message = json.loads(self.socket.recv(timeout=20))
            if 'method' not in message and message.get('id') == self.counter:
                assert 'error' not in message, message
                return message['result']
            self.events.append(message)

    def event(self, predicate):
        deadline = time.monotonic() + 20
        while True:
            found = next((row for row in self.events if predicate(row)), None)
            if found is not None:
                self.events.remove(found)
                return found
            if time.monotonic() >= deadline:
                raise AssertionError('Expected desktop event was not received: ' + json.dumps(self.events))
            message = json.loads(self.socket.recv(timeout=max(.1, deadline - time.monotonic())))
            self.events.append(message)

    def respond(self, identifier, response):
        self.socket.send(json.dumps({'id': identifier, 'result': response}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/mobile-interactions')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    runtime = args.runtime.expanduser().resolve(strict=True)
    version = subprocess.check_output([str(runtime), '--version'], text=True).strip()
    os.umask(0o077)
    checks = []
    with tempfile.TemporaryDirectory(prefix='mi-', dir=ROOT / 'build') as folder, \
            ThreadingHTTPServer(('127.0.0.1', 0), Provider) as provider:
        root = Path(folder); home = root / 'h'; home.mkdir()
        socket = root / 's'
        assert len(str(socket).encode()) < 100, 'Project path is too long for the private Unix socket'
        provider.scenario, provider.phases, provider.tool_results, provider.error = None, {}, {}, None
        provider.question_replies, provider.release = {}, threading.Event()
        provider.workspace = root
        threading.Thread(target=provider.serve_forever, daemon=True).start()
        (home / 'config.toml').write_text(f'''model = "gpt-5.4"
model_provider = "probe"
model_catalog_json = {json.dumps(str(ROOT / 'tests/mobile-models.json'))}
approval_policy = "on-request"
approvals_reviewer = "user"
sandbox_mode = "read-only"
check_for_update_on_startup = false
[tools.experimental_request_user_input]
enabled = true
[model_providers.probe]
name = "Loopback Test Only"
base_url = "http://127.0.0.1:{provider.server_port}/v1"
wire_api = "responses"
supports_websockets = false
env_key = "CODEX_LINK_TEST_API_KEY"
''')
        log = (root / 'runtime.log').open('wb')
        process = subprocess.Popen([str(runtime), 'app-server', '--listen', 'unix://' + str(socket)],
            env={**os.environ, 'CODEX_HOME': str(home), 'CODEX_LINK_TEST_API_KEY': 'local-fixture-only'},
            cwd=root, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        bridge = server = desktop = None
        try:
            wait(lambda: socket.exists() or process.poll() is not None)
            assert process.poll() is None, (root / 'runtime.log').read_text()
            desktop = Desktop(unix_connect(socket))
            desktop.request('initialize', {'clientInfo': {'name': 'codex_desktop', 'version': '0.1.0'},
                                           'capabilities': {'experimentalApi': True, 'requiredHumanApproval': True}})
            desktop.socket.send('{"method":"initialized"}')
            bridge = SharedDesktopBridge(home, root / 'bridge', SimpleNamespace(
                runtime=runtime, socket=socket, running=lambda: process.poll() is None))
            bridge.ipc.connect()
            net = Interfaces(('127.0.0.1',), (), (ipaddress.ip_network('127.0.0.0/8'),))
            server = LoopbackV4Server(('127.0.0.1', 0), bridge, UPSTREAM / 'web', root / 'link', net, confirm=lambda *_: True)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            client = HTTPTests(); client.server = server
            client.base = origin('127.0.0.1', server.server_port)
            client.headers = {'X-Codex-Link': '1'}; client.value = credentials(); client.login()
            headers = {'Cookie': client.cookie, 'Origin': client.base}
            _, auth, _ = client.request('/api/auth', headers=headers); headers['X-CSRF-Token'] = auth['csrf']
            def http(path, body=None, expected=200):
                code, reply, _ = client.request(path, body, headers)
                assert code == expected, (path, code, reply)
                return reply
            for scenario in ('approve', 'cancel', 'desktop', 'replay', 'input', 'async', 'async-active'):
                provider.release.clear()
                provider.scenario = scenario
                thread = http('/api/sessions', {'project': '', 'title': scenario, 'id': str(uuid.uuid4())})['id']
                desktop.request('thread/resume', {'threadId': thread, 'excludeTurns': True})
                if scenario == 'replay':
                    bridge.ipc.close()
                    wait(lambda: bridge.ipc.socket is None)
                params = {'threadId': thread, 'input': [{'type': 'text', 'text': 'mobile-test:' + scenario}]}
                if scenario == 'input':
                    params['collaborationMode'] = {'mode': 'plan', 'settings': {
                        'model': 'gpt-5.4', 'reasoning_effort': 'medium', 'developer_instructions': None}}
                turn = desktop.request('turn/start', params)['turn']['id']
                if scenario.startswith('async'):
                    if scenario == 'async':
                        desktop.event(lambda row: row.get('method') == 'turn/completed'
                                      and row.get('params', {}).get('turn', {}).get('id') == turn)
                    else:
                        desktop.event(lambda row: row.get('method') == 'item/completed'
                                      and row.get('params', {}).get('threadId') == thread
                                      and bool(row['params'].get('item', {}).get('questions')))
                    native_path = '/api/native/v1/threads/' + thread + '/timeline?projection=turns'
                    page = {}
                    def async_pending():
                        nonlocal page
                        page = http(native_path)
                        return bool(page['meta']['requests'])
                    wait(async_pending)
                    card = page['meta']['requests'][0]
                    assert card['method'] == 'bridge/requestUserInputAsync' and card['supported']
                    questions = card['params']['questions']
                    response = {'answers': {questions[0]['id']: ['B'], questions[1]['id']: ['Mobile async reply\nSecond line']}}
                    result = http('/api/sessions/' + thread + '/respond', {'requestId': card['id'], 'response': response})
                    assert result.get('confirmed') is not False, result
                    provider.release.set()
                    desktop.event(lambda row: row.get('method') == 'turn/completed'
                                  and row.get('params', {}).get('threadId') == thread
                                  and (scenario != 'async' or row['params']['turn']['id'] != turn))
                    wait(lambda: not http(native_path)['meta']['requests'])
                    wait(lambda: scenario in provider.question_replies)
                    received = json.dumps(provider.question_replies[scenario], ensure_ascii=False)
                    assert 'Mobile async reply' in received and 'questionItemId' in received, received
                    checks.append(scenario)
                    print('PASS real runtime mobile interaction:', scenario, flush=True)
                    continue
                method = 'item/tool/requestUserInput' if scenario == 'input' else 'item/commandExecution/requestApproval'
                request = desktop.event(lambda row: row.get('method') == method and row.get('params', {}).get('threadId') == thread)
                if scenario == 'replay':
                    bridge.activate(thread)
                native_path = '/api/native/v1/threads/' + thread + '/timeline?projection=turns'
                page = {}
                def pending():
                    nonlocal page
                    page = http(native_path)
                    return bool(page['meta']['requests'])
                wait(pending)
                assert page['capabilities']['respond']
                card = page['meta']['requests'][0]
                assert card['supported'] and card['id'].startswith('shared:')
                if scenario == 'desktop':
                    desktop.respond(request['id'], {'decision': 'accept'})
                else:
                    response = {'answers': {'choice': ['B'], 'notes': ['Mobile custom reply\nSecond line']}} if scenario == 'input' \
                        else {'decision': 'cancel' if scenario == 'cancel' else 'accept'}
                    http('/api/sessions/' + thread + '/respond', {'requestId': card['id'], 'response': response})
                desktop.event(lambda row: row.get('method') == 'serverRequest/resolved'
                              and row.get('params', {}).get('threadId') == thread
                              and row['params']['requestId'] == request['id'])
                desktop.event(lambda row: row.get('method') == 'turn/completed'
                              and row.get('params', {}).get('turn', {}).get('id') == turn)
                wait(lambda: not http(native_path)['meta']['requests'])
                assert provider.phases[scenario] == (1 if scenario == 'cancel' else 2), (scenario, provider.phases, provider.error)
                outputs = json.dumps(provider.tool_results.get(scenario, []), ensure_ascii=False)
                if scenario == 'input':
                    assert 'Mobile custom reply' in outputs and 'Second line' in outputs and 'B' in outputs, outputs
                elif scenario != 'cancel':
                    assert 'MOBILE_INTERACTION_OK' in outputs, outputs
                checks.append(scenario)
                print('PASS real runtime mobile interaction:', scenario, flush=True)
            result = {'result': 'PASS', 'runtime': version, 'checks': checks, 'modelRequests': provider.phases}
            (args.output / 'runtime-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        except Exception:
            if provider.error:
                print('Model fixture:', provider.error, flush=True)
            raise
        finally:
            provider.release.set()
            if server: server.shutdown(); server.server_close()
            if bridge: bridge.close()
            if desktop: desktop.socket.close()
            process.terminate()
            try: process.wait(timeout=8)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
            log.close()
            shutil.copy2(root / 'runtime.log', args.output / 'runtime.log')
            provider.shutdown()


if __name__ == '__main__':
    main()
