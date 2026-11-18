"""Bounded phone projections. Original desktop state stays authoritative.

Cursors belong to one in-memory timeline epoch. Replacement/reordered desktop
history invalidates them explicitly; appending or editing text does not.
"""
import hashlib
import json
import time
import uuid
from collections import OrderedDict
from datetime import datetime

PAGE_BYTES = 192 * 1024
TEXT_PREVIEW = 8000
DETAIL_CHARS = 16000


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def timestamp_ms(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return int(value if value > 10**12 else value * 1000)
    if isinstance(value, str):
        try:
            return int(datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp() * 1000)
        except (ValueError, OverflowError):
            pass
    return None


def group_turn(rows, turn):
    """Project metadata only; process text is delivered on explicit expansion."""
    if not rows:
        return [], [], None
    opening = next((r for r in rows if r['role'] == 'user' and r.get('kind') != 'steeringUserMessage'), None)
    status = turn.get('status')
    running = status in ('inProgress', 'in_progress', 'running', 'active')
    final = next((r for r in reversed(rows) if r['role'] == 'assistant' and r.get('phase') == 'final_answer'), None)
    if final is None and not running:
        final = next((r for r in reversed(rows) if r['role'] == 'assistant' and r.get('phase') != 'commentary'), None)
    boundary = {r['key'] for r in (opening, final) if r is not None}
    process = [r for r in rows if r['key'] not in boundary and r.get('kind') != 'reasoning']
    started, ended = turn.get('startedAt'), turn.get('endedAt')
    duration = turn.get('durationMs')
    if isinstance(started, (int, float)) and isinstance(ended, (int, float)):
        duration = max(0, int(ended - started))
    version = hashlib.sha256(encoded([[r['key'], r['version'], r.get('status'), r.get('exitCode'), r.get('durationMs')]
                                     for r in process])).hexdigest()[:24]
    summary = dict(key=hashlib.sha256(encoded([turn['id'], 'turnProcess'])).hexdigest()[:24] + '-process',
                   version=version, turnId=turn['id'], turnStatus=status, role='process', kind='turnSummary',
                   order=opening['order'] * 2 + 1 if opening else rows[0]['order'] * 2 - 1, text='',
                   processCount=len(process), startedAtMs=started, durationMs=duration)
    main = ([dict(opening, order=opening['order'] * 2)] if opening else []) + [summary]
    if final:
        main.append(dict(final, order=final['order'] * 2))
    return main, process, summary


def bounded_process(rows, offset=0, limit=40):
    offset, limit = max(0, int(offset)), max(1, min(100, int(limit)))
    selected, size = [], 0
    for row in rows[offset:offset + limit]:
        cost = len(encoded(row))
        if selected and size + cost > PAGE_BYTES:
            break
        selected.append(row)
        size += cost
    end = offset + len(selected)
    return selected, end if end < len(rows) else None


class Timeline:
    def __init__(self):
        self.epoch = uuid.uuid4().hex
        self.sequence = -1
        self.rows = []
        self.order_origin = 0
        self.details = {}
        self.positions = {}
        self.versions = OrderedDict()
        self.meta = {}
        self.group_rows = []
        self.processes = {}
        self.summaries = {}
        self.group_versions = OrderedDict()

    def update(self, view):
        if self.sequence == view['sequence']:
            return
        activation_ids = set(view.get('goalActivationIds') or ())
        rows, details = [], {}
        for turn in view['turns']:
            occurrences = {}
            first_user = next((m for m in turn['messages'] if m['role'] == 'user'), None)
            for message in turn['messages']:
                if message.get('requestId') and message['requestId'] in activation_ids:
                    continue
                identity = [turn['id'], message.get('id'), message.get('kind')]
                base = hashlib.sha256(encoded(identity)).hexdigest()[:24]
                ordinal = occurrences.get(base, 0)
                occurrences[base] = ordinal + 1
                key = base + '-' + str(ordinal)
                text = message.get('text') or ''
                if message.get('output'):
                    text += '\n\n' + message['output']
                activity = message['role'] == 'activity'
                version = hashlib.sha256(text.encode()).hexdigest()[:24]
                row = {k: message[k] for k in ('role', 'kind', 'status', 'title', 'phase', 'requestId') if k in message}
                if activity:
                    row['inputLength'] = len(message.get('text') or '')
                    for field in ('exitCode', 'durationMs'):
                        if message.get(field) is not None: row[field] = message[field]
                row.update(key=key, turnId=turn['id'], order=len(rows), version=version,
                           text=text[:180 if activity else TEXT_PREVIEW],
                           truncated=activity or len(text) > TEXT_PREVIEW, turnStatus=turn.get('status'),
                           editable=turn.get('actionable', True) and message is first_user and message.get('kind') == 'userMessage',
                           forkable=turn.get('actionable', True) and message['role'] == 'assistant' and message.get('phase') != 'commentary' and turn.get('status') == 'completed')
                if message.get('attachments'):
                    row['attachments'] = [{k: str(a[k])[:300] for k in ('type', 'name', 'path') if k in a}
                                          for a in message['attachments'][:20]]
                rows.append(row)
                details[key] = text
            if turn.get('error'):
                key = hashlib.sha256(encoded([turn['id'], 'error'])).hexdigest()[:24] + '-error'
                text = turn['error'] if isinstance(turn['error'], str) else json.dumps(turn['error'], ensure_ascii=False)
                rows.append(dict(key=key, turnId=turn['id'], order=len(rows), role='error', text=text[:TEXT_PREVIEW],
                                 truncated=len(text) > TEXT_PREVIEW, version=hashlib.sha256(text.encode()).hexdigest()[:24]))
                details[key] = text
        old_keys = [row['key'] for row in self.rows]
        new_keys = [row['key'] for row in rows]
        # Prepending saved turns preserves existing row keys and cursors.
        first = new_keys.index(old_keys[0]) if old_keys and old_keys[0] in new_keys else 0
        if old_keys != new_keys[first:first + len(old_keys)]:
            self.epoch = uuid.uuid4().hex
            self.versions.clear()
            self.group_versions.clear()
            self.order_origin = 0
        elif old_keys:
            self.order_origin -= first
        for index, row in enumerate(rows):
            row['order'] = self.order_origin + index
        self.sequence = view['sequence']
        self.rows, self.details = rows, details
        self.positions = {row['key']: i for i, row in enumerate(rows)}
        self.meta = {k: v for k, v in view.items() if k != 'turns'}
        self.meta['latestUserTurnId'] = next((t['id'] for t in reversed(view['turns'])
                                              if any(m['role'] == 'user'
                                                     and (not m.get('requestId') or m['requestId'] not in activation_ids)
                                                     for m in t['messages'])), None)
        self.versions[self.sequence] = {row['key']: hashlib.sha256(encoded(row)).digest() for row in rows}
        while len(self.versions) > 16:
            self.versions.popitem(last=False)
        turns = {turn['id']: turn for turn in view['turns']}
        by_turn = {}
        for row in rows:
            by_turn.setdefault(row['turnId'], []).append(row)
        grouped, processes, summaries = [], {}, {}
        for turn_id, turn_rows in by_turn.items():
            turn = dict(turns[turn_id])
            previous = self.summaries.get(turn_id)
            if previous and turn.get('endedAt') is None and turn.get('durationMs') is None:
                if previous.get('turnStatus') in ('inProgress', 'in_progress', 'running', 'active'):
                    if turn.get('status') in ('completed', 'failed', 'interrupted', 'cancelled') and isinstance(turn.get('startedAt'), (int, float)):
                        turn['durationMs'] = max(0, int(time.time() * 1000 - turn['startedAt']))
                elif previous.get('startedAtMs') == turn.get('startedAt'):
                    turn['durationMs'] = previous.get('durationMs')
            main, process, summary = group_turn(turn_rows, turn)
            grouped.extend(main)
            processes[turn_id], summaries[turn_id] = process, summary
        self.group_rows, self.processes, self.summaries = grouped, processes, summaries
        self.group_versions[self.sequence] = {row['key']: hashlib.sha256(encoded(row)).digest() for row in grouped}
        while len(self.group_versions) > 16:
            self.group_versions.popitem(last=False)

    def cursor(self, key):
        return self.epoch + '.' + key

    def position(self, cursor):
        epoch, _, key = cursor.partition('.')
        if epoch != self.epoch or key not in self.positions:
            return None
        return self.positions[key]

    def page(self, limit=20, before=None, grouped=False):
        if grouped:
            return self.group_page(limit, before)
        end = self.position(before) if before else len(self.rows)
        if end is None:
            return {**self.page(), 'reset': True}
        limit = max(1, min(100, limit))
        selected, size = [], 0
        for row in reversed(self.rows[max(0, end - limit):end]):
            cost = len(encoded(row))
            if selected and size + cost > PAGE_BYTES:
                break
            selected.append(row)
            size += cost
        selected.reverse()
        start = end - len(selected)
        return {'epoch': self.epoch, 'sequence': self.sequence, 'rows': selected,
                'before': self.cursor(selected[0]['key']) if selected else None,
                'hasMore': start > 0 or self.meta.get('savedHistoryMore', False), 'meta': self.meta}

    def changes(self, after, epoch, start, grouped=False):
        if grouped:
            return self.group_changes(after, epoch, start)
        first = self.position(start) if start else None
        if epoch != self.epoch or after not in self.versions or (start and first is None):
            return {**self.page(), 'reset': True}
        previous, current = self.versions[after], self.versions[self.sequence]
        rows = [row for row in self.rows[first or 0:]
                if previous.get(row['key']) != current[row['key']]]
        if len(rows) > 100 or sum(len(encoded(row)) for row in rows) > PAGE_BYTES:
            return {**self.page(), 'reset': True}
        return {'epoch': self.epoch, 'sequence': self.sequence, 'rows': rows, 'meta': self.meta}

    def group_page(self, limit=20, before=None):
        positions = {row['key']: i for i, row in enumerate(self.group_rows)}
        prefix, _, key = (before or '').partition('.')
        end = positions.get(key) if before else len(self.group_rows)
        if before and (prefix != self.epoch or end is None):
            return dict(self.group_page(limit), reset=True)
        start, size, count = end, 0, 0
        while start > 0 and count < max(1, min(100, limit)):
            group_start = start - 1
            turn_id = self.group_rows[group_start]['turnId']
            while group_start > 0 and self.group_rows[group_start - 1]['turnId'] == turn_id:
                group_start -= 1
            cost = sum(len(encoded(row)) for row in self.group_rows[group_start:start])
            if count and size + cost > PAGE_BYTES:
                break
            start, size, count = group_start, size + cost, count + 1
        selected = self.group_rows[start:end]
        return dict(epoch=self.epoch, sequence=self.sequence, rows=selected,
                    before=self.cursor(selected[0]['key']) if selected else None,
                    hasMore=start > 0 or self.meta.get('savedHistoryMore', False), meta=self.meta)

    def group_changes(self, after, epoch, start):
        positions = {row['key']: i for i, row in enumerate(self.group_rows)}
        prefix, _, key = (start or '').partition('.')
        first = positions.get(key) if start else 0
        if epoch != self.epoch or after not in self.group_versions or (start and (prefix != epoch or first is None)):
            return dict(self.group_page(), reset=True)
        previous, current = self.group_versions[after], self.group_versions[self.sequence]
        rows = [row for row in self.group_rows[first:] if previous.get(row['key']) != current[row['key']]]
        removed = [key for key in previous if key not in current]
        if len(rows) > 300 or sum(len(encoded(row)) for row in rows) > PAGE_BYTES:
            return dict(self.group_page(), reset=True)
        return dict(epoch=self.epoch, sequence=self.sequence, rows=rows, removed=removed, meta=self.meta)

    def process(self, turnId, offset=0, limit=40):
        if turnId not in self.processes:
            raise ValueError('这轮任务的过程记录已更新，请刷新聊天')
        rows, next_offset = bounded_process(self.processes[turnId], offset, limit)
        return dict(epoch=self.epoch, turnId=turnId, summaryVersion=self.summaries[turnId]['version'],
                    rows=rows, next=next_offset, hasMore=next_offset is not None)

    def detail(self, cursor, offset=0, version=None):
        position = self.position(cursor)
        if position is None:
            raise ValueError('这条内容已更新，请重新打开聊天')
        row = self.rows[position]
        text = self.details[row['key']]
        offset = max(0, min(offset, len(text))) if version == row['version'] else 0
        end = min(len(text), offset + DETAIL_CHARS)
        return {'key': row['key'], 'version': row['version'], 'text': text[offset:end],
                'offset': offset, 'next': end if end < len(text) else None}
