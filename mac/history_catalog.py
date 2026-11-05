"""Read-only local discovery. Being discoverable never grants IPC control."""
import copy
from datetime import datetime
import json
import os
from pathlib import Path
import sqlite3
import threading
import time
import uuid

from bridge.store import SessionStore, StoreUnavailable
from bridge.remote import AppHosts, RemoteUnavailable

META_LIMIT = 1024 * 1024
DESKTOP = {'Codex Desktop', 'codex_work_desktop', 'codex_mobile_bridge'}


def identifier(value):
    try:
        return str(uuid.UUID(value)) if isinstance(value, str) else None
    except ValueError:
        return None


def milliseconds(value):
    if isinstance(value, (int, float)):
        return int(value * 1000) if value < 100_000_000_000 else int(value)
    if isinstance(value, str):
        try:
            return int(datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp() * 1000)
        except (ValueError, OverflowError):
            pass
    return 0


def internal(row):
    source = str(row.get('source') or '').lower()
    return (str(row.get('thread_source') or '').lower() == 'subagent'
            or 'subagent' in source or 'guardian' in source
            or str(row.get('model') or '').lower() == 'codex-auto-review')


def eligible(row):
    # Match the original store's get() gate, and conservatively exclude internal
    # records. A whitelist match still requires an actual owner at execution time.
    return bool(row.get('_database') and not internal(row) and (
        row.get('originator') in DESKTOP
        or row.get('originator') is None and row.get('source') == 'vscode'))


class HistoryUnavailable(ValueError):
    pass


def safe_log(home, value):
    if not isinstance(value, (str, Path)) or not value:
        raise HistoryUnavailable('没有可读取的会话日志')
    home = Path(home).resolve()
    path = Path(value)
    if not path.is_absolute():
        path = home / path
    try:
        resolved = path.resolve()
    except (OSError, RuntimeError):
        raise HistoryUnavailable('日志路径无法安全解析') from None
    # Do not resolve the allowed roots themselves: a symlink named sessions
    # must not expand the authority to an unrelated directory.
    if resolved.suffix != '.jsonl' or not any(home / name in resolved.parents for name in ('sessions', 'archived_sessions')):
        raise HistoryUnavailable('日志路径越出 Codex 会话目录，已拒绝读取')
    if not resolved.is_file():
        raise HistoryUnavailable('会话元信息仍在，但日志文件已缺失或不可读')
    return resolved


