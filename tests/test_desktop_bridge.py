"""Desktop stream compatibility retains upstream ownership and revision guards."""
import copy
from pathlib import Path
import sys
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from mac.runtime import activate_bridge
activate_bridge()
from bridge.service import LiveSession
from mac.desktop_bridge import DesktopBridge

KEY = '01a1c5a9-a560-71c2-9640-6aefe2cde517'


class DesktopBridgeTests(unittest.TestCase):
    def setUp(self):
        self.bridge = DesktopBridge.__new__(DesktopBridge)
        self.bridge.host = 'local'
        self.bridge.lock = threading.RLock()
        self.session = LiveSession(KEY)
        self.session.discovering = True
        self.bridge.live = {KEY: self.session}

    def snapshot(self, version=13, host='local'):
        return {'method': 'thread-stream-state-changed', 'version': version,
                'sourceClientId': 'owner', 'params': {'hostId': host, 'conversationId': KEY,
                    'change': {'type': 'snapshot', 'revision': 1,
                               'conversationState': {'id': KEY, 'title': 'before', 'turns': []}}}}

    def patch(self, owner='owner', base=1):
        return {'method': 'thread-stream-state-changed', 'version': 13,
                'sourceClientId': owner, 'params': {'hostId': 'local', 'conversationId': KEY,
                    'change': {'type': 'patches', 'revision': 2, 'baseRevision': base,
                               'patches': [{'op': 'replace', 'path': ['title'], 'value': 'after'}]}}}

    def test_supported_snapshot_connects_and_does_not_mutate_wire_message(self):
        for version in (11, 13):
            with self.subTest(version=version):
                message = self.snapshot(version)
                original = copy.deepcopy(message)
                self.bridge._event(message)
                self.assertTrue(self.session.connected)
                self.assertEqual(self.session.owner, 'owner')
                self.assertEqual(self.session.revision, 1)
                self.assertEqual(message, original)

    def test_v13_patches_update_connected_session(self):
        self.bridge._event(self.snapshot())
        self.bridge._event(self.patch())
        self.assertTrue(self.session.connected)
        self.assertEqual(self.session.revision, 2)
        self.assertEqual(self.session.state['title'], 'after')

    def test_wrong_owner_and_host_cannot_replace_state(self):
        self.bridge._event(self.snapshot())
        self.bridge._event(self.patch(owner='other-client'))
        self.bridge._event(self.snapshot(host='other-host'))
        self.assertTrue(self.session.connected)
        self.assertEqual(self.session.state['title'], 'before')
        self.assertEqual(self.session.revision, 1)

    def test_bad_revision_disconnects_until_fresh_snapshot(self):
        self.bridge._event(self.snapshot())
        self.bridge._event(self.patch(base=0))
        self.assertFalse(self.session.connected)
        self.assertIsNone(self.session.revision)
        self.bridge._event(self.snapshot())
        self.assertTrue(self.session.connected)
        self.assertIsNone(self.session.error)

    def test_unknown_version_is_logged_and_rejected(self):
        self.bridge._event(self.snapshot())
        with self.assertLogs('mac.desktop_bridge', 'WARNING') as logs:
            self.bridge._event(self.snapshot(version=99))
        self.assertIn('99', logs.output[0])
        self.assertFalse(self.session.connected)

    def test_owner_disconnect_broadcast_still_invalidates_session(self):
        self.bridge._event(self.snapshot())
        self.bridge._event({'method': 'client-status-changed',
                            'params': {'status': 'disconnected', 'clientId': 'owner'}})
        self.assertFalse(self.session.connected)


if __name__ == '__main__':
    unittest.main()
