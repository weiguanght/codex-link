"""First-party project registrations and list preferences, not Codex DB edits."""
import copy
import os
import stat
from pathlib import Path
import threading
import unicodedata
import uuid
import json

from .devices import save_private


def name(value):
    if not isinstance(value, str) or not value.strip() or len(value) > 120 or any(unicodedata.category(c) in ('Cc', 'Zl', 'Zp') for c in value):
        raise ValueError('名称需为 1–120 个字符，不能包含换行或控制字符')
    return value.strip()


def directory(value, exists=True):
    if not isinstance(value, str) or len(value) > 4096 or not value.startswith('/') or any(ord(c) < 32 for c in value):
        raise ValueError('请输入 Mac 上的绝对目录路径')
    try:
        path = Path(value).resolve()
    except (OSError, RuntimeError):
        raise ValueError('目录路径无法解析') from None
    if exists and not path.is_dir():
        raise ValueError('目录不存在或不可访问')
    return path


class Workspace:
    def __init__(self, folder, hosts):
        self.path = Path(folder) / 'workspace.json'
        self.hosts = hosts
        self.lock = threading.RLock()
        self.data = {'version': 1, 'projects': {}, 'projectPrefs': {}, 'sessionPrefs': {}}
        if self.path.exists():
            value = json.loads(self.path.read_text(encoding='utf-8'))
            if value.get('version') != 1 or any(not isinstance(value.get(k), dict) for k in ('projects', 'projectPrefs', 'sessionPrefs')):
                raise ValueError('workspace.json 格式不兼容；请保留文件并检查备份')
            self.data = value

    def snapshot(self):
        with self.lock:
            return copy.deepcopy(self.data)

    def save(self, data):
        save_private(self.path, data)
        self.data = data

    def projects(self, include_hidden=False):
        state = self.snapshot()
        result = []
        for original in [*self.hosts.projects(), *state['projects'].values()]:
            row = dict(original)
            prefs = state['projectPrefs'].get(row['key'], {})
            row.update(name=prefs.get('name', row['name']), hidden=prefs.get('hidden', False), registered=True,
                       managed=row['key'] in state['projects'])
            if include_hidden or not row['hidden']:
                result.append(row)
        return result

    def project(self, key):
        row = next((r for r in self.projects(True) if r['key'] == key), None)
        if row is None:
            raise KeyError('项目尚未添加，请先添加此目录')
        return row

    def create(self, request):
        identifier = str(uuid.UUID(request.get('id', '')))
        title = name(request.get('name'))
        path = directory(request.get('cwd'), exists=False)
        if type(request.get('createDirectory', False)) is not bool:
            raise ValueError('创建目录选项无效')
        key = 'local|link-' + identifier
        with self.lock:
            existing = self.data['projects'].get(key)
            if existing:
                if existing['name'] != title or existing['cwd'] != str(path):
                    raise ValueError('同一新建请求不能用于不同项目')
                return self.project(key)
            if any(p['host'] == 'local' and Path(p['cwd']).resolve() == path for p in self.projects(True)):
                raise ValueError('此目录已添加，请在项目列表或已隐藏项目中查找')
            if not path.exists():
                if not request.get('createDirectory'):
                    raise ValueError('目录不存在；如需创建，请勾选“创建新文件夹”')
                if not path.parent.is_dir():
                    raise ValueError('父目录不存在；请先选择已有父目录')
                path.mkdir(mode=0o755)  # One explicit leaf only; never recursive creation.
            if not path.is_dir():
                raise ValueError('路径不是目录')
            row = {'key': key, 'name': title, 'cwd': str(path), 'host': 'local', 'hostLabel': '此电脑'}
            data = self.snapshot()
            data['projects'][key] = row
            self.save(data)
            return self.project(key)

    def update_project(self, key, changes):
        self.project(key)  # Only known registered projects can be changed.
        if not changes or set(changes) - {'name', 'hidden'}:
            raise ValueError('项目操作无效')
        changes = dict(changes)
        if 'name' in changes:
            changes['name'] = name(changes['name'])
        if 'hidden' in changes and type(changes['hidden']) is not bool:
            raise ValueError('隐藏选项无效')
        with self.lock:
            data = self.snapshot()
            data['projectPrefs'].setdefault(key, {}).update(changes)
            self.save(data)
        return self.project(key)

    def preferences(self, keys, changes):
        allowed = {'pinned', 'hidden', 'unread', 'projectKey'}
        if not changes or set(changes) - allowed or any(
                type(v) is not bool for k, v in changes.items() if k != 'projectKey'):
            raise ValueError('会话列表选项无效')
        if 'projectKey' in changes:
            project_key = changes['projectKey']
            if project_key is not None and (not isinstance(project_key, str) or not any(p['key'] == project_key for p in self.projects(True))):
                raise ValueError('请选择现有项目')
            if project_key is not None:
                project_host = self.project(project_key)['host']
                if any(key.split('|', 1)[0] != project_host for key in keys):
                    raise ValueError('不能将会话分配到其他主机的项目')
        with self.lock:
            data = self.snapshot()
            for key in keys:
                data['sessionPrefs'].setdefault(key, {}).update(changes)
            self.save(data)

    def decorate(self, rows):
        data = self.snapshot()
        projects = self.projects(True)
        by_key = {p['key']: p for p in projects}
        for row in rows:
            # Preserve desktop assignments; otherwise associate exact registered
            # directories, never absorb unrelated descendant projects.
            project = by_key.get(row['projectKey']) or next((p for p in projects if p['host'] == row['host'] and p['cwd'].rstrip('/') == row['cwd'].rstrip('/')), None)
            if project:
                row.update(projectKey=project['key'], projectName=project['name'])
            prefs = data['sessionPrefs'].get(row['host'] + '|' + row['id'], {})
            row.update(pinned=prefs.get('pinned', False), hidden=prefs.get('hidden', False),
                       unread=prefs.get('unread', False))
            assigned_key = prefs.get('projectKey')
            if assigned_key:
                project = by_key.get(assigned_key)
                if project and project['host'] == row['host']:
                    row.update(projectKey=project['key'], projectName=project['name'])
        return rows

    def browse(self, path=None, offset=0, query='', sort='name', descending=False, include_hidden=False):
        path = directory(path or str(Path.home()))
        if sort not in ('name', 'modified', 'created', 'size', 'type'):
            raise ValueError('排序方式无效')
        rows = []
        with os.scandir(path) as entries:
            for entry in entries:
                try:
                    info = entry.stat(follow_symlinks=False)
                    if (include_hidden or not entry.name.startswith('.')) and query.casefold() in entry.name.casefold() and stat.S_ISDIR(info.st_mode):
                        rows.append({'name': entry.name, 'path': str(path / entry.name),
                                     'modified': info.st_mtime, 'created': getattr(info, 'st_birthtime', info.st_ctime),
                                     'bytes': info.st_size, 'type': '文件夹'})
                except FileNotFoundError:
                    continue
        key = {'name': lambda r: r['name'].casefold(), 'modified': lambda r: r['modified'],
               'created': lambda r: r['created'], 'size': lambda r: r['bytes'], 'type': lambda r: r['type']}[sort]
        rows.sort(key=lambda r: (key(r), r['name'].casefold()), reverse=descending)
        return {'path': str(path), 'parent': str(path.parent) if path != path.parent else None,
                'directories': rows[offset:offset + 100], 'hasMore': offset + 100 < len(rows),
                'sort': sort, 'descending': bool(descending), 'includeHidden': bool(include_hidden)}

    def agents(self, key):
        project = self.project(key)
        if project['host'] != 'local':
            raise ValueError('暂不支持读取 SSH 项目的 AGENTS.md')
        root = directory(project['cwd'])
        file = root / 'AGENTS.md'
        if file.is_symlink():
            raise ValueError('不读取符号链接形式的 AGENTS.md')
        with os.fdopen(os.open(file, os.O_RDONLY | os.O_NONBLOCK | getattr(os, 'O_NOFOLLOW', 0)), 'rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError('AGENTS.md 不是普通文件')
            content = stream.read(256 * 1024 + 1)
        if len(content) > 256 * 1024:
            raise ValueError('AGENTS.md 超过 256 KiB，请在 Mac 查看')
        return {'path': str(file), 'text': content.decode('utf-8'), 'readOnly': True}


class ProjectHosts:
    """Feed registered directories to the original idempotent chat creation."""
    def __init__(self, workspace):
        self.workspace = workspace

    def projects(self):
        return self.workspace.projects()

    def __getattr__(self, key):
        return getattr(self.workspace.hosts, key)
