"""First-party presentation overlay; the bundled upstream snapshot stays intact."""
from pathlib import Path
import re

WEB_ROOT = Path(__file__).resolve().parents[1] / 'web'
ASSETS = {
    '/link-presentation.js': ('link-presentation.js', 'text/javascript; charset=utf-8'),
    '/link-timeline.js': ('link-timeline.js', 'text/javascript; charset=utf-8'),
    '/link-ui.css': ('link-ui.css', 'text/css; charset=utf-8'),
    '/link-ui.js': ('link-ui.js', 'text/javascript; charset=utf-8'),
    '/link-history.css': ('link-history.css', 'text/css; charset=utf-8'),
    '/link-history.js': ('link-history.js', 'text/javascript; charset=utf-8'),
    '/link-workspace.css': ('link-workspace.css', 'text/css; charset=utf-8'),
    '/link-workspace.js': ('link-workspace.js', 'text/javascript; charset=utf-8'),
    '/link-settings.css': ('link-settings.css', 'text/css; charset=utf-8'),
    '/link-settings.js': ('link-settings.js', 'text/javascript; charset=utf-8'),
}


def page(upstream):
    """Compose the phone UI, omitting the removed reasoning display option."""
    html = (Path(upstream) / 'index.html').read_text(encoding='utf-8')
    if html.count('</head>') != 1 or html.count('</body>') != 1:
        raise ValueError('内置网页结构不兼容，无法加载 codex-link 界面')
    html, removed = re.subn(r'<label class="display-option"><span><strong data-i18n="思考摘要">.*?</label>', '', html, count=1)
    if removed != 1 or html.count('<script src="/presentation.js" defer></script>') != 1 or html.count('<script src="/timeline.js" defer></script>') != 1:
        raise ValueError('内置网页结构不兼容，无法加载 codex-link 对话显示设置')
    html = html.replace('<script src="/presentation.js" defer></script>', '<script src="/link-presentation.js" defer></script>')
    # Install the timeline policy before app.js can open a saved conversation.
    html = html.replace('<script src="/timeline.js" defer></script>', '<script src="/timeline.js" defer></script><script src="/link-timeline.js" defer></script>')
    html = html.replace('关闭两项可专注回复；错误和待确认请求仍会显示。', '关闭执行过程可专注回复；错误和待确认请求仍会显示。')
    html = html.replace('</head>', ''.join(f'<link rel="stylesheet" href="/link-{part}.css">' for part in ('ui', 'history', 'workspace', 'settings')) + '</head>')
    html = html.replace('</body>', ''.join(f'<script src="/link-{part}.js" defer></script>' for part in ('ui', 'history', 'workspace', 'settings')) + '</body>')
    return html.encode('utf-8')


def validate():
    for name, _ in ASSETS.values():
        if not (WEB_ROOT / name).is_file():
            raise ValueError('缺少 codex-link 网页资源：' + name)
