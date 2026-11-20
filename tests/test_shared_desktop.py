"""Regressions for the new App Server's empty history and partial completion."""
from pathlib import Path
import sys
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from mac.runtime import activate_bridge
activate_bridge()

from bridge.service import LiveSession
from mac.shared_bridge import SharedDesktopBridge, thread_state, update_event
from mac.shared_rpc import RPCRejected


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
            call.request('thread/start', {'cwd': '/synthetic'}),
            call.request('thread/read', {'threadId': thread_id, 'includeTurns': True}),
            call.request('thread/read', {'threadId': thread_id, 'includeTurns': False}),
            call.request('thread/metadata/update', {'threadId': thread_id, 'gitInfo': {'sha': 'abc123'}}),
            call.activate(thread_id),
            call.activate(thread_id),
        ])
