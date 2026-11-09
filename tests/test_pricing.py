"""Synthetic price calculations; no network calls or real conversation data."""
import importlib.util
from pathlib import Path
import unittest

from mac.pricing import price_estimate


class PricingTests(unittest.TestCase):
    def part(self, model, tier='standard', **counts):
        return dict(model=model, serviceTier=tier, **counts)

    def test_public_rates_cache_and_reasoning_not_charged_twice(self):
        part = self.part('gpt-6.1-sol', input_tokens=1000, cached_input_tokens=400,
                         output_tokens=100, reasoning_output_tokens=80, total_tokens=1100)
        result = price_estimate([part])
        self.assertAlmostEqual(result['estimatedCostUSD'], 0.00224)
        self.assertIn('developers.openai.com', result['pricingSource'])
        self.assertEqual(price_estimate([dict(part, serviceTier='fast')])['estimatedCostUSD'], 0.00448)

    def test_unknown_variants_and_missing_tiers_do_not_inherit_base_price(self):
        self.assertIsNone(price_estimate([self.part('gpt-5.4-imaginary', input_tokens=1000)])['estimatedCostUSD'])
        self.assertIsNone(price_estimate([self.part('gpt-5.4-pro', 'fast', input_tokens=1000)])['estimatedCostUSD'])
        self.assertEqual(price_estimate([self.part('gpt-5.4-pro', input_tokens=1000)])['estimatedCostUSD'], 0.03)
        self.assertEqual(price_estimate([self.part('gpt-5.4-2026-03-05', input_tokens=1000)])['estimatedCostUSD'], 0.0025)

    def test_partial_prices_and_cache_write_retention_are_not_presented_as_total(self):
        result = price_estimate([self.part('gpt-5.4', input_tokens=1000),
                                 self.part('unknown-model', input_tokens=1000)])
        self.assertIsNone(result['estimatedCostUSD'])
        self.assertEqual(result['pricingBreakdown'][0]['estimatedCostUSD'], 0.0025)
        self.assertIsNone(result['pricingBreakdown'][1]['estimatedCostUSD'])
        self.assertIsNone(price_estimate([self.part('gpt-6.1-sol', input_tokens=1000,
                                                  cache_write_input_tokens=100)])['estimatedCostUSD'])
        self.assertIsNone(price_estimate([self.part('gpt-5.4', total_tokens=1000)])['estimatedCostUSD'])

    def test_parser_handles_both_tables_and_preserves_service_tiers(self):
        path = Path(__file__).resolve().parents[1] / 'scripts/update-pricing.py'
        spec = importlib.util.spec_from_file_location('update_pricing', path)
        script = importlib.util.module_from_spec(spec); spec.loader.exec_module(script)
        text = '''## Flagship models
Standard
| Model | Input | Output | Cached input | 30m write | 12h write |
| --- | --- | --- | --- | --- | --- |
| gpt-6.1-sol | $2.00 | $10.00 | $0.10 | $2.50 | $5.00 |
| gpt-5.4 | $2.50 | $15.00 | $0.25 | - | - |
Fast
| Model | Input | Output | Cached input |
| --- | --- | --- | --- |
| gpt-6.1-sol | $4.00 | $20.00 | $0.20 |
## Specialized models
Standard
| Category | Model | Input | Output | Cached input |
| --- | --- | --- | --- | --- |
| Codex | gpt-5.3-codex | $1.75 | $14.00 | $0.175 |
'''
        models = script.parse_prices(text)
        self.assertEqual(models['gpt-6.1-sol']['fast']['input'], 4)
        self.assertEqual(models['gpt-5.3-codex']['standard']['cachedInput'], 0.175)
        with self.assertRaises(ValueError):
            script.parse_prices('Temporarily unavailable')


if __name__ == '__main__':
    unittest.main()
