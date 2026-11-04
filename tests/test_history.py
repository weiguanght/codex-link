"""Synthetic Codex homes only. No desktop IPC, real chats, or model requests."""
import json
import io
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from mac.runtime import activate_bridge
activate_bridge()
from bridge.remote import AppHosts
from bridge.store import SessionStore
from mac.history_catalog import HistoryCatalog, HistoryUnavailable, ReadingLibrary, safe_log, public
from mac.history_reader import LogReader, MAX_RECORD
import test_link as support


def uid(number):
    return str(uuid.UUID(int=number))


def record(kind, payload):
    return json.dumps({'type': kind, 'payload': payload}, ensure_ascii=False) + '\n'


def message(role, text):
    return record('response_item', {'type': 'message', 'role': role, 'content': [{'type': 'input_text' if role == 'user' else 'output_text', 'text': text}]})


def log(home, number, content='', archived=False, cwd='/sample/project'):
    path = home / ('archived_sessions' if archived else 'sessions') / f'{number}.jsonl'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(record('session_meta', {'id': uid(number), 'cwd': cwd, 'originator': 'codex-tui'}) + content)
    return path


def database(home, rows):
    path = home / 'state_5.sqlite'
    with sqlite3.connect(path) as connection:
        connection.execute('CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, cwd TEXT, originator TEXT, source TEXT, thread_source TEXT, model TEXT, archived INTEGER, rollout_path TEXT, updated_at INTEGER)')
        for data in rows:
            row = dict(id=uid(data['number']), title='Sample ' + str(data['number']), cwd='/sample/project',
                       originator='codex-tui', source='cli', thread_source=None, model='sample-model', archived=0,
                       rollout_path=str(home / 'sessions' / f"{data['number']}.jsonl"), updated_at=data['number'])
            row.update({k: v for k, v in data.items() if k != 'number'})
            connection.execute('INSERT INTO threads (' + ','.join(row) + ') VALUES (' + ','.join('?' for _ in row) + ')', list(row.values()))
    return path


