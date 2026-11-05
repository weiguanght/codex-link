"""Native API contract over pinned TLS fixtures; no user Codex state."""
import copy
import json
from pathlib import Path
import unittest
from urllib.parse import urlencode

import test_history as history
import test_link as support
from mac.history_catalog import ReadingLibrary
from mac.workspace import Workspace, ProjectHosts
from mac.native_http import capabilities


class NativeHTTPTests(unittest.TestCase):
    setUpClass = classmethod(support.HTTPTests.setUpClass.__func__)
    tearDownClass = classmethod(support.HTTPTests.tearDownClass.__func__)
    request, login, tearDown = support.HTTPTests.request, support.HTTPTests.login, support.HTTPTests.tearDown

    def setUp(self):
        support.HTTPTests.setUp(self)
        home = Path(self.temp.name) / 'codex'; home.mkdir()
        self.folder = Path(self.temp.name) / 'workspace'; self.folder.mkdir()
        (self.folder / 'example.txt').write_text('Synthetic file preview')
        history.database(home, [{'number': 1, 'cwd': str(self.folder)}, {'number': 2, 'cwd': str(self.folder), 'originator': 'Codex Desktop'}])
        history.log(home, 1, history.message('user', 'A synthetic question') + history.message('assistant', 'A synthetic answer'))
        history.log(home, 2, history.message('user', 'Desktop log'))
        bridge = history.SpyBridge(home)
        self.calls = []
        def timeline(key, mode='page', **options):
            self.calls.append((key, mode, options))
            if mode == 'detail': return {'key': 'row', 'version': 'v1', 'text': 'detail', 'offset': 0, 'next': None}
            return {'epoch': 'desktop', 'sequence': 1, 'rows': [], 'hasMore': False,
                    'meta': {'connected': True, 'requests': [], 'submissions': []}}
        bridge.timeline_read = timeline
        workspace = Workspace(self.temp.name, bridge.hosts); bridge.hosts = ProjectHosts(workspace)
        self.server.bridge = bridge; self.server.workspace = workspace; self.server.reading = ReadingLibrary(bridge, workspace)

    def authenticate(self):
        self.login(); _, data, _ = self.request('/api/auth', headers={'Cookie': self.cookie})
        return {'Cookie': self.cookie, 'Origin': self.base, 'X-CSRF-Token': data['csrf']}

    def test_bootstrap_auth_version_and_no_eager_runtime(self):
        path = '/api/native/v1/bootstrap'
        self.assertEqual(self.request(path)[0], 401)
        code, value, _ = self.request(path, headers=self.authenticate())
        self.assertEqual(code, 200); self.assertEqual(value['apiVersion'], 1)
        self.assertEqual(value['limits']['attachmentBytes'], 20*1024*1024)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.request('/api/native/v2/bootstrap', headers={'Cookie': self.cookie})[0], 404)

    def test_readonly_log_caps_pagination_changes_and_detail(self):
        headers = self.authenticate(); path = '/api/native/v1/threads/' + history.uid(1)
        code, page, _ = self.request(path + '/timeline?limit=1', headers=headers)
        self.assertEqual(code, 200); self.assertTrue(page['capabilities']['readOnly'])
        self.assertFalse(page['capabilities']['send']); self.assertEqual(len(page['rows']), 1)
        self.assertFalse(page['meta']['connected']); self.assertEqual(page['meta']['requests'], [])
        query = urlencode({'after': page['sequence'], 'epoch': page['epoch'], 'start': page['before']})
        code, changes, _ = self.request(path + '/changes?' + query, headers=headers); self.assertEqual(code, 200)
        query = urlencode({'key': page['epoch'] + '.' + page['rows'][0]['key'], 'offset': 0, 'version': page['rows'][0]['version']})
        code, detail, _ = self.request(path + '/detail?' + query, headers=headers)
        self.assertEqual(code, 200); self.assertIn('synthetic answer', detail['text'])
        self.assertEqual(self.calls, [])
        self.assertEqual(self.server.bridge.activated, [])

    def test_desktop_projection_retains_controller_and_explicit_log_is_readonly(self):
        headers = self.authenticate(); path = '/api/native/v1/threads/' + history.uid(2)
        code, value, _ = self.request(path + '/timeline', headers=headers)
        self.assertEqual(code, 200); self.assertTrue(value['capabilities']['send']); self.assertTrue(value['capabilities']['archive'])
        self.assertEqual(len(self.calls), 1)
        code, value, _ = self.request(path + '/timeline?view=log', headers=headers)
        self.assertEqual(code, 200); self.assertTrue(value['capabilities']['readOnly']); self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.server.bridge.activated, [])

    def test_no_mutation_passthrough_and_bad_inputs(self):
        headers = self.authenticate(); path = '/api/native/v1/threads/' + history.uid(1)
        self.assertEqual(self.request(path+'/send', {'text': 'NO'}, headers)[0], 405)
        self.assertEqual(self.request(path+'/timeline', {}, {'Cookie': self.cookie, 'Origin': self.base})[0], 403)
        self.assertEqual(self.request(path+'/timeline?limit=invalid', headers=headers)[0], 400)
        self.assertEqual(self.request(path+'/timeline', headers={**headers, 'Origin': 'https://other.invalid'})[0], 403)
        self.assertEqual(self.server.bridge.sent, [])

    def test_remote_cannot_archive_and_default_capabilities_fail_closed(self):
        self.assertFalse(capabilities({})['send'])
        self.assertFalse(capabilities({'host': 'ssh', 'readOnly': False})['archive'])
        self.assertTrue(capabilities({'host': 'local', 'readOnly': False})['send'])

    def test_workspace_reads_are_scoped_authenticated_and_do_not_activate(self):
        path = '/api/native/v1/threads/' + history.uid(2) + '/workspace/'
        self.assertEqual(self.request(path + 'tree')[0], 401)
        headers = self.authenticate()
        code, value, _ = self.request(path + 'tree', headers=headers)
        self.assertEqual(code, 200)
        self.assertEqual([r['name'] for r in value['entries']], ['example.txt'])
        code, value, _ = self.request(path + 'file?path=example.txt', headers=headers)
        self.assertEqual(code, 200); self.assertEqual(value['text'], 'Synthetic file preview')
        self.assertEqual(self.request(path + 'file?' + urlencode({'path': '../server.key'}), headers=headers)[0], 400)
        self.assertEqual(self.request(path + 'tree', {}, headers)[0], 405)
        self.assertEqual(self.request(path + 'tree', headers={**headers, 'Origin': 'https://other.invalid'})[0], 403)
        self.assertEqual(self.request('/api/native/v1/threads/' + history.uid(1) + '/workspace/tree', headers=headers)[0], 403)
        self.assertEqual(self.request(path + 'tree?view=log', headers=headers)[0], 403)
        self.assertEqual(self.server.bridge.activated, [])
        self.assertEqual(self.calls, [])

    def test_workspace_write_is_authenticated_scoped_and_conflict_checked(self):
        path = '/api/native/v1/threads/' + history.uid(2) + '/workspace/file'
        headers = self.authenticate()
        _, current, _ = self.request(path + '?path=example.txt', headers=headers)
        body = {'path': 'example.txt', 'text': 'Edited from phone', 'revision': current['revision']}
        self.assertEqual(self.request(path, body, {'Cookie': self.cookie, 'Origin': self.base})[0], 403)
        self.assertEqual(self.request(path, body, {**headers, 'Origin': 'https://other.invalid'})[0], 403)
        self.assertEqual(self.request(path.replace(history.uid(2), history.uid(1)), body, headers)[0], 403)
        code, saved, _ = self.request(path, body, headers)
        self.assertEqual(code, 200); self.assertNotEqual(saved['revision'], current['revision'])
        self.assertEqual((self.folder / 'example.txt').read_text(), 'Edited from phone')
        code, error, _ = self.request(path, body, headers)
        self.assertEqual(code, 409); self.assertEqual(error['code'], 'conflict')
        self.assertEqual(self.server.bridge.activated, [])

    def test_native_sources_do_not_embed_web_ui(self):
        root = Path(__file__).resolve().parents[1] / 'ios/CodexLink'
        for source in root.glob('*.swift'):
            self.assertNotIn('import WebKit', source.read_text(), source.name)
            self.assertNotIn('WKWebView', source.read_text(), source.name)
