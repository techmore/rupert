import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'rupert-nas-recovery.sh'


class NasRecoveryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.nas = root / 'nas'
        (self.nas / 'rupert-recovery').mkdir(parents=True)
        (root / '.local/share').mkdir(parents=True)
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        payload = b'age-encryption.org/v1 synthetic ciphertext\n'
        digest = hashlib.sha256(payload).hexdigest()
        scripts = {
            'findmnt': '#!/bin/sh\nprintf "%s\\n" "$TEST_NFS_SOURCE"\n',
            'setfacl': '#!/bin/sh\nexit 0\n',
            'incus': f'''#!/bin/sh
printf 'called\\n' >> "$TEST_CALL_LOG"
case "$4" in
  systemctl) exit 0 ;;
  sh) printf '/var/backups/rupert/rupert-20261027-120000.sqlite3.gz.age\\n' ;;
  cat) name=${{5##*/}}; case "$name" in
    *.sha256) printf '%s  %s\\n' "${{TEST_DIGEST:-{digest}}}" "${{name%.sha256}}" ;;
    *.key) printf 'synthetic key metadata\\n' ;;
    *) printf 'age-encryption.org/v1 synthetic ciphertext\\n' ;;
  esac ;;
  *) exit 1 ;;
esac
''',
        }
        for name, content in scripts.items():
            path = bin_dir / name
            path.write_text(content)
            path.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(PATH=f'{bin_dir}:/usr/bin:/bin', HOME=str(root),
                        RUPERT_NAS_MOUNT=str(self.nas), RUPERT_NAS_SOURCE='nas:/test',
                        RUPERT_NAS_CONTAINER='test-container', RUPERT_NAS_READER_UID='123',
                        TEST_NFS_SOURCE='nas:/test', TEST_CALL_LOG=str(root / 'calls'))

    def test_refuses_wrong_mount_before_starting_backup(self):
        self.env['TEST_NFS_SOURCE'] = 'other:/test'
        result = subprocess.run([str(SCRIPT)], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(0, result.returncode)
        self.assertIn('NAS not mounted as expected', result.stderr)
        self.assertFalse(Path(self.env['TEST_CALL_LOG']).exists())

    def test_copies_verified_encrypted_recovery_set(self):
        result = subprocess.run([str(SCRIPT)], env=self.env, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        dest = self.nas / 'rupert-recovery/age-20261027-120000'
        self.assertEqual(9, len(list(dest.iterdir())))
        self.assertTrue((dest / 'env-20261027-120000.age').read_bytes().startswith(b'age-encryption.org/v1'))
        self.assertIn('verified', result.stdout)

    def test_bad_checksum_never_publishes_partial_set(self):
        self.env['TEST_DIGEST'] = '0' * 64
        result = subprocess.run([str(SCRIPT)], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], list((self.nas / 'rupert-recovery').iterdir()))


if __name__ == '__main__':
    unittest.main()
