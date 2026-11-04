"""Synthetic project workflows only; no real directory, Codex, or account edits."""
import json
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

import test_history as history
import test_link as support
from mac.workspace import Workspace, ProjectHosts
from mac.workspace_http import archive
from mac.history_catalog import ReadingLibrary


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / 'codex'; self.home.mkdir()
        self.folder = self.root / 'app'; self.folder.mkdir()
        self.bridge = history.SpyBridge(self.home)
        self.workspace = Workspace(self.root, self.bridge.hosts)
        self.bridge.hosts = ProjectHosts(self.workspace)
        self.library = ReadingLibrary(self.bridge, self.workspace)

    def create(self, **kwargs):
        return self.workspace.create(dict(id=history.uid(900), name='Example', cwd=str(self.folder), **kwargs))

    def test_project_registration_persists_without_editing_codex_config(self):
        config = self.home / '.codex-global-state.json'; config.write_text('{}')
        row = self.create()
        self.assertEqual(self.bridge.hosts.projects()[0]['key'], row['key'])
        self.assertEqual(config.read_text(), '{}')
        self.assertEqual(Workspace(self.root, self.workspace.hosts).projects()[0]['cwd'], str(self.folder))
        self.assertEqual(self.workspace.path.stat().st_mode & 0o777, 0o600)

    def test_empty_project_visible_and_can_be_used_by_original_creation_lookup(self):
        project = self.create()
        result = self.library.list()
        self.assertEqual(result['projects'][0]['count'], 0)
        self.assertEqual(result['projects'][0]['key'], project['key'])
        self.assertTrue(result['projects'][0]['registered'])
        self.assertEqual(self.bridge.hosts.projects()[0]['cwd'], str(self.folder))

    def test_create_is_idempotent_and_duplicate_paths_are_rejected(self):
        self.assertEqual(self.create()['key'], self.create()['key'])
        with self.assertRaises(ValueError):
            self.workspace.create({'id': history.uid(900), 'name': 'Different', 'cwd': str(self.folder)})
        with self.assertRaises(ValueError):
            self.workspace.create({'id': history.uid(901), 'name': 'Duplicate', 'cwd': str(self.folder / '..' / 'app')})

    def test_new_directory_needs_explicit_flag_and_existing_parent(self):
        value = dict(id=history.uid(900), name='New', cwd=str(self.root / 'new-folder'))
        with self.assertRaises(ValueError): self.workspace.create(value)
        self.assertFalse((self.root / 'new-folder').exists())
        row = self.workspace.create(dict(value, createDirectory=True))
        self.assertTrue(Path(row['cwd']).is_dir())
        with self.assertRaises(ValueError): self.workspace.create(dict(value, id=history.uid(901), cwd=str(self.root / 'absent/child'), createDirectory=True))

    def test_invalid_names_paths_and_file_targets_fail(self):
        for title in ('', 'x\ny', 'x' * 121):
            with self.assertRaises(ValueError): self.workspace.create(dict(id=history.uid(900), name=title, cwd=str(self.folder)))
        for path in ('relative', '', '/tmp/\x00'):
            with self.assertRaises(ValueError): self.workspace.create(dict(id=history.uid(900), name='New', cwd=path))
        file = self.root / 'file'; file.write_text('KEEP')
        with self.assertRaises(ValueError): self.workspace.create(dict(id=history.uid(900), name='New', cwd=str(file), createDirectory=True))
        self.assertEqual(file.read_text(), 'KEEP')

    def test_display_rename_hide_restore_do_not_delete_files(self):
        p = self.create(); source = self.folder / 'keep.txt'; source.write_text('KEEP')
        self.workspace.update_project(p['key'], {'name': 'Renamed', 'hidden': True})
        self.assertEqual(self.bridge.hosts.projects(), [])
        self.assertEqual(self.library.list()['projects'], [])
        self.assertEqual(self.library.list(hidden=True)['projects'][0]['name'], 'Renamed')
        self.workspace.update_project(p['key'], {'hidden': False})
        self.assertEqual(self.bridge.hosts.projects()[0]['name'], 'Renamed')
        self.assertEqual(source.read_text(), 'KEEP')

    def test_full_index_sort_and_preferences_before_pagination(self):
        db = history.database(self.home, [{'number': n, 'cwd': str(self.folder)} for n in range(1, 131)])
        before = db.read_bytes(); p = self.create()
        self.workspace.preferences(['local|' + history.uid(1)], {'pinned': True})
        result = self.library.list(limit=1)
        self.assertEqual(result['sessions'][0]['id'], history.uid(1))
        self.assertEqual(result['projects'][0]['count'], 130)
        self.assertEqual(result['projects'][0]['key'], p['key'])
        self.workspace.preferences(['local|' + history.uid(1)], {'hidden': True})
        self.assertEqual(self.library.list()['total'], 129)
        self.assertEqual(self.library.list(hidden=True)['total'], 1)
        self.assertEqual(self.library.list(sort='title')['sessions'][0]['title'], 'Sample 10')
        self.assertEqual(db.read_bytes(), before)
        self.assertTrue(self.library.metadata(history.uid(1))['readOnly'])

    def test_browse_only_lists_directories_and_paginates(self):
        for n in range(105): (self.folder / str(n)).mkdir()
        (self.folder / 'private.txt').write_text('not a directory')
        (self.folder / '.hidden').mkdir()
        (self.folder / 'alias').symlink_to(self.root, target_is_directory=True)
        result = self.workspace.browse(str(self.folder))
        self.assertTrue(result['hasMore']); self.assertEqual(len(result['directories']), 100)
        self.assertEqual(len(self.workspace.browse(str(self.folder), 100)['directories']), 5)
        self.assertEqual(self.workspace.browse(str(self.folder), query='104')['directories'][0]['name'], '104')

    def test_agents_is_bounded_readonly_and_cannot_follow_symlink(self):
        p = self.create(); file = self.folder / 'AGENTS.md'; file.write_text('SYNTHETIC')
        self.assertEqual(self.workspace.agents(p['key'])['text'], 'SYNTHETIC')
        file.write_bytes(b'x' * (256 * 1024 + 1))
        with self.assertRaises(ValueError): self.workspace.agents(p['key'])
        file.unlink(); file.symlink_to(self.root / 'outside')
        with self.assertRaises(ValueError): self.workspace.agents(p['key'])

    def test_archive_uses_only_requested_rpc_and_never_activates(self):
        seen = []
        session = SimpleNamespace(activating=False, state={'turns': []}, action_lock=threading.RLock())
        self.bridge.session = lambda *_, **__: session
        self.bridge.store = SimpleNamespace(get=lambda key: seen.append(('gate', key)))
        self.bridge.catalog_reader = SimpleNamespace(executable='SYNTHETIC-NOT-EXECUTED')
        def run(executable, home, cwd, action):
            return action(lambda method, params: seen.append((method, params)))
        with patch('mac.workspace_http._runtime_operation', side_effect=run):
            archive(self.bridge, history.uid(1), True)
            archive(self.bridge, history.uid(1), False)
            session.state = {'turns': [{'status': 'inProgress'}]}
            with self.assertRaises(ValueError): archive(self.bridge, history.uid(1), True)
            session.state = {'turns': []}
            self.bridge.submissions = {history.uid(1) + ':queued': {'status': 'queued'}}
            with self.assertRaises(ValueError): archive(self.bridge, history.uid(1), True)
        self.assertEqual([m for m, _ in seen if m != 'gate'], ['thread/archive', 'thread/unarchive'])
        self.assertEqual(self.bridge.activated, [])


