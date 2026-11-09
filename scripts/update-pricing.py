#!/usr/bin/env python3
"""Refresh the public text/Codex API price snapshot; no user credentials needed."""
import argparse
from datetime import datetime
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

SOURCE = 'https://developers.openai.com/api/docs/pricing?latest-pricing-expanded=true'
FETCH = 'https://r.jina.ai/' + SOURCE
OUTPUT = Path(__file__).resolve().parents[1] / 'mac/data/model-pricing.json'


def parse_prices(text):
    models = {}
    section = tier = None
    columns = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('## '):
            section = line[3:]
            tier = None
        if section not in ('Flagship models', 'Specialized models'):
            continue
        if line in ('Standard', 'Fast', 'Batch', 'Flex', 'Ultrafast'):
            tier = line.lower()
        if not line.startswith('|'):
            continue
        cells = [cell.strip() for cell in line.strip('|').split('|')]
        if 'Model' in cells and 'Input' in cells and 'Output' in cells:
            columns = cells
            continue
        if not tier or len(cells) != len(columns) or not columns:
            continue
        row = dict(zip(columns, cells))
        model = row.get('Model', '')
        if not re.fullmatch(r'(?:gpt-|o\d|chat-)[a-z0-9.\-]*', model):
            continue
        def price(key):
            raw = row[key]
            if raw == '-':
                return None
            if not re.fullmatch(r'\$\d+(?:\.\d+)?', raw):
                raise ValueError('Unrecognized price for ' + model)
            return float(Decimal(raw[1:]))
        rates = {'input': price('Input'), 'output': price('Output'), 'cachedInput': price('Cached input')}
        if rates['input'] is None or rates['output'] is None:
            raise ValueError('Missing price for ' + model)
        models.setdefault(model, {})[tier] = rates
    if not all(model in models for model in ('gpt-5.4', 'gpt-5.3-codex', 'gpt-6.1-sol')):
        raise ValueError('Pricing page is incomplete; existing snapshot was preserved')
    return models


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-file', type=Path, help='Use a saved Jina Markdown response')
    parser.add_argument('--output', type=Path, default=OUTPUT)
    args = parser.parse_args()
    if args.source_file:
        text = args.source_file.read_text()
    else:
        with urlopen(Request(FETCH, headers={'User-Agent': 'codex-link-pricing'}), timeout=45) as response:
            text = response.read(2 * 1024 * 1024).decode('utf-8')
    data = {'source': SOURCE, 'fetchSource': FETCH,
            'checkedOn': datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat(),
            'sourceSHA256': hashlib.sha256(text.encode()).hexdigest(),
            'unit': 'USD per 1M tokens', 'contextPricing': 'Published short-context table',
            'models': parse_prices(text)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(args.output)
    print('Updated', len(data['models']), 'models:', args.output)


if __name__ == '__main__':
    main()
