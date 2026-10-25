"""Encrypted backups (#421): bin/backup.sh, the frequent snapshot, the host pull, the weekly check and bin/backup-decrypt.

The real `age` CLI does the cryptography (tests skip without it: apt-get install age). sqlite3 and incus are
stand-ins: sqlite3 is a small Python CLI over the sqlite3 module (the SER8 host has no sqlite3 CLI), and incus maps
`incus exec rupert -- …` onto a fake container directory.
"""
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[3]
BACKUP = REPO / 'bin' / 'backup.sh'
DECRYPT = REPO / 'bin' / 'backup-decrypt'
FREQUENT = REPO / 'deploy' / 'ser8' / 'rupert-backup-frequent.sh'
PULL = REPO / 'deploy' / 'ser8' / 'rupert-host-backup-pull.sh'
VERIFY = REPO / 'deploy' / 'ser8' / 'rupert-backup-verify.sh'
HAVE_AGE = bool(shutil.which('age') and shutil.which('age-keygen'))

SQLITE_STUB = r'''#!/usr/bin/env python3
import sqlite3, sys
args = [a for a in sys.argv[1:] if a != '-readonly']
readonly = '-readonly' in sys.argv
db = sqlite3.connect(f"file:{args[0]}?mode=ro" if readonly else args[0], uri=readonly, isolation_level=None)
insert_table = None
for sql in args[1:]:
    if sql.startswith('.mode insert'):
        insert_table = sql.split()[2]
        continue
    try:
        rows = db.execute(sql).fetchall()
    except sqlite3.Error as e:
        sys.stderr.write(f"Error: {e}\n"); sys.exit(1)
    for row in rows:
        if insert_table:
            vals = ','.join('NULL' if v is None else str(v) if isinstance(v, (int, float)) else "'" + str(v).replace("'", "''") + "'" for v in row)
            print(f"INSERT INTO {insert_table} VALUES({vals});")
        else:
            print('|'.join('' if v is None else str(v) for v in row))
'''

INCUS_STUB = r'''#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write('incus ' + ' '.join(args) + '\n')
root = os.environ['FAKE_ROOT']
if args[0] == 'exec':
    cmd = [a.replace('/var/backups/rupert', root + '/var/backups/rupert') for a in args[args.index('--') + 1:]]
    if cmd[:2] == ['systemctl', 'start']:
        if os.environ.get('BACKUP_EXIT', '0') != '0':
            sys.exit(int(os.environ['BACKUP_EXIT']))
        hook = os.environ.get('ON_BACKUP')
        sys.exit(subprocess.call(['bash', '-c', hook]) if hook else 0)
    os.execvp(cmd[0], cmd)
if args[:2] == ['file', 'push']:
    name = os.path.basename(args[-1])
    with open(os.path.join(os.environ['STATUS_OUT'], name), 'wb') as f:
        f.write(sys.stdin.buffer.read())
'''


def write_exec(path, body):
    path.write_text(body)
    path.chmod(0o755)


