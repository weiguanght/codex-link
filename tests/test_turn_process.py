"""Native turn summaries and process paging, with synthetic state and logs only."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import test_history as history
from bridge.model import normalize_state
from bridge.timeline import Timeline, PAGE_BYTES, encoded
from bridge.store import SessionStore
from bridge.service import LiveSession
from mac.history_reader import LogReader


def message(key, role, text, kind=None, **fields):
    return dict(id=key, role=role, text=text, kind=kind or ('userMessage' if role == 'user' else 'agentMessage'), **fields)


def turn(key='one', status='completed'):
    return dict(id=key, status=status, startedAt=1000, endedAt=126000 if status == 'completed' else None,
                messages=[message('u', 'user', 'opening'), message('a', 'assistant', 'progress', phase='commentary'),
                          message('s', 'user', 'additional input', kind='steeringUserMessage'),
                          message('c', 'activity', 'echo hello', kind='commandExecution', output='hello', status='completed'),
                          message('f', 'activity', 'patch', kind='fileChange'),
                          message('answer', 'assistant', 'final', phase='final_answer')])


class TurnTimelineTests(unittest.TestCase):
    def setUp(self):
        self.timeline = Timeline()
        self.view = dict(sequence=1, turns=[turn()])
        self.timeline.update(self.view)

    def test_only_opening_summary_and_final_are_loaded(self):
        legacy = self.timeline.page()
        page = self.timeline.page(grouped=True)
        self.assertEqual([r['text'] for r in legacy['rows']], ['opening', 'progress', 'additional input', 'echo hello\n\nhello', 'patch', 'final'])
        self.assertEqual([r['text'] for r in page['rows']], ['opening', '', 'final'])
        summary = page['rows'][1]
        self.assertEqual(summary['durationMs'], 125000)
        self.assertEqual(summary['processCount'], 4)
        process = self.timeline.process('one', limit=2)
        self.assertEqual([r['text'] for r in process['rows']], ['progress', 'additional input'])
        next_page = self.timeline.process('one', offset=process['next'], limit=2)
        self.assertEqual([r['kind'] for r in next_page['rows']], ['commandExecution', 'fileChange'])
        self.assertIsNone(next_page['next'])
        row = next_page['rows'][0]
        self.assertEqual(self.timeline.detail(self.timeline.cursor(row['key']), version=row['version'])['text'], 'echo hello\n\nhello')
        self.assertEqual(process['summaryVersion'], summary['version'])

    def test_running_commentary_stays_inside_and_tool_edits_invalidate_process(self):
        running = turn(status='inProgress')
        running['messages'].pop()
        self.view = dict(sequence=2, turns=[running])
        self.timeline.update(self.view)
        page = self.timeline.page(grouped=True)
        self.assertEqual([r['role'] for r in page['rows']], ['user', 'process'])
        summary = page['rows'][1]
        self.assertEqual(summary['turnStatus'], 'inProgress')
        running['messages'][3]['output'] = 'updated output'
        self.timeline.update(dict(self.view, sequence=3))
        changes = self.timeline.changes(page['sequence'], page['epoch'], page['before'], grouped=True)
        self.assertFalse(changes.get('reset', False))
        self.assertEqual([r['kind'] for r in changes['rows']], ['turnSummary'])
        self.assertNotEqual(changes['rows'][0]['version'], summary['version'])
        running['messages'].append(message('answer', 'assistant', 'done', phase='final_answer'))
        running.update(status='completed', endedAt=31000)
        self.timeline.update(dict(sequence=4, turns=[running]))
        changes = self.timeline.changes(3, page['epoch'], page['before'], grouped=True)
        self.assertFalse(changes.get('reset', False))
        self.assertEqual([r.get('kind') for r in changes['rows']], ['userMessage', 'turnSummary', 'agentMessage'])
        self.assertEqual(changes['rows'][1]['durationMs'], 30000)

    def test_pages_do_not_split_turns_and_prepend_keeps_existing_order(self):
        current = self.timeline.page(grouped=True, limit=1)
        old_order = [(r['key'], r['order']) for r in current['rows']]
        self.timeline.update(dict(sequence=2, turns=[turn('older'), turn()]))
        earlier = self.timeline.page(grouped=True, before=current['before'], limit=1)
        self.assertEqual(earlier['epoch'], current['epoch'])
        self.assertEqual({r['turnId'] for r in earlier['rows']}, {'older'})
        self.assertEqual(old_order, [(r['key'], r['order']) for r in self.timeline.page(grouped=True, limit=1)['rows']])
        self.assertFalse(earlier['hasMore'])

    def test_process_page_is_bounded_and_unknown_turn_is_rejected(self):
        large = turn()
        large['messages'][1:1] = [message(str(i), 'assistant', 'x' * 10000, phase='commentary') for i in range(90)]
        self.timeline.update(dict(sequence=2, turns=[large]))
        page = self.timeline.process('one', limit=100)
        self.assertLessEqual(sum(len(encoded(row)) for row in page['rows']), PAGE_BYTES)
        self.assertTrue(page['hasMore'])
        with self.assertRaises(ValueError):
            self.timeline.process('unknown')

    def test_observed_completion_keeps_elapsed_time_when_snapshot_has_no_end(self):
        running = turn(status='inProgress')
        self.timeline.update(dict(sequence=2, turns=[running]))
        running['status'] = 'completed'
        with patch('bridge.timeline.time.time', return_value=4):
            self.timeline.update(dict(sequence=3, turns=[running]))
        self.assertEqual(self.timeline.page(grouped=True)['rows'][1]['durationMs'], 3000)
        with patch('bridge.timeline.time.time', return_value=10):
            self.timeline.update(dict(sequence=4, turns=[running]))
        self.assertEqual(self.timeline.page(grouped=True)['rows'][1]['durationMs'], 3000)


class TurnLogTests(unittest.TestCase):
    def setUp(self):
        folder = Path(__file__).resolve().parents[1] / 'build'
        folder.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=folder)
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.reader = LogReader(self.home)

    @staticmethod
    def event(kind, time):
        return json.dumps(dict(type='event_msg', timestamp=time, payload=dict(type=kind, turn_id='one'))) + '\n'

    def prepare(self, complete=True):
        content = (self.event('task_started', '2026-11-18T10:00:00Z')
                   + history.message('user', 'opening')
                   + history.record('turn_context', {'turn_id': 'one'})
                   + history.record('response_item', {'type': 'message', 'role': 'assistant', 'phase': 'commentary', 'content': 'progress'})
                   + history.message('user', 'additional input')
                   + history.record('response_item', {'type': 'function_call', 'name': 'shell', 'arguments': 'pwd'})
                   + history.record('response_item', {'type': 'message', 'role': 'assistant', 'phase': 'final_answer', 'content': 'final'}))
        if complete:
            content += self.event('task_complete', '2026-11-18T10:01:05Z')
        path = history.log(self.home, 1, content)
        self.meta = dict(id=history.uid(1), title='synthetic', cwd='/sample', rollout_path=str(path))
        return path

    def test_history_process_is_not_read_until_opened(self):
        self.prepare()
        original = self.reader._text
        with patch.object(self.reader, '_text', wraps=original) as read:
            page = self.reader.read(self.meta, grouped=True, limit=1)
            self.assertEqual(read.call_count, 2)
        self.assertEqual([r['text'] for r in page['rows']], ['opening', '', 'final'])
        summary = page['rows'][1]
        self.assertEqual(summary['durationMs'], 65000)
        self.assertEqual(summary['processCount'], 3)
        first = self.reader.read(self.meta, 'process', turnId='one', limit=2)
        self.assertEqual([r['text'] for r in first['rows']], ['progress', 'additional input'])
        second = self.reader.read(self.meta, 'process', turnId='one', offset=first['next'])
        self.assertEqual(second['rows'][0]['text'], 'pwd')
        row = first['rows'][0]
        self.assertEqual(self.reader.read(self.meta, 'detail', cursor=page['epoch'] + '.' + row['key'])['text'], 'progress')
        self.assertEqual(self.reader.read(self.meta)['total'], 5)

    def test_appending_intermediate_records_updates_summary_not_main_text(self):
        path = self.prepare(complete=False)
        page = self.reader.read(self.meta, grouped=True)
        with path.open('a') as stream:
            stream.write(history.record('response_item', {'type': 'function_call_output', 'output': 'new output'}))
        changed = self.reader.read(self.meta, 'changes', grouped=True, after=page['sequence'], epoch=page['epoch'], start=page['before'])
        self.assertEqual([r['kind'] for r in changed['rows']], ['turnSummary'])
        with path.open('a') as stream:
            stream.write(self.event('task_complete', '2026-11-18T10:01:05Z'))
        completed = self.reader.read(self.meta, 'changes', grouped=True, after=changed['sequence'], epoch=page['epoch'], start=page['before'])
        self.assertEqual(completed['rows'][0]['turnStatus'], 'completed')
        self.assertEqual(completed['rows'][0]['durationMs'], 65000)

    def test_event_only_supplement_is_not_removed_by_the_opening_response(self):
        path = self.prepare()
        source = path.read_text().replace(history.message('user', 'additional input'),
                                          history.record('event_msg', {'type': 'user_message', 'message': 'additional input'}))
        path.write_text(source)
        self.reader.read(self.meta, grouped=True)
        process = self.reader.read(self.meta, 'process', turnId='one')
        self.assertEqual([r['text'] for r in process['rows']], ['progress', 'additional input', 'pwd'])

    def test_saved_desktop_history_preserves_duration_for_projection(self):
        self.prepare()
        history.database(self.home, [{'number': 1, 'originator': 'Codex Desktop'}])
        saved = SessionStore(self.home).history(history.uid(1))
        view = normalize_state(saved)
        projection = Timeline()
        projection.update(dict(view, sequence=1))
        self.assertEqual(projection.page(grouped=True)['rows'][1]['durationMs'], 65000)
        session = LiveSession(history.uid(1))
        with session.condition:
            session.set_history(saved)
            saved['turns'][0].pop('turnStartedAtMs')
            saved['turns'][0].pop('turnCompletedAtMs')
            session.state = saved
            live = session.view()
        self.assertEqual(live['turns'][0]['endedAt'] - live['turns'][0]['startedAt'], 65000)


if __name__ == '__main__':
    unittest.main()
