"""Receipt gating tests using fake age; real cryptography has its own tests."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[3] / 'bin' / 'backup-decrypt'

class RestoreReceiptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.root = root
        bindir = root / 'bin'
        bindir.mkdir()
        age = bindir / 'age'
        age.write_text('''#!/usr/bin/env python3
import pathlib, sys
sys.stdout.buffer.write(pathlib.Path(sys.argv[-1]).read_bytes().split(b'\\n', 1)[1])
''')
        age.chmod(0o755)
        keygen = bindir / 'age-keygen'
        keygen.write_text('#!/bin/sh\necho age1' + 'q' * 58 + '\n')
        keygen.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{bindir}:{os.environ["PATH"]}')
        self.key = root / 'identity'
        self.key.write_text('AGE-SECRET-KEY-1TESTKEY\n')
        self.key.chmod(0o600)
        db = root / 'source.sqlite3'
        conn = sqlite3.connect(db)
        try:
            conn.execute('CREATE TABLE test(id INTEGER PRIMARY KEY)')
            conn.commit()
        finally:
            conn.close()
        self.backup = root / 'rupert-20261027-120000.sqlite3.gz.age'
        self.backup.write_bytes(b'age-encryption.org/v1\n' + gzip.compress(db.read_bytes()))
        self.write_sidecars()

    def write_sidecars(self):
        digest = hashlib.sha256(self.backup.read_bytes()).hexdigest()
        Path(str(self.backup) + '.sha256').write_text(f'{digest}  {self.backup.name}\n')
        Path(str(self.backup) + '.key').write_text('recipient age1' + 'q' * 58 + '\n')

    def run_decrypt(self):
        return subprocess.run(['bash', str(SCRIPT), '--identity-file', str(self.key), '--out', str(self.root / 'restored.sqlite3'),
                               '--receipt', str(self.root / 'restore.json'), str(self.backup)], env=self.env, capture_output=True, text=True)

    def test_receipt_follows_validated_database_recovery(self):
        result = self.run_decrypt()
        self.assertEqual(0, result.returncode, result.stderr)
        receipt = json.loads((self.root / 'restore.json').read_text())
        self.assertEqual(('restore', 'ok', True), (receipt['layer'], receipt['state'], receipt['encrypted']))
        self.assertNotIn('SECRET', json.dumps(receipt))
        self.assertEqual(0o600, (self.root / 'restore.json').stat().st_mode & 0o777)

    def test_receipt_not_written_for_invalid_database(self):
        self.backup.write_bytes(b'age-encryption.org/v1\n' + gzip.compress(b'not sqlite'))
        self.write_sidecars()
        result = self.run_decrypt()
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((self.root / 'restore.json').exists())
        self.assertFalse((self.root / 'restored.sqlite3').exists())

    def test_receipt_requires_recorded_checksum_and_key(self):
        Path(str(self.backup) + '.key').unlink()
        result = self.run_decrypt()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('requires both checksum and key metadata', result.stderr)
        self.assertFalse((self.root / 'restore.json').exists())
        self.assertFalse((self.root / 'restored.sqlite3').exists())