class WorkspaceHTTPTests(unittest.TestCase):
    setUpClass = classmethod(support.HTTPTests.setUpClass.__func__)
    tearDownClass = classmethod(support.HTTPTests.tearDownClass.__func__)
    request, login, tearDown = support.HTTPTests.request, support.HTTPTests.login, support.HTTPTests.tearDown

    def setUp(self):
        support.HTTPTests.setUp(self)
        self.home = Path(self.temp.name) / 'codex'; self.home.mkdir()
        history.database(self.home, [{'number': 1}, {'number': 2, 'originator': 'Codex Desktop'}])
        self.bridge = history.SpyBridge(self.home)
        self.workspace = Workspace(self.temp.name, self.bridge.hosts)
        self.bridge.hosts = ProjectHosts(self.workspace)
        self.server.bridge = self.bridge; self.server.workspace = self.workspace
        self.server.reading = ReadingLibrary(self.bridge, self.workspace)

    def authenticate(self):
        self.login()
        _, auth, _ = self.request('/api/auth', headers={'Cookie': self.cookie})
        return {'Cookie': self.cookie, 'Origin': self.base, 'X-CSRF-Token': auth['csrf']}

    def test_project_create_auth_csrf_duplicate_and_new_chat_flow(self):
        path = '/api/workspace/projects'
        body = {'action': 'create', 'id': history.uid(100), 'name': 'Created', 'cwd': str(self.home)}
        self.assertEqual(self.request(path, body, {'Origin': self.base})[0], 401)
        headers = self.authenticate()
        self.assertEqual(self.request(path, body, {'Cookie': self.cookie, 'Origin': self.base})[0], 403)
        code, value, _ = self.request(path, body, headers)
        self.assertEqual(code, 200)
        code, result, _ = self.request('/api/projects', headers=headers)
        self.assertEqual(result['projects'][0]['key'], value['project']['key'])
        # The unchanged create route resolves the newly registered directory.
        self.bridge.create_chat = lambda key, title, request: {'project': next(p for p in self.bridge.hosts.projects() if p['key'] == key)}
        code, result, _ = self.request('/api/sessions', {'project': value['project']['key'], 'title': 'Test', 'id': history.uid(101)}, headers)
        self.assertEqual(code, 200); self.assertEqual(result['project']['cwd'], str(self.home.resolve()))

    def test_readonly_preferences_never_grant_archive_or_send_capability(self):
        headers = self.authenticate()
        body = {'sessions': [{'id': history.uid(1), 'host': 'local'}], 'changes': {'pinned': True, 'hidden': True}}
        self.assertEqual(self.request('/api/workspace/preferences', body, headers)[0], 200)
        with patch('mac.workspace_http.archive') as mock:
            code, _, _ = self.request('/api/workspace/archive', {'id': history.uid(1), 'archived': True, 'confirmed': True}, headers)
            self.assertEqual(code, 403); mock.assert_not_called()
            code, _, _ = self.request('/api/workspace/archive', {'id': history.uid(2), 'archived': True, 'confirmed': True}, headers)
            self.assertEqual(code, 200); mock.assert_called_once()
        self.assertEqual(self.request('/api/sessions/' + history.uid(1) + '/send', {'text': 'NO'}, headers)[0], 403)
        self.assertEqual(self.bridge.sent, [])

    def test_batch_validation_is_atomic_and_requires_csrf(self):
        headers = self.authenticate()
        body = {'sessions': [{'id': history.uid(1)}, {'id': history.uid(999)}], 'changes': {'hidden': True}}
        self.assertEqual(self.request('/api/workspace/preferences', body, headers)[0], 404)
        self.assertEqual(self.workspace.snapshot()['sessionPrefs'], {})
        self.assertEqual(self.request('/api/workspace/preferences', body, {'Cookie': self.cookie})[0], 403)

    def test_browse_and_agents_require_auth(self):
        for path in ('/api/workspace/directories', '/api/workspace/agents'):
            self.assertEqual(self.request(path)[0], 401)
        headers = self.authenticate()
        code, result, _ = self.request('/api/workspace/directories?' + urlencode({'path': str(self.home)}), headers=headers)
        self.assertEqual(code, 200); self.assertEqual(result['directories'], [])
        self.assertEqual(self.request('/api/workspace/archive', {'id': history.uid(2), 'archived': True}, headers)[0], 400)


if __name__ == '__main__':
    unittest.main()
