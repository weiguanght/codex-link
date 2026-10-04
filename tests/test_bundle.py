"""Integrity and dependency checks for the self-contained runtime snapshot."""
import ast
import hashlib
import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from mac.runtime import DEFAULT_BRIDGE, activate_bridge

BUNDLE = activate_bridge()


class BundleTests(unittest.TestCase):
    def test_default_runtime_is_inside_project(self):
        self.assertEqual(BUNDLE, DEFAULT_BRIDGE)
        self.assertIn(ROOT, BUNDLE.parents)
        for path in BUNDLE.rglob('*'):
            self.assertFalse(path.is_symlink(), str(path))

    def test_snapshot_hashes_and_licenses(self):
        manifest = json.loads((BUNDLE / 'UPSTREAM.json').read_text())
        self.assertEqual(manifest['version'], '1.3.2')
        for name, digest in manifest['files'].items():
            with self.subTest(file=name):
                self.assertEqual(hashlib.sha256((BUNDLE / name).read_bytes()).hexdigest(), digest)
        for name in ('LICENSE', 'web/vendor/markdown-it.LICENSE',
                     'web/vendor/texmath.LICENSE', 'web/vendor/katex/LICENSE'):
            self.assertIn(name, manifest['files'])

    def test_all_relative_module_dependencies_are_bundled(self):
        manifest = json.loads((BUNDLE / 'UPSTREAM.json').read_text())
        modules = set(manifest['modules'])
        for name in modules:
            path = BUNDLE / 'bridge' / (name + '.py')
            for node in ast.walk(ast.parse(path.read_text(encoding='utf-8'))):
                if isinstance(node, ast.ImportFrom) and node.level == 1:
                    dependencies = [node.module.split('.')[0]] if node.module else [item.name for item in node.names]
                    self.assertTrue(set(dependencies) <= modules, (name, dependencies))
            # Import definitions only; do not instantiate Bridge or access Codex.
            module = importlib.import_module('bridge' if name == '__init__' else 'bridge.' + name)
            self.assertIn(BUNDLE, Path(module.__file__).resolve().parents)

    def test_every_registered_static_asset_exists(self):
        from bridge.httpd import STATIC
        for name, _ in STATIC.values():
            self.assertTrue((BUNDLE / 'web' / name).is_file(), name)
        self.assertTrue(any((BUNDLE / 'web/vendor/katex/fonts').glob('*.woff2')))

    def test_missing_bundle_is_an_error_not_a_parent_directory_fallback(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ValueError, '网关资源不完整'):
                activate_bridge(folder)


if __name__ == '__main__':
    unittest.main()