class SpyBridge:
    def __init__(self, home):
        self.codex_home = home
        self.hosts = AppHosts(home)
        self.store = SessionStore(home)
        self.lock = threading.RLock()
        self.listed = set()
        self.sent, self.activated = [], []
    def for_host(self, host):
        if host != 'local':
            raise KeyError('Unknown host')
        return self
    def send(self, *args, **kwargs):
        self.sent.append((args, kwargs))
        return {'ok': True}
    def activate(self, key):
        self.activated.append(key)
        raise AssertionError('Historical reads must not activate')


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()

    def test_sources_visible_but_only_original_desktop_sources_eligible(self):
        db = database(self.home, [
            {'number': 1, 'originator': 'Codex Desktop'}, {'number': 2},
            {'number': 3, 'originator': 'codex_exec'}, {'number': 4, 'originator': None, 'source': 'vscode'},
            {'number': 5, 'originator': None}, {'number': 6, 'originator': 'codex_mobile_bridge'},
            {'number': 7, 'thread_source': 'subagent'}, {'number': 8, 'model': 'codex-auto-review'},
        ])
        for n in range(1, 9):
            log(self.home, n)
        before = db.read_bytes()
        library = ReadingLibrary(SpyBridge(self.home))
        result = library.list()
        self.assertEqual(result['total'], 6)
        self.assertEqual({r['id'] for r in result['sessions'] if r['desktopEligible']}, {uid(1), uid(4), uid(6)})
        self.assertEqual(library.list(scope='desktop')['total'], 3)
        self.assertEqual(library.list(include_internal=True)['total'], 8)
        self.assertEqual(library.bridge.listed, {uid(1), uid(4), uid(6)})
        self.assertEqual(before, db.read_bytes())

    def test_database_optional_log_only_and_latest_title_index(self):
        log(self.home, 1, message('user', 'hello'))
        (self.home / 'session_index.jsonl').write_text(json.dumps({'id': uid(1), 'thread_name': 'old'}) + '\n' + json.dumps({'id': uid(1), 'thread_name': 'latest'}) + '\n')
        catalog = HistoryCatalog(self.home)
        rows, warnings = catalog.snapshot()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['title'], 'latest')
        self.assertTrue(rows[0]['readOnly'])
        self.assertTrue(warnings)

    def test_archive_state_not_directory_location(self):
        database(self.home, [{'number': 1, 'archived': 1}])
        log(self.home, 1)
        log(self.home, 2, archived=True)
        library = ReadingLibrary(SpyBridge(self.home))
        self.assertEqual(library.list()['total'], 0)
        self.assertEqual(library.list(archived=True)['total'], 2)

    def test_project_index_is_complete_before_pagination(self):
        database(self.home, [{'number': n, 'cwd': '/sample/' + str(n)} for n in range(1, 131)])
        library = ReadingLibrary(SpyBridge(self.home))
        result = library.list(limit=100)
        self.assertEqual((len(result['sessions']), result['total'], len(result['projects'])), (100, 130, 130))
        self.assertTrue(result['hasMore'])
        last = library.list(offset=100)
        self.assertEqual(len(last['sessions']), 30)
        self.assertFalse(last['hasMore'])
        oldest = library.list(project='local|/sample/1')
        self.assertEqual(oldest['total'], 1)
        self.assertEqual(oldest['sessions'][0]['id'], uid(1))
        self.assertEqual(library.list(query='Sample 130')['total'], 1)

    def test_missing_path_and_schema_fallback_are_explicit(self):
        database(self.home, [{'number': 1}])
        catalog = HistoryCatalog(self.home)
        row = catalog.get(uid(1))
        self.assertFalse(row['historyReadable'])
        self.assertIn('缺失', row['historyError'])
        with sqlite3.connect(self.home / 'state_5.sqlite') as c:
            c.execute('DROP TABLE threads')
        log(self.home, 2)
        rows, warnings = catalog.snapshot(force=True)
        self.assertEqual([r['id'] for r in rows], [uid(2)])
        self.assertTrue(warnings)

    def test_duplicates_and_safe_log_fallback_do_not_grant_control(self):
        original = log(self.home, 1)
        archive = log(self.home, 1, archived=True)
        database(self.home, [{'number': 1, 'rollout_path': '/outside.jsonl'}])
        catalog = HistoryCatalog(self.home)
        rows, _ = catalog.snapshot()
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]['historyReadable'])
        self.assertFalse(rows[0]['desktopEligible'])
        self.assertIn(rows[0]['rollout_path'], (str(original), str(archive)))

    def test_wrong_log_id_is_unreadable_until_matching_fallback_exists(self):
        wrong = log(self.home, 2)
        database(self.home, [{'number': 1, 'rollout_path': str(wrong)}])
        catalog = HistoryCatalog(self.home)
        row = catalog.get(uid(1))
        self.assertFalse(row['historyReadable'])
        self.assertIn('ID', row['historyError'])
        correct = log(self.home, 1)
        catalog.snapshot(force=True)
        row = catalog.get(uid(1))
        self.assertTrue(row['historyReadable'])
        self.assertEqual(row['rollout_path'], str(correct))
        self.assertTrue(row['readOnly'])

    def test_allowed_root_itself_cannot_be_symlinked_outside(self):
        with tempfile.TemporaryDirectory() as outside:
            (Path(outside) / 'x.jsonl').write_text('{}')
            (self.home / 'sessions').symlink_to(outside, target_is_directory=True)
            with self.assertRaises(HistoryUnavailable):
                safe_log(self.home, self.home / 'sessions/x.jsonl')
            rows, warnings = HistoryCatalog(self.home).snapshot()
            self.assertEqual(rows, [])
            self.assertTrue(any('安全' in w for w in warnings))

    def test_workspace_root_grouping_keeps_distinct_worktrees(self):
        database(self.home, [{'number': 1, 'cwd': '/sample/app/src'}, {'number': 2, 'cwd': '/sample/app-worktree'}])
        (self.home / '.codex-global-state.json').write_text(json.dumps({'electron-saved-workspace-roots': ['/sample/app']}))
        rows, _ = HistoryCatalog(self.home).snapshot()
        self.assertEqual({r['projectKey'] for r in rows}, {'local|/sample/app/src', 'local|/sample/app-worktree'})

    def test_broad_desktop_root_cannot_swallow_independent_projects(self):
        database(self.home, [{'number': 1, 'cwd': '/sample/one'}, {'number': 2, 'cwd': '/sample/two'}])
        (self.home / '.codex-global-state.json').write_text(json.dumps({'local-projects': {'home': {'id': 'home', 'name': 'Home', 'rootPaths': ['/sample']}}}))
        rows, _ = HistoryCatalog(self.home).snapshot()
        self.assertEqual(len({r['projectKey'] for r in rows}), 2)

    def test_large_base_instructions_are_not_retained_or_published(self):
        path = log(self.home, 1)
        path.write_text(record('session_meta', {'id': uid(1), 'cwd': '/sample', 'base_instructions': 'PRIVATE SAMPLE ' * 1000}))
        catalog = HistoryCatalog(self.home)
        rows, _ = catalog.snapshot()
        self.assertNotIn('PRIVATE SAMPLE', json.dumps([public(r) for r in rows]))
        self.assertNotIn('PRIVATE SAMPLE', json.dumps(list(catalog.log_cache.values())))

    def test_wal_rows_are_visible_and_original_bytes_unchanged(self):
        path = database(self.home, [{'number': 1}])
        with sqlite3.connect(path) as connection:
            connection.execute('PRAGMA journal_mode=WAL')
            connection.execute('INSERT INTO threads (id, title, cwd, originator, archived, updated_at) VALUES (?, ?, ?, ?, 0, 2)', (uid(2), 'WAL sample', '/sample', 'codex_exec'))
            connection.commit()
            wal = Path(str(path) + '-wal')
            before = path.read_bytes(), wal.read_bytes()
            rows, _ = HistoryCatalog(self.home).snapshot()
            self.assertEqual(len(rows), 2)
            self.assertEqual(before, (path.read_bytes(), wal.read_bytes()))

    def test_old_schema_without_originator_uses_source_conservatively(self):
        with sqlite3.connect(self.home / 'state_1.sqlite') as connection:
            connection.execute('CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT, source TEXT, archived INTEGER)')
            connection.executemany('INSERT INTO threads VALUES (?, ?, ?, ?, 0)', [(uid(1), 'One', '/sample', 'vscode'), (uid(2), 'Two', '/sample', 'cli')])
        rows, _ = HistoryCatalog(self.home).snapshot()
        self.assertEqual({r['id'] for r in rows if r['desktopEligible']}, {uid(1)})


class ReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.reader = LogReader(self.home)

    def metadata(self, path):
        return {'id': uid(1), 'title': 'Sample', 'cwd': '/sample', 'rollout_path': str(path), 'desktopEligible': False}

    def test_all_pages_and_large_detail_without_body_in_index(self):
        huge = '多字节文本🙂' * 5000
        data = ''.join(message('user' if n % 2 == 0 else 'assistant', huge if n == 149 else f'row {n}') for n in range(150))
        path = log(self.home, 1, data)
        meta = self.metadata(path)
        result = self.reader.read(meta)
        self.assertEqual(result['total'], 150)
        self.assertTrue(result['hasMore'])
        self.assertTrue(result['rows'][-1]['truncated'])
        row = result['rows'][-1]
        chunks, offset = [], 0
        while offset is not None:
            detail = self.reader.read(meta, 'detail', cursor=result['epoch'] + '.' + row['key'], offset=offset, version=row['version'])
            chunks.append(detail['text']); offset = detail['next']
        self.assertEqual(''.join(chunks), huge)
        keys = {r['key'] for r in result['rows']}
        while result['hasMore']:
            result = self.reader.read(meta, before=result['before'], limit=100)
            self.assertFalse(keys.intersection(r['key'] for r in result['rows']))
            keys.update(r['key'] for r in result['rows'])
        self.assertEqual(len(keys), 150)
        self.assertNotIn('text', self.reader.cache[str(path)]['entries'][0])
        self.assertTrue(all(not r['editable'] and not r['forkable'] for r in result['rows']))

    def test_event_only_logs_and_mirrored_events(self):
        path = log(self.home, 1, record('event_msg', {'type': 'user_message', 'message': 'hello'}) + message('user', 'hello')
                   + message('assistant', 'answer') + record('event_msg', {'type': 'agent_message', 'message': 'answer'}))
        result = self.reader.read(self.metadata(path))
        self.assertEqual([r['text'] for r in result['rows']], ['hello', 'answer'])
        path.write_text(record('session_meta', {'id': uid(1)}) + record('event_msg', {'type': 'user_message', 'message': 'old format'})
                        + record('event_msg', {'type': 'agent_message', 'message': 'still readable'}))
        self.assertEqual(self.reader.read(self.metadata(path))['total'], 2)

    def test_repeated_user_prompt_after_answer_is_not_deduplicated(self):
        path = log(self.home, 1, record('event_msg', {'type': 'user_message', 'message': 'continue'})
                   + record('event_msg', {'type': 'agent_message', 'message': 'answer'}) + message('user', 'continue'))
        self.assertEqual(self.reader.read(self.metadata(path))['total'], 3)

    def test_reasoning_is_omitted_while_tools_and_errors_remain(self):
        path = log(self.home, 1, record('response_item', {'type': 'function_call', 'name': 'shell', 'arguments': '{"cmd":"do not execute"}'})
            + record('response_item', {'type': 'function_call_output', 'output': 'result'})
            + record('response_item', {'type': 'reasoning', 'summary': [{'type': 'summary_text', 'text': 'exposed summary'}], 'encrypted_content': 'never display'})
            + record('event_msg', {'type': 'agent_reasoning', 'text': 'event reasoning'})
            + record('event_msg', {'type': 'reasoning_summary', 'message': 'event summary'})
            + record('event_msg', {'type': 'error', 'message': 'sample failure'}))
        result = self.reader.read(self.metadata(path))
        self.assertEqual([r['role'] for r in result['rows']], ['activity', 'activity', 'error'])
        self.assertEqual(result['total'], 3)
        for omitted in ('exposed summary', 'never display', 'event reasoning', 'event summary'):
            self.assertNotIn(omitted, json.dumps(result))
        with path.open('a') as stream:
            stream.write(record('event_msg', {'type': 'agent_reasoning', 'text': 'appended reasoning'}) + message('assistant', 'visible answer'))
        changes = self.reader.read(self.metadata(path), 'changes', after=result['sequence'], epoch=result['epoch'])
        self.assertEqual([r['text'] for r in changes['rows']], ['visible answer'])

    def test_partial_tail_malformed_middle_and_append_recovery(self):
        path = log(self.home, 1, message('user', 'first') + 'invalid json\n' + '{"type":')
        meta = self.metadata(path)
        result = self.reader.read(meta)
        self.assertEqual(result['total'], 1)
        self.assertEqual(len(result['meta']['historyWarnings']), 2)
        with path.open('a') as stream:
            stream.write('"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"recovered"}]}}\n')
        changes = self.reader.read(meta, 'changes', after=result['sequence'], epoch=result['epoch'])
        self.assertEqual([r['text'] for r in changes['rows']], ['recovered'])

    def test_replaced_log_resets_old_cursors(self):
        path = log(self.home, 1, message('user', 'first'))
        meta = self.metadata(path)
        old = self.reader.read(meta)
        path.write_text(record('session_meta', {'id': uid(1)}) + message('user', 'new'))
        self.assertTrue(self.reader.read(meta, before=old['before']).get('reset'))
        with self.assertRaises(HistoryUnavailable):
            self.reader.read(meta, 'detail', cursor=old['before'])

    def test_identity_mismatch_and_symlink_escape(self):
        path = log(self.home, 2, message('user', 'other thread'))
        with self.assertRaises(HistoryUnavailable):
            self.reader.read(self.metadata(path))
        with tempfile.TemporaryDirectory() as outside:
            external = Path(outside) / 'x.jsonl'; external.write_text('{}')
            (self.home / 'sessions/escape.jsonl').symlink_to(external)
            with self.assertRaises(HistoryUnavailable):
                self.reader.read(self.metadata(self.home / 'sessions/escape.jsonl'))

    def test_truncated_during_scan_does_not_loop_at_eof(self):
        data = record('session_meta', {'id': uid(1)}).encode()
        with self.assertRaises(HistoryUnavailable):
            self.reader._scan(None, uid(1), io.BytesIO(data), (0, 0, len(data) + 100, 0, 0), None)

    def test_oversized_record_is_reported_and_later_messages_survive(self):
        path = log(self.home, 1, 'x' * (MAX_RECORD + 10) + '\n' + message('user', 'after huge line'))
        result = self.reader.read(self.metadata(path))
        self.assertEqual(result['rows'][0]['text'], 'after huge line')
        self.assertTrue(any('8 MiB' in w for w in result['meta']['historyWarnings']))


