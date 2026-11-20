"""Regressions for the new App Server's empty history and partial completion."""
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

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
