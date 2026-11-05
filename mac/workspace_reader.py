"""Bounded, read-only access to one session's local working directory."""
import codecs
import contextlib
import hashlib
import os
from pathlib import Path
import selectors
import stat
import subprocess
import time
import threading
import uuid

PREVIEW_BYTES = 128 * 1024
GIT_BYTES = 1024 * 1024
SCAN_ENTRIES = 6000
SEARCH_SKIP = {'.git', 'node_modules', '.build', '.venv', '__pycache__'}
WRITE_LOCK = threading.Lock()


class WorkspaceReadError(ValueError):
    pass


class WorkspaceConflictError(ValueError):
    pass


def relative_path(value, allow_root=False):
    if not isinstance(value, str) or len(value) > 4096 or '\x00' in value:
        raise ValueError('工作区路径无效')
    if value == '' and allow_root:
        return []
    parts = value.split('/')
    if any(part in ('', '.', '..') or part.casefold() == '.git' for part in parts):
        raise ValueError('请选择工作区内的文件或目录')
    return parts


class WorkspaceReader:
    def __init__(self, cwd):
        if not isinstance(cwd, str) or not cwd.startswith('/'):
            raise WorkspaceReadError('此会话没有本机工作目录')
        self.root = Path(cwd).resolve(strict=True)
        if self.root == Path('/') or not self.root.is_dir():
            raise WorkspaceReadError('此会话工作目录不可浏览')

    @contextlib.contextmanager
    def opened(self, path='', directory=False):
        parts = relative_path(path, allow_root=directory)
        flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
        descriptor = os.open(self.root, flags | os.O_DIRECTORY)
        try:
            for index, part in enumerate(parts):
                mode = flags | (os.O_DIRECTORY if directory or index < len(parts) - 1 else 0)
                child = os.open(part, mode, dir_fd=descriptor)
                os.close(descriptor)
                descriptor = child
            yield descriptor
        finally:
            os.close(descriptor)

    @staticmethod
    def entry(entry, prefix):
        info = entry.stat(follow_symlinks=False)
        kind = 'directory' if stat.S_ISDIR(info.st_mode) else 'file' if stat.S_ISREG(info.st_mode) else 'unavailable'
        return {'name': entry.name, 'path': prefix + entry.name, 'kind': kind,
                'bytes': info.st_size if kind == 'file' else None}

    def tree(self, path='', offset=0):
        if not 0 <= offset <= SCAN_ENTRIES:
            raise ValueError('分页位置无效')
        prefix = path + '/' if path else ''
        rows = []; limited = False
        with self.opened(path, directory=True) as descriptor, os.scandir(descriptor) as entries:
            for count, entry in enumerate(entries):
                if count >= SCAN_ENTRIES:
                    limited = True; break
                if entry.name.casefold() == '.git':
                    continue
                try:
                    rows.append(self.entry(entry, prefix))
                except FileNotFoundError:
                    continue
        rows.sort(key=lambda r: (r['kind'] != 'directory', r['name'].casefold(), r['name']))
        return {'root': str(self.root), 'path': path, 'entries': rows[offset:offset + 100],
                'hasMore': offset + 100 < len(rows), 'limited': limited}

    def search(self, query):
        if not isinstance(query, str) or not 1 <= len(query.strip()) <= 200:
            raise ValueError('请输入 1–200 个字符的文件名或相对路径')
        query = query.strip().casefold()
        rows = []; scanned = 0; limited = False
        def visit(descriptor, prefix, depth):
            nonlocal scanned, limited
            with os.scandir(descriptor) as entries:
                for entry in entries:
                    scanned += 1
                    if scanned > SCAN_ENTRIES or len(rows) >= 100:
                        limited = True; return
                    if entry.name in SEARCH_SKIP or entry.name.casefold() == '.git':
                        continue
                    try:
                        row = self.entry(entry, prefix)
                        if query in row['path'].casefold():
                            rows.append(row)
                        if row['kind'] == 'directory':
                            if depth >= 12:
                                limited = True; continue
                            try:
                                child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
                            except OSError:
                                continue
                            try:
                                visit(child, row['path'] + '/', depth + 1)
                            finally:
                                os.close(child)
                            if scanned > SCAN_ENTRIES or len(rows) >= 100:
                                return
                    except (FileNotFoundError, PermissionError):
                        continue
        with self.opened(directory=True) as descriptor:
            visit(descriptor, '', 0)
        rows.sort(key=lambda r: (r['kind'] != 'directory', r['path'].casefold()))
        return {'root': str(self.root), 'path': '', 'entries': rows, 'hasMore': False, 'limited': limited}

    def file(self, path):
        with self.opened(path) as descriptor:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode):
                raise WorkspaceReadError('仅支持预览普通文件')
            with os.fdopen(os.dup(descriptor), 'rb') as stream:
                data = stream.read(PREVIEW_BYTES + 1)
        truncated = len(data) > PREVIEW_BYTES
        data = data[:PREVIEW_BYTES]
        result = {'path': path, 'bytes': info.st_size, 'truncated': truncated, 'text': '', 'previewable': False,
                  'revision': hashlib.sha256(data).hexdigest() if not truncated else None}
        if b'\x00' not in data:
            try:
                result.update(text=codecs.getincrementaldecoder('utf-8-sig')().decode(data, final=not truncated), previewable=True)
            except UnicodeError:
                pass
        return result

    def save(self, path, text, revision):
        parts = relative_path(path)
        if not isinstance(text, str) or '\x00' in text or len(text.encode('utf-8')) > PREVIEW_BYTES:
            raise ValueError('仅支持保存不超过 128 KiB 的 UTF-8 文本')
        if not isinstance(revision, str) or len(revision) != 64:
            raise ValueError('请先读取文件版本，再保存修改')
        parent = '/'.join(parts[:-1])
        with WRITE_LOCK, self.opened(parent, directory=True) as directory:
            flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
            descriptor = os.open(parts[-1], flags, dir_fd=directory)
            try:
                info = os.fstat(descriptor)
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise ValueError('仅支持编辑普通文件，不支持链接文件')
                with os.fdopen(os.dup(descriptor), 'rb') as stream:
                    original = stream.read(PREVIEW_BYTES + 1)
                if len(original) > PREVIEW_BYTES or b'\x00' in original:
                    raise ValueError('此文件过大或不是可编辑文本')
                original.decode('utf-8-sig')
                if hashlib.sha256(original).hexdigest() != revision:
                    raise WorkspaceConflictError('文件已在 Mac 上改变。草稿已保留，请重新读取后合并修改。')
                data = (codecs.BOM_UTF8 if original.startswith(codecs.BOM_UTF8) else b'') + text.encode('utf-8')
                if len(data) > PREVIEW_BYTES: raise ValueError('文件超过 128 KiB')
                temporary = '.codex-link-' + uuid.uuid4().hex
                try:
                    target = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, stat.S_IMODE(info.st_mode), dir_fd=directory)
                    with os.fdopen(target, 'wb') as stream:
                        os.fchmod(stream.fileno(), stat.S_IMODE(info.st_mode))
                        stream.write(data); stream.flush(); os.fsync(stream.fileno())
                    current = os.stat(parts[-1], dir_fd=directory, follow_symlinks=False)
                    if (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns, current.st_ctime_ns) != (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns):
                        raise WorkspaceConflictError('文件保存期间发生改变。草稿已保留，请重新读取。')
                    os.replace(temporary, parts[-1], src_dir_fd=directory, dst_dir_fd=directory)
                finally:
                    try: os.unlink(temporary, dir_fd=directory)
                    except FileNotFoundError: pass
            finally:
                os.close(descriptor)
        return {'path': path, 'text': text, 'bytes': len(data), 'revision': hashlib.sha256(data).hexdigest(), 'truncated': False, 'previewable': True}

    def git(self, *args, overrides=()):
        # A repo can configure executable filters as well as external diffs.
        # Never inherit a caller's alternate repository/object/config settings.
        env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        env.update(GIT_OPTIONAL_LOCKS='0', GIT_LITERAL_PATHSPECS='1', GIT_NO_LAZY_FETCH='1',
                   GIT_TERMINAL_PROMPT='0', GIT_ALLOW_PROTOCOL='', LC_ALL='C')
        env['GIT_CONFIG_COUNT'] = str(len(overrides))
        for index, (key, value) in enumerate(overrides):
            env['GIT_CONFIG_KEY_' + str(index)] = key
            env['GIT_CONFIG_VALUE_' + str(index)] = value
        command = ['/usr/bin/git', '--no-pager', '-c', 'safe.bareRepository=explicit',
                   '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false', *args]
        with subprocess.Popen(command, cwd=self.root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            buffers = {process.stdout: bytearray(), process.stderr: bytearray()}
            try:
                with selectors.DefaultSelector() as selector:
                    for stream in buffers:
                        selector.register(stream, selectors.EVENT_READ)
                    deadline = time.monotonic() + 6
                    while selector.get_map():
                        if time.monotonic() > deadline:
                            raise WorkspaceReadError('Git 读取超时，请在 Mac 检查仓库')
                        for event, _ in selector.select(timeout=.1):
                            chunk = os.read(event.fileobj.fileno(), 65536)
                            if not chunk:
                                selector.unregister(event.fileobj); continue
                            buffers[event.fileobj].extend(chunk)
                            if sum(map(len, buffers.values())) > GIT_BYTES:
                                raise WorkspaceReadError('差异超过 1 MiB，请缩小范围或在 Mac 查看')
                    try:
                        code = process.wait(timeout=max(.1, deadline - time.monotonic()))
                    except subprocess.TimeoutExpired:
                        raise WorkspaceReadError('Git 读取超时，请在 Mac 检查仓库') from None
                return code, bytes(buffers[process.stdout])
            finally:
                if process.poll() is None:
                    process.kill(); process.wait()

    def repository(self):
        code, raw = self.git('rev-parse', '--show-toplevel')
        if code or Path(os.fsdecode(raw).rstrip('\n')).resolve() != self.root:
            raise WorkspaceReadError('差异视图需要会话工作目录为 Git 仓库根目录')
        code, raw = self.git('config', '--null', '--name-only', '--get-regexp', r'^filter\..*\.(clean|process|required)$')
        if code not in (0, 1):
            raise WorkspaceReadError('无法读取 Git 过滤器配置')
        drivers = {os.fsdecode(key).rsplit('.', 1)[0] for key in raw.split(b'\x00') if key}
        overrides = []
        for driver in sorted(drivers):
            # Separate keys and values also cover filter names containing '='.
            overrides.extend([(driver + '.clean', ''), (driver + '.process', ''), (driver + '.required', 'false')])
        return overrides

    def changes(self, source='unstaged'):
        if source not in ('unstaged', 'staged'):
            raise ValueError('差异来源无效')
        overrides = self.repository()
        arguments = ['diff', '--no-ext-diff', '--no-textconv', '--no-renames', '--numstat', '-z']
        if source == 'staged': arguments.append('--cached')
        code, raw = self.git(*arguments, '--', overrides=overrides)
        if code:
            raise WorkspaceReadError('无法读取 Git 差异')
        rows = []
        for value in raw.split(b'\x00'):
            if not value: continue
            added, removed, name = value.split(b'\t', 2)
            path = os.fsdecode(name)
            relative_path(path)
            rows.append({'path': path, 'added': None if added == b'-' else int(added),
                         'removed': None if removed == b'-' else int(removed), 'untracked': False})
        if source == 'unstaged':
            code, raw = self.git('ls-files', '--others', '--exclude-standard', '-z', overrides=overrides)
            if code: raise WorkspaceReadError('无法读取未跟踪文件')
            for name in raw.split(b'\x00'):
                if not name: continue
                path = os.fsdecode(name); relative_path(path)
                rows.append({'path': path, 'added': None, 'removed': None, 'untracked': True})
        rows.sort(key=lambda r: r['path'].casefold())
        return {'root': str(self.root), 'source': source, 'files': rows[:200], 'limited': len(rows) > 200,
                'fileCount': len(rows), 'added': sum(r['added'] or 0 for r in rows), 'removed': sum(r['removed'] or 0 for r in rows)}

    def patch(self, path, source='unstaged'):
        relative_path(path)
        if source not in ('unstaged', 'staged'):
            raise ValueError('差异来源无效')
        overrides = self.repository()
        arguments = ['diff', '--no-ext-diff', '--no-textconv', '--no-renames', '--no-color', '--src-prefix=a/', '--dst-prefix=b/']
        if source == 'staged': arguments.append('--cached')
        code, raw = self.git(*arguments, '--', path, overrides=overrides)
        if code: raise WorkspaceReadError('无法读取文件差异')
        return {'path': path, 'source': source, 'text': raw.decode('utf-8', errors='replace')}
