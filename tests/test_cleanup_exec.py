"""Destructive cleanup tests use disposable, synthetic Codex homes ONLY."""
from contextlib import closing, redirect_stdout, redirect_stderr
import io
import os
import subprocess
import sys
import types
import json
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
COMMAND = ROOT / '清理CodexExec对话.command'
EMBEDDED = COMMAND.read_text().split("<<'CODEX_LINK_EXEC_CLEANUP_PY'\n", 1)[1].rsplit('\nCODEX_LINK_EXEC_CLEANUP_PY', 1)[0]
cleanup = types.ModuleType('cleanup_embedded')
exec(compile(EMBEDDED, str(COMMAND), 'exec'), cleanup.__dict__)


def uid(n): return str(uuid.UUID(int=n))


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.db = self.home / 'state_5.sqlite'
        with closing(sqlite3.connect(self.db)) as c:
            c.executescript('''
                CREATE TABLE threads(id TEXT PRIMARY KEY, source TEXT, originator TEXT,
                    rollout_path TEXT, archived INTEGER DEFAULT 0, title TEXT, updated_at INTEGER DEFAULT 1);
                CREATE TABLE thread_dynamic_tools(thread_id TEXT REFERENCES threads(id) ON DELETE CASCADE, name TEXT);
                CREATE TABLE thread_attachments(id TEXT PRIMARY KEY, thread_id TEXT REFERENCES threads(id) ON DELETE CASCADE);
                CREATE TABLE thread_spawn_edges(parent_thread_id TEXT, child_thread_id TEXT, status TEXT);
                CREATE TABLE projects(id TEXT PRIMARY KEY, name TEXT);
                INSERT INTO projects VALUES ('keep', 'KEEP');
            ''')

    def sql(self, query, args=()):
        with closing(sqlite3.connect(self.db)) as c:
            result = c.execute(query, args).fetchall(); c.commit(); return result

    def log(self, n, source='exec', archived=False, originator=None, name=None):
        path = self.home / ('archived_sessions' if archived else 'sessions') / '2026/10' / (name or f'{uid(n)}.jsonl')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': uid(n), 'source': source, 'originator': originator}}) + '\n' +
                        json.dumps({'type': 'event_msg', 'payload': {'message': 'Synthetic conversation only'}}) + '\n')
        return path

    def row(self, n, source='exec', log=True, archived=False, originator=None, title='Test'):
        path = self.log(n, source, archived, originator) if log else self.home / 'sessions' / f'{uid(n)}.jsonl'
        self.sql('INSERT INTO threads(id,source,originator,rollout_path,archived,title) VALUES (?,?,?,?,?,?)',
                 (uid(n), source, originator, str(path), int(archived), title))
        return path

    def plan(self):
        with closing(sqlite3.connect(self.db)) as conn:
            conn.row_factory = sqlite3.Row
            return cleanup.build_plan(self.home, self.db, conn)

    def clean(self, **kwargs): return cleanup.clean(self.home, self.db, **kwargs)


    def test_command_runs_standalone_and_deletes_without_confirmation(self):
        removed = self.row(1); keep = self.row(2, 'cli', title='codex exec cleanup')
        before = keep.read_bytes()
        folder = self.home / 'separate folder with spaces'; folder.mkdir()
        script = folder / COMMAND.name; shutil.copy2(COMMAND, script)
        self.assertTrue(os.access(script, os.X_OK))
        # Test the actual shell entry, using only a synthetic home. No repository
        # .py dependency, no stdin, no preview/apply/confirmation flags.
        result = subprocess.run([str(script)], cwd=folder, env={**os.environ, 'HOME': str(self.home),
            'CODEX_HOME': str(self.home), 'CODEX_STATE_DATABASE': self.db.name, 'CODEX_LINK_PYTHON': sys.executable},
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('已清理 1 条', result.stdout)
        self.assertFalse(removed.exists()); self.assertEqual(keep.read_bytes(), before)
        self.assertEqual(self.sql('SELECT id FROM threads'), [(uid(2),)])
        self.assertFalse((self.home / 'exec-cleanup-backups').exists())
        self.assertEqual(list(self.home.rglob('*.sqlite')), [self.db])
        self.assertFalse(list(self.home.glob('.exec-index-*')))

    def test_exact_type_filter_and_legacy_originator_fallback(self):
        for value in ('exec', '"exec"'): self.assertTrue(cleanup.is_exec(value))
        self.assertTrue(cleanup.is_exec(None, 'codex_exec'))
        for value in ('cli', 'vscode', 'execute', 'subagent', '{"subagent":{"source":"exec"}}', {'subagent': 'exec'}):
            self.assertFalse(cleanup.is_exec(value, 'codex_exec'))
        self.assertFalse(cleanup.is_exec(None, 'codex-tui'))
        self.row(1, 'cli', originator='codex_exec')
        self.row(2, None, originator='codex_exec')
        self.assertEqual([t['id'] for t in self.plan()['targets']], [uid(2)])

    def test_delete_active_archived_orphan_duplicates_and_missing_logs(self):
        first = self.row(1); archived = self.row(2, archived=True); self.row(3, log=False)
        orphan = self.log(4); duplicate = self.log(1, name='copy.jsonl'); keep = self.row(5, 'cli')
        keep_bytes = keep.read_bytes()
        result = self.clean()
        self.assertEqual((result['conversations'], result['threads'], result['logs']), (4, 3, 4))
        self.assertEqual(self.sql('SELECT id FROM threads'), [(uid(5),)])
        self.assertEqual(keep.read_bytes(), keep_bytes)
        for path in (first, archived, orphan, duplicate): self.assertFalse(path.exists())
        self.assertFalse((self.home / 'exec-cleanup-backups').exists())
        self.assertEqual(self.clean()['status'], 'nothing_to_do')

    def test_related_rows_and_index_only_remove_target_references(self):
        self.row(1); self.row(2, 'cli'); self.row(3, '{"subagent":{"parent":"exec"}}')
        for n in (1, 2):
            self.sql('INSERT INTO thread_dynamic_tools VALUES (?, ?)', (uid(n), 'tool'))
            self.sql('INSERT INTO thread_attachments VALUES (?, ?)', ('attachment-' + str(n), uid(n)))
        self.sql('INSERT INTO thread_spawn_edges VALUES (?, ?, ?)', (uid(1), uid(3), 'done'))
        self.sql('INSERT INTO thread_spawn_edges VALUES (?, ?, ?)', (uid(2), uid(3), 'done'))
        index = self.home / 'session_index.jsonl'
        retained = b'{invalid line}\n' + json.dumps({'id': uid(2), 'thread_name': 'KEEP'}).encode() + b'\n'
        original = json.dumps({'id': uid(1), 'thread_name': 'REMOVE'}).encode() + b'\n' + retained
        index.write_bytes(original)
        result = self.clean()
        self.assertEqual(index.read_bytes(), retained)
        self.assertFalse(list(self.home.glob('.exec-index-*')))
        self.assertEqual(result['indexRows'], 1)
        self.assertEqual(self.sql('SELECT thread_id FROM thread_dynamic_tools'), [(uid(2),)])
        self.assertEqual(self.sql('SELECT thread_id FROM thread_attachments'), [(uid(2),)])
        self.assertEqual(self.sql('SELECT parent_thread_id FROM thread_spawn_edges'), [(uid(2),)])
        self.assertEqual(self.sql('SELECT id FROM threads ORDER BY id'), [(uid(2),), (uid(3),)])
        self.assertEqual(self.sql('SELECT name FROM projects'), [('KEEP',)])

    def test_wal_records_are_deleted_without_copying_database(self):
        writer = sqlite3.connect(self.db); self.addCleanup(writer.close)
        writer.execute('PRAGMA journal_mode=WAL'); writer.execute('PRAGMA wal_autocheckpoint=0')
        for n, source in ((1, 'exec'), (2, 'cli')):
            path = self.log(n, source)
            writer.execute('INSERT INTO threads(id,source,rollout_path) VALUES (?,?,?)', (uid(n), source, str(path)))
        writer.commit()
        self.assertTrue(Path(str(self.db) + '-wal').exists())
        result = self.clean(); self.assertEqual(result['threads'], 1)
        self.assertEqual(self.sql('SELECT id FROM threads'), [(uid(2),)])
        self.assertEqual(list(self.home.rglob('*.sqlite')), [self.db])

    def test_log_change_after_scan_aborts_before_file_deletion(self):
        log = self.row(1)
        def mutate(stage):
            if stage == 'before_files':
                with log.open('a') as f: f.write('Synthetic new event\n')
        with self.assertRaises(cleanup.CleanupError): self.clean(hook=mutate)
        self.assertTrue(log.exists()); self.assertEqual(len(self.sql('SELECT id FROM threads')), 1)
        self.sql('UPDATE threads SET source=? WHERE id=?', ('cli', uid(1)))
        self.assertEqual(self.clean()['threads'], 0)
        self.assertEqual(self.sql('SELECT source FROM threads'), [('cli',)])

    def test_partial_file_failure_does_not_claim_deleted_logs_were_restored(self):
        first, second = self.row(1), self.row(2)
        def fail(stage):
            if stage == 'log_deleted': raise RuntimeError('Synthetic failure')
        with self.assertRaises(cleanup.CleanupError) as error: self.clean(hook=fail)
        self.assertIn('已永久删除 1 个日志文件', str(error.exception))
        self.assertFalse(first.exists()); self.assertTrue(second.exists())
        self.assertEqual(len(self.sql('SELECT id FROM threads')), 2)
        result = self.clean()
        self.assertEqual((result['threads'], result['logs']), (2, 1))
        self.assertFalse((self.home / 'exec-cleanup-backups').exists())

    def test_failure_before_commit_preserves_sql_but_not_removed_files(self):
        removed = self.row(1); keep = self.row(2, 'cli')
        index = self.home / 'session_index.jsonl'
        keep_line = json.dumps({'id': uid(2)}) + '\n'
        index.write_text(json.dumps({'id': uid(1)}) + '\n' + keep_line)
        def fail(stage):
            if stage == 'before_commit': raise RuntimeError('Synthetic failure')
        with self.assertRaises(cleanup.CleanupError) as error: self.clean(hook=fail)
        self.assertIn('标题索引已修改：True', str(error.exception))
        self.assertFalse(removed.exists()); self.assertTrue(keep.exists())
        self.assertEqual(index.read_text(), keep_line)
        self.assertEqual(len(self.sql('SELECT id FROM threads')), 2)
        self.assertFalse(list(self.home.glob('.exec-index-*')))

    def test_source_conflict_mismatched_id_and_shared_path_block(self):
        log = self.row(1); self.log(1, 'cli', name='contradiction.jsonl')
        self.assertTrue(self.plan()['blocked'])
        with self.assertRaises(cleanup.CleanupError): self.clean()
        self.assertTrue(log.exists())
        (log.parent / 'contradiction.jsonl').unlink()
        other = self.row(2, 'cli')
        self.sql('UPDATE threads SET rollout_path=? WHERE id=?', (str(log), uid(2)))
        self.assertTrue(self.plan()['blocked'])
        self.sql('UPDATE threads SET rollout_path=? WHERE id=?', (str(other), uid(1)))
        self.assertTrue(self.plan()['blocked'])

    def test_symlinks_and_outside_paths_never_deleted(self):
        outside = self.home / 'keep.jsonl'; outside.write_text('KEEP')
        log = self.row(1); log.unlink(); log.symlink_to(outside)
        plan = self.plan(); self.assertTrue(plan['blocked'])
        with self.assertRaises(cleanup.CleanupError): self.clean()
        self.assertEqual(outside.read_text(), 'KEEP')
        log.unlink(); self.sql('UPDATE threads SET rollout_path=?', (str(outside),))
        self.assertTrue(self.plan()['blocked'])
        (self.home / 'archived_sessions').symlink_to(self.home, target_is_directory=True)
        with self.assertRaises(cleanup.CleanupError): self.plan()

    def test_unknown_cascades_or_triggers_fail_closed(self):
        self.row(1)
        self.sql('CREATE TABLE unknown(thread_id TEXT REFERENCES threads(id) ON DELETE CASCADE)')
        with self.assertRaises(cleanup.CleanupError): self.plan()
        self.sql('DROP TABLE unknown')
        self.sql('CREATE TRIGGER unsafe AFTER DELETE ON threads BEGIN DELETE FROM projects; END')
        with self.assertRaises(cleanup.CleanupError): self.plan()
        self.assertEqual(self.sql('SELECT name FROM projects'), [('KEEP',)])

    def test_audited_native_timestamp_triggers_are_supported(self):
        for column in ('created_at', 'created_at_ms', 'updated_at_ms', 'recency_at', 'recency_at_ms'):
            self.sql('ALTER TABLE threads ADD COLUMN ' + column + ' INTEGER')
        for sql in cleanup.SAFE_TRIGGERS: self.sql(sql)
        self.row(1); self.row(2, 'cli')
        self.clean()
        self.assertEqual(self.sql('SELECT id, updated_at_ms FROM threads'), [(uid(2), 1000)])

    def test_multiple_databases_require_explicit_choice(self):
        shutil.copyfile(self.db, self.home / 'state_4.sqlite')
        with self.assertRaises(cleanup.CleanupError): cleanup.database_path(self.home)
        self.assertEqual(cleanup.database_path(self.home, 'state_5.sqlite'), self.db)

    def test_default_main_needs_no_apply_flag_or_stdin(self):
        removed = self.row(1)
        with patch('builtins.input', side_effect=AssertionError('Must not prompt')), redirect_stdout(io.StringIO()):
            self.assertEqual(cleanup.main(['--codex-home', str(self.home)]), 0)
        self.assertFalse(removed.exists())
        self.assertEqual(self.sql('SELECT id FROM threads'), [])


if __name__ == '__main__': unittest.main()
