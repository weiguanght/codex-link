#!/usr/bin/env python3
"""Prove portability in a clean directory without moving/deleting live files."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='codex-link-standalone-') as folder:
        copy = Path(folder) / 'codex-link'
        copy.mkdir()
        ignore = shutil.ignore_patterns('__pycache__', '*.pyc', '.DS_Store', '.local', 'build')
        for name in ('mac', 'vendor', 'tests'):
            shutil.copytree(ROOT / name, copy / name, ignore=ignore)
        shutil.copy2(ROOT / 'run-mac.py', copy / 'run-mac.py')
        # No pairing files, real home, upstream sibling or build cache is copied.
        assert not (copy / '.local').exists()
        assert not (copy.parent / 'codex-mobile-bridge-1.3.2').exists()
        env = {k: v for k, v in os.environ.items() if k not in ('PYTHONPATH', 'PYTHONHOME', 'CODEX_HOME')}
        home = Path(folder) / 'empty-home'
        home.mkdir()
        env.update(HOME=str(home), CODEX_HOME=str(home / '.codex'))
        bootstrap = '''import pathlib,runpy,sys
root=pathlib.Path(sys.argv[1])
sys.path.insert(0,str(root))
sys.argv=[str(root/'run-mac.py'),'--check-runtime']
runpy.run_path(sys.argv[0],run_name='__main__')
'''
        subprocess.run([sys.executable, '-I', '-B', '-c', bootstrap, str(copy)],
                       cwd=folder, env=env, check=True, timeout=30)
        assert not (copy / '.local').exists(), 'runtime check must not create pairing data'
        subprocess.run([sys.executable, '-I', '-B', '-m', 'unittest', 'discover', '-s', str(copy / 'tests'), '-v'],
                       cwd=folder, env=env, check=True, timeout=120)
        print('PASS：仅复制 codex-link 运行文件，在无上游目录、空 HOME 的隔离环境通过全部测试。')


if __name__ == '__main__':
    main()
