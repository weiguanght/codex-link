#!/usr/bin/env python3
"""Normalize staged iOS permissions and check the actual IPA before publishing."""
import argparse
from pathlib import Path, PurePosixPath
import plistlib
import stat
import zipfile


APP = 'CodexLink.app'
BUNDLE_ID = 'local.codex.link'
EXECUTABLE = 'CodexLink'
PREFIX = 'Payload/' + APP + '/'


def validate_info(info):
    if not isinstance(info, dict):
        raise ValueError('Info.plist must be a dictionary')
    for key, expected in (('CFBundleIdentifier', BUNDLE_ID), ('CFBundleExecutable', EXECUTABLE),
                          ('CFBundlePackageType', 'APPL')):
        if info.get(key) != expected:
            raise ValueError(f'Invalid {key}: expected {expected}')
    for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
        value = info.get(key)
        if not isinstance(value, str) or not value.strip() or '$' in value:
            raise ValueError(f'Invalid {key}')


def prepare(payload):
    payload = Path(payload)
    app = payload / APP
    paths = [payload, *payload.rglob('*')]
    modes = {}
    for path in paths:
        mode = path.lstat().st_mode
        # This app ships self-contained regular resources, not external links.
        if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise ValueError(f'Unsupported bundle entry: {path}')
        modes[path] = 0o755 if stat.S_ISDIR(mode) or mode & 0o111 else 0o644
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    validate_info(info)
    executable = app / EXECUTABLE
    if not executable.is_file():
        raise ValueError(f'Missing executable: {executable}')
    modes[executable] = 0o755
    # Include Payload and the .app root. TrollStore's descendant-only repair
    # otherwise leaves a copied, root-owned 0700 .app unreadable to mobile.
    for path, mode in modes.items():
        path.chmod(mode)


def verify(ipa):
    with zipfile.ZipFile(ipa) as package:
        entries = {}
        for entry in package.infolist():
            name = entry.filename
            path = PurePosixPath(name)
            canonical = str(path) + ('/' if entry.is_dir() else '')
            if (name != canonical or path.is_absolute() or '..' in path.parts
                    or not path.parts or path.parts[0] != 'Payload' or '\\' in name
                    or name in entries):
                raise ValueError(f'Invalid archive path: {name}')
            mode = entry.external_attr >> 16
            if entry.create_system != 3 or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise ValueError(f'Unsupported archive entry: {name}')
            permissions = stat.S_IMODE(mode)
            allowed = (0o755,) if entry.is_dir() else (0o644, 0o755)
            if permissions not in allowed:
                raise ValueError(f'Invalid permissions for {name}: {permissions:04o}')
            entries[name] = entry
        for name in ('Payload/', PREFIX, PREFIX + 'Info.plist', PREFIX + EXECUTABLE):
            if name not in entries:
                raise ValueError(f'Missing archive entry: {name}')
        if stat.S_IMODE(entries[PREFIX + 'Info.plist'].external_attr >> 16) != 0o644:
            raise ValueError('Info.plist must have permissions 0644')
        if stat.S_IMODE(entries[PREFIX + EXECUTABLE].external_attr >> 16) != 0o755:
            raise ValueError('Executable must have permissions 0755')
        validate_info(plistlib.loads(package.read(PREFIX + 'Info.plist')))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('prepare', 'verify'))
    parser.add_argument('path', type=Path)
    args = parser.parse_args()
    try:
        (prepare if args.operation == 'prepare' else verify)(args.path)
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        parser.exit(1, str(exc) + '\n')
    print(f'iOS bundle {args.operation}: PASS ({args.path})')


if __name__ == '__main__':
    main()
