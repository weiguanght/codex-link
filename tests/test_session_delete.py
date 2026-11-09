"""Permanent deletion is exercised exclusively against disposable synthetic homes."""
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import test_history as history
from mac import session_delete as deletion
from mac.workspace_http import delete_conversation
from bridge.service import LiveSession


class SessionDeleteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / 'codex'; self.home.mkdir()
        self.backups = self.root / 'backups'
        self.key, self.other = history.uid(1), history.uid(2)
        history.database(self.home, [{'number': 1, 'originator': 'Codex Desktop'}, {'number': 2}])
        self.log = history.log(self.home, 1, history.message('user', 'remove me'))
        self.keep_log = history.log(self.home, 2, history.message('user', self.key))
        self.archived = history.log(self.home, 1, archived=True)
        self.index_keep = json.dumps({'id': self.other, 'text': self.key}).encode() + b'\nnot json\n'
        for relative in deletion.INDEXES:
            (self.home / relative).write_bytes(json.dumps({'id' if relative.startswith('session') else 'session_id': self.key}).encode() + b'\n' + self.index_keep)
        for relative in ('logs_2.sqlite', 'thread_history_1.sqlite', 'sqlite/codex.db'):
            path = self.home / relative; path.parent.mkdir(exist_ok=True)
            with closing(sqlite3.connect(path)) as connection, connection:
                connection.execute('CREATE TABLE records (id INTEGER PRIMARY KEY, thread_id TEXT, body BLOB)')
                connection.executemany('INSERT INTO records VALUES (?,?,?)', [(1, self.key, b'\x00delete'), (2, self.other, self.key.encode())])
        with self.connect('state_5.sqlite') as connection:
            connection.execute('CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT PRIMARY KEY)')
            connection.executemany('INSERT INTO thread_spawn_edges VALUES (?,?)', [(self.key, history.uid(3)), (history.uid(4), self.key), (self.other, history.uid(5))])
        with self.connect('sqlite/codex.db') as connection:
            connection.execute('CREATE TABLE local_thread_catalog(host_id TEXT, thread_id TEXT, title TEXT)')
            connection.execute('CREATE TABLE automations(id TEXT PRIMARY KEY, target_thread_id TEXT, name TEXT)')
            connection.executemany('INSERT INTO automations VALUES (?,?,?)', [("target-match", self.key, 'remove'), ("unrelated", self.other, 'keep')])
            connection.executemany('INSERT INTO local_thread_catalog VALUES (?,?,?)', [('local', self.key, 'delete'), ('ssh-test', self.key, 'keep remote'), ('local', self.other, 'keep other')])

    def connect(self, relative):
        connection = sqlite3.connect(self.home / relative)
        self.addCleanup(connection.close)
        return connection

    def delete(self, **kwargs):
        return deletion.permanently_delete(self.home, self.backups, self.key, **dict(confirmed=True, **kwargs))

    def test_exact_cleanup_all_databases_indexes_and_matching_logs(self):
        result = self.delete()
        self.assertTrue(result['deleted'])
        self.assertEqual(set(result['databaseRows']), set(deletion.DATABASES))
        self.assertEqual(result['sessionLogs'], 2)
        self.assertFalse(self.log.exists()); self.assertFalse(self.archived.exists())
        self.assertTrue(self.keep_log.exists())
        for relative in deletion.INDEXES:
            self.assertEqual((self.home / relative).read_bytes(), self.index_keep)
        self.assertEqual(self.connect('state_5.sqlite').execute('SELECT id FROM threads').fetchall(), [(self.other,)])
        self.assertEqual(self.connect('state_5.sqlite').execute('SELECT * FROM thread_spawn_edges').fetchall(), [(self.other, history.uid(5))])
        self.assertEqual(self.connect('sqlite/codex.db').execute('SELECT host_id,title FROM local_thread_catalog ORDER BY title').fetchall(), [('local', 'keep other'), ('ssh-test', 'keep remote')])
        self.assertEqual(self.connect('sqlite/codex.db').execute('SELECT id FROM automations').fetchall(), [('unrelated',)])
        for relative in ('logs_2.sqlite', 'thread_history_1.sqlite', 'sqlite/codex.db'):
            self.assertEqual(self.connect(relative).execute('SELECT thread_id,body FROM records').fetchall(), [(self.other, self.key.encode())])
        backup = Path(result['backup'])
        self.assertEqual(backup.stat().st_mode & 0o777, 0o700)
        self.assertEqual(json.loads((backup / 'manifest.json').read_text())['status'], 'deleted')
        with closing(sqlite3.connect(backup / 'logs_2.sqlite')) as connection:
            self.assertEqual(connection.execute('SELECT * FROM records').fetchall(), [(1, self.key, b'\x00delete')])
        for path in backup.rglob('*'):
            if path.is_file(): self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_wal_content_in_db_extension_is_backed_up_as_rows(self):
        connection = self.connect('sqlite/codex.db')
        connection.execute('PRAGMA journal_mode=WAL')
        connection.execute('INSERT INTO records VALUES (3,?,?)', (self.key, b'uncheckpointed WAL')); connection.commit()
        result = self.delete()
        with closing(sqlite3.connect(Path(result['backup']) / 'sqlite/codex.db')) as backup:
            self.assertIn((3, self.key, b'uncheckpointed WAL'), backup.execute('SELECT * FROM records').fetchall())

    def test_explicit_confirmation_and_valid_uuid_are_required_before_mutation(self):
        before = self.log.read_bytes()
        for value in (False, None, 1, 'true'):
            with self.assertRaises(PermissionError): deletion.permanently_delete(self.home, self.backups, self.key, value)
        with self.assertRaises(ValueError): deletion.permanently_delete(self.home, self.backups, '../bad', True)
        self.assertEqual(self.log.read_bytes(), before)
        self.assertFalse(self.backups.exists())

    def test_failure_before_commit_rolls_back_databases_and_restores_indexes(self):
        original = deletion._clean_index
        def fail_second(path, identifier):
            if path.name == 'history.jsonl': raise OSError('synthetic write failure')
            return original(path, identifier)
        before = {relative: (self.home / relative).read_bytes() for relative in deletion.INDEXES}
        with patch('mac.session_delete._clean_index', side_effect=fail_second):
            with self.assertRaisesRegex(deletion.SessionDeleteError, '已回滚'): self.delete()
        self.assertEqual(self.connect('state_5.sqlite').execute('SELECT COUNT(*) FROM threads').fetchone()[0], 2)
        self.assertEqual(self.connect('logs_2.sqlite').execute('SELECT COUNT(*) FROM records').fetchone()[0], 2)
        self.assertTrue(self.log.exists())
        for relative in deletion.INDEXES: self.assertEqual((self.home / relative).read_bytes(), before[relative])

    def test_partial_commit_restores_only_deleted_rows_preserving_other_changes(self):
        real_connect = sqlite3.connect
        state_path = str(self.home / 'state_5.sqlite')
        class FailingCommit(sqlite3.Connection):
            def commit(connection):
                if connection.execute('PRAGMA database_list').fetchone()[2] == state_path:
                    raise sqlite3.OperationalError('synthetic commit failure')
                return super().commit()
        def connect(*args, **kwargs):
            return real_connect(*args, **dict(kwargs, factory=FailingCommit))
        original_restore = deletion._restore_rows
        def restore(connection, source):
            # Simulate a different conversation changing after locks are released.
            connection.execute('UPDATE records SET body=? WHERE thread_id=?', (b'new unrelated content', self.other))
            return original_restore(connection, source)
        with patch('mac.session_delete.sqlite3.connect', side_effect=connect), patch('mac.session_delete._restore_rows', side_effect=restore):
            with self.assertRaisesRegex(deletion.SessionDeleteError, '已回滚'): self.delete()
        self.assertEqual(self.connect('logs_2.sqlite').execute('SELECT body FROM records ORDER BY id').fetchall(), [(b'\x00delete',), (b'new unrelated content',)])
        self.assertTrue(self.log.exists()); self.assertTrue(self.archived.exists())

    def test_concurrent_index_append_is_preserved_when_cleanup_aborts(self):
        original = deletion._clean_index
        appended = b'{"id":"another-chat","text":"concurrent append"}\n'
        def concurrent(path, identifier):
            if path.name == 'history.jsonl':
                with (self.home / 'session_index.jsonl').open('ab') as stream: stream.write(appended)
                raise OSError('synthetic concurrent failure')
            return original(path, identifier)
        with patch('mac.session_delete._clean_index', side_effect=concurrent):
            with self.assertRaisesRegex(deletion.SessionDeleteError, '恢复失败'): self.delete()
        self.assertTrue((self.home / 'session_index.jsonl').read_bytes().endswith(appended))
        self.assertEqual(self.connect('state_5.sqlite').execute('SELECT COUNT(*) FROM threads').fetchone()[0], 2)
        manifest = json.loads(next(self.backups.glob('*/manifest.json')).read_text())
        self.assertEqual(manifest['status'], 'recovery_failed')
        self.assertTrue(manifest['recoveryErrors'])

    def test_active_history_or_desktop_marker_blocks_deletion(self):
        for relative, schema, values in (
            ('thread_history_1.sqlite', 'CREATE TABLE thread_turns(thread_id TEXT, status TEXT)', (self.key, 'inProgress')),
            ('sqlite/codex.db', 'CREATE TABLE active_chat_turns(thread_id TEXT, launch_id TEXT)', (self.key, 'test-launch')),
        ):
            connection = self.connect(relative)
            with connection:
                connection.execute(schema)
                table = schema.split('(')[0].split()[-1]
                connection.execute('INSERT INTO ' + table + ' VALUES (?,?)', values)
            with self.assertRaisesRegex(deletion.SessionDeleteError, '运行|执行'): self.delete()
            self.assertTrue(self.log.exists())
            with connection: connection.execute('DROP TABLE ' + table)

    def test_symlinks_mismatched_headers_and_unrelated_files_are_untouched(self):
        outside = self.root / 'outside'; outside.mkdir()
        outside_log = history.log(outside, 1)
        alias = self.home / 'sessions/alias.jsonl'; alias.symlink_to(outside_log)
        (self.home / 'sessions/subdir').symlink_to(outside / 'sessions', target_is_directory=True)
        mismatch = self.home / ('sessions/filename-' + self.key + '.jsonl')
        mismatch.write_text(history.record('session_meta', {'id': self.other}))
        outside_index = outside / 'index'; outside_index.write_text(json.dumps({'id': self.key}))
        (self.home / 'history.jsonl').unlink(); (self.home / 'history.jsonl').symlink_to(outside_index)
        (self.home / 'sqlite/codex.db').unlink()
        (self.home / 'sqlite').rmdir(); (self.home / 'sqlite').symlink_to(outside, target_is_directory=True)
        outside_db = outside / 'codex.db'; outside_db.write_bytes(b'do not open')
        self.delete()
        self.assertTrue(alias.is_symlink()); self.assertTrue(outside_log.exists()); self.assertTrue(mismatch.exists())
        self.assertEqual(outside_db.read_bytes(), b'do not open')
        self.assertEqual(outside_index.read_text(), json.dumps({'id': self.key}))

    def test_bridge_gate_rejects_active_pending_and_uncertain_actions(self):
        session = LiveSession(self.key)
        bridge = SimpleNamespace(store=SimpleNamespace(get=lambda _: None), session=lambda *a, **k: session,
                                 lock=threading.RLock(), codex_home=self.home, live={self.key: session}, listed={self.key})
        cases = [('activating', True), ('connecting', True), ('discovering', True), ('viewers', 1),
                 ('state', {'turns': [{'status': 'inProgress'}]}), ('state', {'requests': [{'id': 'approval'}]}),
                 ('state', {'threadRuntimeStatus': {'type': 'active'}})]
        for field, value in cases:
            prior = getattr(session, field); setattr(session, field, value)
            with patch('mac.workspace_http.permanently_delete') as perform:
                with self.assertRaises(ValueError): delete_conversation(bridge, self.key, self.backups)
                perform.assert_not_called()
            setattr(session, field, prior)
        for field, value in [('submissions', {self.key + ':request': {'status': 'unknown'}}),
                             ('goal_commands', {self.key + ':goal': {'state': 'pending'}}),
                             ('message_actions', {'request': {'source': self.key, 'status': 'unknown'}})]:
            setattr(bridge, field, value)
            with self.assertRaises(ValueError): delete_conversation(bridge, self.key, self.backups)
            setattr(bridge, field, {})
        self.assertTrue(delete_conversation(bridge, self.key, self.backups)['deleted'])
        self.assertNotIn(self.key, bridge.live); self.assertNotIn(self.key, bridge.listed)

    def test_read_only_deletion_keeps_live_execution_guards(self):
        session = LiveSession(self.key)
        session.state = {'turns': [{'status': 'inProgress'}]}
        bridge = SimpleNamespace(lock=threading.RLock(), codex_home=self.home,
                                 live={self.key: session}, listed={self.key})
        with patch('mac.workspace_http.permanently_delete') as perform:
            with self.assertRaises(ValueError): delete_conversation(bridge, self.key, self.backups, read_only=True)
            perform.assert_not_called()
        session.state = None
        self.assertTrue(delete_conversation(bridge, self.key, self.backups, read_only=True)['deleted'])


if __name__ == '__main__':
    unittest.main()
