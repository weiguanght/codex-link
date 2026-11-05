#!/usr/bin/env python3
"""Export a bounded, non-executable Serena navigation view of binary evidence.

Bodies describe direct call edges only. They are NOT reconstructed algorithms,
source signatures, execution order, or the app's implementation.
"""
import argparse
import collections
import csv
import json
from pathlib import Path
import subprocess


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--analysis', type=Path, required=True)
    cli.add_argument('--output', type=Path, required=True)
    cli.add_argument('--module', default='CodexRemoteHost')
    cli.add_argument('--address', action='append', default=[])
    cli.add_argument('--limit', type=int, default=64)
    args = cli.parse_args()
    if not 1 <= args.limit <= 1000:
        cli.error('--limit must be 1..1000; keep semantic work bounded')
    analysis = args.analysis.resolve()
    manifest = json.loads((analysis / 'manifest.json').read_text())
    by_address = {r['address']: r for r in manifest}
    if args.address:
        requested = [int(a, 0) for a in args.address]
        missing = [hex(a) for a in requested if a not in by_address]
        if missing:
            cli.error('Addresses outside manifest: ' + ', '.join(missing))
        candidates = [by_address[a] for a in dict.fromkeys(requested)]
    else:
        candidates = [r for r in manifest if r['module'] == args.module]
        # Prefer direct evidence within the module's own linker range.
        spans = json.loads((analysis / 'module_spans.json').read_text())
        span = next((r for r in spans if r['module'] == args.module), None)
        def score(r):
            in_span = span and int(span['start'], 16) <= r['address'] < int(span['end'], 16)
            return (not in_span, r['ownership'] != 'direct_evidence', r['address'])
        candidates.sort(key=score)
    selected = candidates[:args.limit]
    if not selected:
        cli.error('No candidates selected')
    addresses = {r['address'] for r in selected}
    calls = collections.defaultdict(list)
    with (analysis / 'direct_calls.jsonl').open() as stream:
        for line in stream:
            edge = json.loads(line)
            if edge['from'] in addresses:
                calls[edge['from']].append(edge)
    index = {int(r['address'], 16): r for r in csv.DictReader((analysis / 'function_index.csv').open()) if int(r['address'], 16) in addresses}
    targets = addresses | {edge['to'] for edges in calls.values() for edge in edges}
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    code = ['/* NAVIGATION PROJECTION ONLY. Non-executable binary evidence.',
            ' * Parameters, conditions, order and indirect calls are not recovered here.',
            ' * Use mapping.json to open the real pseudocode and assembly. */']
    (output / 'EvidenceDeclarations.h').write_text('#pragma once\n' + '\n'.join(f'void rva_{a:X}(void);' for a in sorted(targets)) + '\n')
    code.append('#include "EvidenceDeclarations.h"')
    mappings = []
    for row in selected:
        a = row['address']; source = index[a]
        code.extend(['', f'/* {row["module"]}; {row["ownership"]}; RVA {a:#x}',
                     ' * ' + '; '.join(e['reason'] + ': ' + e['detail'].replace('*/', '* /').replace('\n', ' ') for e in row['evidence'])[:4000],
                     f' * Pseudocode: {analysis / source["pseudocode"]}:{source["pseudocode_line"]}', ' */'])
        line = len(code) + 1
        code.append(f'void rva_{a:X}(void) {{')
        for edge in calls[a]:
            code.append(f'    rva_{edge["to"]:X}(); /* {edge["kind"]} at {edge["at"]:#x}; {edge["target_scope"]} */')
        code.append('}')
        mappings.append({**row, 'symbol': f'rva_{a:X}', 'projection_line': line,
                         'pseudocode': str(analysis / source['pseudocode']), 'pseudocode_line': int(source['pseudocode_line']),
                         'assembly': str(analysis / source['assembly']), 'assembly_line': int(source['assembly_line']),
                         'direct_edges': calls[a]})
    path = output / 'EvidenceNavigation.c'
    path.write_text('\n'.join(code) + '\n')
    clang = subprocess.check_output(['xcrun', '--find', 'clang'], text=True).strip()
    (output / 'compile_commands.json').write_text(json.dumps([{'directory': str(output), 'file': str(path), 'arguments': [clang, '-x', 'c', '-fsyntax-only', str(path)]}], indent=2))
    report = {'kind': 'binary-direct-call-navigation-only', 'selected_functions': len(selected),
              'candidate_functions': len(candidates), 'selection_truncated': len(selected) < len(candidates),
              'source_analysis': str(analysis), 'functions': mappings}
    (output / 'mapping.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    (output / 'README.md').write_text('这是二进制直接调用证据的导航投影，不能执行或链接进 App。\n\n'
        'Serena/clangd 可以查询这些合法 C 符号与引用；它们不恢复 Swift 签名、控制流或间接调用。'
        'mapping.json 将每个符号映射回原始伪代码、汇编行和归属证据。\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'functions'}, ensure_ascii=False))


if __name__ == '__main__':
    main()
