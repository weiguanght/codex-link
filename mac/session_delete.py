"""Confirmed deletion of one local conversation, with row-level recovery backups.

Never replace whole live databases on failure: other conversations may have
changed since the backup. SQLite write locks cover validation through commit.
"""
from contextlib import ExitStack, closing
import filecmp
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile
import threading
import time
import uuid

DATABASES = ('logs_2.sqlite', 'state_5.sqlite', 'thread_history_1.sqlite', 'sqlite/codex.db')
INDEXES = ('session_index.jsonl', 'history.jsonl')
ID_COLUMNS = {'thread_id', 'threadid', 'conversation_id', 'conversationid', 'session_id', 'sessionid', 'target_thread_id', 'targetthreadid'}
DELETE_LOCK = threading.RLock()


class SessionDeleteError(ValueError):
    pass


def quote(value):
    return '"' + value.replace('"', '""') + '"'


def _safe_file(home, path):
    return path.is_file() and not path.is_symlink() and path.resolve() == home / path.relative_to(home)


def _contains_identifier(value, identifier):
    return isinstance(value, dict) and any(value.get(key) == identifier for key in
        ('id', 'thread_id', 'threadId', 'conversation_id', 'conversationId', 'session_id', 'sessionId'))


def _matching_logs(home, identifier):
    result = []
    for folder in ('sessions', 'archived_sessions'):
        root = home / folder
        if root.is_symlink() or not root.is_dir():
            continue
        for parent, directories, files in os.walk(root, followlinks=False):
            directories[:] = [name for name in directories if not (Path(parent) / name).is_symlink()]
            for name in files:
                path = Path(parent) / name
                if not name.endswith('.jsonl') or not _safe_file(home, path):
                    continue
                try:
                    with path.open('rb') as stream:
                        header = json.loads(stream.readline(1024 * 1024 + 1))
                    if (isinstance(header, dict) and header.get('type') == 'session_meta'
                            and isinstance(header.get('payload'), dict) and header['payload'].get('id') == identifier):
                        result.append(path)
                except (OSError, ValueError, TypeError):
                    continue
    return result


