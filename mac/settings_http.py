"""Authenticated settings facade, not an arbitrary JSON-RPC proxy."""
from urllib.parse import parse_qs, urlsplit
from .settings_rpc import SettingsError


def handle(handler, write, path):
    if not path.startswith('/api/codex-settings'):
        return False
    try:
        handler.check_request(write)
        if not handler.authorized(write):
            return True
        settings = handler.server.codex_settings
        if settings is None:
            raise SettingsError('设置服务未配置。', 'unsupported')
        scope = parse_qs(urlsplit(handler.path).query).get('scope', [''])[0]
        if path == '/api/codex-settings':
            result = settings.write(handler.read_json()) if write else settings.read(scope)
        elif path == '/api/codex-settings/skills':
            result = settings.skill_write(handler.read_json()) if write else settings.skills(scope)
        elif not write and path == '/api/codex-settings/models':
            result = settings.models()
        elif not write and path == '/api/codex-settings/mcp':
            result = settings.mcp()
        else:
            handler.close_connection = True
            handler.output(404, {'error': '设置接口不存在'})
            return True
        handler.output(200, result)
    except SettingsError as exc:
        handler.close_connection = True
        handler.output(exc.status, {'error': str(exc), 'code': exc.code})
    except PermissionError:
        handler.close_connection = True
        handler.output(403, {'error': '不允许此设置请求'})
    except KeyError:
        handler.close_connection = True
        handler.output(404, {'error': '项目不存在，请刷新设置范围'})
    except (ValueError, TypeError) as exc:
        handler.close_connection = True
        handler.output(400, {'error': str(exc) or '设置请求格式无效'})
    except OSError:
        handler.close_connection = True
        handler.output(409, {'error': '设置读取或保存未确认，请检查 Mac 后刷新。', 'code': 'unconfirmed'})
    except Exception:
        # An incompatible runtime response must not expose configuration values.
        handler.close_connection = True
        handler.output(409, {'error': '设置响应不兼容，请刷新检查；保存结果未确认。', 'code': 'unconfirmed'})
    return True