@unittest.skipUnless(HAVE_AGE, 'age is not installed (apt-get install age)')
class EncryptedBackupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.bin = self.tmp / 'bin'
        self.bin.mkdir()
        write_exec(self.bin / 'sqlite3', SQLITE_STUB)
        write_exec(self.bin / 'incus', INCUS_STUB)
        self.db = self.tmp / 'production.sqlite3'
        con = sqlite3.connect(self.db)
        con.executescript('''
          CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, tenant_id TEXT, updated_at TEXT, value TEXT);
          INSERT INTO settings (key, value) VALUES ('business_name', 'Test Co'), ('quote', 'it''s');
          CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT);
          INSERT INTO users (email) VALUES ('owner@example.com');
          CREATE TABLE backup_encryption_keys (id INTEGER PRIMARY KEY, recipient TEXT NOT NULL, fingerprint TEXT,
            confirmation_digest TEXT, created_by_id INTEGER, activated_by_id INTEGER, activated_at TEXT, retired_at TEXT,
            created_at TEXT, updated_at TEXT);
        ''')
        con.commit()
        con.close()
        self.identity, self.recipient = self.new_key()
        self.key_file = self.tmp / 'kit.key'
        self.key_file.write_text(self.identity + '\n')
        self.key_file.chmod(0o600)
        self.env_file = self.tmp / 'rupert.env'
        self.env_file.write_text(f'RAILS_ENCRYPTION_PRIMARY_KEY=primary-secret\nRUPERT_SQLITE_DATABASE_PRODUCTION={self.db}\n')
        self.container = self.tmp / 'container'
        self.local = self.container / 'var' / 'backups' / 'rupert'
        self.status = self.tmp / 'status'
        self.status.mkdir()
        self.scratch = self.tmp / 'scratch'
        self.scratch.mkdir()
        self.host_out = self.tmp / 'host'
        self.calls = self.tmp / 'calls'
        self.calls.touch()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    # helpers -----------------------------------------------------------------------------------------------------
    def new_key(self):
        out = subprocess.run(['age-keygen'], capture_output=True, text=True, check=True).stdout
        identity = next(line for line in out.splitlines() if line.startswith('AGE-SECRET-KEY-1'))
        recipient = next(line.split(': ')[1] for line in out.splitlines() if line.startswith('# public key'))
        return identity, recipient

    def activate(self, recipient, retired=False):
        con = sqlite3.connect(self.db)
        con.execute('INSERT INTO backup_encryption_keys (recipient, activated_at, retired_at) VALUES (?, ?, ?)',
                    (recipient, '2026-10-25 12:00:00', '2026-10-25 13:00:00' if retired else None))
        con.commit()
        con.close()

    def env(self, **extra):
        env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}', ENV_FILE=str(self.env_file),
                   STATUS_DIR=str(self.status), MIN_FREE_MB='1', SCRATCH=str(self.scratch), CALLS=str(self.calls),
                   FAKE_ROOT=str(self.container), STATUS_OUT=str(self.status), HOME=str(self.tmp))
        env.update({k: str(v) for k, v in extra.items()})
        return env

    def run_backup(self, **extra):
        return subprocess.run(['bash', str(BACKUP)], env=self.env(OUT=self.local, **extra), capture_output=True, text=True)

    def run_pull(self, **extra):
        hook = f'OUT={self.local} STATUS_DIR={self.status} bash {BACKUP}'
        env = self.env(OUT=self.host_out, ON_BACKUP=hook, **extra)
        return subprocess.run(['bash', str(PULL)], env=env, capture_output=True, text=True)

    def decrypt(self, path, *args, stdin=None, out=None):
        out = out or (self.tmp / f'restored-{time.time_ns()}')
        cmd = ['bash', str(DECRYPT), *args, '--out', str(out), str(path)]
        return subprocess.run(cmd, env=self.env(), capture_output=True, text=True, input=stdin), out

    def status_of(self, layer):
        return json.loads((self.status / f'{layer}.json').read_text())

    def only(self, directory, pattern):
        found = sorted(directory.glob(pattern))
        self.assertEqual(1, len(found), found)
        return found[0]

    def age_decrypt(self, path):
        return subprocess.run(['age', '-d', '-i', str(self.key_file), str(path)], capture_output=True, check=True).stdout

    # bin/backup.sh -----------------------------------------------------------------------------------------------
    def test_backup_writes_only_age_files_with_digest_and_key_sidecars(self):
        self.activate(self.recipient)
        r = self.run_backup()
        self.assertEqual(0, r.returncode, r.stderr)
        files = sorted(p.name for p in self.local.iterdir() if p.is_file())
        self.assertTrue(files)
        for name in files:
            self.assertRegex(name, r'\.(age|age\.sha256|age\.key)$', 'no plaintext file is left behind')
        self.assertEqual([], list(self.scratch.iterdir()), 'the transient snapshot is removed')
        db = self.only(self.local, 'rupert-*.sqlite3.gz.age')
        for f in [db, self.only(self.local, 'settings-*.sql.age'), self.only(self.local, 'env-*.age')]:
            self.assertTrue(f.read_bytes().startswith(b'age-encryption.org/v1\n'))
            self.assertEqual(0o600, stat.S_IMODE(f.stat().st_mode))
            digest, name = (f.parent / (f.name + '.sha256')).read_text().split()
            self.assertEqual((hashlib.sha256(f.read_bytes()).hexdigest(), f.name), (digest, name))
            self.assertIn(f'recipient {self.recipient}', (f.parent / (f.name + '.key')).read_text())
            self.assertNotIn(b'primary-secret', f.read_bytes())
            self.assertNotIn(b'owner@example.com', f.read_bytes())
        restored = self.tmp / 'r.sqlite3'
        restored.write_bytes(gzip.decompress(self.age_decrypt(db)))
        self.assertEqual([('owner@example.com',)], sqlite3.connect(restored).execute('SELECT email FROM users').fetchall())
        self.assertIn(b"INSERT INTO settings VALUES(2,'quote',NULL,NULL,'it''s');", self.age_decrypt(self.only(self.local, 'settings-*.sql.age')))
        self.assertIn(b'RAILS_ENCRYPTION_PRIMARY_KEY=primary-secret', self.age_decrypt(self.only(self.local, 'env-*.age')))
        status = self.status_of('local')
        self.assertEqual('ok', status['state'])
        self.assertTrue(status['encrypted'])
        fpr = hashlib.sha256(self.recipient.encode()).hexdigest()[:16]
        self.assertEqual(' '.join(fpr[i:i + 4] for i in range(0, 16, 4)), status['key_fingerprint'])

    def test_backup_refuses_without_an_active_key_and_writes_nothing(self):
        for retired in (None, True):
            if retired:
                self.activate(self.recipient, retired=True)
            r = self.run_backup()
            self.assertEqual(1, r.returncode)
            self.assertIn('refused: no active backup key', r.stderr)
            status = self.status_of('local')
            self.assertEqual('failed', status['state'])
            self.assertFalse(status['encrypted'])
            self.assertEqual([], [p for p in self.local.iterdir() if p.is_file()])

    def test_backup_rejects_a_malformed_recipient(self):
        self.activate("age1'; touch /tmp/pwned; '")
        r = self.run_backup()
        self.assertEqual(1, r.returncode)
        self.assertIn('no active backup key', r.stderr)

    def test_backup_moves_legacy_plaintext_aside_and_prunes_whole_sets(self):
        self.activate(self.recipient)
        self.local.mkdir(parents=True)
        for name in ['rupert-20261020-0617.sql.gz', 'settings-20261020-0617.sql', 'env-20261020-0617']:
            (self.local / name).write_text('old plaintext')
        for i in range(3):
            stamp = f'20261001-00{i:02d}'
            for base in [f'rupert-{stamp}.sqlite3.gz.age', f'settings-{stamp}.sql.age', f'env-{stamp}.age']:
                for suffix in ['', '.sha256', '.key']:
                    p = self.local / (base + suffix)
                    p.write_text('x')
                    os.utime(p, (time.time() - 86400 * (10 - i),) * 2)
        r = self.run_backup(KEEP=2)
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertEqual(sorted(['env-20261020-0617', 'rupert-20261020-0617.sql.gz', 'settings-20261020-0617.sql']),
                         sorted(p.name for p in (self.local / 'legacy-plaintext').iterdir()))
        left = sorted(p.name for p in self.local.iterdir() if p.is_file())
        self.assertEqual(2 * 9, len(left), left)
        self.assertFalse(any('20261001-0000' in n or '20261001-0001' in n for n in left), left)
        self.assertTrue(any('20261001-0002' in n for n in left))

    # frequent snapshot --------------------------------------------------------------------------------------------
    def test_frequent_snapshot_is_encrypted_and_refuses_without_a_key(self):
        out = self.tmp / 'frequent'
        env = self.env(OUT=out)
        r = subprocess.run(['bash', str(FREQUENT)], env=env, capture_output=True, text=True)
        self.assertEqual(1, r.returncode)
        self.assertIn('refused', r.stderr)
        self.assertEqual('failed', self.status_of('frequent')['state'])
        self.assertEqual([], list(out.glob('rupert-*')))

        self.activate(self.recipient)
        old = out / 'rupert-20261001-000000.sqlite3.gz'
        old.write_bytes(b'plain')
        os.utime(old, (time.time() - 3 * 86400,) * 2)
        r = subprocess.run(['bash', str(FREQUENT)], env=env, capture_output=True, text=True)
        self.assertEqual(0, r.returncode, r.stderr)
        snap = self.only(out, 'rupert-*.sqlite3.gz.age')
        self.assertTrue((out / (snap.name + '.sha256')).exists())
        self.assertTrue((out / (snap.name + '.key')).exists())
        self.assertFalse(old.exists(), 'pre-encryption snapshots still age out after 24 h')
        self.assertTrue(gzip.decompress(self.age_decrypt(snap)).startswith(b'SQLite format 3'))
        self.assertTrue(self.status_of('frequent')['encrypted'])
        self.assertEqual([], list(self.scratch.iterdir()))

    # host pull ---------------------------------------------------------------------------------------------------
    def test_host_pull_copies_only_encrypted_db_and_settings_never_env(self):
        self.activate(self.recipient)
        r = self.run_pull()
        self.assertEqual(0, r.returncode, r.stderr)
        names = sorted(p.name for p in self.host_out.iterdir() if p.is_file() and not p.name.startswith('.'))
        self.assertEqual(6, len(names), names)
        self.assertFalse(any(n.startswith('env') for n in names), names)
        self.assertNotIn('env-', self.calls.read_text(), 'the env file is never read from the container')
        db = self.only(self.host_out, 'rupert-*.sqlite3.gz.age')
        self.assertEqual((self.local / db.name).read_bytes(), db.read_bytes())
        res, out = self.decrypt(db, '--identity-file', str(self.key_file))
        self.assertEqual(0, res.returncode, res.stderr)
        status = self.status_of('offhost')
        self.assertEqual('ok', status['state'])
        self.assertTrue(status['encrypted'])

    def test_host_pull_refuses_when_container_backups_are_not_encrypted(self):
        self.local.mkdir(parents=True)
        (self.local / 'rupert-20261024-0617.sql.gz').write_bytes(gzip.compress(b'plain'))
        r = subprocess.run(['bash', str(PULL)], env=self.env(OUT=self.host_out), capture_output=True, text=True)
        self.assertEqual(1, r.returncode)
        self.assertIn('is not encrypted', r.stderr)
        self.assertEqual('failed', self.status_of('offhost')['state'])
        self.assertEqual([], [p for p in self.host_out.iterdir() if not p.name.startswith('.')])

    def test_host_pull_stops_when_the_container_backup_fails(self):
        r = self.run_pull(BACKUP_EXIT=1)
        self.assertEqual(1, r.returncode)
        self.assertIn('rupert-backup.service failed', r.stderr)

    def test_host_pull_rejects_a_copy_that_does_not_match_or_is_not_age(self):
        self.activate(self.recipient)
        flip = ('f=$(ls -1t {d}/rupert-*.sqlite3.gz.age | head -1); '
                'printf "\\x00" | dd of="$f" bs=1 seek=200 conv=notrunc 2>/dev/null').format(d=self.local)
        hook = f'OUT={self.local} STATUS_DIR={self.status} bash {BACKUP} && {flip}'
        r = subprocess.run(['bash', str(PULL)], env=self.env(OUT=self.host_out, ON_BACKUP=hook), capture_output=True, text=True)
        self.assertEqual(1, r.returncode)
        self.assertIn('digest mismatch', r.stderr)
        self.assertEqual([], list(self.host_out.glob('rupert-*')))

        fake = ('f=$(ls -1t {d}/rupert-*.sqlite3.gz.age | head -1); echo plaintext > "$f"; '
                '(cd {d} && sha256sum "$(basename "$f")" > "$f.sha256")').format(d=self.local)
        hook = f'OUT={self.local} STATUS_DIR={self.status} bash {BACKUP} && {fake}'
        r = subprocess.run(['bash', str(PULL)], env=self.env(OUT=self.host_out, ON_BACKUP=hook), capture_output=True, text=True)
        self.assertEqual(1, r.returncode)
        self.assertIn('not age-encrypted', r.stderr)
        self.assertEqual([], list(self.host_out.glob('rupert-*')))

    def test_host_pull_prunes_every_type_to_keep_and_leaves_legacy_files(self):
        self.activate(self.recipient)
        self.host_out.mkdir()
        for i in range(36):
            stamp = f'20261001-{i:04d}'
            for base in [f'rupert-{stamp}.sqlite3.gz.age', f'settings-{stamp}.sql.age']:
                for suffix in ['', '.sha256', '.key']:
                    p = self.host_out / (base + suffix)
                    p.write_text('x')
                    os.utime(p, (time.time() - 86400 * 40 + i * 3600,) * 2)
        legacy = ['rupert-sqlite-20261020T071700Z.sql.gz', 'env-sqlite-20261020T071700Z', 'settings-20261020T071700Z.sql',
                  'rupert-sqlite-20261020T124700Z.sql.gz.enc']
        for name in legacy:
            (self.host_out / name).write_text('legacy')
        r = self.run_pull()
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertEqual(35, len(list(self.host_out.glob('rupert-*.sqlite3.gz.age'))))
        self.assertEqual(35, len(list(self.host_out.glob('settings-*.sql.age'))))
        self.assertEqual(35, len(list(self.host_out.glob('*.age.key'))) // 2)
        self.assertEqual(70, len(list(self.host_out.glob('*.age.sha256'))))
        self.assertFalse(list(self.host_out.glob('*20261001-0000*')), 'the oldest sets went whole')
        self.assertFalse(list(self.host_out.glob('*20261001-0001.*')))
        for name in legacy:
            self.assertTrue((self.host_out / name).exists(), f'{name} is the owner\'s to delete')

    # weekly check ------------------------------------------------------------------------------------------------
    def test_verify_checks_digests_headers_and_the_active_key_without_decrypting(self):
        self.activate(self.recipient)
        self.assertEqual(0, self.run_pull().returncode)
        env = self.env(OUT=self.host_out, SQLITE_DB=self.db)
        r = subprocess.run(['bash', str(VERIFY)], env=env, capture_output=True, text=True)
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertIn('match their digests', r.stdout)
        self.assertEqual('ok', self.status_of('verify')['state'])
        self.assertNotIn('age -d', VERIFY.read_text(), 'the host has no key and never decrypts')

        # Rotated in the container but not pulled since: flagged.
        con = sqlite3.connect(self.db)
        con.execute("UPDATE backup_encryption_keys SET retired_at = '2026-10-26'")
        con.commit()
        con.close()
        self.activate(self.new_key()[1])
        r = subprocess.run(['bash', str(VERIFY)], env=env, capture_output=True, text=True)
        self.assertEqual(1, r.returncode)
        self.assertIn('not the active key', r.stderr)

        db = self.only(self.host_out, 'rupert-*.sqlite3.gz.age')
        with open(db, 'r+b') as f:
            f.seek(300)
            f.write(b'\x00')
        r = subprocess.run(['bash', str(VERIFY)], env=env, capture_output=True, text=True)
        self.assertEqual(1, r.returncode)
        self.assertIn('digest mismatch', r.stderr)

    # bin/backup-decrypt -----------------------------------------------------------------------------------------
    def make_set(self):
        self.activate(self.recipient)
        self.assertEqual(0, self.run_backup().returncode)
        return self.only(self.local, 'rupert-*.sqlite3.gz.age')

    def test_decrypt_restores_and_checks_the_database_from_a_key_file_or_stdin(self):
        db = self.make_set()
        r, out = self.decrypt(db, '--identity-file', str(self.key_file))
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertIn('integrity_check ok', r.stderr)
        self.assertEqual(0o600, stat.S_IMODE(out.stat().st_mode))
        self.assertEqual(1, sqlite3.connect(out).execute('SELECT COUNT(*) FROM users').fetchone()[0])

        r, out = self.decrypt(db, '--identity-stdin', stdin=f'# kit\n{self.identity}\n')
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertTrue(out.read_bytes().startswith(b'SQLite format 3'))

        r, out = self.decrypt(self.only(self.local, 'env-*.age'), '--identity-file', str(self.key_file))
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertIn('RAILS_ENCRYPTION_PRIMARY_KEY', out.read_text())

    def test_decrypt_never_takes_the_key_on_the_command_line(self):
        db = self.make_set()
        for args in ([self.identity, '--identity-stdin'], ['--identity-file', self.identity]):
            r, out = self.decrypt(db, *args)
            self.assertEqual(64, r.returncode, r.stderr)
            self.assertIn('refusing a private key on the command line', r.stderr)
            self.assertFalse(out.exists())
        self.key_file.chmod(0o644)
        r, out = self.decrypt(db, '--identity-file', str(self.key_file))
        self.assertEqual(1, r.returncode)
        self.assertIn('readable only by you', r.stderr)

    def test_decrypt_rejects_tampered_ciphertext_and_the_wrong_kit(self):
        db = self.make_set()
        other_identity, _ = self.new_key()
        r, out = self.decrypt(db, '--identity-stdin', stdin=other_identity + '\n')
        self.assertEqual(1, r.returncode)
        self.assertIn('wrong recovery kit', r.stderr)
        self.assertFalse(out.exists())

        data = bytearray(db.read_bytes())
        data[-50] ^= 1
        db.write_bytes(bytes(data))
        r, out = self.decrypt(db, '--identity-file', str(self.key_file))
        self.assertEqual(1, r.returncode)
        self.assertIn('digest mismatch', r.stderr)
        self.assertFalse(out.exists())

        # Without the digest file, age's authentication still catches it, and nothing is left behind.
        Path(str(db) + '.sha256').unlink()
        r, out = self.decrypt(db, '--identity-file', str(self.key_file))
        self.assertEqual(1, r.returncode)
        self.assertIn('decryption failed', r.stderr)
        self.assertFalse(out.exists())
        self.assertEqual([], list(self.tmp.glob('restored-*')))


class ScriptSyntaxTest(unittest.TestCase):
    def test_scripts_parse(self):
        for script in [BACKUP, DECRYPT, FREQUENT, PULL, VERIFY, REPO / 'deploy' / 'offsite' / 'rupert-backup-mirror.sh']:
            r = subprocess.run(['bash', '-n', str(script)], capture_output=True, text=True)
            self.assertEqual(0, r.returncode, f'{script}: {r.stderr}')

    def test_host_scripts_never_reference_the_old_host_key_or_env_copies(self):
        for script in [PULL, VERIFY]:
            text = script.read_text()
            self.assertNotIn('offhost.key', text)
            self.assertNotIn('openssl enc', text)
        self.assertNotIn('env-', PULL.read_text().split('set -euo pipefail', 1)[1])


if __name__ == '__main__':
    unittest.main()
