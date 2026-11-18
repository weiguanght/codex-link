#!/usr/bin/env python3
"""Opt-in installed-runtime settings contract test; entirely synthetic HOME.

No credentials, real settings, desktop IPC, turns, model calls, or MCP servers.
"""
import argparse
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from mac.settings import CodexSettings
from mac.settings_rpc import SettingsRPC, SettingsError, SettingsSchema


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', default='/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex')
    args = parser.parse_args()
    schema = SettingsSchema(args.runtime)
    build = ROOT / 'build'
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='codex-link-native-settings-', dir=build) as folder:
        root = Path(folder).resolve(); home = root / '.codex'; home.mkdir()
        project = root / 'project'; (project / '.codex').mkdir(parents=True)
        env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(root), 'CODEX_HOME': str(home)}
        factory = lambda: SettingsRPC(home, args.runtime, env=env)
        bridge = SimpleNamespace(codex_home=home, catalog_reader=SimpleNamespace(executable=args.runtime))
        workspace = SimpleNamespace(project=lambda _: {'name': 'Synthetic', 'host': 'local', 'cwd': str(project)})
        service = CodexSettings(bridge, workspace, rpc_factory=factory, schema=schema)
        def save(changes, confirm=False):
            return service.write({'revision': service.read()['revision'], 'changes': changes,
                                  'confirmPermissions': confirm})
        before = service.read(); assert before['writable'], before['reason']
        saved = save({'model_reasoning_effort': 'high', 'developer_instructions': 'Synthetic test only'})
        assert saved['status'] == 'saved' and not saved['liveApplied']
        assert saved['settings']['fields']['model_reasoning_effort']['effective'] == 'high'
        cleared = save({'model_reasoning_effort': None, 'developer_instructions': None})
        assert cleared['settings']['fields']['model_reasoning_effort']['value'] is None
        samples = {
            'review_model': 'gpt-5', 'plan_mode_reasoning_effort': 'high', 'personality': 'pragmatic',
            'service_tier': 'default', 'model_context_window': 128000, 'model_auto_compact_token_limit': 64000,
            'model_auto_compact_token_limit_scope': 'total', 'model_post_turn_compact_threshold_percent': 75,
            'approvals_reviewer': 'user', 'allow_login_shell': False, 'include_environment_context': False,
            'include_environment_context_time': False, 'include_apps_instructions': False,
            'include_collaboration_mode_instructions': False,
            'compact_prompt': 'Synthetic compact prompt', 'project_doc_max_bytes': 4096,
            'features.memories': True, 'memories.generate_memories': True,
            'memories.use_memories': False, 'memories.disable_on_external_context': True,
            'tool_output_token_limit': 3000, 'background_terminal_max_timeout': 45000,
            'history.persistence': 'none', 'history.max_bytes': 100000,
        }
        available = {key: item for key, item in samples.items() if before['fields'][key]['supported']}
        if available:
            out = save(available, confirm=True)
            assert out['status'] == 'saved', out['overridden']
            assert all(out['settings']['fields'][key]['effective'] == item for key, item in available.items())
            if 'memories.use_memories' in available:
                cleared = save({'memories.use_memories': None})
                fields = cleared['settings']['fields']
                assert fields['memories.use_memories']['value'] is None
                assert fields['memories.generate_memories']['value'] is True
            save(dict.fromkeys(available), confirm=True)
        revision = service.read()['revision']; save({'model_reasoning_effort': 'low'})
        try: service.write({'revision': revision, 'changes': {'model_reasoning_effort': 'high'}})
        except SettingsError as e: assert e.code == 'conflict'
        else: raise AssertionError('Stale revision was accepted')
        # Native optimistic concurrency, not only our facade's revision check.
        with factory() as rpc:
            raw = rpc.request('config/read', {'includeLayers': True})
            user = next(l for l in raw['layers'] if l['name']['type'] == 'user')
            rpc.request('config/batchWrite', {'edits': [{'keyPath': 'projects', 'value': {str(project): {'trust_level': 'trusted'}}, 'mergeStrategy': 'replace'}], 'expectedVersion': user['version'], 'reloadUserConfig': False})
            try:
                rpc.request('config/batchWrite', {'edits': [{'keyPath': 'model_reasoning_effort', 'value': 'high', 'mergeStrategy': 'replace'}], 'expectedVersion': user['version']})
            except SettingsError: pass
            else: raise AssertionError('Native stale version was accepted')
        (project / '.codex/config.toml').write_text('model_reasoning_effort = "medium"\n')
        project_settings = service.read('local|synthetic')
        assert not project_settings['writable']
        assert project_settings['fields']['model_reasoning_effort']['effective'] == 'medium'
        with factory() as rpc:
            raw = rpc.request('config/read', {'includeLayers': True, 'cwd': str(project)})
            layer = next(l for l in raw['layers'] if l['name']['type'] == 'project')
            try:
                rpc.request('config/batchWrite', {'edits': [{'keyPath': 'model_reasoning_effort', 'value': 'high', 'mergeStrategy': 'replace'}], 'filePath': str(project / '.codex/config.toml'), 'expectedVersion': layer['version']})
            except SettingsError: pass
            else: raise AssertionError('Project writes are now supported: revisit the UI capability policy')
        skill = home / 'skills/demo/SKILL.md'; skill.parent.mkdir(parents=True)
        skill.write_text('---\nname: demo\ndescription: Synthetic settings contract test\n---\nDo not run anything.\n')
        skills = service.skills(); assert skills['writable'], skills
        row = next(s for s in skills['skills'] if Path(s['path']) == skill)
        out = service.skill_write({'revision': skills['revision'], 'path': row['path'], 'enabled': False, 'confirmed': True})
        assert any(s['path'] == row['path'] and not s['enabled'] for s in out['skills'])
        editor = service.read_advanced()
        content = 'model = "gpt-5"\nmodel_reasoning_effort = "high"\n'
        saved_editor = service.write_advanced({'revision': editor['revision'], 'content': content})
        assert saved_editor['content'] == content and Path(saved_editor['path']).read_text() == content
        try:
            service.write_advanced({'revision': saved_editor['revision'], 'content': 'model = 7\n'})
        except ValueError:
            pass
        else:
            raise AssertionError('Codex Runtime accepted a config field with the wrong type')
        assert Path(saved_editor['path']).read_text() == content
        print('PASS:', schema.get()['version'], f'{len(available)} additional fields written and verified,',
              'nested reset, native CAS, project read-only, skills toggle and TOML validation')


if __name__ == '__main__': main()
