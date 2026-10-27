"""Exercise backup publication and failure handling without crypto dependencies.

The fake age tool is deliberately not cryptographic; real encryption is covered
by test_encrypted_backups.py when the age binaries are available.
"""
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from deploy.ser8.tests.test_encrypted_backups import SQLITE_STUB

SCRIPT = Path(__file__).resolve().parents[3] / 'bin' / 'backup.sh'

class BackupPublicationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        bindir = root / 'bin'
        bindir.mkdir()
        for name, contents in {
            'sqlite3': SQLITE_STUB,
            'age': '''#!/usr/bin/env python3
import os, pathlib, sys
name = sys.argv[sys.argv.index('-o') + 1]
if os.environ.get('FAIL_SETTINGS') == '1' and 'settings-' in name:
    sys.exit(1)
pathlib.Path(name).write_bytes(b'age-encryption.org/v1\\n' + sys.stdin.buffer.read())
''',
        }.items():
            path = bindir / name
            path.write_text(contents)
            path.chmod(0o755)
        self.db = root / 'db.sqlite3'
        conn = sqlite3.connect(self.db)
        try:
            conn.executescript("CREATE TABLE backup_encryption_keys(recipient, activated_at, retired_at, id);"
                "INSERT INTO backup_encryption_keys VALUES('age1" + 'q' * 58 + "', '2026-01-01', NULL, 1);"
                "CREATE TABLE settings(key, value); INSERT INTO settings VALUES('key', 'value');")
            conn.commit()
        finally:
            conn.close()
        self.env_file = root / 'env'
        self.env_file.write_text(f'RUPERT_SQLITE_DATABASE_PRODUCTION={self.db}\n')
        self.out = root / 'out'
        self.env = dict(os.environ, PATH=f'{bindir}:{os.environ["PATH"]}', ENV_FILE=str(self.env_file),
                        OUT=str(self.out), STATUS_DIR=str(root / 'status'), SCRATCH=str(root), MIN_FREE_MB='1')

    def run_backup(self, **extra):
        return subprocess.run(['bash', str(SCRIPT)], env={**self.env, **extra}, capture_output=True, text=True)

    def test_settings_failure_does_not_publish_a_database(self):
        result = self.run_backup(FAIL_SETTINGS='1')
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], list(self.out.glob('rupert-*.sqlite3.gz.age')))
        self.assertEqual([], list(self.out.glob('*.partial')))

    def test_complete_set_has_all_sidecars(self):
        result = self.run_backup()
        self.assertEqual(0, result.returncode, result.stderr)
        dbs = list(self.out.glob('rupert-*.sqlite3.gz.age'))
        self.assertEqual(1, len(dbs))
        stamp = dbs[0].name.removeprefix('rupert-').removesuffix('.sqlite3.gz.age')
        for name in (dbs[0].name, f'settings-{stamp}.sql.age', f'env-{stamp}.age'):
            for suffix in ('', '.key', '.sha256'):
                self.assertTrue((self.out / (name + suffix)).is_file(), name + suffix)

    def test_overlapping_runs_produce_distinct_complete_sets(self):
        first = subprocess.Popen(['bash', str(SCRIPT)], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        second = subprocess.Popen(['bash', str(SCRIPT)], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        for process in (first, second):
            _stdout, stderr = process.communicate(timeout=15)
            self.assertEqual(0, process.returncode, stderr)
        databases = list(self.out.glob('rupert-*.sqlite3.gz.age'))
        self.assertEqual(2, len(databases))
        for database in databases:
            stamp = database.name.removeprefix('rupert-').removesuffix('.sqlite3.gz.age')
            self.assertTrue((self.out / f'settings-{stamp}.sql.age').exists())
            self.assertTrue((self.out / f'env-{stamp}.age').exists())
