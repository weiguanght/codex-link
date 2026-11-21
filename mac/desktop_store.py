"""Bound saved-history reads without changing the bundled upstream snapshot."""
import json
import logging

from bridge.store import SessionStore
from .history_catalog import eligible

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


class SharedDesktopSessionStore(DesktopSessionStore):
    """Only the gateway's confirmed creations supplement the desktop whitelist.

    A shared daemon keeps the originator of its initial client (often codex-tui)
    even for later mobile/desktop creations. Do not rewrite that provenance or
    make unrelated CLI/exec history executable.
    """
    def __init__(self, home, created_thread_ids):
        super().__init__(home)
        self.created_thread_ids = created_thread_ids

    def get(self, thread_id):
        with self._connect() as connection:
            row = connection.execute('SELECT * FROM threads WHERE id = ?', (thread_id,)).fetchone()
        result = dict(row) if row else None
        if result is None or not eligible(dict(result, _database=True), self.created_thread_ids()):
            raise KeyError('找不到可控制的桌面或本网关新建会话')
        return result

    def list(self, query='', limit=100, offset=0, archived=False):
        # Enough original rows for this page, plus exact IDs from our ledger.
        rows = {row['id']: row for row in super().list(query, limit + offset, 0, archived)}
        created_ids = tuple(self.created_thread_ids())
        if created_ids:
            with self._connect() as connection:
                columns = {r[1] for r in connection.execute('PRAGMA table_info(threads)')}
                where = ['archived = ?', 'id IN (' + ','.join('?' for _ in created_ids) + ')']
                params = [int(archived), *created_ids]
                if query:
                    fields = [name for name in ('name', 'title', 'cwd') if name in columns]
                    where.append('(' + ' OR '.join(name + ' LIKE ?' for name in fields) + ')')
                    params += ['%' + query + '%'] * len(fields)
                for record in connection.execute('SELECT * FROM threads WHERE ' + ' AND '.join(where), params):
                    row = dict(record)
                    if eligible(dict(row, _database=True), created_ids):
                        rows[row['id']] = row
        def recency(row):
            return next((row[key] * (1 if key.endswith('_ms') else 1000)
                         for key in ('recency_at_ms', 'recency_at', 'updated_at') if row.get(key) is not None), 0)
        return sorted(rows.values(), key=lambda row: (recency(row), row['id']), reverse=True)[offset:offset + limit]
