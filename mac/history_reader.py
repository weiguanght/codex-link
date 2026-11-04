"""Bounded JSONL history pages. Index offsets, not entire conversation bodies."""
from collections import OrderedDict
import hashlib
import json
import os
import threading
import uuid

from .history_catalog import HistoryUnavailable, safe_log, identifier

MAX_RECORD = 8 * 1024 * 1024
PAGE_BYTES = 192 * 1024
PREVIEW = 8000
DETAIL = 16000


def text_content(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return '\n'.join(text_content(v) for v in value if isinstance(v, (str, dict)))
    if isinstance(value, dict):
        for field in ('text', 'content', 'output', 'message'):
            if field in value:
                return text_content(value[field])
    return ''


def printable(value):
    return value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=2)


def extract(record):
    """Return display messages only. Never interpret tool calls as instructions."""
    payload = record.get('payload')
    if not isinstance(payload, dict):
        return []
    category, kind = record.get('type'), payload.get('type')
    role, text, title = None, '', ''
    if category == 'response_item':
        if kind == 'message' and payload.get('role') in ('user', 'assistant'):
            role, text = payload['role'], text_content(payload.get('content', []))
            parts = payload.get('content')
            images = [v for v in (parts if isinstance(parts, list) else []) if isinstance(v, dict) and v.get('type') in ('input_image', 'image', 'image_url')]
            if images:
                text += '\n[此消息包含图片附件；历史只读视图不加载本地附件]'
        elif kind in ('agent_message', 'agentMessage'):
            role, text = 'assistant', text_content(payload.get('text'))
        elif kind in ('function_call', 'custom_tool_call'):
            role, title = 'activity', str(payload.get('name') or '工具调用')
            text = printable(payload.get('arguments', payload.get('input', '')))
        elif kind in ('function_call_output', 'custom_tool_call_output'):
            role, title, text = 'activity', '工具输出', printable(payload.get('output', ''))
    elif category == 'event_msg':
        if kind in ('user_message', 'agent_message'):
            role = 'user' if kind == 'user_message' else 'assistant'
            text = text_content(payload.get('message', payload.get('text', '')))
        elif kind in ('error', 'turn_aborted'):
            role, title = 'error', '执行错误' if kind == 'error' else '任务已中止'
            text = text_content(payload.get('message')) or title
    if role is None or not text.strip():
        return []
    return [{'role': role, 'kind': 'userMessage' if role == 'user' else str(kind),
             'family': role, 'title': title[:1000], 'text': text,
             'phase': payload.get('phase'), 'origin': category}]


def stamp(stat):
    return stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns


class LogReader:
    def __init__(self, home):
        self.home = home
        self.cache = OrderedDict()
        self.lock = threading.RLock()

    def _scan(self, path, key, stream, fingerprint, prior):
        entries, malformed, oversized, incomplete = [], 0, 0, 0
        turn, serial, last_user = 'history', 0, None
        first_line = True
        responses = set()
        # Read only the size observed at open; concurrent appended bytes belong
        # to the next snapshot. Unterminated invalid JSON is retried next time.
        boundary = fingerprint[2]
        while stream.tell() < boundary:
            offset = stream.tell()
            line = stream.readline(min(MAX_RECORD + 1, boundary - offset))
            if not line:
                raise HistoryUnavailable('日志在索引期间被截断，请刷新历史')
            if len(line) > MAX_RECORD:
                while not line.endswith(b'\n') and stream.tell() < boundary:
                    line = stream.readline(min(MAX_RECORD, boundary - stream.tell()))
                    if not line:
                        raise HistoryUnavailable('日志在索引期间被截断，请刷新历史')
                oversized += 1
                continue
            try:
                record = json.loads(line)
                if not isinstance(record, dict):
                    raise ValueError('non-object record')
            except (ValueError, UnicodeError, RecursionError):
                if stream.tell() == boundary and not line.endswith(b'\n'):
                    incomplete += 1
                else:
                    malformed += 1
                if first_line:
                    raise HistoryUnavailable('日志缺少有效的 session_meta，无法验证会话归属') from None
                continue
            payload = record.get('payload')
            payload = payload if isinstance(payload, dict) else {}
            if first_line:
                first_line = False
                if record.get('type') != 'session_meta' or identifier(payload.get('id')) != key:
                    raise HistoryUnavailable('日志的会话 ID 与索引不一致，已拒绝读取')
            if record.get('type') == 'turn_context' and payload.get('turn_id'):
                turn = str(payload['turn_id'])
                last_user = None
            if record.get('type') == 'event_msg' and payload.get('type') == 'task_started':
                serial += 1
                turn = str(payload.get('turn_id') or 'turn-' + str(serial))
                last_user = None
            for part, message in enumerate(extract(record)):
                digest = hashlib.sha256(message['text'].encode()).hexdigest()[:24]
                # Old logs may have no turn IDs. A new user prompt forms a
                # boundary, except the paired event/response copy of that prompt.
                if message['role'] == 'user':
                    paired = last_user and last_user[0] == digest and last_user[1] != message['origin']
                    if not paired:
                        serial += 1
                        turn = 'message-turn-' + str(serial)
                    last_user = (digest, message['origin'])
                elif message['role'] == 'assistant':
                    last_user = None
                family = (turn, message['family'])
                if message['origin'] == 'response_item':
                    responses.add(family)
                item = {k: v for k, v in message.items() if k != 'text'}
                item.update(key=f'{offset:x}-{part}', offset=offset, size=len(line), part=part,
                            version=digest, turnId=turn, familyKey=family)
                entries.append(item)
        if first_line:
            raise HistoryUnavailable('会话日志为空')
        # Canonical response records win over mirrored events within a turn.
        entries = [e for e in entries if not (e['origin'] == 'event_msg' and e['familyKey'] in responses and e['role'] != 'error')]
        for i, entry in enumerate(entries):
            entry['order'] = i
        same_prefix = (prior and prior['stamp'][:2] == fingerprint[:2]
                       and [(e['key'], e['version']) for e in prior['entries']] == [(e['key'], e['version']) for e in entries[:len(prior['entries'])]])
        epoch = prior['epoch'] if same_prefix else uuid.uuid4().hex
        sequence = prior['sequence'] + 1 if prior else 1
        versions = OrderedDict(prior['versions']) if same_prefix else OrderedDict()
        versions[sequence] = len(entries)
        while len(versions) > 16:
            versions.popitem(last=False)
        warnings = []
        if malformed:
            warnings.append(f'{malformed} 条损坏记录已跳过；其他内容仍可读取。')
        if oversized:
            warnings.append(f'{oversized} 条记录超过 8 MiB 安全上限，未解析；请在电脑查看原日志。')
        if incomplete:
            warnings.append('日志末尾正在写入，未完成的记录会在下一次读取时重试。')
        if not entries:
            warnings.append('日志暂未包含可识别的对话消息，可能只有元信息或使用了不支持的格式。')
        return {'stamp': fingerprint, 'entries': entries, 'positions': {e['key']: i for i, e in enumerate(entries)},
                'epoch': epoch, 'sequence': sequence, 'versions': versions, 'warnings': warnings, 'id': key}

    def _text(self, entry, stream):
        stream.seek(entry['offset'])
        try:
            record = json.loads(stream.read(entry['size']))
            text = extract(record)[entry['part']]['text']
        except (ValueError, IndexError, KeyError, TypeError, AttributeError, RecursionError):
            raise HistoryUnavailable('日志正在变化，请刷新历史') from None
        if hashlib.sha256(text.encode()).hexdigest()[:24] != entry['version']:
            raise HistoryUnavailable('日志内容已变化，请刷新历史')
        return text

    def _row(self, entry, stream):
        text = self._text(entry, stream)
        limit = 180 if entry['role'] == 'activity' else PREVIEW
        row = {k: entry[k] for k in ('key', 'version', 'turnId', 'order', 'role', 'kind', 'title', 'phase')}
        return dict(row, text=text[:limit], truncated=len(text) > limit, editable=False, forkable=False, turnStatus='completed')

    def read(self, metadata, mode='page', **options):
        path = safe_log(self.home, metadata.get('rollout_path'))
        with self.lock:
            # O_NOFOLLOW protects a replaced final path component after resolve.
            fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
            with os.fdopen(fd, 'rb') as stream:
                fingerprint = stamp(os.fstat(stream.fileno()))
                index = self.cache.get(str(path))
                if not index or index['stamp'] != fingerprint or index['id'] != metadata['id']:
                    index = self._scan(path, metadata['id'], stream, fingerprint, index)
                    self.cache[str(path)] = index
                self.cache.move_to_end(str(path))
                while len(self.cache) > 8:
                    self.cache.popitem(last=False)
                return self._result(index, metadata, stream, mode, options)

    def _result(self, index, metadata, stream, mode, options):
        entries, epoch = index['entries'], index['epoch']
        def position(cursor):
            prefix, _, key = (cursor or '').partition('.')
            return index['positions'].get(key) if prefix == epoch else None
        meta = {'id': metadata['id'], 'title': metadata['title'], 'cwd': metadata['cwd'], 'host': 'local', 'hostLabel': '此电脑',
                'model': metadata.get('model'), 'provider': metadata.get('model_provider'), 'effort': None,
                'connected': False, 'readOnly': True, 'desktopEligible': metadata.get('desktopEligible', False),
                'historyComplete': True, 'savedHistoryMore': False, 'loadingHistory': False, 'status': 'history',
                'requests': [], 'submissions': [], 'goalRuntimeAvailable': False, 'sequence': index['sequence'],
                'historyWarnings': index['warnings'], 'historyTotal': len(entries),
                'connectionError': '只读历史：不会自动连接或恢复桌面会话。'}
        base = {'epoch': epoch, 'sequence': index['sequence'], 'meta': meta, 'files': []}
        if mode == 'detail':
            at = position(options.get('cursor'))
            if at is None:
                raise HistoryUnavailable('历史内容已变化，请重新打开会话')
            entry = entries[at]
            text = self._text(entry, stream)
            offset = max(0, min(int(options.get('offset', 0)), len(text))) if options.get('version') == entry['version'] else 0
            end = min(offset + DETAIL, len(text))
            return {'key': entry['key'], 'version': entry['version'], 'text': text[offset:end], 'offset': offset,
                    'next': end if end < len(text) else None, 'files': []}
        if mode == 'changes':
            after = int(options.get('after', -1))
            if options.get('epoch') == epoch and after in index['versions']:
                start = index['versions'][after]
                if len(entries) - start <= 100:
                    rows = [self._row(e, stream) for e in entries[start:]]
                    if len(json.dumps(rows, ensure_ascii=False).encode()) <= PAGE_BYTES:
                        return dict(base, rows=rows)
            return dict(self._result(index, metadata, stream, 'page', {}), reset=True)
        limit = max(1, min(int(options.get('limit', 20)), 100))
        before = options.get('before')
        end = position(before) if before else len(entries)
        if end is None:
            return dict(self._result(index, metadata, stream, 'page', {'limit': limit}), reset=True)
        rows, size = [], 0
        for entry in reversed(entries[max(0, end - limit):end]):
            row = self._row(entry, stream)
            cost = len(json.dumps(row, ensure_ascii=False).encode())
            if rows and size + cost > PAGE_BYTES:
                break
            rows.append(row)
            size += cost
        rows.reverse()
        return dict(base, rows=rows, before=epoch + '.' + rows[0]['key'] if rows else None,
                    hasMore=end - len(rows) > 0, total=len(entries))
