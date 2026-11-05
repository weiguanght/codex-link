"""Workspace reads use disposable directories and local Git only."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from mac.workspace_reader import WorkspaceReader, WorkspaceReadError, WorkspaceConflictError, PREVIEW_BYTES


class WorkspaceReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'workspace'; self.root.mkdir()
        self.reader = WorkspaceReader(str(self.root))

    def git(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        return subprocess.check_output(['/usr/bin/git', '-c', 'user.name=Synthetic', '-c', 'user.email=test@example.invalid', *args], cwd=self.root, env=env)

    def repository(self):
        self.git('init', '-q')
        (self.root / 'tracked.txt').write_text('old\n')
        self.git('add', '--', 'tracked.txt'); self.git('commit', '-qm', 'synthetic baseline')

    def test_tree_search_preview_and_pagination(self):
        (self.root / 'Sources').mkdir(); (self.root / 'Sources/main.swift').write_text('let value = "你好"\n')
        for i in range(105): (self.root / f'file-{i:03d}').write_text('x')
        first = self.reader.tree(); second = self.reader.tree(offset=100)
        self.assertTrue(first['hasMore']); self.assertFalse(second['hasMore'])
        self.assertEqual(first['entries'][0]['kind'], 'directory')
        self.assertEqual(len(first['entries']) + len(second['entries']), 106)
        self.assertEqual(self.reader.search('MAIN.SWIFT')['entries'][0]['path'], 'Sources/main.swift')
        value = self.reader.file('Sources/main.swift')
        self.assertTrue(value['previewable']); self.assertIn('你好', value['text'])
        self.assertEqual(self.reader.tree('Sources')['entries'][0]['path'], 'Sources/main.swift')

    def test_save_preserves_bom_crlf_and_mode_and_rejects_stale_revision(self):
        file = self.root / '脚本.sh'; file.write_bytes(b'\xef\xbb\xbfecho old\r\n'); file.chmod(0o751)
        initial = self.reader.file(file.name)
        saved = self.reader.save(file.name, 'echo new\r\n', initial['revision'])
        self.assertEqual(file.read_bytes(), b'\xef\xbb\xbfecho new\r\n')
        self.assertEqual(file.stat().st_mode & 0o777, 0o751)
        self.assertEqual(saved['revision'], self.reader.file(file.name)['revision'])
        with self.assertRaises(WorkspaceConflictError): self.reader.save(file.name, 'overwrite', initial['revision'])
        self.assertEqual(file.read_bytes(), b'\xef\xbb\xbfecho new\r\n')

    def test_save_limits_missing_binary_symlinks_and_hardlinks(self):
        file = self.root / 'file'; file.write_text('old')
        revision = self.reader.file('file')['revision']
        (self.root / 'symlink').symlink_to(file); os.link(file, self.root / 'hardlink')
        for path in ('../file', '.git/config', 'symlink', 'hardlink', 'missing'):
            with self.assertRaises((ValueError, OSError)): self.reader.save(path, 'new', revision)
        (self.root / 'hardlink').unlink()
        for text in ('a' * (PREVIEW_BYTES + 1), '\x00', None):
            with self.assertRaises(ValueError): self.reader.save('file', text, revision)
        file.write_bytes(b'\x00binary')
        with self.assertRaises(ValueError): self.reader.save('file', 'new', self.reader.file('file')['revision'])

    def test_failed_atomic_save_keeps_original_and_removes_temporary_file(self):
        file = self.root / 'file'; file.write_text('old')
        with patch('mac.workspace_reader.os.replace', side_effect=OSError('synthetic failure')):
            with self.assertRaises(OSError): self.reader.save('file', 'new', self.reader.file('file')['revision'])
        self.assertEqual(file.read_text(), 'old')
        self.assertEqual([p.name for p in self.root.iterdir()], ['file'])

    def test_no_escape_symlink_fifo_or_git_internals(self):
        outside = self.root.parent / 'secret'; outside.write_text('DO NOT READ')
        (self.root / 'link').symlink_to(outside)
        (self.root / 'dir-link').symlink_to(self.root.parent, target_is_directory=True)
        (self.root / '.git').mkdir(); (self.root / '.git/config').write_text('secret')
        os.mkfifo(self.root / 'pipe')
        for path in ('../secret', '/etc/passwd', '.git/config', '.GIT/config', 'dir-link/secret', 'link', 'pipe'):
            with self.assertRaises((OSError, ValueError)): self.reader.file(path)
        with self.assertRaises(OSError): self.reader.tree('dir-link')
        paths = [r['path'] for r in self.reader.search('secret')['entries']]
        self.assertEqual(paths, [])
        self.assertNotIn('.git', [r['name'] for r in self.reader.tree()['entries']])

    def test_binary_and_large_preview_are_explicit_and_bounded(self):
        (self.root / 'binary').write_bytes(b'\x00\xffsecret')
        value = self.reader.file('binary'); self.assertFalse(value['previewable']); self.assertEqual(value['text'], '')
        (self.root / 'large').write_bytes(b'a' * (PREVIEW_BYTES - 1) + '你'.encode() * 3)
        value = self.reader.file('large')
        self.assertTrue(value['previewable']); self.assertTrue(value['truncated'])
        self.assertLessEqual(len(value['text'].encode()), PREVIEW_BYTES)

    def test_search_budget_and_no_recursion_into_dependency_folders(self):
        (self.root / 'node_modules').mkdir(); (self.root / 'node_modules/match').write_text('x')
        for i in range(8): (self.root / f'match-{i}').write_text('x')
        with patch('mac.workspace_reader.SCAN_ENTRIES', 4):
            value = self.reader.search('match')
        self.assertTrue(value['limited']); self.assertLessEqual(len(value['entries']), 4)
        self.assertNotIn('node_modules/match', [r['path'] for r in value['entries']])

    def test_staged_unstaged_untracked_binary_and_odd_paths(self):
        self.repository()
        (self.root / 'tracked.txt').write_text('staged\n'); self.git('add', '--', 'tracked.txt')
        (self.root / 'tracked.txt').write_text('worktree\n')
        odd = 'odd\tname\n.txt'; (self.root / odd).write_text('untracked')
        (self.root / 'binary').write_bytes(b'\x00old'); self.git('add', '--', 'binary')
        staged = self.reader.changes('staged')
        self.assertEqual(staged['fileCount'], 2)
        self.assertIn('+staged', self.reader.patch('tracked.txt', 'staged')['text'])
        self.assertIn('+worktree', self.reader.patch('tracked.txt')['text'])
        unstaged = self.reader.changes()
        self.assertTrue(next(r for r in unstaged['files'] if r['path'] == odd)['untracked'])
        self.assertEqual(next(r for r in staged['files'] if r['path'] == 'binary')['added'], None)
        self.assertEqual(self.git('diff', '--cached', '--numstat'), b'-\t-\tbinary\n1\t1\ttracked.txt\n')
        with self.assertRaises(ValueError): self.reader.changes('branch')
        nested = self.root / 'nested'; nested.mkdir()
        with self.assertRaises(WorkspaceReadError): WorkspaceReader(str(nested)).changes()

    def test_repository_cannot_execute_filters_external_diff_or_fsmonitor(self):
        self.repository()
        marker = self.root.parent / 'executed'
        command = 'touch ' + str(marker)
        self.git('config', 'filter.sneaky=driver.clean', command)
        self.git('config', 'filter.sneaky=driver.process', command)
        self.git('config', 'filter.sneaky=driver.required', 'true')
        self.git('config', 'diff.external', command)
        self.git('config', 'core.fsmonitor', command)
        (self.root / '.gitattributes').write_text('tracked.txt filter=sneaky=driver\n')
        (self.root / 'tracked.txt').write_text('new\n')
        self.reader.changes(); self.reader.patch('tracked.txt')
        self.assertFalse(marker.exists())

    def test_git_inherited_repository_variables_are_discarded_and_output_is_bounded(self):
        self.repository(); (self.root / 'tracked.txt').write_text('new\n')
        with patch.dict(os.environ, {'GIT_DIR': '/does-not-exist', 'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'diff.external', 'GIT_CONFIG_VALUE_0': 'false'}):
            self.assertEqual(self.reader.changes()['fileCount'], 1)
        (self.root / 'tracked.txt').write_text('z' * 2048)
        with patch('mac.workspace_reader.GIT_BYTES', 1024):
            with self.assertRaises(WorkspaceReadError): self.reader.patch('tracked.txt')
