"""Real user-config settings with optimistic concurrency and fresh readback."""
from collections import OrderedDict
from contextlib import nullcontext
import hashlib
import json
from pathlib import Path
import re
import threading
import time
import uuid

from .settings_rpc import SettingsError, SettingsRPC, SettingsSchema, enum_values, allows_string

FIELDS = {
    'model': 'text', 'model_reasoning_effort': 'choice', 'model_reasoning_summary': 'choice',
    'model_verbosity': 'choice', 'web_search': 'choice', 'approval_policy': 'choice',
    'sandbox_mode': 'choice', 'developer_instructions': 'multiline',
}
PERMISSIONS = {'approval_policy', 'sandbox_mode'}
REQUIREMENTS = {'approval_policy': 'allowedApprovalPolicies', 'sandbox_mode': 'allowedSandboxModes', 'web_search': 'allowedWebSearchModes'}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()


def text(value, limit=300):
    return value[:limit] if isinstance(value, str) else ''


def origin(value):
    source = value.get('name', {}) if isinstance(value, dict) else {}
    return {k: text(source[k], 4096 if k in ('file', 'dotCodexFolder') else 120)
            for k in ('type', 'file', 'dotCodexFolder', 'profile') if isinstance(source.get(k), str)}


class CodexSettings:
    def __init__(self, bridge, workspace, rpc_factory=None, schema=None, clock=time.monotonic):
        self.bridge, self.workspace = bridge, workspace
        self.home = Path(bridge.codex_home).resolve()
        self.executable = getattr(getattr(bridge, 'catalog_reader', None), 'executable', None)
        self.schema = schema or SettingsSchema(self.executable)
        self.rpc_factory = rpc_factory or (lambda: SettingsRPC(self.home, self.executable))
        self.lock = threading.RLock()
        self.snapshots = OrderedDict()
        self.clock = clock

    def gate(self):
        manager = getattr(self.bridge, 'accounts', None)
        return manager.gate if manager and hasattr(manager, 'gate') else nullcontext()

    def ready(self):
        manager = getattr(self.bridge, 'accounts', None)
        if manager and hasattr(manager, 'check_ready'):
            manager.check_ready()

    def scope(self, key=''):
        if not isinstance(key, str):
            raise ValueError('设置范围无效')
        if not key:
            return {'key': '', 'name': '全局默认设置', 'cwd': str(self.home), 'file': str(self.home / 'config.toml')}
        project = self.workspace.project(key)
        if project['host'] != 'local':
            raise SettingsError('当前仅支持本机设置，SSH 项目设置未开放。', 'unsupported')
        cwd = Path(project['cwd']).resolve()
        if not cwd.is_dir():
            raise ValueError('项目目录不存在')
        return {'key': key, 'name': project['name'], 'cwd': str(cwd), 'file': str(cwd / '.codex/config.toml')}

    def _remember(self, scope, fingerprint, kind='config', extra=None):
        token = uuid.uuid4().hex
        self.snapshots[token] = {'scope': scope, 'fingerprint': fingerprint, 'kind': kind, 'at': self.clock(), 'extra': extra}
        while len(self.snapshots) > 64:
            self.snapshots.popitem(last=False)
        return token

    def _previous(self, token, scope, kind='config'):
        row = self.snapshots.get(token) if isinstance(token, str) else None
        if not row or row['scope'] != scope or row['kind'] != kind or self.clock() - row['at'] > 900:
            raise SettingsError('配置页面已过期或范围不匹配，请重新读取；不会覆盖当前配置。', 'conflict')
        return row

    def _read(self, scope):
        schema = self.schema.get()
        if 'config/read' not in schema['methods']:
            raise SettingsError('此运行时不支持读取配置。', 'unsupported')
        with self.rpc_factory() as rpc:
            raw = rpc.request('config/read', {'includeLayers': True, **({'cwd': scope['cwd']} if scope['key'] else {})})
            requirements = None
            if 'configRequirements/read' in schema['methods']:
                requirements = rpc.request('configRequirements/read', {}).get('requirements') or {}
        config = raw.get('config', {})
        layers = raw.get('layers')
        if not isinstance(config, dict) or not isinstance(layers, list):
            raise SettingsError('缺少配置层或版本信息，不能安全保存。', 'unsupported')
        user = next((l for l in layers if l.get('name', {}).get('type') == 'user'
                     and not l['name'].get('profile') and Path(l['name'].get('file', '')).resolve() == self.home / 'config.toml'), None)
        definitions = schema['files'].get('ConfigReadResponse', {}).get('definitions', {})
        properties = definitions.get('Config', {}).get('properties', {})
        write_params = schema['files'].get('ConfigBatchWriteParams', {}).get('properties', {})
        reason = ''
        if scope['key']:
            reason = '项目有效配置只读：当前 Codex 写接口只允许写用户配置。'
        elif 'config/batchWrite' not in schema['methods'] or not {'edits', 'expectedVersion'} <= write_params.keys():
            reason = '运行时未提供可校验版本的配置写接口。'
        elif not user or not isinstance(user.get('version'), str):
            reason = '无法确认用户配置层版本。'
        elif requirements is None:
            reason = '无法读取管理员限制，已禁用写入。'
        elif config.get('profile') or any(l.get('name', {}).get('profile') for l in layers):
            reason = '当前使用 profile，暂不修改基底配置；请在 Mac 管理 profile。'
        elif (self.home / 'config.toml').is_symlink():
            reason = '用户配置是符号链接，暂不支持写入。'
        elif (self.home / 'config.toml').exists() and not (self.home / 'config.toml').is_file():
            reason = '用户配置不是普通文件。'
        local = (user or {}).get('config', {})
        if not isinstance(local, dict):
            raise SettingsError('配置层结构不兼容。', 'unsupported')
        fields = {}
        for key, kind in FIELDS.items():
            choices = enum_values(properties.get(key, {}), definitions)
            # Newer runtimes advertise model-dependent effort strings instead
            # of an enum. Do not freeze old effort names into the protocol.
            if key == 'model_reasoning_effort' and not choices and allows_string(properties.get(key, {}), definitions):
                kind = 'text'
            restriction = (requirements or {}).get(REQUIREMENTS.get(key, ''))
            if isinstance(restriction, list):
                choices = [v for v in choices if v in restriction]
            field_reason = reason
            if key not in properties:
                field_reason = '当前运行时未声明此配置项。'
            elif kind == 'choice' and not choices:
                field_reason = '此配置项没有可用的选项或被管理员限制。'
            elif key in PERMISSIONS and (config.get('permissions') is not None or config.get('default_permissions') is not None):
                field_reason = '已配置命名权限方案，避免与旧式沙盒设置冲突；请在 Mac 管理。'
            effective = config.get(key)
            value = local.get(key)
            limit = 32768 if key == 'developer_instructions' else 200
            oversized = any(isinstance(v, str) and len(v) > limit for v in (effective, value))
            if (effective is not None and not isinstance(effective, str)) or (value is not None and not isinstance(value, str)):
                field_reason = '这是高级结构化设置，当前表单只读。'
            if oversized:
                field_reason = '此配置值过长，显示已截断；请在 Mac 管理。'
            fields[key] = {'kind': kind, 'value': value if isinstance(value, str) else None,
                'effective': effective if isinstance(effective, str) else None,
                'structured': isinstance(effective, (dict, list)), 'choices': choices,
                'origin': origin(raw.get('origins', {}).get(key)), 'editable': not field_reason, 'reason': field_reason}
            if oversized:
                for part in ('value', 'effective'):
                    if isinstance(fields[key][part], str): fields[key][part] = fields[key][part][:limit]
        # Store only opaque hashes of full layer versions/constraints; never return
        # full configs, environment variables, provider definitions or credentials.
        fingerprint = digest({'layers': [{k: l.get(k) for k in ('name', 'version', 'disabledReason')} for l in layers],
                              'requirements': requirements, 'scope': scope, 'fields': fields, 'profile': config.get('profile')})
        result = {'scope': scope, 'runtimeVersion': schema['version'], 'fields': fields,
                  'writable': not reason, 'reason': reason, 'provider': text(config.get('model_provider'), 120),
                  'layers': [{**origin({'name': l.get('name', {})}), 'disabled': bool(l.get('disabledReason'))} for l in layers],
                  'notice': '保存后续会话的默认配置，不热更新或接管当前任务。桌面可能需重新加载配置，以新会话实际加载值为准。',
                  'capabilities': {key: method in schema['methods'] for key, method in
                                   (('models', 'model/list'), ('skills', 'skills/list'), ('skillWrite', 'skills/config/write'), ('mcp', 'mcpServerStatus/list'))}}
        return result, fingerprint, user, config, schema

    def read(self, key=''):
        with self.gate(), self.lock:
            self.ready()
            scope = self.scope(key)
            result, fingerprint, *_ = self._read(scope)
            result['revision'] = self._remember(key, fingerprint)
            return result

    def write(self, body):
        if not isinstance(body, dict) or set(body) - {'scope', 'revision', 'changes', 'confirmPermissions'}:
            raise ValueError('设置请求包含不支持的字段')
        key, changes = body.get('scope', ''), body.get('changes')
        if not isinstance(changes, dict) or not changes or set(changes) - FIELDS.keys():
            raise ValueError('请选择支持的设置项；不接受任意配置键或文件路径')
        with self.gate(), self.lock:
            self.ready()
            prior = self._previous(body.get('revision'), key)
            scope = self.scope(key)
            before, fingerprint, user, _, schema = self._read(scope)
            if fingerprint != prior['fingerprint']:
                raise SettingsError('配置已被其他设备或 Mac 修改，请重新读取并合并更改；本次未写入。', 'conflict')
            if not before['writable']:
                raise SettingsError(before['reason'], 'read_only', 403)
            edits = []
            for name, value in changes.items():
                field = before['fields'][name]
                if not field['editable']:
                    raise SettingsError(field['reason'], 'read_only', 403)
                if value is not None:
                    if not isinstance(value, str):
                        raise ValueError('设置值必须是字符串或 null')
                    if field['kind'] == 'choice' and value not in field['choices']:
                        raise ValueError('选项不受运行时支持或被管理员限制')
                    if name == 'model' and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_./:@+\-]{0,199}', value):
                        raise ValueError('模型 ID 无效')
                    if name == 'model_reasoning_effort' and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_\-]{0,79}', value):
                        raise ValueError('推理强度 ID 无效；请参考模型目录')
                    if name == 'developer_instructions' and (len(value) > 32768 or '\x00' in value):
                        raise ValueError('开发者指令过长或包含无效字符')
                if value == field['value']:
                    continue
                if name in PERMISSIONS and body.get('confirmPermissions') is not True:
                    raise ValueError('修改审批或沙盒设置前必须确认其影响')
                edits.append({'keyPath': name, 'value': value, 'mergeStrategy': 'replace'})
            if not edits:
                return {'status': 'unchanged', 'settings': self.read(key), 'overridden': []}
            params = {'edits': edits, 'expectedVersion': user['version']}
            if 'reloadUserConfig' in schema['files']['ConfigBatchWriteParams']['properties']:
                params['reloadUserConfig'] = False
            with self.rpc_factory() as rpc:
                written = rpc.request('config/batchWrite', params)
            if written.get('status') not in ('ok', 'okOverridden') or Path(written.get('filePath', '')).resolve() != self.home / 'config.toml':
                raise SettingsError('配置写入结果未确认，请重新读取；不要直接重复保存。', 'unconfirmed')
            try:
                after, fingerprint, layer, _, _ = self._read(scope)
            except (SettingsError, OSError):
                raise SettingsError('写接口已返回，但回读失败；设置可能已保存，请重新读取。', 'unconfirmed') from None
            stored = (layer or {}).get('config', {})
            if any((e['value'] is None and e['keyPath'] in stored) or (e['value'] is not None and stored.get(e['keyPath']) != e['value']) for e in edits):
                raise SettingsError('回读值与提交值不同，可能发生并发修改；请重新读取。', 'unconfirmed')
            overridden = [e['keyPath'] for e in edits if e['value'] is not None and after['fields'][e['keyPath']]['effective'] != e['value']]
            self.snapshots.pop(body['revision'], None)
            after['revision'] = self._remember(key, fingerprint)
            catalog = getattr(self.bridge, 'catalog_reader', None)
            if catalog and hasattr(catalog, 'lock') and hasattr(catalog, 'cache'):
                with catalog.lock:
                    catalog.cache.clear()
            return {'status': 'saved_overridden' if overridden or written['status'] == 'okOverridden' else 'saved',
                    'settings': after, 'overridden': overridden, 'liveApplied': False}

    def models(self):
        with self.gate(), self.lock:
            self.ready()
            return self._models()

    def _models(self):
        schema = self.schema.get()
        if 'model/list' not in schema['methods']:
            raise SettingsError('模型列表接口不可用；仍可输入模型 ID。', 'unsupported')
        rows, cursors, cursor = [], set(), None
        with self.rpc_factory() as rpc:
            for _ in range(10):
                result = rpc.request('model/list', {'cursor': cursor, 'limit': 100, 'includeHidden': False})
                for row in result.get('data', []):
                    rows.append({'id': text(row.get('model') or row.get('id'), 200), 'name': text(row.get('displayName') or row.get('model') or row.get('id'), 200),
                                 'efforts': [text(e.get('reasoningEffort'), 80) for e in row.get('supportedReasoningEfforts', [])[:50] if isinstance(e, dict)],
                                 'defaultEffort': text(row.get('defaultReasoningEffort'), 80)})
                cursor = result.get('nextCursor')
                if not cursor or cursor in cursors:
                    break
                cursors.add(cursor)
        return {'models': rows, 'hasMore': bool(cursor), 'notice': '运行时提供的模型目录；自定义接入可手动输入模型 ID。'}

    def _skills(self, scope, rpc):
        raw = rpc.request('skills/list', {'cwds': [scope['cwd']], 'forceReload': True})
        rows = []
        for entry in raw.get('data', []):
            for row in entry.get('skills', []):
                if isinstance(row.get('path'), str) and isinstance(row.get('enabled'), bool):
                    rows.append({'path': row['path'], 'name': text(row.get('name'), 200), 'enabled': row['enabled'],
                                 'description': text(row.get('shortDescription') or row.get('description'), 500), 'scope': text(row.get('scope'), 50)})
        if len(rows) > 1000:
            raise SettingsError('技能列表过大，请在 Mac 管理。', 'unsupported')
        return rows

    def skills(self, key=''):
        with self.gate(), self.lock:
            self.ready()
            scope = self.scope(key)
            settings, fingerprint, _, _, schema = self._read(self.scope(''))
            if 'skills/list' not in schema['methods']:
                raise SettingsError('技能接口不可用。', 'unsupported')
            with self.rpc_factory() as rpc:
                rows = self._skills(scope, rpc)
            writable = settings['writable'] and 'skills/config/write' in schema['methods'] and 'path' in schema['files'].get('SkillsConfigWriteParams', {}).get('properties', {})
            token = self._remember(key, fingerprint, 'skills', digest(rows))
            return {'skills': rows, 'revision': token, 'writable': bool(writable),
                    'reason': settings['reason'] or ('' if writable else '当前运行时不支持安全修改技能。'),
                    'notice': '技能开关写入用户配置，对以后加载此技能的会话生效，不会卸载当前任务中的技能。'}

    def skill_write(self, body):
        if not isinstance(body, dict) or set(body) - {'scope', 'revision', 'path', 'enabled', 'confirmed'}:
            raise ValueError('技能请求格式无效')
        if type(body.get('enabled')) is not bool or body.get('confirmed') is not True:
            raise ValueError('请确认技能开关操作')
        key = body.get('scope', '')
        with self.gate(), self.lock:
            self.ready()
            prior = self._previous(body.get('revision'), key, 'skills')
            latest = self.skills(key)
            current = self.snapshots[latest['revision']]
            if prior['fingerprint'] != current['fingerprint'] or prior['extra'] != current['extra']:
                raise SettingsError('配置或技能列表已变化，请刷新后再修改。', 'conflict')
            if not latest['writable']:
                raise SettingsError('当前技能配置只读。', 'read_only', 403)
            skill = next((r for r in latest['skills'] if r['path'] == body.get('path')), None)
            if not skill:
                raise ValueError('只能修改当前运行时列出的技能')
            with self.rpc_factory() as rpc:
                rpc.request('skills/config/write', {'path': skill['path'], 'enabled': body['enabled']})
            try:
                after = self.skills(key)
            except SettingsError:
                raise SettingsError('技能开关已提交但回读失败，请刷新检查。', 'unconfirmed') from None
            if not any(r['path'] == skill['path'] and r['enabled'] == body['enabled'] for r in after['skills']):
                raise SettingsError('技能开关回读未确认，可能被其他配置覆盖。', 'unconfirmed')
            self.snapshots.pop(body['revision'], None)
            return {'status': 'saved', **after}

    def mcp(self):
        with self.gate(), self.lock:
            self.ready()
            return self._mcp()

    def _mcp(self):
        if 'mcpServerStatus/list' not in self.schema.get()['methods']:
            raise SettingsError('此运行时未提供 MCP 状态接口。', 'unsupported')
        rows, cursor, seen = [], None, set()
        with self.rpc_factory() as rpc:
            for _ in range(10):
                result = rpc.request('mcpServerStatus/list', {'cursor': cursor, 'limit': 100})
                for row in result.get('data', []):
                    rows.append({'name': text(row.get('name'), 200), 'authStatus': text(row.get('authStatus'), 80),
                                 'toolCount': len(row.get('tools', {})), 'discoveryError': bool(row.get('toolsError'))})
                cursor = result.get('nextCursor')
                if not cursor or cursor in seen: break
                seen.add(cursor)
        return {'servers': rows, 'hasMore': bool(cursor), 'readOnly': True,
                'notice': '这里是设置查询进程的 MCP 状态，不代表桌面正在执行的会话；不会调用工具、登录或重载桌面 MCP。'}
