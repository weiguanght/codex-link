#!/usr/bin/env python3
"""Explicit, offline maintenance command; never used during normal startup."""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
ENTRY_MODULES = ('service', 'httpd', 'notifications')
PINNED_VERSION = '1.3.2'


def runtime_modules(source):
    names = {'__init__'}
    pending = list(ENTRY_MODULES)
    while pending:
        name = pending.pop()
        if name in names:
            continue
        path = source / 'bridge' / (name + '.py')
        if not path.is_file():
            raise ValueError('缺少运行时模块：' + str(path))
        names.add(name)
        for node in ast.walk(ast.parse(path.read_text(encoding='utf-8'))):
            if isinstance(node, ast.ImportFrom) and node.level == 1:
                pending.extend([node.module.split('.')[0]] if node.module else [item.name for item in node.names])
    return names


def main():
    parser = argparse.ArgumentParser(description='从明确指定的上游源码生成本地运行时快照')
    parser.add_argument('source', type=Path, help='上游 codex-mobile-bridge 1.3.2 源码目录')
    parser.add_argument('--output', type=Path, default=ROOT / 'vendor' / 'codex-mobile-bridge',
                        help='必须是尚不存在的目录，避免覆盖正在运行的网关')
    args = parser.parse_args()
    source, destination = args.source.resolve(), args.output.resolve()
    version = json.loads((source / 'package.json').read_text(encoding='utf-8'))['version']
    if version != PINNED_VERSION:
        parser.error('只接受已验证的 ' + PINNED_VERSION + '；升级需先审查运行时依赖及协议')
    if destination.exists():
        parser.error('输出目录已存在；请使用 --output 写入新目录并测试，不会原地覆盖')
    modules = runtime_modules(source)
    (destination / 'bridge').mkdir(parents=True)
    for name in sorted(modules):
        shutil.copy2(source / 'bridge' / (name + '.py'), destination / 'bridge' / (name + '.py'))
    # All fonts, images, scripts and third-party licenses are copied byte-for-byte.
    shutil.copytree(source / 'web', destination / 'web',
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '.DS_Store'))
    shutil.copy2(source / 'LICENSE', destination / 'LICENSE')
    files = {str(path.relative_to(destination)): hashlib.sha256(path.read_bytes()).hexdigest()
             for path in sorted(destination.rglob('*')) if path.is_file()}
    manifest = {
        'project': 'codex-mobile-bridge', 'version': version,
        'upstream': 'https://github.com/try2love/codex-mobile-bridge',
        'source': 'Local source snapshot supplied with this project; not fetched from the network.',
        'entryModules': list(ENTRY_MODULES), 'modules': sorted(modules),
        'modifications': 'None. Runtime subset; Electron, old launchers, deployment and updater excluded.',
        'files': files,
    }
    (destination / 'UPSTREAM.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'已内置 {len(modules)} 个 Python 模块、{len(files)} 个文件；版本 {version}')


if __name__ == '__main__':
    main()
