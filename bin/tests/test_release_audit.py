"""Tests for bin/release-audit (docs/ops/release-audit.md). All card numbers are public test cards."""
import json
import os
import subprocess
import sys
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'release-audit'
audit = SourceFileLoader('release_audit', str(SCRIPT)).load_module()
# A Luhn-valid Visa number that is not a published test card, split so the repo scan never sees it whole.
NOT_A_TEST_CARD = '4532' + '0151' + '1283' + '0366'


class CardDataTest(unittest.TestCase):
    def test_finds_card_numbers_plain_and_grouped(self):
        for line in ['card 4111111111111111 ok', 'card 4111 1111 1111 1111', 'card 4111-1111-1111-1111',
                     'amex 3782 822463 10005', 'mc 5555555555554444.', 'visa ' + NOT_A_TEST_CARD]:
            self.assertTrue(audit.pans_in_line(line), line)

    def test_ignores_ids_dates_versions_and_non_luhn_numbers(self):
        for line in ['migration `20261017235700_create_receipts`', '%w[2026-07-23 2026-07-24 2026-07-25 2026-07-26]',
                     'https://help.example.com/articles/27117544574487-Export', "id: '11111111-2222-3333-4444-555555555555'",
                     "'M8 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8Z'", 'order 4111111111111112', 'tracking 9400111899223333444455',
                     'gtin 00012345678905']:
            self.assertEqual(audit.pans_in_line(line), [], line)

    def test_test_cards_are_known(self):
        self.assertIn('4111111111111111', audit.TEST_CARDS)
        self.assertNotIn(NOT_A_TEST_CARD, audit.TEST_CARDS)


class PrivacyTest(unittest.TestCase):
    def denylist(self, *names):
        result = subprocess.run([sys.executable, str(SCRIPT), 'privacy-hash'], input='\n'.join(names), capture_output=True,
                                text=True, check=True, env={**os.environ, 'RUPERT_PRIVACY_KEY': '00' * 32})
        for name in names:
            self.assertNotIn(name, result.stdout)
            self.assertNotIn(name, result.stderr)
        data = json.loads(result.stdout)
        return bytes.fromhex(data['key']), data['max_tokens'], set(data['hashes'])

    def test_names_match_regardless_of_case_accents_spacing_and_punctuation(self):
        key, max_tokens, hashes = self.denylist('Acme Café Supply', 'Zed')
        for line in ['Sold to ACME CAFE SUPPLY last week', 'host acmecafesupply.example.com', 'acme-café-supply', 'zed.']:
            self.assertTrue(audit.line_hits(line, key, max_tokens, hashes), line)
        for line in ['Acme sells coffee', 'cafe supply', 'zedd and zebra']:
            self.assertFalse(audit.line_hits(line, key, max_tokens, hashes), line)

    def test_a_different_key_matches_nothing(self):
        _, max_tokens, hashes = self.denylist('Acme')
        self.assertFalse(audit.line_hits('Acme', b'\x01' * 32, max_tokens, hashes))

    def test_invalid_denylist_is_a_finding(self):
        result = audit.Audit()
        os.environ['RUPERT_PRIVACY_DENYLIST'] = 'not json'
        try:
            self.assertIsNone(audit.load_denylist(result))
        finally:
            del os.environ['RUPERT_PRIVACY_DENYLIST']
        self.assertEqual(result.findings[0].rule, 'privacy')


class ClaimsTest(unittest.TestCase):
    def claim(self, line):
        hits = []
        for name, (pattern, _) in audit.CLAIMS.items():
            for match in pattern.finditer(line):
                if not audit.NEGATION.search(line):
                    hits.append(name)
        return hits

    def test_affirmative_claims_are_found(self):
        self.assertEqual(self.claim('Rupert is PCI certified.'), ['pci'])
        self.assertEqual(self.claim('We are SOC 2 Type II audited.'), ['soc2'])
        self.assertEqual(self.claim('Rupert is pen-tested every year.'), ['pentest'])

    def test_negated_and_planned_wording_is_allowed(self):
        for line in ['Rupert has no SOC 2 report or ISO 27001 certificate.', 'Rupert is not PCI certified.',
                     'No external penetration test has been performed.', 'A SOC 2 audit is planned.']:
            self.assertEqual(self.claim(line), [], line)


class RepositoryTest(unittest.TestCase):
    def test_the_repository_passes_with_its_baseline(self):
        result = subprocess.run([sys.executable, str(SCRIPT), '--baseline', str(SCRIPT.parents[1] / '.github/release-audit-baseline.json')],
                                capture_output=True, text=True, env={k: v for k, v in os.environ.items() if not k.startswith('RUPERT_PRIVACY')})
        self.assertEqual(result.returncode, 0, result.stdout[-3000:])
        self.assertIn('Result: **PASS**', result.stdout)


if __name__ == '__main__':
    unittest.main()
