import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'team-chat/benchmark-probes/local-snapshot.sh'


class BenchmarkLocalSnapshotTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        (root / 'bin').mkdir()
        self.out = root / 'evidence'
        self.out.mkdir()
        incus = root / 'bin/incus'
        incus.write_text('''#!/bin/sh
case "$1" in
 exec) exit 0 ;;
 file) printf 'synthetic sqlite snapshot' > "$4" ;;
 *) exit 1 ;;
esac
''')
        incus.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(PATH=f'{root / "bin"}:/usr/bin:/bin', RUPERT_BENCHMARK_OUTPUT=str(self.out),
                        RUPERT_BENCHMARK_CONTAINER='test-container')

    def test_saves_locally_with_restricted_permissions(self):
        result = subprocess.run([str(SCRIPT)], env=self.env, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        snapshot = self.out / 'progress.sqlite3'
        self.assertEqual('synthetic sqlite snapshot', snapshot.read_text())
        self.assertEqual(0o600, snapshot.stat().st_mode & 0o777)
        self.assertFalse((self.out / 'progress.sqlite3.partial').exists())

    def test_rejects_invalid_container(self):
        self.env['RUPERT_BENCHMARK_CONTAINER'] = '../production'
        result = subprocess.run([str(SCRIPT)], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((self.out / 'progress.sqlite3').exists())


if __name__ == '__main__':
    unittest.main()
