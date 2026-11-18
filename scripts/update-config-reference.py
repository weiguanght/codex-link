#!/usr/bin/env python3
"""Project the Codex TOML schema into a browsable index of keys and value types."""
import argparse
import json
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def index(schema):
    definitions = schema.get('definitions', {})
    entries = defaultdict(lambda: (set(), set()))

    def visit(path, node, refs=frozenset()):
        types, choices = entries[path]
        kind = node.get('type', [])
        types.update([kind] if isinstance(kind, str) else kind)
        choices.update(value for value in node.get('enum', []) if isinstance(value, str))
        ref = node.get('$ref', '').removeprefix('#/definitions/')
        if ref in definitions and ref not in refs:
            visit(path, definitions[ref], refs | {ref})
        for variant in ('allOf', 'anyOf', 'oneOf'):
            for child in node.get(variant, []):
                visit(path, child, refs)
        for name, child in node.get('properties', {}).items():
            visit(f'{path}.{name}', child, refs)
        extra = node.get('additionalProperties')
        if isinstance(extra, dict) or extra is True:
            visit(f'{path}.*', extra if isinstance(extra, dict) else {}, refs)
        items = node.get('items')
        if isinstance(items, dict):
            visit(f'{path}[]', items, refs)

    for name, node in schema['properties'].items():
        visit(name, node)
    return [
        {'key': key, 'types': sorted(types - {'null'}), **({'choices': sorted(choices)} if choices else {})}
        for key, (types, choices) in sorted(entries.items())
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('schema', type=Path)
    parser.add_argument('--version', required=True, help='Version of the input Codex source snapshot')
    args = parser.parse_args()
    schema = json.loads(args.schema.read_text(encoding='utf-8'))
    output = ROOT / 'mac' / 'config_reference.json'
    lines = [json.dumps(row, ensure_ascii=False, separators=(',', ':')) for row in index(schema)]
    header = json.dumps({'version': args.version, 'topLevelCount': len(schema['properties'])}, ensure_ascii=False)
    output.write_text(header[:-1] + ', "entries": [\n' + ',\n'.join(lines) + '\n]}\n', encoding='utf-8')
    print(f'{len(schema["properties"])} top-level settings, {len(lines)} indexed paths')


if __name__ == '__main__':
    main()
