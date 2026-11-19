from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import unittest

import test_autodeploy

ROLLBACK = Path(__file__).parents[1] / 'rupert-rollback.sh'


class RollbackTest(test_autodeploy.AutodeployTest):
    """The operator pause and rupert-rollback, on the same fake host as the auto-deploy tests."""

    def run_rollback(self, *args, **env):
        if self.calls.exists():
            self.calls.unlink()
        result = subprocess.run(['bash', str(ROLLBACK), *args], env={**self.env, **env}, capture_output=True, text=True)
        return result, self.calls.read_text() if self.calls.exists() else ''

    def deploy_new(self):
        new = self.commit('feature')
        result, _ = self.run_deploy()
        self.assertIn(f'deployed {new[:8]}, healthy', result.stdout, result.stdout + result.stderr)
        return new

    def use_real_sqlite(self):
        sqlite = self.tmp / 'bin' / 'sqlite3'
        sqlite.write_text(f'#!/bin/sh\nexec "{shutil.which("sqlite3")}" "$@"\n')
        sqlite.chmod(0o755)

    def test_pause_file_stops_the_updater_and_keeps_requests(self):
        self.commit('feature')
        (self.tmp / 'state').mkdir()
        (self.tmp / 'state' / 'paused').write_text('testing\n')
        self.request_install(1_800_000_000)
        result, calls = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('paused by operator: testing', result.stdout)
        self.assertEqual(self.status()['state'], 'blocked')
        self.assertNotIn('check-runs', calls)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertFalse((self.tmp / 'state' / 'request-handled-ns').exists())

        (self.tmp / 'state' / 'paused').unlink()
        result, _ = self.run_deploy()
        self.assertIn('healthy', result.stdout, result.stdout + result.stderr)

    def test_sidecars_of_pruned_backups_are_removed(self):
        backups = self.tmp / 'backups'
        backups.mkdir()
        for i in range(6):
            for suffix in ('', '-shm', '-wal'):
                path = backups / f'old-{i}.sqlite3{suffix}'
                path.write_text('backup')
                os.utime(path, (1_600_000_000 + i, 1_600_000_000 + i))
        self.commit('feature')
        result, _ = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((backups / 'old-0.sqlite3-shm').exists())
        self.assertFalse((backups / 'old-1.sqlite3-wal').exists())
        self.assertTrue((backups / 'old-5.sqlite3-shm').exists())

    def test_forced_health_failure_rolls_back_to_a_verified_old_build(self):
        new = self.commit('feature')
        result, calls = self.run_deploy(RUPERT_AUTODEPLOY_FORCE_HEALTH_FAIL='1')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('forced health-check failure', result.stdout)
        self.assertIn('rollback healthy', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertEqual(calls.count('systemctl restart rupert-web rupert-jobs'), 2)
        receipt = json.loads(Path(self.status()['receipt']).read_text())
        self.assertEqual((receipt['failed_stage'], receipt['rollback'], receipt['running_sha']), ('health', 'healthy', self.old))
        self.assertEqual(self.status()['state'], 'failed')
        (self.tmp / 'state' / 'failed-sha').unlink()
        result, _ = self.run_deploy()
        self.assertIn(f'deployed {new[:8]}, healthy', result.stdout)

    def test_rollback_defaults_to_the_commit_before_the_last_deploy_and_pauses(self):
        new = self.deploy_new()
        result, calls = self.run_rollback()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'rolled back to {self.old[:8]}, healthy', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertIn('systemctl restart rupert-web rupert-jobs', calls)
        self.assertNotIn('systemctl stop', calls)
        self.assertIn(f'rollback from {new[:8]} to {self.old[:8]}', (self.tmp / 'state' / 'paused').read_text())
        self.assertIn('rolled back', (self.tmp / 'state' / 'rollback.log').read_text())

        result, _ = self.run_deploy()
        self.assertIn('paused by operator', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        (self.tmp / 'state' / 'paused').unlink()
        result, _ = self.run_deploy()
        self.assertIn(f'deployed {new[:8]}, healthy', result.stdout)

    def test_rollback_without_a_recorded_deploy_needs_a_commit(self):
        result, calls = self.run_rollback()
        self.assertEqual(result.returncode, 1)
        self.assertIn('name the commit', result.stdout)
        self.assertNotIn('systemctl', calls)
        self.assertFalse((self.tmp / 'state' / 'paused').exists())

    def test_unknown_commit_or_dirty_checkout_changes_nothing(self):
        self.deploy_new()
        result, calls = self.run_rollback('0' * 40)
        self.assertEqual(result.returncode, 1)
        self.assertIn('unknown commit', result.stdout)
        (self.tmp / 'app' / 'web' / 'app.txt').write_text('local edit')
        result, calls2 = self.run_rollback(self.old)
        self.assertEqual(result.returncode, 1)
        self.assertIn('dirty', result.stdout)
        self.assertNotIn('systemctl', calls + calls2)
        self.assertFalse((self.tmp / 'state' / 'paused').exists())

    def test_unhealthy_rollback_fails_and_stays_paused(self):
        self.deploy_new()
        result, _ = self.run_rollback(self.old, HEALTH='502')
        self.assertEqual(result.returncode, 1)
        self.assertIn('not healthy', result.stdout)
        self.assertTrue((self.tmp / 'state' / 'paused').exists())

    def test_wrong_served_build_fails_the_rollback(self):
        new = self.deploy_new()
        result, _ = self.run_rollback(self.old, SERVED_BUILD=new)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"serves build '{new}'", result.stdout)

    @unittest.skipUnless(shutil.which('sqlite3'), 'the SQLite CLI is required')
    def test_restore_db_keeps_the_current_database_then_restores_the_backup(self):
        self.use_real_sqlite()
        live = self.tmp / 'live.sqlite3'
        backup = self.tmp / 'pre-deploy.sqlite3'
        for path, value in ((live, 'current'), (backup, 'from backup')):
            with closing(sqlite3.connect(path)) as db:
                db.execute('CREATE TABLE sample (value TEXT)')
                db.execute('INSERT INTO sample VALUES (?)', (value,))
                db.commit()
        (self.tmp / 'rupert.env').write_text(f"RUPERT_SQLITE_DATABASE_PRODUCTION='{live}'\n")
        self.deploy_new()
        result, calls = self.run_rollback(self.old, '--restore-db', str(backup))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLess(calls.index('systemctl stop rupert-web rupert-jobs'), calls.index('systemctl restart'))
        with closing(sqlite3.connect(live)) as db:
            self.assertEqual(db.execute('SELECT value FROM sample').fetchone(), ('from backup',))
        kept = list((self.tmp / 'backups').glob('pre-rollback-*.sqlite3'))
        self.assertEqual(len(kept), 1)
        with closing(sqlite3.connect(kept[0])) as db:
            self.assertEqual(db.execute('SELECT value FROM sample').fetchone(), ('current',))
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_corrupt_restore_backup_is_refused_before_anything_changes(self):
        new = self.deploy_new()
        backup = self.tmp / 'bad.sqlite3'
        backup.write_text('not a database')
        result, calls = self.run_rollback(self.old, '--restore-db', str(backup), BACKUP_INTEGRITY='corrupt')
        self.assertEqual(result.returncode, 1)
        self.assertIn('integrity check', result.stdout)
        self.assertNotIn('systemctl', calls)
        self.assertEqual(self.head(self.tmp / 'app'), new)


# Only run the tests defined here; the inherited auto-deploy tests run from their own module.
for _name in [n for n in dir(test_autodeploy.AutodeployTest) if n.startswith('test_')]:
    if _name not in RollbackTest.__dict__:
        setattr(RollbackTest, _name, None)

if __name__ == '__main__':
    unittest.main()
