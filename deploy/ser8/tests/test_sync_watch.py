"""Host watcher must not report success without a disk measurement."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'rupert-sync-watch.sh'

class SyncWatchTest(unittest.TestCase):
    def test_timer_runs_after_user_manager_starts(self):
        timer = SCRIPT.with_suffix('.timer').read_text()
        self.assertIn('OnStartupSec=1min', timer)
        self.assertIn('OnUnitActiveSec=15min', timer)

    def test_unknown_disk_is_a_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            incus = Path(tmp) / 'incus'
            incus.write_text('#!/bin/sh\nexit 1\n')
            incus.chmod(0o755)
            result = subprocess.run(['bash', str(SCRIPT)], env={**os.environ, 'PATH': f'{tmp}:/usr/bin:/bin'}, text=True, capture_output=True)
            self.assertNotEqual(0, result.returncode)
            self.assertIn('UNKNOWN DISK', result.stderr)

    def test_catalog_check_failure_propagates(self):
        with tempfile.TemporaryDirectory() as tmp:
            incus = Path(tmp) / 'incus'
            incus.write_text('''#!/bin/sh
case "$*" in
  *"RUPERT_SQLITE_DATABASE_PRODUCTION"*) echo /opt/rupert/web/storage/production.sqlite3 ;;
  *"df -Pm"*) printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/test 10000 1 9999 1%% /\\n' ;;
  *"/up/ready"*)
    case "$*" in *"X-Forwarded-Proto: https"*) printf "%s" "${READY_CODE:-200}" ;; *) printf 301 ;; esac ;;
  *"systemctl is-active"*) echo active ;;
  *"script/sync_watch.rb"*) echo 'STALE: test source' >&2; exit 1 ;;
  *) exit 2 ;;
esac
''')
            incus.chmod(0o755)
            result = subprocess.run(['bash', str(SCRIPT)], env={**os.environ, 'PATH': f'{tmp}:/usr/bin:/bin'}, text=True, capture_output=True)
            self.assertNotEqual(0, result.returncode)
            self.assertIn('STALE: test source', result.stderr)
            result = subprocess.run(['bash', str(SCRIPT)], env={**os.environ, 'PATH': f'{tmp}:/usr/bin:/bin', 'READY_CODE': '503'}, text=True, capture_output=True)
            self.assertNotEqual(0, result.returncode)
            self.assertIn('NOT READY', result.stderr)
