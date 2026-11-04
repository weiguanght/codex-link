"""Presentation keeps supported controls and uses only bundled resources."""
from html.parser import HTMLParser
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from mac import web_ui


class Inventory(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.ids, self.scripts, self.styles = [], [], []
        self.feed(html)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if 'id' in attrs:
            self.ids.append(attrs['id'])
        if tag == 'script':
            self.scripts.append(attrs.get('src'))
        if tag == 'link' and attrs.get('rel') == 'stylesheet':
            self.styles.append(attrs.get('href'))


class WebUITests(unittest.TestCase):
    def test_supported_upstream_ids_and_script_order_preserved(self):
        source = ROOT / 'vendor/codex-mobile-bridge/web'
        original = Inventory((source / 'index.html').read_text())
        enhanced = Inventory(web_ui.page(source).decode())
        self.assertEqual([name for name in original.ids if name != 'appearance-reasoning'], enhanced.ids)
        self.assertEqual(len(enhanced.ids), len(set(enhanced.ids)))
        scripts = [src if src != '/presentation.js' else '/link-presentation.js' for src in original.scripts]
        scripts.insert(scripts.index('/timeline.js') + 1, '/link-timeline.js')
        self.assertEqual(enhanced.scripts, scripts + ['/link-ui.js', '/link-history.js', '/link-workspace.js', '/link-settings.js'])
        self.assertEqual(enhanced.styles, original.styles + ['/link-ui.css', '/link-history.css', '/link-workspace.css', '/link-settings.css'])
        for url in enhanced.scripts + enhanced.styles:
            self.assertTrue(url.startswith('/') and not url.startswith('//'))

    def test_overlay_is_self_contained_and_whitelisted(self):
        web_ui.validate()
        self.assertEqual(set(web_ui.ASSETS), {'/link-ui.css', '/link-ui.js', '/link-history.css', '/link-history.js', '/link-workspace.css', '/link-workspace.js', '/link-settings.css', '/link-settings.js', '/link-timeline.js', '/link-presentation.js'})
        for name, _ in web_ui.ASSETS.values():
            self.assertEqual(Path(name).name, name)
            self.assertFalse((web_ui.WEB_ROOT / name).is_symlink())

    def test_overlay_has_no_network_or_desktop_operations(self):
        source = (web_ui.WEB_ROOT / 'link-ui.js').read_text()
        for forbidden in ('fetch(', 'XMLHttpRequest', 'WebSocket(', '/api/', 'innerHTML'):
            self.assertNotIn(forbidden, source)


if __name__ == '__main__':
    unittest.main()
