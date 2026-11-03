"""Tests for deploy/ser8/rupert-release-audit: backup freshness, company facts, and no values in the report."""
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'rupert-release-audit'
NOW = dt.datetime(2026, 11, 2, 18, 0, tzinfo=dt.timezone.utc)


class RuntimeAuditTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        (self.tmp / 'app/web/storage/backups').mkdir(parents=True)
        self.env_file = self.tmp / 'rupert.env'
        os.environ['RUPERT_AUTODEPLOY_APP'] = str(self.tmp / 'app')
        os.environ['RUPERT_ENV_FILE'] = str(self.env_file)
        self.addCleanup(os.environ.pop, 'RUPERT_AUTODEPLOY_APP', None)
        self.addCleanup(os.environ.pop, 'RUPERT_ENV_FILE', None)
        self.audit = SourceFileLoader('rupert_release_audit', str(SCRIPT)).load_module()

    def backup(self, layer, state='ok', hours=1, encrypted=True, message=''):
        at = (NOW - dt.timedelta(hours=hours)).strftime('%Y-%m-%dT%H:%M:%SZ')
        (self.tmp / f'app/web/storage/backups/{layer}.json').write_text(json.dumps(
            {'layer': layer, 'state': state, 'at': at, 'encrypted': encrypted, 'message': message}))

    def test_fresh_encrypted_backups_pass(self):
        self.backup('local', hours=5)
        self.backup('frequent', hours=0.1)
        self.assertTrue(all(ok for _, ok, _ in self.audit.check_backups(NOW)))

    def test_stale_failed_unencrypted_or_missing_backups_fail(self):
        self.backup('local', hours=27)
        self.backup('frequent', state='failed', message='refused: no active backup key')
        results = dict((name, (ok, detail)) for name, ok, detail in self.audit.check_backups(NOW))
        self.assertFalse(results['backup:local'][0])
        self.assertFalse(results['backup:frequent'][0])
        self.assertIn('Settings -> Backups', results['backup:frequent'][1])
        self.backup('local', encrypted=False)
        self.assertFalse(dict((n, ok) for n, ok, _ in self.audit.check_backups(NOW))['backup:local'])
        (self.tmp / 'app/web/storage/backups/local.json').unlink()
        self.assertIn('no report', dict((n, d) for n, _, d in self.audit.check_backups(NOW))['backup:local'])

    def test_company_facts_must_be_set_and_not_placeholders_and_values_are_never_reported(self):
        self.env_file.write_text('RUPERT_LEGAL_NAME="Secret Legal Name LLC"\nRUPERT_BUSINESS_ADDRESS=[Owner to add: address]\n'
                                 'export RUPERT_SUPPORT_PHONE=555-0100\nSECRET_KEY_BASE=do-not-leak\n')
        results = {name: (ok, detail) for name, ok, detail in self.audit.check_company()}
        self.assertEqual(results['company:RUPERT_LEGAL_NAME'], (True, 'set'))
        self.assertEqual(results['company:RUPERT_BUSINESS_ADDRESS'], (False, 'placeholder'))
        self.assertEqual(results['company:RUPERT_SUPPORT_PHONE'], (True, 'set'))
        self.assertEqual(results['company:RUPERT_SECURITY_EMAIL'], (False, 'missing'))
        out = subprocess.run([sys.executable, str(SCRIPT), '--skip', 'backups,health,tls,dmarc', '--sha', 'abc'],
                             capture_output=True, text=True, env=os.environ.copy())
        self.assertEqual(out.returncode, 1)
        for secret in ('Secret Legal Name', '555-0100', 'do-not-leak', 'Owner to add'):
            self.assertNotIn(secret, out.stdout + out.stderr)
        self.assertIn('Result: **FAIL**', out.stdout)

    def test_unreadable_env_file_fails(self):
        self.assertFalse(self.audit.check_company()[0][1])


if __name__ == '__main__':
    unittest.main()