class ReadingHTTPTests(unittest.TestCase):
    setUpClass = classmethod(support.HTTPTests.setUpClass.__func__)
    tearDownClass = classmethod(support.HTTPTests.tearDownClass.__func__)
    request, login, tearDown = support.HTTPTests.request, support.HTTPTests.login, support.HTTPTests.tearDown

    def setUp(self):
        support.HTTPTests.setUp(self)
        self.home = Path(self.temp.name) / 'codex'; self.home.mkdir()
        database(self.home, [{'number': 1}, {'number': 2, 'originator': 'Codex Desktop'}])
        log(self.home, 1, message('user', 'synthetic only'))
        log(self.home, 2, message('user', 'desktop history'))
        self.bridge = SpyBridge(self.home)
        self.server.bridge = self.bridge
        self.server.reading = ReadingLibrary(self.bridge)

    def test_discovery_and_history_require_authentication(self):
        for path in ('/api/sessions', '/api/session-meta/' + uid(1), '/api/history/' + uid(1) + '/timeline'):
            self.assertEqual(self.request(path)[0], 401)
        self.login()
        headers = {'Cookie': self.cookie}
        code, rows, _ = self.request('/api/sessions', headers=headers)
        self.assertEqual((code, rows['total']), (200, 2))
        for path in ('/api/history/' + uid(1) + '/timeline', '/api/sessions/' + uid(1) + '/timeline'):
            code, result, _ = self.request(path, headers=headers)
            self.assertEqual(code, 200)
            self.assertTrue(result['meta']['readOnly'])
        self.assertEqual(self.bridge.activated, [])

    def test_readonly_write_guard_cannot_be_bypassed_by_direct_api(self):
        self.login()
        _, auth, _ = self.request('/api/auth', headers={'Cookie': self.cookie})
        headers = {'Cookie': self.cookie, 'Origin': self.base, 'X-CSRF-Token': auth['csrf']}
        for action in ('reconnect', 'send', 'stop', 'respond', 'uploads', 'rename', 'settings', 'message-action', 'notifications', 'goal/status', 'queue'):
            code, result, _ = self.request('/api/sessions/' + uid(1) + '/' + action, {'activate': True}, headers)
            self.assertEqual((code, result.get('code')), (403, 'read_only'), action)
        self.assertEqual(self.bridge.sent, [])
        self.assertEqual(self.bridge.activated, [])
        # Existing desktop send path retains its original authorization checks.
        path = '/api/sessions/' + uid(2) + '/send'
        body = {'text': 'SYNTHETIC', 'id': uid(99)}
        self.assertEqual(self.request(path, body, {'Cookie': self.cookie, 'Origin': self.base})[0], 403)
        self.assertEqual(self.request(path, body, headers)[0], 200)
        self.assertEqual(len(self.bridge.sent), 1)

    def test_explicit_readonly_desktop_history_does_not_activate(self):
        self.login()
        code, result, _ = self.request('/api/history/' + uid(2) + '/timeline', headers={'Cookie': self.cookie})
        self.assertEqual(code, 200)
        self.assertTrue(result['meta']['readOnly'])
        self.assertEqual(self.bridge.activated, [])


if __name__ == '__main__':
    unittest.main()