class HistoryCatalog:
    def __init__(self, home, clock=time.monotonic):
        self.home = Path(home).resolve()
        self.store = SessionStore(self.home)
        self.hosts = AppHosts(self.home)
        self.clock = clock
        self.lock = threading.RLock()
        self.expires = 0
        self.rows = {}
        self.warnings = []
        self.log_cache = {}

    def _database(self, warnings):
        try:
            with self.store._connect() as connection:
                columns = {r[1] for r in connection.execute('PRAGMA table_info(threads)')}
                if 'id' not in columns:
                    raise StoreUnavailable('缺少 threads.id')
                wanted = ('id', 'name', 'title', 'cwd', 'originator', 'source', 'thread_source',
                          'model', 'model_provider', 'archived', 'rollout_path', 'updated_at',
                          'updated_at_ms', 'recency_at', 'recency_at_ms')
                fields = ','.join(k for k in wanted if k in columns)
                rows = {}
                for record in connection.execute('SELECT ' + fields + ' FROM threads'):
                    row = dict(record)
                    key = identifier(row.get('id'))
                    if key:
                        rows[key] = dict(row, id=key, _database=True)
                return rows
        except (StoreUnavailable, sqlite3.Error):
            warnings.append('数据库不可用或结构不兼容，当前使用日志发现；会话仅可只读。')
            return {}

    def _logs(self, warnings):
        cache, rows, invalid, unsafe = {}, {}, 0, 0
        for name in ('sessions', 'archived_sessions'):
            root = self.home / name
            if root.is_symlink():
                unsafe += 1
                continue
            if not root.exists():
                continue
            def failed(_):
                nonlocal invalid
                invalid += 1
            for folder, directories, files in os.walk(root, followlinks=False, onerror=failed):
                # Missing optional directories are normal, not data loss.
                directories[:] = sorted(d for d in directories if not (Path(folder) / d).is_symlink())
                for filename in sorted(files):
                    if not filename.endswith('.jsonl'):
                        continue
                    path = Path(folder) / filename
                    try:
                        path = safe_log(self.home, path)
                        stat = path.stat()
                        fingerprint = (stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)
                        prior = self.log_cache.get(str(path))
                        if prior and prior[0] == fingerprint:
                            meta = prior[1]
                        else:
                            with path.open('rb') as stream:
                                line = stream.readline(META_LIMIT + 1)
                            if len(line) > META_LIMIT:
                                raise ValueError('metadata too large')
                            value = json.loads(line)
                            meta = value.get('payload') if value.get('type') == 'session_meta' else None
                        key = identifier(meta.get('id')) if isinstance(meta, dict) else None
                        if not key:
                            raise ValueError('missing session metadata')
                        # session_meta can include very large base instructions.
                        # Discovery neither retains nor publishes those bodies.
                        meta = {k: v for k, v in meta.items() if k in
                                ('id', 'cwd', 'originator', 'source', 'thread_source', 'model', 'model_provider', 'timestamp')}
                        cache[str(path)] = (fingerprint, meta)
                        row = dict(meta, id=key, rollout_path=str(path), _log_mtime=stat.st_mtime_ns // 1_000_000,
                                   archived=name == 'archived_sessions', _database=False)
                        previous = rows.get(key)
                        if not previous or row['_log_mtime'] > previous['_log_mtime']:
                            rows[key] = row
                    except HistoryUnavailable:
                        unsafe += 1
                    except (OSError, ValueError, TypeError, AttributeError, RecursionError):
                        invalid += 1
        self.log_cache = cache
        if invalid:
            warnings.append(f'{invalid} 个日志或目录不可读／格式不兼容，未计入发现结果。')
        if unsafe:
            warnings.append(f'{unsafe} 个日志或目录因路径安全限制被跳过。')
        return rows

    def _titles(self, warnings):
        result = {}
        try:
            with (self.home / 'session_index.jsonl').open('rb') as stream:
                while True:
                    line = stream.readline(META_LIMIT + 1)
                    if not line:
                        break
                    if len(line) > META_LIMIT:
                        warnings.append('标题索引含超大记录，已停止读取该索引。')
                        break
                    try:
                        record = json.loads(line)
                        key = identifier(record.get('id'))
                        title = record.get('thread_name')
                        if key and isinstance(title, str) and title.strip():
                            result[key] = title.strip()[:1000]
                    except (ValueError, AttributeError):
                        continue
        except FileNotFoundError:
            pass
        except OSError:
            warnings.append('标题索引不可读，将使用数据库标题。')
        return result

    def snapshot(self, force=False):
        with self.lock:
            if not force and self.clock() < self.expires:
                return copy.deepcopy(list(self.rows.values())), list(self.warnings)
            warnings = []
            rows = self._database(warnings)
            logs = self._logs(warnings)
            titles = self._titles(warnings)
            for key, log in logs.items():
                if key not in rows:
                    rows[key] = log
                else:
                    row = rows[key]
                    for field in ('cwd', 'originator', 'source', 'model'):
                        # Do not fill originator/source on DB rows: it could
                        # silently change the desktop eligibility decision.
                        if field not in ('originator', 'source') and not row.get(field):
                            row[field] = log.get(field)
                    try:
                        selected = safe_log(self.home, row.get('rollout_path'))
                        header = self.log_cache.get(str(selected))
                        if not header or identifier(header[1].get('id')) != key:
                            raise HistoryUnavailable('日志 ID 不一致')
                    except HistoryUnavailable:
                        row['rollout_path'] = log['rollout_path']
                    row['_log_mtime'] = log['_log_mtime']
            for key, row in rows.items():
                row['title'] = str(row.get('name') or row.get('title') or titles.get(key) or '未命名会话')[:1000]
                row['cwd'] = str(row.get('cwd') or '')
                row['archived'] = bool(row.get('archived'))
                row['internal'] = internal(row)
                row['desktopEligible'] = eligible(row)
                row['readOnly'] = not row['desktopEligible']
                row['discoveredBy'] = 'database' if row.get('_database') else 'jsonl'
                row['recency_at_ms'] = next((milliseconds(row.get(k)) for k in
                    ('recency_at_ms', 'recency_at', 'updated_at_ms', 'updated_at', '_log_mtime', 'timestamp') if row.get(k)), 0)
                try:
                    selected = safe_log(self.home, row.get('rollout_path'))
                    header = self.log_cache.get(str(selected))
                    if not header or identifier(header[1].get('id')) != key:
                        raise HistoryUnavailable('日志格式不兼容或会话 ID 不一致')
                    row['historyReadable'], row['historyError'] = True, None
                except HistoryUnavailable as exc:
                    row['historyReadable'], row['historyError'] = False, str(exc)
            values = self.hosts.decorate(list(rows.values()), 'local', '此电脑')
            state = self.hosts.state()
            configured = state.get('local-projects', {}).values()
            exact_roots = {str(root).rstrip('/') for p in configured for root in p.get('rootPaths', []) if isinstance(root, str)}
            project_ids = {p.get('id') for p in state.get('local-projects', {}).values()}
            assignments = state.get('thread-project-assignments', {})
            for row in values:
                cwd = row['cwd'].rstrip('/')
                assigned = assignments.get(row['id'], {})
                explicit = assigned.get('projectId') in project_ids and assigned.get('hostId', 'local') == 'local'
                if not explicit and cwd not in exact_roots:
                    # A saved home/Downloads root must not swallow hundreds of
                    # independent projects. Preserve individual cwd/worktrees.
                    row.update(projectKey='local|' + (cwd or 'unassigned'), projectName=Path(cwd).name or '未归类')
            self.rows = {r['id']: r for r in values}
            self.warnings = warnings
            self.expires = self.clock() + 2
            return copy.deepcopy(values), list(warnings)

    def get(self, key):
        key = identifier(key)
        with self.lock:
            if self.clock() >= self.expires:
                self.snapshot()
            if key not in self.rows:
                self.snapshot(force=True)
            if key not in self.rows:
                raise KeyError('找不到会话')
            return copy.deepcopy(self.rows[key])

    def convert_cli_to_desktop(self, key):
        key = identifier(key)
        if not key:
            raise KeyError('会话 ID 无效')
        with self.lock:
            row = self.get(key)
            if row.get('host') != 'local' or not row.get('_database'):
                raise PermissionError('仅支持转换本机数据库中的 CLI 会话')
            if internal(row) or row.get('archived'):
                raise PermissionError('内部或已归档会话不能转换')
            if row.get('originator') in DESKTOP:
                return row
            if row.get('originator') != 'codex-tui' or row.get('source') != 'cli':
                raise PermissionError('仅支持 codex-tui 来源的 CLI 会话')

            path = safe_log(self.home, row.get('rollout_path'))
            try:
                with path.open('rb') as stream:
                    header = json.loads(stream.readline(META_LIMIT + 1))
                meta = header.get('payload', {}) if header.get('type') == 'session_meta' else {}
                if identifier(meta.get('id')) != key or meta.get('originator') != 'codex-tui':
                    raise HistoryUnavailable('日志身份或来源与 CLI 会话不一致，已拒绝转换')
            except (OSError, ValueError, TypeError, AttributeError, RecursionError) as exc:
                raise HistoryUnavailable('无法验证 CLI 会话日志，已拒绝转换') from exc

            databases = sorted(self.home.glob('state_*.sqlite'), key=lambda item: item.stat().st_mtime, reverse=True)
            if not databases:
                raise HistoryUnavailable('找不到 Codex 会话数据库')
            try:
                with sqlite3.connect(databases[0], timeout=3) as connection:
                    connection.execute('BEGIN IMMEDIATE')
                    current = connection.execute(
                        'SELECT originator, source, thread_source, rollout_path FROM threads WHERE id = ?', (key,)
                    ).fetchone()
                    if not current:
                        raise KeyError('找不到会话')
                    originator, source, thread_source, rollout_path = current
                    if originator in DESKTOP:
                        connection.commit()
                    elif (originator != 'codex-tui' or source != 'cli' or thread_source == 'subagent'
                          or Path(rollout_path).resolve() != path):
                        raise PermissionError('CLI 会话来源或日志路径已变化，已拒绝转换')
                    else:
                        connection.execute(
                            "UPDATE threads SET originator = 'Codex Desktop' WHERE id = ? AND originator = 'codex-tui'",
                            (key,)
                        )
                        if connection.total_changes != 1:
                            raise HistoryUnavailable('会话状态已变化，请重新打开后重试')
                        connection.commit()
            except (OSError, sqlite3.Error) as exc:
                raise HistoryUnavailable('Codex 会话数据库正忙或无法更新，请稍后重试') from exc

            self.expires = 0
            self.snapshot(force=True)
            return self.get(key)


