"""Regression coverage for huge records in the desktop saved-history path."""
from pathlib import Path
import random
import sys
import tempfile
import tracemalloc
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from mac.runtime import activate_bridge
activate_bridge()
from bridge.store import SessionStore
from mac.desktop_store import DesktopSessionStore
import mac.desktop_store as bounded
import test_history as history


class DesktopStoreTests(unittest.TestCase):
    def setUp(self):
        folder = ROOT / 'build'
        folder.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=folder)
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.path = self.home / 'sample.jsonl'

    def test_normal_turns_match_upstream_across_block_boundaries(self):
        rng = random.Random(42)
        lines = [history.record('session_meta', {'id': history.uid(1)})]
        for turn in range(9):
            lines.append(history.record('event_msg', {'type': 'task_started', 'turn_id': str(turn)}))
            lines.append(history.message('user', '测试' * rng.randrange(1, 80)))
            lines.append(history.message('assistant', 'reply' * rng.randrange(1, 80)))
        for ending in ('\n', ''):
            self.path.write_text(''.join(lines).rstrip('\n') + ending)
            for block_size in (1, 23, 256, 65536):
                with patch.object(bounded, 'BLOCK_SIZE', block_size):
                    for limit in (None, 1, 2, 9, 20):
                        actual, complete = DesktopSessionStore._recent_lines(self.path, limit)
                        expected, expected_complete = SessionStore._recent_lines(self.path, limit)
                        self.assertEqual(actual.splitlines(), expected.splitlines())
                        self.assertEqual(complete, expected_complete)

    def test_huge_record_is_skipped_with_bounded_memory_and_neighbors_survive(self):
        before = history.message('user', 'before')
        after = history.message('assistant', 'after')
        with self.path.open('wb') as stream:
            stream.write(before.encode())
            for _ in range(256):
                stream.write(b'x' * 65536)
            stream.write(b'\n' + after.encode())
        tracemalloc.start()
        try:
            with patch.object(bounded, 'MAX_RECORD', 256 * 1024), self.assertLogs(bounded.LOG, 'WARNING'):
                raw, complete = DesktopSessionStore._recent_lines(self.path, 20)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual(raw.decode(), before + after)
        self.assertTrue(complete)
        self.assertLess(peak, 2 * 1024 * 1024)

    def test_history_retains_turns_around_oversized_tool_output(self):
        content = (history.record('event_msg', {'type': 'task_started', 'turn_id': 'one'})
                   + history.message('user', 'question')
                   + history.record('response_item', {'type': 'function_call_output', 'output': 'x' * 2048})
                   + history.message('assistant', 'answer')
                   + history.record('event_msg', {'type': 'task_complete'}))
        history.log(self.home, 1, content)
        history.database(self.home, [{'number': 1, 'originator': 'Codex Desktop'}])
        with patch.object(bounded, 'MAX_RECORD', 1024), self.assertLogs(bounded.LOG, 'WARNING'):
            result = DesktopSessionStore(self.home).history(history.uid(1), turn_limit=20)
        self.assertEqual(len(result['turns']), 1)
        self.assertEqual(result['turns'][0]['status'], 'completed')
        self.assertEqual([item['type'] for item in result['turns'][0]['items']], ['userMessage', 'agentMessage'])

    def test_oversized_first_or_last_record_does_not_swallow_neighbor(self):
        for content in (b'x' * 1024 + b'\nvalid\n', b'valid\n' + b'x' * 1024,
                        b'valid\r\n' + b'x' * 1024 + b'\r\n'):
            self.path.write_bytes(content)
            with patch.object(bounded, 'MAX_RECORD', 64), patch.object(bounded, 'BLOCK_SIZE', 23), self.assertLogs(bounded.LOG, 'WARNING'):
                raw, complete = DesktopSessionStore._recent_lines(self.path, None)
            self.assertEqual(raw.splitlines(), [b'valid'])
            self.assertTrue(complete)


if __name__ == '__main__':
    unittest.main()
