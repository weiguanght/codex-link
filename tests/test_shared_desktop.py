"""Regressions for the new App Server's empty history and partial completion."""
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call
import test_history as history

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from mac.runtime import activate_bridge
activate_bridge()

from bridge.service import LiveSession
from mac.shared_bridge import SharedDesktopBridge, thread_state, update_event
from mac.shared_rpc import RPCRejected
from mac.desktop_store import DesktopSessionStore, SharedDesktopSessionStore
from mac.history_catalog import ReadingLibrary


class SharedDesktopTests(unittest.TestCase):
    def setUp(self):
        self.thread = {'id': 'test-thread', 'status': {'type': 'idle'}}
        self.bridge = SharedDesktopBridge.__new__(SharedDesktopBridge)
        self.bridge.ipc = Mock()

    def test_empty_history_only_accepts_known_runtime_error(self):
        def request(method, params):
            if method == 'thread/resume':
                self.assertTrue(params['excludeTurns'])
                return {'thread': self.thread}
            raise RPCRejected(method, {'message': 'list_turns is not supported yet'})

        self.bridge.ipc.request.side_effect = request
        self.assertEqual(self.bridge._snapshot('test-thread', resume=True)['turns'], [])
        self.thread['preview'] = 'existing chat'
        with self.assertRaises(RPCRejected):
            self.bridge._snapshot('test-thread', resume=True)

    def test_partial_completion_preserves_user_message_and_submission_identity(self):
        state = thread_state(self.thread, {'data': []})
        self.assertTrue(update_event(state, 'turn/started', {
            'turn': {'id': 'turn', 'status': 'inProgress', 'items': []},
        }))
        user = {'id': 'user', 'type': 'userMessage', 'clientId': 'submission',
                'content': [{'type': 'text', 'text': 'test'}]}
        agent = {'id': 'agent', 'type': 'agentMessage', 'text': ''}
        for item in (user, agent):
            update_event(state, 'item/started', {'turnId': 'turn', 'item': item})
        update_event(state, 'item/agentMessage/delta', {'turnId': 'turn', 'itemId': 'agent', 'delta': 'one'})
        update_event(state, 'turn/completed', {
            'turn': {'id': 'turn', 'status': 'completed', 'items': [dict(agent, text='one two')]},
        })
        session = LiveSession('test-thread')
        session.state = state
        messages = session.view()['turns'][0]['messages']
        self.assertEqual([(row['role'], row['text']) for row in messages], [('user', 'test'), ('assistant', 'one two')])
        self.assertEqual(messages[0]['requestId'], 'submission')

    def test_list_observer_does_not_resume_threads(self):
        self.bridge._subscribe = Mock()
        self.bridge._attach(SimpleNamespace(), timeout=0)
        self.bridge._subscribe.assert_not_called()

    def test_legacy_history_uses_its_declared_contract_not_paginated_rpc(self):
        turns = [{'id': key, 'status': 'completed', 'items': []} for key in ('first', 'second')]
        thread = dict(self.thread, historyMode='legacy', preview='existing chat')
        self.bridge.ipc.request.side_effect = [{'thread': thread}, {'thread': dict(thread, turns=turns)}]
        state = self.bridge._snapshot('test-thread')
        self.assertEqual([turn['turnId'] for turn in state['turns']], ['first', 'second'])
        self.assertTrue(state['turnsPagination']['hasLoadedOldest'])
        self.assertEqual(self.bridge.ipc.request.call_args_list, [
            call('thread/read', {'threadId': 'test-thread'}),
            call('thread/read', {'threadId': 'test-thread', 'includeTurns': True}),
        ])

    def test_unnamed_chat_is_indexed_before_activation_and_retry_reuses_it(self):
        create_id = '00000000-0000-0000-0000-000000000001'
        thread_id = '00000000-0000-0000-0000-000000000002'
        self.bridge.codex_home = Path('/synthetic/codex')
        self.bridge.create_lock = threading.Lock()
        self.bridge.creations = {}
        self.bridge._save_creations = Mock()
        self.bridge.activate = Mock()
        self.bridge.ipc.request.side_effect = [
            {'thread': {'id': thread_id}},
            RPCRejected('thread/read', {'message': 'list_turns is not supported yet'}),
            {'thread': {'id': thread_id, 'gitInfo': {'sha': 'abc123'}}},
            {'thread': {'id': thread_id}},
        ]
        calls = Mock()
        calls.attach_mock(self.bridge.ipc.request, 'request')
        calls.attach_mock(self.bridge.activate, 'activate')

        first = self.bridge.create_chat(None, '', create_id)
        self.assertEqual(self.bridge.create_chat(None, '', create_id), first)
        self.assertEqual(first['id'], thread_id)
        self.assertEqual(calls.mock_calls, [
            call.request('thread/start', {'cwd': '/synthetic', 'ephemeral': False,
                                           'historyMode': 'paginated', 'threadSource': 'user'}),
            call.request('thread/read', {'threadId': thread_id, 'includeTurns': True}),
            call.request('thread/read', {'threadId': thread_id, 'includeTurns': False}),
            call.request('thread/metadata/update', {'threadId': thread_id, 'gitInfo': {'sha': 'abc123'}}),
            call.activate(thread_id),
            call.activate(thread_id),
        ])


class SharedSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.db = history.database(self.home, [
            {'number': 1, 'source': 'vscode'},  # gateway-created, daemon says TUI
            {'number': 2, 'source': 'vscode'},  # unrelated TUI stays read-only
            {'number': 3, 'originator': 'codex_link', 'source': 'vscode'},
            {'number': 4, 'originator': 'Codex Desktop', 'source': 'vscode'},
            {'number': 5, 'thread_source': 'subagent'},
            {'number': 6, 'originator': 'codex_exec', 'source': 'exec'},
            {'number': 7, 'model': 'codex-auto-review'},
            {'number': 8, 'archived': 1},
        ])
        for n in range(1, 10):
            history.log(self.home, n)
        self.bridge = history.SpyBridge(self.home)
        self.bridge.creations = {str(n): {'id': history.uid(n), 'host': 'local'} for n in (1, 3, 5, 7, 8, 9)}
        self.bridge.created_thread_ids = lambda: SharedDesktopBridge.created_thread_ids(self.bridge)
        self.store = SharedDesktopSessionStore(self.home, self.bridge.created_thread_ids)
        self.library = ReadingLibrary(self.bridge)

    def test_only_confirmed_gateway_ids_supplement_whitelist_without_db_rewrites(self):
        before = self.db.read_bytes()
        for n in (1, 3, 4):
            self.assertEqual(self.store.get(history.uid(n))['id'], history.uid(n))
            self.assertFalse(self.library.metadata(history.uid(n))['readOnly'])
        for n in (2, 5, 6, 7, 9):
            with self.assertRaises(KeyError): self.store.get(history.uid(n))
            self.assertTrue(self.library.metadata(history.uid(n))['readOnly'])
        with self.assertRaises(KeyError): DesktopSessionStore(self.home).get(history.uid(1))
        self.assertFalse(self.library.convert_cli_to_desktop(history.uid(1))['readOnly'])
        self.assertEqual(self.db.read_bytes(), before)
        with sqlite3.connect(self.db) as db:
            self.assertEqual(db.execute('SELECT originator FROM threads WHERE id=?', (history.uid(1),)).fetchone()[0], 'codex-tui')

    def test_list_pagination_search_archive_and_catalog_agree(self):
        self.assertEqual([row['id'] for row in self.store.list()], [history.uid(n) for n in (4, 3, 1)])
        self.assertEqual([row['id'] for row in self.store.list(limit=1, offset=1)], [history.uid(3)])
        self.assertEqual([row['id'] for row in self.store.list(query='Sample 1')], [history.uid(1)])
        self.assertEqual([row['id'] for row in self.store.list(query='%')], [history.uid(n) for n in (4, 3, 1)])
        self.assertEqual([row['id'] for row in self.store.list(archived=True)], [history.uid(8)])
        self.assertEqual({row['id'] for row in self.library.list(scope='desktop')['sessions']}, {history.uid(n) for n in (1, 3, 4)})

    def test_source_ledger_changes_are_dynamic_and_deleted_requests_are_tombstoned(self):
        self.bridge.creations['1']['deleted'] = True
        self.bridge.creations['unconfirmed'] = {'host': 'local'}
        self.bridge.creations['remote'] = {'host': 'ssh-test', 'id': history.uid(2)}
        with self.assertRaises(KeyError): self.store.get(history.uid(1))
        self.library.catalog.expires = 0
        self.assertTrue(self.library.metadata(history.uid(1))['readOnly'])
        self.assertNotIn(history.uid(2), self.bridge.created_thread_ids())
