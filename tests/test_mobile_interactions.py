"""Shared-desktop approvals/input: exact wire replies, replay and stale cards."""
import json
from pathlib import Path
import sys
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from mac.runtime import activate_bridge
activate_bridge()

from bridge.ipc import IPCError
from bridge.model import normalize_request, async_requests
from bridge.service import LiveSession
from mac.native_http import capabilities
from mac.shared_bridge import SharedDesktopBridge, thread_state
from mac.shared_rpc import SharedRPC

THREAD = '00000000-0000-0000-0000-000000000001'
OTHER = '00000000-0000-0000-0000-000000000002'


class Socket:
    def __init__(self):
        self.sent = []
        self.error = None
        self.closed = False

    def send(self, data):
        self.sent.append(json.loads(data))
        if self.error:
            raise self.error

    def __iter__(self):
        return iter(())

    def close(self):
        self.closed = True


class RequestTransportTests(unittest.TestCase):
    def setUp(self):
        self.socket = Socket()
        self.rpc = SharedRPC('/synthetic/socket', '/synthetic/home', Mock(), Mock(), lambda: True)
        self.rpc.socket, self.rpc.client_id = self.socket, 'shared-app-server'

    def request(self, method='item/commandExecution/requestApproval', identifier=7, thread=THREAD, **params):
        raw = {'id': identifier, 'method': method,
               'params': {'threadId': thread, 'turnId': 'turn', 'itemId': 'item', **params}}
        return self.rpc._server_event(self.socket, raw)

    def resolve(self, identifier=7, thread=THREAD):
        return self.rpc._server_event(self.socket, {'method': 'serverRequest/resolved',
                                                   'params': {'threadId': thread, 'requestId': identifier}})

    def test_reply_is_json_rpc_result_not_an_outbound_request(self):
        row = self.request(command='echo test')
        self.assertTrue(row['id'].startswith('shared:'))
        self.assertNotEqual(row['id'], 7)
        result = self.rpc.respond(THREAD, row['id'], {'decision': 'accept'})
        self.assertEqual(result['status'], 'submitted')
        self.assertEqual(self.socket.sent, [{'id': 7, 'result': {'decision': 'accept'}}])
        self.assertTrue(normalize_request(self.rpc.requests(THREAD)[0])['submitted'])

    def test_duplicate_response_sends_once_and_conflicting_response_is_rejected(self):
        row = self.request()
        self.rpc.respond(THREAD, row['id'], {'decision': 'accept'})
        self.assertTrue(self.rpc.respond(THREAD, row['id'], {'decision': 'accept'})['duplicate'])
        with self.assertRaisesRegex(ValueError, '不同回应'):
            self.rpc.respond(THREAD, row['id'], {'decision': 'decline'})
        self.assertEqual(len(self.socket.sent), 1)

    def test_replayed_request_preserves_identity_and_submission_state(self):
        row = self.request(command='echo test')
        self.rpc.respond(THREAD, row['id'], {'decision': 'decline'})
        self.assertEqual(self.request(command='echo test')['id'], row['id'])
        self.assertTrue(self.rpc.requests(THREAD)[0]['submitted'])
        self.assertEqual(len(self.rpc.requests(THREAD)), 1)

    def test_wire_integer_and_string_ids_remain_distinct(self):
        first, second = self.request(identifier=7), self.request(identifier='7')
        self.assertNotEqual(first['id'], second['id'])
        self.rpc.respond(THREAD, second['id'], {'decision': 'decline'})
        self.assertEqual(self.socket.sent[0]['id'], '7')
        self.assertEqual(self.resolve()['params']['requestId'], first['id'])
        self.assertEqual([r['id'] for r in self.rpc.requests(THREAD)], [second['id']])

    def test_resolved_wrong_thread_and_unknown_requests_cannot_be_answered(self):
        row = self.request()
        with self.assertRaises(ValueError):
            self.rpc.respond(OTHER, row['id'], {'decision': 'accept'})
        self.assertIsNone(self.resolve(thread=OTHER))
        self.assertEqual(len(self.rpc.requests(THREAD)), 1)
        self.resolve()
        for identifier in (row['id'], 7, '7', None):
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                self.rpc.respond(THREAD, identifier, {'decision': 'accept'})
        self.assertEqual(self.socket.sent, [])

    def test_connection_loss_clears_requests_and_old_cards_cannot_target_replayed_ids(self):
        row = self.request()
        self.rpc._read(self.socket)
        self.assertIsNone(self.rpc.socket)
        self.assertEqual(self.rpc.requests(THREAD), [])
        self.rpc.disconnect.assert_called_once()
        old_socket = self.socket
        self.socket = Socket()
        self.rpc.socket, self.rpc.client_id = self.socket, 'shared-app-server'
        replay = self.request()
        self.assertNotEqual(row['id'], replay['id'])
        with self.assertRaises(ValueError):
            self.rpc.respond(THREAD, row['id'], {'decision': 'accept'})
        self.assertIsNone(self.rpc._server_event(old_socket, {'method': 'serverRequest/resolved',
                                                            'params': {'threadId': THREAD, 'requestId': 7}}))
        self.assertEqual([r['id'] for r in self.rpc.requests(THREAD)], [replay['id']])

    def test_uncertain_send_is_not_automatically_retried(self):
        row = self.request()
        self.socket.error = OSError('synthetic dropped write')
        with self.assertRaisesRegex(IPCError, '结果未确认'):
            self.rpc.respond(THREAD, row['id'], {'decision': 'accept'})
        self.assertTrue(self.rpc.requests(THREAD)[0]['submitted'])
        self.assertTrue(self.rpc.respond(THREAD, row['id'], {'decision': 'accept'})['duplicate'])
        self.assertEqual(len(self.socket.sent), 1)

    def test_closed_thread_only_discards_its_own_requests(self):
        self.request()
        other = self.request(identifier=8, thread=OTHER)
        self.rpc._server_event(self.socket, {'method': 'thread/closed', 'params': {'threadId': THREAD}})
        self.assertEqual(self.rpc.requests(THREAD), [])
        self.assertEqual([r['id'] for r in self.rpc.requests(OTHER)], [other['id']])

    def test_read_copies_cannot_mutate_approval_scope(self):
        self.request(permissions={'network': {'enabled': False}})
        rows = self.rpc.requests(THREAD)
        rows[0]['params']['permissions']['network']['enabled'] = True
        self.assertFalse(self.rpc.requests(THREAD)[0]['params']['permissions']['network']['enabled'])

    def test_global_auth_requests_and_invalid_ids_are_not_forwarded(self):
        for identifier in (None, True, [], {}):
            with self.subTest(identifier=identifier):
                self.assertIsNone(self.request(identifier=identifier))
        self.assertIsNone(self.rpc._server_event(self.socket, {
            'id': 42, 'method': 'account/chatgptAuthTokens/refresh', 'params': {'challenge': 'private'},
        }))
        self.assertEqual(self.rpc.requests(THREAD), [])

    def test_initialize_registers_one_time_human_approval_support(self):
        self.rpc.socket = self.rpc.client_id = None
        self.rpc._request = Mock(return_value={'codexHome': '/synthetic/home'})
        with patch('mac.shared_rpc.unix_connect', return_value=self.socket), patch('mac.shared_rpc.threading.Thread'):
            self.rpc.connect()
        initialize = self.rpc._request.call_args.args
        self.assertEqual(initialize[0], 'initialize')
        self.assertEqual(initialize[1]['capabilities'], {'experimentalApi': True, 'requiredHumanApproval': True})
        self.assertEqual(self.socket.sent, [{'method': 'initialized'}])


