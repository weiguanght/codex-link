"""IPA metadata and cross-owner permissions; fixtures stay inside build/."""
import importlib.util
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ios_bundle', ROOT / 'scripts/ios-bundle.py')
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class IOSPackageTests(unittest.TestCase):
    def setUp(self):
        (ROOT / 'build').mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix='ios-package-test-', dir=ROOT / 'build')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.payload = self.root / 'Payload'
        self.app = self.payload / bundle.APP
        resources = self.app / 'Resources'
        resources.mkdir(parents=True)
        self.info = {'CFBundleIdentifier': bundle.BUNDLE_ID, 'CFBundleExecutable': bundle.EXECUTABLE,
                     'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '3'}
        self.write_info()
        (self.app / bundle.EXECUTABLE).write_bytes(b'synthetic executable')
        (resources / 'data.txt').write_text('synthetic resource')
        for path in [self.payload, *self.payload.rglob('*')]:
            path.chmod(0o700 if path.is_dir() or path.name == bundle.EXECUTABLE else 0o600)
        self.ipa = self.root / 'fixture.ipa'

    def write_info(self):
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info))

    def archive(self):
        with zipfile.ZipFile(self.ipa, 'w') as package:
            for path in [self.payload, *self.payload.rglob('*')]:
                package.write(path, str(path.relative_to(self.root)))

    def test_restrictive_umask_is_normalized_including_both_root_directories(self):
        before = {path: path.read_bytes() for path in self.payload.rglob('*') if path.is_file()}
        bundle.prepare(self.payload)
        for path in [self.payload, *self.payload.rglob('*')]:
            with self.subTest(path=path):
                expected = 0o755 if path.is_dir() or path.name == bundle.EXECUTABLE else 0o644
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), expected)
        self.assertEqual(before, {path: path.read_bytes() for path in before})
        self.archive()
        bundle.verify(self.ipa)

    def test_descendant_only_installer_repair_leaves_unreadable_app_root(self):
        # Mirror TrollStore fixPermissionsOfAppBundle: the root is not enumerated.
        self.payload.chmod(0o755)
        for path in self.app.rglob('*'):
            path.chmod(0o755 if path.is_dir() or path.name == bundle.EXECUTABLE else 0o644)
        self.archive()
        with self.assertRaisesRegex(ValueError, r'CodexLink.app/.*0700'):
            bundle.verify(self.ipa)
        bundle.prepare(self.payload)
        self.archive()
        bundle.verify(self.ipa)

    def test_unreadable_resource_is_rejected_in_actual_archive(self):
        bundle.prepare(self.payload)
        (self.app / 'Resources/data.txt').chmod(0o600)
        self.archive()
        with self.assertRaisesRegex(ValueError, r'data.txt.*0600'):
            bundle.verify(self.ipa)

    def test_executable_without_execute_bits_is_repaired_and_rejected_if_regressed(self):
        (self.app / bundle.EXECUTABLE).chmod(0o600)
        bundle.prepare(self.payload)
        self.assertEqual(stat.S_IMODE((self.app / bundle.EXECUTABLE).stat().st_mode), 0o755)
        (self.app / bundle.EXECUTABLE).chmod(0o644)
        self.archive()
        with self.assertRaisesRegex(ValueError, 'Executable must have permissions'):
            bundle.verify(self.ipa)

    def test_bundle_identity_and_unexpanded_version_are_rejected(self):
        for key, value in (('CFBundleIdentifier', ''), ('CFBundleIdentifier', 'other.app'),
                           ('CFBundleExecutable', '$(EXECUTABLE_NAME)'), ('CFBundlePackageType', 'FMWK'),
                           ('CFBundleVersion', '$(CURRENT_PROJECT_VERSION)')):
            with self.subTest(key=key, value=value):
                info = dict(self.info, **{key: value})
                with self.assertRaisesRegex(ValueError, key):
                    bundle.validate_info(info)

    def test_missing_executable_does_not_publish_a_prepared_bundle(self):
        (self.app / bundle.EXECUTABLE).unlink()
        with self.assertRaisesRegex(ValueError, 'Missing executable'):
            bundle.prepare(self.payload)
        self.assertEqual(stat.S_IMODE(self.app.stat().st_mode), 0o700)

    def test_links_are_rejected_without_changing_external_permissions(self):
        outside = self.root / 'outside'; outside.write_text('not a packaged resource'); outside.chmod(0o600)
        (self.app / 'linked-resource').symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'Unsupported bundle entry'):
            bundle.prepare(self.payload)
        self.assertEqual(stat.S_IMODE(outside.stat().st_mode), 0o600)

    def test_archive_metadata_is_checked_after_packaging(self):
        bundle.prepare(self.payload)
        self.info['CFBundleIdentifier'] = 'wrong.bundle'
        self.write_info()
        self.archive()
        with self.assertRaisesRegex(ValueError, 'CFBundleIdentifier'):
            bundle.verify(self.ipa)


if __name__ == '__main__':
    unittest.main()
