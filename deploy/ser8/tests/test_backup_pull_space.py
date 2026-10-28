"""Host pull keeps its disk reserve even when the next set is large."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'rupert-host-backup-pull.sh'

class BackupPullSpaceTest(unittest.TestCase):
    def test_refuses_set_that_would_consume_reserve(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bindir = root / 'bin'
            bindir.mkdir()
            scripts = {
                'df': '#!/bin/sh\nprintf "Avail\\n10485760\\n"\n',
                'incus': '''#!/bin/sh
case "$*" in
  *"systemctl start"*) exit 0 ;;
  *"ls -1t"*) echo /var/backups/rupert/rupert-20261027-080000.sqlite3.gz.age ;;
  *"stat -c"*) printf '6291456\\n1048576\\n' ;;
  *"file push"*) cat >/dev/null ;;
  *" cat "*) echo unexpected-copy >&2; exit 1 ;;
  *) exit 1 ;;
esac
''',
            }
            for name, source in scripts.items():
                path = bindir / name
                path.write_text(source)
                path.chmod(0o755)
            env = dict(os.environ, PATH=f'{bindir}:{os.environ["PATH"]}', OUT=str(root / 'out'), MIN_FREE_MB='5')
            result = subprocess.run(['bash', str(SCRIPT)], env=env, capture_output=True, text=True)
            self.assertNotEqual(0, result.returncode)
            self.assertIn('reserved space', result.stderr)
            self.assertNotIn('unexpected-copy', result.stderr)
            self.assertEqual([], list((root / 'out').glob('*.age')))