class SharedInteractionTests(RequestTransportTests):
    def setUp(self):
        super().setUp()
        self.session = LiveSession(THREAD)
        self.session.state = thread_state({'id': THREAD, 'status': {'type': 'active'}}, {'data': []})
        self.session.state['requests'] = []
        self.session.connected, self.session.owner = True, self.rpc.client_id
        self.bridge = SharedDesktopBridge.__new__(SharedDesktopBridge)
        self.bridge.ipc, self.bridge.host = self.rpc, 'local'
        self.bridge.accounts = SimpleNamespace(index={}, gate=threading.RLock(), check_ready=Mock())
        self.bridge.lock, self.bridge.closed = threading.RLock(), threading.Event()
        self.bridge.submit_lock, self.bridge.submissions = threading.Lock(), {}
        self.bridge.live = {THREAD: self.session}
        self.bridge._target = Mock(return_value=self.session)

    def request(self, *args, **kwargs):
        row = super().request(*args, **kwargs)
        if row:
            self.bridge._shared_event(row)
        return row

    def resolve(self, *args, **kwargs):
        row = super().resolve(*args, **kwargs)
        if row:
            self.bridge._shared_event(row)
        return row

    def test_request_and_desktop_resolution_update_mobile_timeline(self):
        before = self.session.sequence
        row = self.request(command='echo live')
        self.assertEqual(self.session.view()['requests'][0]['id'], row['id'])
        self.assertGreater(self.session.sequence, before)
        self.resolve()
        self.assertEqual(self.session.view()['requests'], [])
        with self.assertRaises(ValueError):
            self.bridge.respond(THREAD, row['id'], {'decision': 'accept'})

    def test_command_file_and_permissions_replies_use_the_actual_server_request(self):
        cases = [
            ('item/commandExecution/requestApproval', {'decision': 'accept'}, {}, {'decision': 'accept'}),
            ('item/fileChange/requestApproval', {'decision': 'cancel'}, {}, {'decision': 'cancel'}),
            ('item/permissions/requestApproval', {'decision': 'accept'}, {'permissions': {'network': {'enabled': True}}},
             {'permissions': {'network': {'enabled': True}}, 'scope': 'turn'}),
            ('item/permissions/requestApproval', {'decision': 'decline'}, {'permissions': {'network': {'enabled': True}}},
             {'permissions': {}, 'scope': 'turn'}),
        ]
        for index, (method, response, params, expected) in enumerate(cases):
            with self.subTest(method=method, response=response):
                row = self.request(method, identifier=index, **params)
                result = self.bridge.respond(THREAD, row['id'], response)
                self.assertEqual(result['status'], 'submitted')
                self.assertEqual(self.socket.sent[-1], {'id': index, 'result': expected})
                self.assertTrue(next(r for r in self.session.view()['requests'] if r['id'] == row['id'])['submitted'])
                self.resolve(identifier=index)

    def test_multiple_questions_and_custom_answers_have_nested_wire_shape(self):
        row = self.request('item/tool/requestUserInput', questions=[
            {'id': 'choice', 'question': 'Choose', 'options': [{'label': 'A'}, {'label': 'B'}]},
            {'id': 'free', 'question': 'Explain', 'options': None},
        ])
        response = {'answers': {'choice': ['B'], 'free': ['自定义回答\n第二行']}}
        self.bridge.respond(THREAD, row['id'], response)
        self.assertEqual(self.socket.sent, [{'id': 7, 'result': {'answers': {
            'choice': {'answers': ['B']}, 'free': {'answers': ['自定义回答\n第二行']},
        }}}])

    def test_incomplete_empty_oversized_or_unknown_answers_do_not_reach_runtime(self):
        row = self.request('item/tool/requestUserInput', questions=[{'id': 'q', 'question': 'Question'}])
        for answers in ({}, {'other': ['answer']}, {'q': []}, {'q': ['  ']}, {'q': ['x' * 20001]}, {'q': 'answer'}):
            with self.subTest(answers=str(answers)[:70]), self.assertRaises(ValueError):
                self.bridge.respond(THREAD, row['id'], {'answers': answers})
        self.assertEqual(self.socket.sent, [])

    def test_persistent_or_unavailable_approval_decisions_are_rejected(self):
        row = self.request(availableDecisions=['decline'])
        for response in ({'decision': 'accept'}, {'decision': 'acceptForSession'}, {'decision': 'never'}, [], None):
            with self.subTest(response=response), self.assertRaises(ValueError):
                self.bridge.respond(THREAD, row['id'], response)
        self.assertEqual(self.socket.sent, [])

    def test_empty_available_decisions_and_account_gate_fail_closed(self):
        row = self.request(availableDecisions=[])
        with self.assertRaises(ValueError):
            self.bridge.respond(THREAD, row['id'], {'decision': 'accept'})
        self.resolve()
        row = self.request()
        self.bridge.accounts.check_ready.side_effect = ValueError('Synthetic account switch pending')
        with self.assertRaises(ValueError):
            self.bridge.respond(THREAD, row['id'], {'decision': 'accept'})
        self.assertEqual(self.socket.sent, [])

    def test_uncertain_reply_is_published_as_submitted_to_other_mobile_views(self):
        row = self.request()
        self.socket.error = OSError('synthetic uncertain write')
        with self.assertRaises(IPCError):
            self.bridge.respond(THREAD, row['id'], {'decision': 'accept'})
        self.assertTrue(self.session.view()['requests'][0]['submitted'])
        self.assertEqual(len(self.socket.sent), 1)

    def test_file_diff_and_extra_permission_scope_are_exposed(self):
        change = {'path': '/synthetic/file', 'kind': {'type': 'update'}, 'diff': '-old\n+new'}
        self.session.state['turns'] = [{'turnId': 'turn', 'status': 'inProgress',
                                       'items': [{'id': 'item', 'type': 'fileChange', 'changes': [change]}]}]
        self.request('item/fileChange/requestApproval', grantRoot='/synthetic')
        self.assertEqual(self.session.view()['requests'][0]['params']['changes'], [change])
        self.resolve()
        self.request(kind='humanCommand', additionalPermissions={'network': {'enabled': True}}, environmentId='environment')
        params = self.session.view()['requests'][0]['params']
        self.assertEqual(params['additionalPermissions'], {'network': {'enabled': True}})
        self.assertEqual(params['kind'], 'humanCommand')
        self.assertEqual(params['environmentId'], 'environment')

    def test_identity_verification_and_unsupported_requests_stay_desktop_only(self):
        cases = [('item/tool/call', {}), ('mcpServer/elicitation/request', {
            '_meta': {'openai/userVerification': {'challenge': 'secret'}}, 'requestedSchema': {'type': 'object'},
        })]
        for index, (method, params) in enumerate(cases):
            row = self.request(method, identifier=index, **params)
            normalized = normalize_request(row)
            self.assertFalse(normalized['supported'])
            self.assertEqual(normalized['params'], {'message': '请在桌面 App 处理此请求'})
            with self.assertRaises(ValueError):
                self.bridge.respond(THREAD, row['id'], {'action': 'accept'})
        self.assertEqual(self.socket.sent, [])

    def test_nonblocking_agent_questions_are_answered_by_steer_or_new_turn(self):
        self.bridge.send = Mock(return_value={'status': 'accepted'})
        item = {'id': 'question-item', 'type': 'agentMessage', 'text': '',
                'questions': [{'title': 'Choose', 'options': ['A', 'B']} ]}
        for active in (True, False):
            with self.subTest(active=active):
                self.session.state['threadRuntimeStatus'] = {'type': 'active' if active else 'idle'}
                self.session.state['turns'] = [{'turnId': 'turn', 'status': 'inProgress' if active else 'completed', 'items': [item]}]
                row = async_requests(self.session.state)[0]
                question = row['params']['questions'][0]['id']
                self.bridge.respond(THREAD, row['id'], {'answers': {question: ['Custom']}})
                args = self.bridge.send.call_args.args
                self.assertEqual(args[0], THREAD)
                self.assertIn('<send_user_message_question_reply>', args[1])
                self.assertIn('"answer":"Custom"', args[1])
                self.assertEqual(args[3], 'steer' if active else 'send')
        self.assertEqual(self.socket.sent, [])

    def test_pending_replay_during_subscribe_is_not_lost_or_resurrected_after_resolution(self):
        self.session.connected = False
        self.rpc.connect = Mock()
        self.rpc.request = Mock(return_value={'thread': {'id': THREAD, 'status': {'type': 'active'}}})
        def snapshot(*args, **kwargs):
            self.request(command='echo during snapshot')
            return thread_state({'id': THREAD, 'status': {'type': 'active'}}, {'data': []})
        self.bridge._snapshot = Mock(side_effect=snapshot)
        self.bridge._subscribe(self.session, explicit=True)
        self.assertEqual(len(self.session.view()['requests']), 1)
        self.session.connected = False
        def resolved_snapshot(*args, **kwargs):
            self.request(command='echo during snapshot')
            self.resolve()
            return thread_state({'id': THREAD, 'status': {'type': 'active'}}, {'data': []})
        self.bridge._snapshot.side_effect = resolved_snapshot
        self.bridge._subscribe(self.session, explicit=True)
        self.assertEqual(self.session.view()['requests'], [])

    def test_disconnection_removes_actionable_cards_from_the_timeline(self):
        self.request()
        self.bridge._disconnected()
        self.assertFalse(self.session.connected)
        self.assertEqual(self.session.view()['requests'], [])


class MobileCapabilitiesTests(unittest.TestCase):
    def test_shared_and_legacy_controllable_threads_allow_respond_but_logs_do_not(self):
        for shared in (True, False):
            self.assertTrue(capabilities({'host': 'local', 'readOnly': False}, shared)['respond'])
            self.assertFalse(capabilities({'host': 'local', 'readOnly': True}, shared)['respond'])
            self.assertFalse(capabilities({}, shared)['respond'])


if __name__ == '__main__':
    unittest.main()