def _plans(connection, identifier):
    """Match structured IDs only, including spawn edges; never search bodies."""
    plans = []
    tables = [r[0] for r in connection.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    for table in tables:
        columns = [r[1] for r in connection.execute('PRAGMA table_info(' + quote(table) + ')')]
        selected = [c for c in columns if c.casefold() in ID_COLUMNS
                    or c == 'id' and table in ('threads', 'thread', 'thread_history')
                    or table == 'thread_spawn_edges' and c in ('parent_thread_id', 'child_thread_id')]
        if not selected:
            continue
        where = '(' + ' OR '.join(quote(c) + ' = ?' for c in selected) + ')'
        params = [identifier] * len(selected)
        if 'host_id' in columns:
            where += ' AND host_id = ?'
            params.append('local')
        # active_chat_turns is a live ownership marker, not historical data.
        if table == 'active_chat_turns' and connection.execute('SELECT 1 FROM ' + quote(table) + ' WHERE ' + where + ' LIMIT 1', params).fetchone():
            raise ValueError('会话仍在桌面端运行，请结束任务后再删除')
        if table == 'thread_turns' and 'status' in columns and connection.execute(
                'SELECT 1 FROM ' + quote(table) + ' WHERE ' + where + " AND status IN ('inProgress', 'in_progress', 'running') LIMIT 1", params).fetchone():
            raise ValueError('会话存在执行中的轮次，请结束任务后再删除')
        plans.append((table, columns, where, params))
    return plans


def _backup_rows(connection, destination, plans):
    """Store only affected rows, preserving BLOB values and SQLite value types."""
    with closing(sqlite3.connect(destination)) as backup, backup:
        for table, columns, where, params in plans:
            cursor = connection.execute('SELECT ' + ','.join(map(quote, columns)) + ' FROM ' + quote(table) + ' WHERE ' + where, params)
            rows = cursor.fetchmany(256)
            if not rows:
                continue
            backup.execute('CREATE TABLE ' + quote(table) + ' (' + ','.join(map(quote, columns)) + ')')
            insert = 'INSERT INTO ' + quote(table) + ' VALUES (' + ','.join('?' for _ in columns) + ')'
            while rows:
                backup.executemany(insert, rows)
                rows = cursor.fetchmany(256)
    destination.chmod(0o600)


def _restore_rows(connection, source):
    with closing(sqlite3.connect(source)) as backup, backup:
        tables = [r[0] for r in backup.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        for table in tables:
            columns = [r[1] for r in backup.execute('PRAGMA table_info(' + quote(table) + ')')]
            connection.executemany('INSERT INTO ' + quote(table) + ' (' + ','.join(map(quote, columns)) + ') VALUES ('
                + ','.join('?' for _ in columns) + ')', backup.execute('SELECT * FROM ' + quote(table)))
    connection.commit()


def _clean_index(path, identifier):
    original = path.read_bytes()
    fingerprint = path.stat()
    kept, removed = [], 0
    for line in original.splitlines(keepends=True):
        try:
            item = json.loads(line)
        except (ValueError, UnicodeError):
            kept.append(line)
            continue
        if _contains_identifier(item, identifier):
            removed += 1
        else:
            kept.append(line)
    if removed:
        fd, temporary = tempfile.mkstemp(prefix=path.name + '.codex-link-', dir=path.parent)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(b''.join(kept))
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(temporary, fingerprint.st_mode & 0o777)
            current = path.stat()
            if (current.st_ino, current.st_size, current.st_mtime_ns) != (fingerprint.st_ino, fingerprint.st_size, fingerprint.st_mtime_ns):
                raise ValueError('会话索引被其他进程更新，请稍后重试')
            os.replace(temporary, path)
        finally:
            Path(temporary).unlink(missing_ok=True)
    return removed


def permanently_delete(codex_home, backup_root, identifier, confirmed=False):
    try:
        identifier = str(uuid.UUID(identifier))
    except (ValueError, TypeError, AttributeError):
        raise ValueError('会话 ID 无效') from None
    if confirmed is not True:
        raise PermissionError('永久删除需要显式确认')
    home = Path(codex_home).resolve(strict=True)
    backup_base = Path(backup_root).resolve()
    backup_base.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = Path(tempfile.mkdtemp(prefix=time.strftime('%Y%m%d-%H%M%S') + '-' + identifier + '-', dir=backup_base))
    with DELETE_LOCK, ExitStack() as stack:
        databases, restored_files, committed = [], [], []
        manifest = {'version': 2, 'threadId': identifier, 'createdAt': time.time(), 'status': 'preparing', 'databases': [], 'files': []}
        def save_manifest():
            (backup / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
            (backup / 'manifest.json').chmod(0o600)
        try:
            for relative in DATABASES:
                path = home / relative
                if not _safe_file(home, path):
                    continue
                connection = sqlite3.connect(path.as_uri() + '?mode=rw', uri=True, timeout=5)
                stack.callback(connection.close)
                connection.execute('BEGIN IMMEDIATE')
                # Register before validation so a failure releases every lock.
                databases.append((relative, connection, []))
                plans = _plans(connection, identifier)
                databases[-1] = (relative, connection, plans)
                destination = backup / relative
                destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                _backup_rows(connection, destination, plans)
                manifest['databases'].append(relative)
            logs = _matching_logs(home, identifier)
            for path in [*(home / relative for relative in INDEXES), *logs]:
                if _safe_file(home, path):
                    relative = str(path.relative_to(home))
                    destination = backup / relative
                    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    shutil.copy2(path, destination)
                    destination.chmod(0o600)
                    manifest['files'].append(relative)
            manifest['status'] = 'backed_up'
            save_manifest()
            removed_rows, removed_indexes = {}, {}
            for relative, connection, plans in databases:
                removed_rows[relative] = sum(connection.execute('DELETE FROM ' + quote(table) + ' WHERE ' + where, params).rowcount
                    for table, _, where, params in plans)
            for relative in INDEXES:
                if relative in manifest['files']:
                    path = home / relative
                    if path.read_bytes() != (backup / relative).read_bytes():
                        raise ValueError('会话索引在备份后被其他进程更新，请稍后重试')
                    removed_indexes[relative] = _clean_index(path, identifier)
                    if removed_indexes[relative]:
                        restored_files.append((path, path.read_bytes()))
            for path in logs:
                if not filecmp.cmp(path, backup / path.relative_to(home), shallow=False):
                    raise ValueError('会话日志仍被其他进程写入，请关闭会话后再删除')
                path.unlink()
                restored_files.append((path, None))
            for relative, connection, _ in databases:
                connection.commit()
                committed.append((relative, connection))
            manifest['status'] = 'deleted'
            manifest.update(databaseRows=removed_rows, indexLines=removed_indexes, sessionLogs=len(logs))
            save_manifest()
            return {'deleted': True, 'threadId': identifier, 'backup': str(backup),
                    'databaseRows': removed_rows, 'indexLines': removed_indexes, 'sessionLogs': len(logs)}
        except Exception as exc:
            errors = []
            for _, connection, _ in databases:
                connection.rollback()
            for relative, connection in reversed(committed):
                try:
                    _restore_rows(connection, backup / relative)
                except Exception as recovery:
                    errors.append(relative + ': ' + str(recovery))
            for target, expected in reversed(restored_files):
                try:
                    if (target.exists() and expected is None) or (expected is not None and (not target.is_file() or target.read_bytes() != expected)):
                        raise ValueError('文件被其他进程更新，保留现状；请从备份手动恢复本会话的条目')
                    shutil.copy2(backup / target.relative_to(home), target)
                except Exception as recovery:
                    errors.append(str(target.relative_to(home)) + ': ' + str(recovery))
            manifest.update(status='recovery_failed' if errors else 'rolled_back', error=str(exc), recoveryErrors=errors)
            try:
                save_manifest()
            except OSError as recovery:
                errors.append('manifest.json: ' + str(recovery))
            raise SessionDeleteError('永久删除未完成；' + ('恢复失败，请使用备份检查。' if errors else '已回滚本次变更。')
                + '恢复备份：' + str(backup) + '；' + str(exc)) from None
