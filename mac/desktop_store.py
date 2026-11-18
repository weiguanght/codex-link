"""Bound saved-history reads without changing the bundled upstream snapshot."""
import json
import logging

from bridge.store import SessionStore

MAX_RECORD = 8 * 1024 * 1024
BLOCK_SIZE = 64 * 1024
LOG = logging.getLogger(__name__)


class DesktopSessionStore(SessionStore):
    @staticmethod
    def _recent_lines(path, turn_limit):
        """Scan backwards in linear time; never accumulate an oversized line.

        Tool outputs and inline attachments can produce enormous JSONL records.
        Prepending and splitting an ever-growing partial record is quadratic and
        can monopolize the interpreter, including unrelated HTTP requests.
        """
        parts, fragments = [], []
        length = starts = skipped = 0
        oversized = False
        with path.open('rb') as stream:
            stream.seek(0, 2)
            position = stream.tell()
            while position:
                size = min(position, BLOCK_SIZE)
                position -= size
                stream.seek(position)
                block = stream.read(size)
                if len(block) != size:
                    raise OSError('会话日志在读取期间被截断，请刷新重试')
                segments = block.split(b'\n')
                for index in range(len(segments) - 1, -1, -1):
                    segment = segments[index]
                    length += len(segment)
                    if length > MAX_RECORD:
                        oversized = True
                        fragments.clear()
                    elif not oversized:
                        fragments.append(segment)
                    if index == 0 and position:
                        continue
                    if oversized:
                        skipped += 1
                    elif length:
                        line = b''.join(reversed(fragments)) + b'\n'
                        parts.append(line)
                        if turn_limit is not None and b'"task_started"' in line:
                            try:
                                record = json.loads(line)
                            except (ValueError, RecursionError):
                                record = None
                            if (isinstance(record, dict) and record.get('type') == 'event_msg'
                                    and isinstance(record.get('payload'), dict)
                                    and record['payload'].get('type') == 'task_started'):
                                starts += 1
                    fragments, length, oversized = [], 0, False
                    if turn_limit is not None and starts >= turn_limit:
                        if skipped:
                            LOG.warning('Skipped %d oversized saved-history records; desktop snapshot remains available', skipped)
                        return b''.join(reversed(parts)), position == 0 and index == 0
        if skipped:
            LOG.warning('Skipped %d oversized saved-history records; desktop snapshot remains available', skipped)
        return b''.join(reversed(parts)), True
