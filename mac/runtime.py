"""Resolve the bundled gateway without depending on the parent directory."""
from pathlib import Path
import sys

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BRIDGE = PROJECT_ROOT / 'vendor' / 'codex-mobile-bridge'


def activate_bridge(directory=None):
    root = Path(directory if directory is not None else DEFAULT_BRIDGE).expanduser().resolve()
    required = ('bridge/__init__.py', 'bridge/service.py', 'bridge/httpd.py',
                'bridge/notifications.py', 'web/index.html', 'web/app.js', 'LICENSE')
    missing = [name for name in required if not (root / name).is_file()]
    if missing:
        raise ValueError('网关资源不完整：' + str(root) + '（缺少 ' + ', '.join(missing) + '）')
    # Refuse mixed versions in one process rather than silently reusing a module
    # imported from a now-unrelated checkout.
    loaded = sys.modules.get('bridge')
    if loaded is not None and Path(loaded.__file__).resolve() != root / 'bridge/__init__.py':
        raise ValueError('当前进程已载入另一份 bridge；请重启后再切换运行时')
    if str(root) not in sys.path:
        sys.path.insert(0, str(root))
    return root
