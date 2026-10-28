"""Mirror health must represent fresh, complete, verified recovery sets."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'offsite' / 'rupert-backup-mirror.sh'

class MirrorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.out = root / 'out'
        self.out.mkdir()
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        self.bin_dir = bin_dir
        for name, body in [('ssh', 'cat >/dev/null; exit 0'), ('rsync', 'exit 0')]:
            executable = bin_dir / name
            executable.write_text('#!/bin/sh\n' + body + '\n')
            executable.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', OUT=str(self.out), MIN_FREE_MB='1')

    def file(self, name, old=False):
        path = self.out / name
        path.write_bytes(b'age-encryption.org/v1\nencrypted test')
        (self.out / (name + '.sha256')).write_text(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + name + '\n')
        if old:
            os.utime(path, (time.time() - 48 * 3600,) * 2)
        return path

    def age_set(self, old=False):
        name = 'rupert-20261025-1200.sqlite3.gz.age'
        db = self.file(name, old=old)
        side = self.file('settings-20261025-1200.sql.age')
        for file in (db, side):
            Path(str(file) + '.key').write_text('fingerprint test\nrecipient age1' + 'q' * 58 + '\n')
        return side

    def run_mirror(self):
        return subprocess.run(['bash', str(SCRIPT)], env=self.env, text=True, capture_output=True)

    def test_age_only_set_is_valid(self):
        self.age_set()
        result = self.run_mirror()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('mirror ok: 1 sets', result.stdout)

    def test_rejects_stale_and_incomplete_sets(self):
        self.age_set(old=True)
        result = self.run_mirror()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('old', result.stderr)
        for f in self.out.iterdir(): f.unlink()
        side = self.age_set()
        side.unlink()
        result = self.run_mirror()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('settings', result.stderr)

    def test_rejects_mismatched_keys(self):
        side = self.age_set()
        Path(str(side) + '.key').write_text('fingerprint other\nrecipient age1' + 'p' * 58 + '\n')
        result = self.run_mirror()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('mismatched', result.stderr)

    def test_rejects_future_timestamp(self):
        self.age_set()
        db = next(self.out.glob('rupert-*.sqlite3.gz.age'))
        os.utime(db, (time.time() + 3600,) * 2)
        result = self.run_mirror()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('future timestamp', result.stderr)

    def test_refuses_transfer_that_would_consume_reserve(self):
        df = self.bin_dir / 'df'
        df.write_text('#!/bin/sh\nprintf "Avail\\n10485760\\n"\n')
        df.chmod(0o755)
        rsync = self.bin_dir / 'rsync'
        rsync.write_text('#!/bin/sh\ncase "$*" in *--dry-run*) echo 9437184 ;; *) echo unexpected-transfer >&2; exit 1 ;; esac\n')
        rsync.chmod(0o755)
        self.env['MIN_FREE_MB'] = '5'
        result = self.run_mirror()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('reserved space', result.stderr)
        self.assertNotIn('unexpected-transfer', result.stderr)

    @unittest.skipUnless(shutil.which('rsync'), 'rsync is not installed')
    def test_real_rsync_copies_complete_set_but_not_plaintext(self):
        self.age_set()
        source = self.out.parent / 'source'
        self.out.rename(source)
        self.out.mkdir()
        (source / 'plaintext-secret.txt').write_text('private')
        (self.bin_dir / 'rsync').unlink()
        ssh = self.bin_dir / 'ssh'
        ssh.write_text('''#!/bin/sh
while [ "$1" = -o ]; do shift 2; done
shift
case "$1" in
  true) exit 0 ;;
  rsync) exec "$@" ;;
  *) cat >/dev/null; exit 0 ;;
esac
''')
        ssh.chmod(0o755)
        self.env['SOURCE_DIR'] = str(source)
        result = self.run_mirror()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(6, len(list(self.out.iterdir())))
        self.assertFalse((self.out / 'plaintext-secret.txt').exists())