def public(row):
    fields = ('id', 'title', 'cwd', 'archived', 'internal', 'originator', 'model', 'recency',
              'host', 'hostLabel', 'projectKey', 'projectName', 'readOnly', 'desktopEligible',
              'discoveredBy', 'historyReadable', 'historyError', 'connected', 'pinned', 'hidden')
    return {k: row[k] for k in fields if k in row}


class ReadingLibrary:
    def __init__(self, bridge, workspace=None):
        from .history_reader import LogReader
        self.bridge = bridge
        self.catalog = HistoryCatalog(bridge.codex_home)
        self.reader = LogReader(bridge.codex_home)
        self.workspace = workspace

    def metadata(self, key, host='local'):
        if host == 'local':
            row = self.catalog.get(key)
            return self.workspace.decorate([row])[0] if self.workspace else row
        remote = self.bridge.for_host(host)
        row = remote.store.get(key)  # Remote scope deliberately remains upstream.
        row.update(desktopEligible=True, readOnly=False, discoveredBy='remote-desktop')
        row = self.bridge.hosts.decorate([row], host, host)[0]
        return self.workspace.decorate([row])[0] if self.workspace else row

    def convert_cli_to_desktop(self, key, host='local'):
        if host != 'local':
            raise PermissionError('远程 CLI 会话转换尚未支持')
        row = self.catalog.convert_cli_to_desktop(key)
        return self.workspace.decorate([row])[0] if self.workspace else row

    def list(self, query='', limit=100, offset=0, archived=False, scope='all', include_internal=False, project=None, force=False, hidden=False, sort='updated'):
        rows, warnings = self.catalog.snapshot(force=force)
        failures = []
        for host, info in self.bridge.hosts.hosts().items():
            try:
                remote = self.bridge.for_host(host)
                offset_remote = 0
                while True:
                    page = remote.store.list(limit=500, offset=offset_remote, archived=archived, query=query)
                    for row in page:
                        row.update(desktopEligible=True, readOnly=False, internal=False, archived=archived, discoveredBy='remote-desktop')
                    rows.extend(self.bridge.hosts.decorate(page, host, info.get('displayName') or host))
                    if len(page) < 500:
                        break
                    offset_remote += len(page)
            except (StoreUnavailable, RemoteUnavailable):
                failures.append({'host': host, 'label': info.get('displayName') or host, 'error': 'SSH 会话暂不可用'})
        if self.bridge.hosts.hosts():
            warnings.append('SSH 主机暂沿用上游桌面会话范围；本次全历史发现仅针对当前 Mac。')
        if self.workspace:
            rows = self.workspace.decorate(rows)
        query = query.casefold()
        rows = [r for r in rows if bool(r.get('archived')) == archived
                and bool(r.get('hidden')) == hidden
                and (include_internal or not r.get('internal'))
                and (scope != 'desktop' or r.get('desktopEligible'))
                and (not query or query in (str(r.get('title', '')) + '\n' + str(r.get('cwd', '')) + '\n' + str(r.get('projectName', ''))).casefold())]
        rows.sort(key=lambda r: (r.get('recency', 0), r['id'], r.get('host', 'local')), reverse=True)
        if sort == 'title':
            rows.sort(key=lambda r: r.get('title', '').casefold())
        rows.sort(key=lambda r: not r.get('pinned', False))
        projects = {}
        for row in rows:
            entry = projects.setdefault(row['projectKey'], {'key': row['projectKey'], 'name': row['projectName'],
                'host': row['host'], 'hostLabel': row['hostLabel'], 'cwd': row['cwd'], 'count': 0, 'recency': row.get('recency', 0), 'registered': False})
            entry['count'] += 1
        selected_project = projects.get(project)
        if self.workspace:
            for info in self.workspace.projects(True):
                if query and not any(query in str(info.get(k, '')).casefold() for k in ('name', 'cwd')) and info['key'] not in projects:
                    continue
                entry = projects.setdefault(info['key'], {'count': 0, 'recency': 0})
                entry.update(info)
            selected_project = projects.get(project)
            projects = {k: p for k, p in projects.items() if bool(p.get('hidden')) == hidden}
        if project:
            rows = [r for r in rows if r['projectKey'] == project]
        total = len(rows)
        page = rows[offset:offset + limit]
        # Activity monitoring may follow only the original eligible desktop set.
        for row in page:
            if row.get('desktopEligible'):
                target = self.bridge.for_host(row['host'])
                with target.lock:
                    target.listed.add(row['id'])
        return {'sessions': [public(r) for r in page], 'total': total, 'hasMore': offset + len(page) < total,
                'projects': list(projects.values()), 'selectedProject': selected_project, 'warnings': warnings, 'unavailableHosts': failures}

    def timeline(self, key, mode='page', **options):
        return self.reader.read(self.catalog.get(key), mode, **options)
