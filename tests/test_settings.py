"""Synthetic settings only: no real accounts, config files or Codex tasks."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest

import test_link as support
from mac.settings import CodexSettings, FIELDS, digest
from mac.settings_rpc import SettingsRPC, SettingsError, METHODS, enum_values


class FakeSchema:
    def __init__(self):
        choices = {'model_reasoning_effort': ['low', 'medium', 'high'], 'model_reasoning_summary': ['auto', 'concise', 'detailed', 'none'],
                   'model_verbosity': ['low', 'medium', 'high'], 'web_search': ['disabled', 'cached', 'live'],
                   'approval_policy': ['untrusted', 'on-request', 'never'], 'sandbox_mode': ['read-only', 'workspace-write', 'danger-full-access']}
        props = {key: {'enum': choices[key]} if key in choices else {'type': ['string', 'null']} for key in FIELDS}
        self.value = {'methods': set(METHODS), 'version': 'synthetic-only', 'files': {
            'ConfigReadResponse': {'definitions': {'Config': {'properties': props}}},
            'ConfigBatchWriteParams': {'properties': {k: {} for k in ('edits', 'expectedVersion', 'reloadUserConfig')}},
            'SkillsConfigWriteParams': {'properties': {'path': {}, 'enabled': {}}}}}

    def get(self): return self.value


class FakeRuntime:
    def __init__(self, home):
        self.home = home
        self.local = {'model': 'test-model', 'model_reasoning_effort': 'medium', 'api_key': 'SYNTHETIC_SECRET'}
        self.requirements, self.extra, self.overrides = {}, {}, {}
        self.calls = []
        self.ignore_write = False
        self.skill_enabled = True
        self.fail_readback = False
        self.written = False

    def __enter__(self): return self
    def __exit__(self, *_): pass
    def request(self, method, params):
        assert method in METHODS, method
        self.calls.append((method, copy.deepcopy(params)))
        if method == 'config/read':
            if self.written and self.fail_readback: raise SettingsError('synthetic failure')
            effective = {**self.local, **self.extra, **self.overrides}
            user = {'name': {'type': 'user', 'file': str(self.home / 'config.toml'), 'profile': self.extra.get('profile')}, 'version': digest(self.local), 'config': copy.deepcopy(self.local)}
            layers = [user]
            if params.get('cwd'):
                layers.insert(0, {'name': {'type': 'project', 'dotCodexFolder': params['cwd'] + '/.codex'}, 'version': 'project1', 'config': {'model': 'project-model', 'env': {'TOKEN': 'SYNTHETIC_SECRET'}}})
                effective['model'] = 'project-model'
            return {'config': effective, 'origins': {k: {'name': user['name'], 'version': user['version']} for k in effective}, 'layers': layers}
        if method == 'configRequirements/read': return {'requirements': self.requirements}
        if method == 'config/batchWrite':
            assert params['expectedVersion'] == digest(self.local)
            assert 'filePath' not in params
            assert params['reloadUserConfig'] is False
            self.written = True
            if not self.ignore_write:
                for e in params['edits']:
                    assert e['mergeStrategy'] == 'replace'
                    if e['value'] is None: self.local.pop(e['keyPath'], None)
                    else: self.local[e['keyPath']] = e['value']
            return {'status': 'okOverridden' if self.overrides else 'ok', 'filePath': str(self.home / 'config.toml'), 'version': digest(self.local), 'overriddenMetadata': {'secret': 'SYNTHETIC_SECRET'}}
        if method == 'model/list': return {'data': [{'id': 'internal', 'model': 'test-model', 'displayName': 'Test model', 'token': 'SYNTHETIC_SECRET'}], 'nextCursor': None}
        if method == 'skills/list': return {'data': [{'cwd': params['cwds'][0], 'skills': [{'path': str(self.home / 'skills/demo/SKILL.md'), 'name': 'Demo', 'enabled': self.skill_enabled, 'scope': 'user', 'description': 'A demo', 'env': 'SYNTHETIC_SECRET'}]}]}
        if method == 'skills/config/write':
            self.skill_enabled = params['enabled']; self.local['skills'] = {'test_enabled': self.skill_enabled}; return {'effectiveEnabled': self.skill_enabled}
        if method == 'mcpServerStatus/list': return {'data': [{'name': 'Demo MCP', 'authStatus': 'notLoggedIn', 'tools': {'demo': {'description': 'SYNTHETIC_SECRET'}}, 'toolsError': 'SYNTHETIC_SECRET', 'env': 'SYNTHETIC_SECRET'}], 'nextCursor': None}
        raise AssertionError(method)


def fixture(root):
    home = root / 'codex'; home.mkdir()
    project = root / 'project'; project.mkdir()
    def lookup(key):
        if key not in ('local|demo', 'ssh|demo'): raise KeyError(key)
        return {'key': key, 'cwd': str(project), 'name': 'Demo', 'host': key.split('|')[0]}
    bridge = SimpleNamespace(codex_home=home, accounts=SimpleNamespace(gate=threading.RLock(), check_ready=lambda: None))
    rpc, schema = FakeRuntime(home), FakeSchema()
    service = CodexSettings(bridge, SimpleNamespace(project=lookup), rpc_factory=lambda: rpc, schema=schema)
    return service, rpc, schema


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.service, self.rpc, self.schema = fixture(self.root)

    def save(self, **changes):
        return self.service.write({'revision': self.service.read()['revision'], 'changes': changes})

    def test_startup_lazy_and_safe_read(self):
        self.assertEqual(self.rpc.calls, [])
        value = self.service.read()
        self.assertTrue(value['writable']); self.assertEqual(set(value['fields']), set(FIELDS))
        self.assertNotIn('SYNTHETIC_SECRET', json.dumps(value)); self.assertNotIn('api_key', json.dumps(value))
        self.assertEqual(value['fields']['model']['effective'], 'test-model')

    def test_versioned_write_and_readback_without_live_reload(self):
        out = self.save(model_reasoning_effort='high', developer_instructions='Synthetic instructions')
        self.assertEqual(out['status'], 'saved'); self.assertFalse(out['liveApplied'])
        self.assertEqual(out['settings']['fields']['model_reasoning_effort']['value'], 'high')
        self.assertNotIn('SYNTHETIC_SECRET', json.dumps(out))
        writes = [p for m, p in self.rpc.calls if m == 'config/batchWrite']
        self.assertEqual(len(writes), 1)
        self.assertEqual(set(writes[0]), {'edits', 'expectedVersion', 'reloadUserConfig'})

    def test_clear_override_and_noop(self):
        out = self.save(model=None); self.assertEqual(out['status'], 'saved'); self.assertNotIn('model', self.rpc.local)
        self.rpc.calls.clear(); self.assertEqual(self.save(model=None)['status'], 'unchanged')
        self.assertNotIn('config/batchWrite', [m for m, _ in self.rpc.calls])

    def test_conflict_preserves_external_changes(self):
        token = self.service.read()['revision']; self.rpc.local['external'] = 42
        with self.assertRaises(SettingsError) as error: self.service.write({'revision': token, 'changes': {'model': 'new'}})
        self.assertEqual(error.exception.code, 'conflict'); self.assertEqual(self.rpc.local['model'], 'test-model')

    def test_scope_binding_expiry_and_consumed_revision(self):
        token = self.service.read()['revision']
        for body in ({'revision': token, 'scope': 'local|demo'}, {'revision': 'unknown'}):
            with self.assertRaises(SettingsError): self.service.write({**body, 'changes': {'model': 'new'}})
        self.service.clock = lambda: float('inf')
        with self.assertRaises(SettingsError): self.service.write({'revision': token, 'changes': {'model': 'new'}})
        self.service.clock = lambda: 0
        token = self.service.read()['revision']; self.service.write({'revision': token, 'changes': {'model': 'new'}})
        with self.assertRaises(SettingsError): self.service.write({'revision': token, 'changes': {'model': 'again'}})

    def test_project_read_only_and_remote_rejected(self):
        out = self.service.read('local|demo'); self.assertFalse(out['writable']); self.assertEqual(out['fields']['model']['effective'], 'project-model')
        with self.assertRaises(SettingsError) as error: self.service.write({'scope': 'local|demo', 'revision': out['revision'], 'changes': {'model': 'new'}})
        self.assertEqual(error.exception.status, 403)
        with self.assertRaises(SettingsError): self.service.read('ssh|demo')
        with self.assertRaises(KeyError): self.service.read('/arbitrary/cwd')

    def test_managed_restrictions_and_explicit_permission_confirmation(self):
        self.rpc.requirements = {'allowedSandboxModes': ['read-only'], 'allowedApprovalPolicies': ['on-request'], 'allowedWebSearchModes': ['disabled']}
        data = self.service.read(); self.assertEqual(data['fields']['sandbox_mode']['choices'], ['read-only'])
        for key, value in [('sandbox_mode', 'danger-full-access'), ('approval_policy', 'never'), ('web_search', 'live')]:
            with self.assertRaises(ValueError): self.save(**{key: value})
        with self.assertRaises(ValueError): self.save(sandbox_mode='read-only')
        result = self.service.write({'revision': self.service.read()['revision'], 'changes': {'sandbox_mode': 'read-only'}, 'confirmPermissions': True})
        self.assertEqual(result['status'], 'saved')

    def test_profile_permissions_missing_schema_and_symlinks_fail_closed(self):
        self.rpc.extra['profile'] = 'work'; self.assertFalse(self.service.read()['writable']); self.rpc.extra.clear()
        self.rpc.extra['permissions'] = {'work': {}}
        self.assertFalse(self.service.read()['fields']['sandbox_mode']['editable']); self.rpc.extra.clear()
        self.schema.value['methods'].remove('configRequirements/read'); self.assertFalse(self.service.read()['writable'])
        self.schema.value['methods'].add('configRequirements/read')
        target = self.root / 'outside.toml'; target.write_text('KEEP')
        (self.rpc.home / 'config.toml').symlink_to(target)
        self.assertFalse(self.service.read()['writable']); self.assertEqual(target.read_text(), 'KEEP')

    def test_invalid_values_and_arbitrary_keys_never_forwarded(self):
        for changes in ({'api_key': 'bad'}, {'model': '../file'}, {'model': 123}, {'web_search': 'unknown'}, {'developer_instructions': 'x'*32769}):
            with self.assertRaises(ValueError): self.service.write({'revision': self.service.read()['revision'], 'changes': changes})
        with self.assertRaises(ValueError): self.service.write({'filePath': '/tmp/config.toml', 'changes': {'model': 'new'}})
        self.assertNotIn('config/batchWrite', [m for m, _ in self.rpc.calls])

    def test_overrides_and_unconfirmed_readback(self):
        self.rpc.overrides['model'] = 'managed-model'; self.assertEqual(self.save(model='chosen-model')['status'], 'saved_overridden')
        self.rpc.ignore_write = True
        with self.assertRaises(SettingsError) as error: self.save(model='new-model')
        self.assertEqual(error.exception.code, 'unconfirmed')
        self.rpc.ignore_write = False; self.rpc.written = False; self.rpc.fail_readback = True
        with self.assertRaises(SettingsError) as error: self.save(model='new-model')
        self.assertEqual(error.exception.code, 'unconfirmed')
        self.assertEqual(self.rpc.local['model'], 'new-model')

    def test_structured_and_oversized_values_readonly(self):
        self.rpc.local['approval_policy'] = {'granular': {'sandbox_approval': True}}
        self.rpc.local['developer_instructions'] = 'x'*40000
        result = self.service.read()
        self.assertFalse(result['fields']['approval_policy']['editable'])
        self.assertFalse(result['fields']['developer_instructions']['editable'])
        self.assertEqual(len(result['fields']['developer_instructions']['effective']), 32768)

    def test_model_dependent_effort_string_in_new_protocol(self):
        definitions = self.schema.value['files']['ConfigReadResponse']['definitions']
        definitions['Effort'] = {'type': 'string', 'minLength': 1}
        definitions['Config']['properties']['model_reasoning_effort'] = {'anyOf': [{'$ref': '#/definitions/Effort'}, {'type': 'null'}]}
        field = self.service.read()['fields']['model_reasoning_effort']
        self.assertTrue(field['editable']); self.assertEqual(field['kind'], 'text')
        self.assertEqual(self.save(model_reasoning_effort='xhigh')['status'], 'saved')
        with self.assertRaises(ValueError): self.save(model_reasoning_effort='invalid effort')

    def test_models_mcp_and_skills_are_filtered(self):
        for value in (self.service.models(), self.service.mcp(), self.service.skills('local|demo')):
            self.assertNotIn('SYNTHETIC_SECRET', json.dumps(value))
        mcp = self.service.mcp(); self.assertTrue(mcp['readOnly']); self.assertEqual(mcp['servers'][0]['toolCount'], 1)

    def test_skill_toggle_validates_revision_path_and_readback(self):
        skills = self.service.skills(); body = {'revision': skills['revision'], 'path': skills['skills'][0]['path'], 'enabled': False, 'confirmed': True}
        for bad in ({'path': '/etc/passwd'}, {'confirmed': False}):
            with self.assertRaises(ValueError): self.service.skill_write({**body, **bad})
        result = self.service.skill_write(body); self.assertEqual(result['status'], 'saved'); self.assertFalse(result['skills'][0]['enabled'])
        with self.assertRaises(SettingsError): self.service.skill_write(body)
        skills = self.service.skills(); self.rpc.local['external'] = True
        with self.assertRaises(SettingsError): self.service.skill_write({**body, 'revision': skills['revision']})

    def test_no_conversation_fs_or_generic_rpc(self):
        self.assertFalse(any(m.startswith(('thread/', 'turn/', 'fs/', 'command/', 'project/')) for m in METHODS))
        r = SettingsRPC(self.rpc.home, 'NEVER EXECUTED')
        for method in ('thread/resume', 'turn/start', 'fs/writeFile', 'command/exec', 'mcpServer/tool/call'):
            with self.assertRaises(SettingsError) as error: r.request(method, {})
            self.assertEqual(error.exception.status, 403)
        self.assertEqual(enum_values({'$ref': '#/definitions/E'}, {'E': {'anyOf': [{'enum': ['low', None]}, {'$ref': '#/definitions/E'}]}}), ['low'])


class SettingsHTTPTests(unittest.TestCase):
    setUpClass = classmethod(support.HTTPTests.setUpClass.__func__)
    tearDownClass = classmethod(support.HTTPTests.tearDownClass.__func__)
    request, login, tearDown = support.HTTPTests.request, support.HTTPTests.login, support.HTTPTests.tearDown

    def setUp(self):
        support.HTTPTests.setUp(self)
        self.service, self.rpc, _ = fixture(Path(self.temp.name).resolve())
        self.server.codex_settings = self.service

    def authenticate(self):
        self.login(); _, data, _ = self.request('/api/auth', headers={'Cookie': self.cookie})
        return {'Cookie': self.cookie, 'Origin': self.base, 'X-CSRF-Token': data['csrf']}

    def test_auth_origin_csrf_and_native_save(self):
        path = '/api/codex-settings'
        self.assertEqual(self.request(path)[0], 401)
        headers = self.authenticate(); code, value, _ = self.request(path, headers=headers); self.assertEqual(code, 200)
        body = {'revision': value['revision'], 'changes': {'model': 'new'}}
        self.assertEqual(self.request(path, body, {'Cookie': self.cookie, 'Origin': self.base})[0], 403)
        self.assertEqual(self.request(path, body, {**headers, 'Origin': 'https://attacker.invalid'})[0], 403)
        code, value, _ = self.request(path, body, headers); self.assertEqual(code, 200); self.assertEqual(value['status'], 'saved')
        self.assertEqual(self.request(path, body, headers)[0], 409)

    def test_no_rpc_passthrough_and_no_secrets_in_http_errors(self):
        headers = self.authenticate()
        self.assertEqual(self.request('/api/codex-settings/thread/resume', {'id': 'fake'}, headers)[0], 404)
        for suffix in ('', '/models', '/skills', '/mcp'):
            code, body, _ = self.request('/api/codex-settings' + suffix, headers=headers)
            self.assertEqual(code, 200); self.assertNotIn('SYNTHETIC_SECRET', json.dumps(body))
        self.service.read = lambda *_: (_ for _ in ()).throw(RuntimeError('SYNTHETIC_SECRET'))
        code, body, _ = self.request('/api/codex-settings', headers=headers)
        self.assertEqual(code, 409); self.assertNotIn('SYNTHETIC_SECRET', json.dumps(body))


class TransportTests(unittest.TestCase):
    def fake(self, mode):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        root = Path(temp.name); exe = root / 'fake-codex'
        exe.write_text('#!' + sys.executable + '\n' + '''import json, sys, time
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 if r['method']=='initialize': out={'result':{}}
 elif MODE=='error': out={'error':{'code':-32600,'message':'SYNTHETIC_SECRET'}}
 elif MODE=='unsupported': out={'error':{'code':-32601,'message':'SYNTHETIC_SECRET'}}
 elif MODE=='timeout': time.sleep(3); continue
 elif MODE=='oversize': print('x'*2048,flush=True); continue
 else: out={'result':{'config':{}}}
 print(json.dumps({'id':r['id'],**out}),flush=True)
'''.replace('MODE', repr(mode)))
        exe.chmod(0o700)
        return root, exe

    def test_stdio_init_response_errors_and_cleanup(self):
        for mode in ('ok', 'error', 'unsupported', 'timeout', 'oversize'):
            with self.subTest(mode=mode):
                root, exe = self.fake(mode)
                rpc = SettingsRPC(root, exe, timeout=.1); rpc.MAX_LINE = 1024
                with rpc:
                    if mode == 'ok': self.assertEqual(rpc.request('config/read', {}), {'config': {}})
                    else:
                        with self.assertRaises(SettingsError) as error: rpc.request('config/read', {})
                        self.assertNotIn('SYNTHETIC_SECRET', str(error.exception))
                        if mode == 'unsupported': self.assertEqual(error.exception.code, 'unsupported')
                self.assertIsNotNone(rpc.process.poll()); self.assertFalse(rpc.reader.is_alive())
                self.assertTrue(rpc.process.stdin.closed); self.assertTrue(rpc.process.stdout.closed)


if __name__ == '__main__': unittest.main()
