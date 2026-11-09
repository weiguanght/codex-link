"""OpenAI API reference estimates from a dated, refreshable public price snapshot."""
from functools import lru_cache
import json
from pathlib import Path
import re

CATALOG = Path(__file__).with_name('data') / 'model-pricing.json'
TOKEN_FIELDS = ('input_tokens', 'cached_input_tokens', 'cache_write_input_tokens', 'output_tokens',
                'reasoning_output_tokens', 'total_tokens')


def token_counts(value):
    result = {}
    for key in TOKEN_FIELDS:
        number = value.get(key, 0)
        result[key] = max(0, min(number, 10**15)) if isinstance(number, int) and not isinstance(number, bool) else 0
    return result


@lru_cache(maxsize=1)
def _catalog(path, stamp):
    return json.loads(Path(path).read_text())


def price_estimate(parts, fallback_model=None):
    try:
        stat = CATALOG.stat()
        catalog = _catalog(str(CATALOG), (stat.st_mtime_ns, stat.st_size))
    except (OSError, ValueError):
        return {'estimatedCostUSD': None, 'costCurrency': 'USD'}
    result = {'estimatedCostUSD': None, 'costCurrency': 'USD',
              'pricingSource': catalog['source'], 'pricingCheckedOn': catalog['checkedOn'],
              'pricingBasis': 'OpenAI API reference', 'pricingTiers': [], 'pricingBreakdown': []}
    estimate = 0
    complete = True
    for part in parts:
        model = part.get('model') or fallback_model or ''
        # Only exact public IDs and dated snapshots qualify. A "-pro" or
        # "-codex" suffix must never accidentally inherit a cheaper base rate.
        pricing_model = model if model in catalog['models'] else re.sub(r'-\d{4}-\d{2}-\d{2}$', '', model)
        tier = part.get('serviceTier') or 'standard'
        rates = catalog['models'].get(pricing_model, {}).get(tier)
        counts = token_counts(part)
        cached = min(counts['cached_input_tokens'], counts['input_tokens'])
        cost = None
        missing_split = counts['total_tokens'] > 0 and counts['input_tokens'] + counts['output_tokens'] == 0
        if rates and not missing_split and (not cached or rates['cachedInput'] is not None) and not counts['cache_write_input_tokens']:
            cost = ((counts['input_tokens'] - cached) * rates['input']
                    + cached * (rates['cachedInput'] or 0)
                    + counts['output_tokens'] * rates['output']) / 1_000_000
            estimate += cost
        else:
            complete = False
        result['pricingBreakdown'].append(dict(counts, model=model, serviceTier=tier,
                                              estimatedCostUSD=round(cost, 6) if cost is not None else None))
        if tier not in result['pricingTiers']:
            result['pricingTiers'].append(tier)
    if complete:
        result['estimatedCostUSD'] = round(estimate, 6)
    return result


def service_tier(value):
    if not isinstance(value, str):
        return 'standard'
    return {'default': 'standard', 'auto': 'standard', 'priority': 'fast'}.get(value, value or 'standard')
