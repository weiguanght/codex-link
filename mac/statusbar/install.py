#!/usr/bin/env python3
"""Build and register the current user's menu bar gateway without stopping existing processes."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
LABEL = 'com.hoto.codex-link.gateway'
APP = Path.home() / 'Applications' / 'Codex网关.app'
AGENT = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
LOGS = Path.home() / 'Library/Logs/CodexLink'


def main():
    if sys.platform != 'darwin':
        raise SystemExit('需要 macOS。')
    if APP.exists() or AGENT.exists():
        raise SystemExit('状态栏程序或自启配置已存在，请先检查现有安装。')
    subprocess.run([sys.executable, str(ROOT / 'run-mac.py'), '--check-runtime'], check=True)
    LOGS.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix='codex-link-statusbar-') as directory:
        bundle = Path(directory) / APP.name
        binaries = bundle / 'Contents/MacOS'
        resources = bundle / 'Contents/Resources'
        binaries.mkdir(parents=True)
        resources.mkdir()
        executable = binaries / 'CodexLinkStatusBar'
        subprocess.run(['/usr/bin/xcrun', 'swiftc', '-O', '-framework', 'Cocoa',
                        str(ROOT / 'mac/statusbar/GatewayStatusBar.swift'), '-o', str(executable)], check=True)
        info = {'CFBundleIdentifier': LABEL, 'CFBundleName': 'Codex网关',
                'CFBundleDisplayName': 'Codex网关', 'CFBundleExecutable': executable.name,
                'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
                'CFBundleShortVersionString': '1.0', 'LSUIElement': True,
                'LSMinimumSystemVersion': '13.0',
                'NSDownloadsFolderUsageDescription': '运行您保存在下载目录中的 Mac 网关及其配对配置。'}
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        configuration = {'projectDirectory': str(ROOT), 'pythonExecutable': sys.executable,
                         'logDirectory': str(LOGS), 'launchAgent': str(AGENT)}
        (resources / 'gateway.json').write_text(json.dumps(configuration, ensure_ascii=False, indent=2))
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(bundle)], check=True)
        APP.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(bundle, APP)
    agent = {'Label': LABEL, 'ProgramArguments': [str(APP / 'Contents/MacOS/CodexLinkStatusBar')],
             'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 5,
             'LimitLoadToSessionType': 'Aqua', 'ProcessType': 'Interactive',
             'StandardOutPath': str(LOGS / 'statusbar.log'),
             'StandardErrorPath': str(LOGS / 'statusbar.log'), 'Umask': 0o077}
    AGENT.parent.mkdir(parents=True, exist_ok=True)
    temporary = AGENT.with_suffix('.plist.tmp')
    temporary.write_bytes(plistlib.dumps(agent))
    temporary.chmod(0o644)
    temporary.replace(AGENT)
    subprocess.run(['/usr/bin/plutil', '-lint', str(AGENT)], check=True)
    domain = 'gui/' + str(os.getuid())
    subprocess.run(['/bin/launchctl', 'enable', domain + '/' + LABEL], check=True)
    subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(AGENT)], check=True)
    print('状态栏程序：', APP)
    print('登录自启配置：', AGENT)
    print('日志目录：', LOGS)


if __name__ == '__main__':
    main()
