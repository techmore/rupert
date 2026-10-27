import fcntl
from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import hashlib
import time
import unittest

SCRIPT = Path(__file__).parents[1] / 'rupert-autodeploy.sh'
PRINTER = Path(__file__).parents[1] / 'rupert-deploy-receipt'

# Stand-ins for the host tools. Each records its call in $CALLS. curl serves the
# check-runs JSON from $CHECKS (or $CHECKS_DIR/<sha>.json), answers the health
# check with $HEALTH, renders the smoke page with an X-Rupert-Build of the app
# checkout's HEAD (or $SERVED_BUILD) and serves assets (a path containing
# $BROKEN_ASSET answers 404 with an empty body).
PAGE = ('<link rel="stylesheet" href="/api/assets/tailwind-' + 'a' * 64 + '.css" />'
        '<link rel="modulepreload" href="/api/assets/application-' + 'b' * 64 + '.js">'
        '<link rel="modulepreload" href="/api/assets/controllers/application-' + 'c' * 64 + '.js">'
        '<link rel="modulepreload" href="/api/assets/turbo.min-' + 'd' * 64 + '.js">')
STUBS = {
    'curl': '''#!/usr/bin/env python3
import os, re, subprocess, sys
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write('curl ' + ' '.join(args) + '\\n')
url = args[-1]
def opt(name):
    return args[args.index(name) + 1] if name in args else None
def emit(body, code=None):
    out = opt('-o')
    if out and out != '/dev/null':
        with open(out, 'w') as f:
            f.write(body)
    elif not out:
        sys.stdout.write(body)
    if code is not None:
        sys.stdout.write(code)
if '/check-runs' in url:
    sha = re.search(r'/commits/([0-9a-f]+)/check-runs', url).group(1)
    if os.environ.get('CANCEL_DURING_CHECKS'):
        try: os.unlink(os.path.join(os.environ['RUPERT_AUTODEPLOY_INBOX'], 'install-requested'))
        except FileNotFoundError: pass
    if os.environ.get('MANUAL_DURING_CHECKS'):
        open(os.path.join(os.environ['RUPERT_AUTODEPLOY_INBOX'], 'manual'), 'a').close()
    path = os.path.join(os.environ['CHECKS_DIR'], sha + '.json')
    sys.stdout.write(open(path if os.path.exists(path) else os.environ['CHECKS']).read())
elif url.endswith('/up'):
    emit('', os.environ.get('HEALTH', '200'))
elif '/assets/' in url:
    broken = os.environ.get('BROKEN_ASSET')
    emit('', '404') if broken and broken in url else emit('compiled ' + url, '200')
else:
    build = os.environ.get('SERVED_BUILD') or subprocess.run(
        ['git', '-C', os.environ['RUPERT_AUTODEPLOY_APP'], 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    if opt('-D'):
        with open(opt('-D'), 'w') as f:
            f.write('HTTP/1.1 200 OK\\r\\nx-rupert-build: ' + build + '\\r\\n\\r\\n')
    emit(os.environ.get('PAGE', ''' + repr(PAGE) + '''), os.environ.get('PAGE_CODE', '200'))
''',
    'systemctl': '''#!/bin/sh
echo "systemctl $*" >> "$CALLS"
if [ "$1" = is-active ] && [ -n "${INACTIVE_UNIT:-}" ]; then
  # systemctl returns success when *any* requested unit is active.
  for unit in "$@"; do
    case "$unit" in rupert-web|rupert-jobs) [ "$unit" != "$INACTIVE_UNIT" ] && exit 0 ;; esac
  done
  exit 3
fi
if [ "$1" = restart ]; then exit "${RESTART_EXIT:-0}"; fi
''',
    'sqlite3': '''#!/bin/sh
echo "sqlite3 $*" >> "$CALLS"
[ "${BACKUP_EXIT:-0}" = 0 ] || exit "$BACKUP_EXIT"
for arg in "$@"; do
  case "$arg" in '.backup '*) set -- $arg; touch "$2" ;; 'PRAGMA quick_check;') echo "${BACKUP_INTEGRITY:-ok}" ;; esac
done
''',
    'bundle': '#!/bin/sh\necho "bundle $*" >> "$CALLS"\ncase "$*" in *db:migrate*) exit "${MIGRATE_EXIT:-0}" ;; *assets:precompile*) exit "${ASSETS_EXIT:-0}" ;; esac\n[ "$1" = install ] && exit "${INSTALL_EXIT:-0}"\n',
    'chown': '#!/bin/sh\necho "chown $*" >> "$CALLS"\n',
    'sleep': '#!/bin/sh\n',
    'date': '#!/bin/sh\nif [ -n "${FIXED_DATE:-}" ]; then echo "$FIXED_DATE"; else exec /bin/date "$@"; fi\n',
}


def check_runs(*runs):
    """(name, conclusion) or (name, conclusion, status); no conclusion means still in progress."""
    out = []
    for i, run in enumerate(runs):
        name, conclusion = run[:2]
        status = run[2] if len(run) > 2 else ('completed' if conclusion else 'in_progress')
        out.append({'id': 1000 + i, 'name': name, 'status': status, 'conclusion': conclusion, 'app': {'id': 15368},
                    'html_url': f'https://github.com/techmore/rupert/runs/{1000 + i}',
                    'completed_at': '2026-10-25T12:00:00Z' if status == 'completed' else None})
    return {'total_count': len(out), 'check_runs': out}


REQUIRED = ('CI (sqlite3)', 'Product site consistency', 'Dependency and static scan')
GREEN = check_runs(*[(name, 'success') for name in REQUIRED])


class AutodeployTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        bin_dir = self.tmp / 'bin'
        bin_dir.mkdir()
        for name, body in STUBS.items():
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        (self.tmp / 'rupert.env').write_text('SECRET_KEY_BASE=do-not-leak-this\n')
        self.calls = self.tmp / 'calls'
        self.checks = self.tmp / 'checks.json'
        self.checks_dir = self.tmp / 'checks'
        self.checks_dir.mkdir()
        self.set_checks(GREEN)
        self.env = {
            'HOME': str(self.tmp), 'CALLS': str(self.calls), 'CHECKS': str(self.checks), 'CHECKS_DIR': str(self.checks_dir), 'HEALTH': '200',
            'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@example.org',
            'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@example.org',
            'RUPERT_AUTODEPLOY_APP': str(self.tmp / 'app'),
            'RUPERT_AUTODEPLOY_BACKUPS': str(self.tmp / 'backups'),
            'RUPERT_AUTODEPLOY_STATE': str(self.tmp / 'state'),
            'RUPERT_AUTODEPLOY_LOCK': str(self.tmp / 'lock'),
            'RUPERT_AUTODEPLOY_ENV_FILE': str(self.tmp / 'rupert.env'),
            'RUPERT_AUTODEPLOY_PATH': f'{bin_dir}:/usr/bin:/bin',
            'RUPERT_AUTODEPLOY_INBOX': str(self.tmp / 'inbox'),
        }
        self.inbox = self.tmp / 'inbox'
        self.inbox.mkdir()
        self.origin = self.tmp / 'origin'
        self.git('init', '-q', '-b', 'main', str(self.origin))
        (self.origin / 'web' / 'storage').mkdir(parents=True)
        (self.origin / 'web' / 'storage' / '.keep').write_text('')
        (self.origin / 'web' / 'storage' / '.gitignore').write_text('production.sqlite3\n')
        self.commit('initial')
        self.git('clone', '-q', str(self.origin), str(self.tmp / 'app'))
        (self.tmp / 'app' / 'web' / 'storage' / 'production.sqlite3').write_text('test database')
        self.old = self.head(self.tmp / 'app')

    def git(self, *args, cwd=None):
        return subprocess.run(['git', *args], cwd=cwd, env={**os.environ, **self.env}, check=True,
                              capture_output=True, text=True).stdout.strip()

    def head(self, repo):
        return self.git('rev-parse', 'HEAD', cwd=repo)

    def commit(self, message, path='web/app.txt'):
        (self.origin / path).parent.mkdir(parents=True, exist_ok=True)
        (self.origin / path).write_text(message)
        self.git('add', '-A', cwd=self.origin)
        self.git('commit', '-q', '-m', message, cwd=self.origin)
        return self.head(self.origin)

    def set_checks(self, data, sha=None):
        (self.checks_dir / f'{sha}.json' if sha else self.checks).write_text(json.dumps(data))

    def run_deploy(self, **env):
        if self.calls.exists():
            self.calls.unlink()
        result = subprocess.run(['bash', str(SCRIPT)], env={**self.env, **env}, capture_output=True, text=True)
        calls = self.calls.read_text() if self.calls.exists() else ''
        return result, calls

    def status(self, name='status.json'):
        return json.loads((self.tmp / 'state' / name).read_text())

    def request_install(self, at):
        path = self.inbox / 'install-requested'
        path.write_text('')
        os.utime(path, (at, at))

    def test_up_to_date_does_nothing(self):
        result, calls = self.run_deploy()
        self.assertEqual(result.returncode, 0)
        self.assertIn('up to date', result.stdout)
        self.assertNotIn('systemctl', calls)

    def test_all_exact_sha_checks_green_deploys_after_backup(self):
        new = self.commit('feature')
        result, calls = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'deployed {new[:8]}, healthy', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), new)
        self.assertLess(calls.index('sqlite3'), calls.index('db:migrate'))
        self.assertIn('systemctl restart rupert-web rupert-jobs', calls)
        # Regression: status.json kept the old SHA as current until the next run.
        self.assertEqual((self.status()['current'], self.status()['target']), (new, new))
        self.assertEqual(self.status('last-deploy.json')['current'], new)
        self.assertEqual(self.status('last-deploy.json')['previous'], self.old)

    def test_inactive_job_worker_cannot_pass_health(self):
        self.commit('feature')
        result, _ = self.run_deploy(INACTIVE_UNIT='rupert-jobs')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.status()['state'], 'recovery_required')
        self.assertNotIn('rollback healthy', result.stdout)

    def test_backup_uses_configured_database_and_refuses_missing_database(self):
        configured = self.tmp / 'custom.sqlite3'
        configured.write_text('configured database')
        (self.tmp / 'rupert.env').write_text(f'RUPERT_SQLITE_DATABASE_PRODUCTION={configured}\n')
        self.commit('feature')
        result, calls = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'sqlite3 -readonly {configured} .backup ', calls)

        self.commit('next feature')
        configured.unlink()
        result, calls = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('db:migrate', calls)
        self.assertEqual(self.status()['state'], 'failed')

    def test_backup_retention_handles_filenames_with_spaces(self):
        backups = self.tmp / 'backups'
        backups.mkdir()
        for i in range(6):
            path = backups / f'old backup {i}.sqlite3'
            path.write_text('backup')
            os.utime(path, (1_600_000_000 + i, 1_600_000_000 + i))
        self.commit('feature')
        result, _ = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        remaining = {path.name for path in backups.glob('*.sqlite3')}
        self.assertEqual(len(remaining), 5)
        self.assertFalse((backups / 'old backup 0.sqlite3').exists())
        self.assertFalse((backups / 'old backup 1.sqlite3').exists())
        self.assertTrue((backups / 'old backup 2.sqlite3').exists())

    def test_backup_retention_preserves_current_backup_when_older_files_have_future_mtimes(self):
        backups = self.tmp / 'backups'
        backups.mkdir()
        future = int(time.time()) + 86400
        for i in range(5):
            path = backups / f'old-{i}.sqlite3'
            path.write_text('backup')
            os.utime(path, (future + i, future + i))
        new = self.commit('feature')
        result, _ = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        current = Path(self.receipt(f'{new}.json')['backup']['path'])
        self.assertTrue(current.is_file())
        self.assertEqual(len(list(backups.glob('*.sqlite3'))), 5)
        self.assertFalse((backups / 'old-0.sqlite3').exists())

    @unittest.skipUnless(shutil.which('sqlite3'), 'the SQLite CLI is required')
    def test_real_sqlite_backup_contains_configured_database(self):
        configured = self.tmp / 'custom data.sqlite3'
        with closing(sqlite3.connect(configured)) as db:
            db.execute('CREATE TABLE sample (value TEXT)')
            db.execute('INSERT INTO sample VALUES (?)', ('verified',))
            db.commit()
        (self.tmp / 'rupert.env').write_text(f"RUPERT_SQLITE_DATABASE_PRODUCTION='{configured}'\n")
        sqlite = self.tmp / 'bin' / 'sqlite3'
        sqlite.write_text(f'#!/bin/sh\nexec "{shutil.which("sqlite3")}" "$@"\n')
        sqlite.chmod(0o755)
        new = self.commit('feature')
        result, _ = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = self.receipt(f'{new}.json')
        with closing(sqlite3.connect(receipt['backup']['path'])) as db:
            self.assertEqual(db.execute('SELECT value FROM sample').fetchone(), ('verified',))
            self.assertEqual(db.execute('PRAGMA quick_check').fetchone(), ('ok',))

    def test_untrusted_or_incomplete_check_runs_cannot_pass_the_gate(self):
        self.commit('feature')
        fake = check_runs(*[(name, 'success') for name in REQUIRED])
        for check in fake['check_runs']:
            check['app']['id'] = 99999
        self.set_checks(fake)
        self.assert_not_deployed('waiting_ci', 'pending')

        incomplete = check_runs(*[(name, 'success') for name in REQUIRED])
        incomplete['total_count'] = 101
        self.set_checks(incomplete)
        self.assert_not_deployed('waiting_ci', 'unknown')

    def test_deployed_files_stay_readable_by_the_app_user(self):
        # Regression: umask 077 made Gemfile.lock and new gems root-only and the
        # app (running as another user) could not boot.
        new = self.commit('gem update', path='web/Gemfile.lock')
        result, _ = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.head(self.tmp / 'app'), new)
        mode = (self.tmp / 'app' / 'web' / 'Gemfile.lock').stat().st_mode
        self.assertTrue(mode & 0o004, oct(mode))
        self.assertEqual((self.tmp / 'backups').stat().st_mode & 0o777, 0o700)

    def test_pending_or_red_ci_is_not_deployed(self):
        self.commit('feature')
        for checks, word in [(check_runs(('Product site consistency', 'success')), 'pending'),
                             (check_runs(('CI (sqlite3)', 'failure')), 'red'),
                             (check_runs(('CI (sqlite3)', 'success'), ('Product site consistency', 'success'),
                                         ('Dependency and static scan', 'skipped')), 'red'),
                             (check_runs(('CI (sqlite3)', 'success'), ('Product site consistency', 'success')),
                              'pending')]:
            self.set_checks(checks)
            result, calls = self.run_deploy()
            self.assertIn(f'is {word}, not deploying', result.stdout)
            self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_rerun_that_passed_supersedes_earlier_failure(self):
        self.commit('feature')
        self.set_checks(check_runs(('CI (sqlite3)', 'failure'), ('CI (sqlite3)', 'success'),
                                   ('Product site consistency', 'success'), ('Dependency and static scan', 'success')))
        result, _ = self.run_deploy()
        self.assertIn('healthy', result.stdout)

    def test_mobile_changes_require_the_exact_sha_mobile_check(self):
        self.commit('mobile change', path='mobile/src/task.js')
        result, _ = self.run_deploy()
        self.assertIn('is pending, not deploying', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

        self.set_checks(check_runs(*[(name, 'success') for name in REQUIRED], ('validate', 'success')))
        result, _ = self.run_deploy()
        self.assertIn('healthy', result.stdout)

    def test_mobile_check_is_read_from_the_last_mobile_commit_not_a_later_one(self):
        mobile = self.commit('mobile change', path='mobile/src/task.js')
        later = self.commit('web change after it')
        self.set_checks(GREEN, sha=later)  # the mobile workflow never runs on the web-only commit
        self.set_checks(check_runs(*[(name, 'success') for name in REQUIRED], ('validate', 'failure')), sha=mobile)
        result, _ = self.run_deploy()
        self.assertIn(f'CI for {mobile[:8]} is red', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

        self.set_checks(check_runs(*[(name, 'success') for name in REQUIRED], ('validate', 'success')), sha=mobile)
        result, _ = self.run_deploy()
        self.assertIn('healthy', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), later)

    def test_retired_postgresql_check_is_ignored(self):
        self.commit('feature')
        self.set_checks(check_runs(('CI (postgresql)', 'failure'), ('CI (sqlite3)', 'success'),
                                   ('Product site consistency', 'success'), ('Dependency and static scan', 'success')))
        result, _ = self.run_deploy()
        self.assertIn('healthy', result.stdout)

    def test_dirty_checkout_is_skipped(self):
        self.commit('feature')
        (self.tmp / 'app' / 'stray.txt').write_text('x')
        result, _ = self.run_deploy()
        self.assertIn('dirty', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_diverged_checkout_is_not_reset_or_deployed(self):
        app = self.tmp / 'app'
        (app / 'local.txt').write_text('local commit')
        self.git('add', 'local.txt', cwd=app)
        self.git('commit', '-q', '-m', 'local only', cwd=app)
        local = self.head(app)
        self.commit('remote only')

        result, calls = self.run_deploy()

        self.assertIn('not a fast-forward', result.stdout)
        self.assertEqual(self.head(app), local)
        self.assertNotIn('systemctl restart', calls)

    def test_existing_deploy_lock_prevents_overlapping_install(self):
        self.commit('feature')
        with self.open_lock():
            result, calls = self.run_deploy()

        self.assertIn('another deploy is running', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertNotIn('sqlite3', calls)

    def open_lock(self):
        handle = open(self.tmp / 'lock', 'w')
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.addCleanup(handle.close)
        return handle

    def test_backup_failure_stops_before_checkout_or_build(self):
        self.commit('feature')

        result, calls = self.run_deploy(BACKUP_EXIT='1')

        self.assertEqual(result.returncode, 1)
        self.assertIn('backup failed, aborting', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertNotIn('db:migrate', calls)

    def test_corrupt_backup_stops_before_checkout_or_build(self):
        self.commit('feature')
        result, calls = self.run_deploy(BACKUP_INTEGRITY='corrupt')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertNotIn('db:migrate', calls)
        self.assertEqual(self.status()['state'], 'failed')

    def test_asset_build_failure_rolls_back_code(self):
        self.commit('feature')

        result, _ = self.run_deploy(ASSETS_EXIT='1')

        self.assertEqual(result.returncode, 1)
        self.assertIn('no new migrations', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertIn('rollback failed or could not be verified', result.stdout)

    def test_failed_rollback_checkout_never_claims_the_old_build_is_running(self):
        new = self.commit('feature')
        git_stub = self.tmp / 'bin' / 'git'
        git_stub.write_text('''#!/bin/sh
if [ "$1" = checkout ] && [ "$4" = "$ROLLBACK_SHA" ]; then exit 1; fi
exec /usr/bin/git "$@"
''')
        git_stub.chmod(0o755)
        result, _ = self.run_deploy(ASSETS_EXIT='1', ROLLBACK_SHA=self.old)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.head(self.tmp / 'app'), new)
        self.assertIn('rollback failed or could not be verified', result.stdout)
        receipt = self.receipt(self.receipts()[0])
        self.assertEqual(receipt['rollback'], 'unhealthy')
        self.assertIsNone(receipt['running_sha'])
        self.assertNotEqual(self.status()['current'], self.old)

    def test_shallow_checkout_is_completed_before_deploying(self):
        shutil.rmtree(self.tmp / 'app')
        self.git('clone', '-q', '--depth', '1', f'file://{self.origin}', str(self.tmp / 'app'))
        (self.tmp / 'app' / 'web' / 'storage' / 'production.sqlite3').write_text('test database')
        new = self.commit('feature')
        self.assertEqual(self.git('rev-parse', '--is-shallow-repository', cwd=self.tmp / 'app'), 'true')
        result, _ = self.run_deploy()
        self.assertIn(f'deployed {new[:8]}, healthy', result.stdout)
        self.assertEqual(self.git('rev-parse', '--is-shallow-repository', cwd=self.tmp / 'app'), 'false')

    def test_dry_run_changes_nothing(self):
        self.commit('feature')
        result, calls = self.run_deploy(DRY_RUN='1')
        self.assertIn('dry run', result.stdout)
        self.assertNotIn('sqlite3', calls)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_failed_deploy_rolls_back_and_is_not_retried(self):
        new = self.commit('broken migration', path='web/db/migrate/20261020000000_broken.rb')
        result, calls = self.run_deploy(MIGRATE_EXIT='1')
        self.assertEqual(result.returncode, 1)
        self.assertIn('1 migration(s) may have run', result.stdout)
        self.assertIn('rollback healthy', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertIn('chown', calls)

        result, calls = self.run_deploy()
        self.assertEqual(result.returncode, 0)
        self.assertIn(f'{new[:8]} already failed', result.stdout)
        self.assertNotIn('systemctl', calls)

        fixed = self.commit('fix')
        result, _ = self.run_deploy()
        self.assertIn(f'deployed {fixed[:8]}, healthy', result.stdout)
        self.assertFalse((self.tmp / 'state' / 'failed-sha').exists())

    def test_install_stops_if_failed_commit_latch_cannot_be_persisted(self):
        self.commit('feature')
        (self.tmp / 'state' / 'failed-sha.tmp').mkdir(parents=True)
        result, calls = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('db:migrate', calls)
        self.assertNotIn('systemctl restart', calls)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_failed_commit_latch_exists_before_migration(self):
        new = self.commit('feature')
        bundle = self.tmp / 'bin' / 'bundle'
        bundle.write_text('''#!/bin/sh
echo "bundle $*" >> "$CALLS"
if [ "$1 $2 $3" = "exec rails db:migrate" ]; then
  [ "$(cat "$RUPERT_AUTODEPLOY_STATE/failed-sha")" = "$EXPECTED_SHA" ] || exit 42
fi
exit 0
''')
        bundle.chmod(0o755)
        result, _ = self.run_deploy(EXPECTED_SHA=new)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.tmp / 'state' / 'failed-sha').exists())

    def test_interrupted_install_on_target_is_not_reported_up_to_date(self):
        new = self.commit('feature')
        app = self.tmp / 'app'
        self.git('fetch', '-q', 'origin', 'main', cwd=app)
        self.git('checkout', '-q', '--detach', new, cwd=app)
        (self.tmp / 'state').mkdir()
        (self.tmp / 'state' / 'failed-sha').write_text(new + '\n')
        self.request_install(1_800_000_000)
        result, calls = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.status()['state'], 'recovery_required')
        self.assertIn('manual recovery', self.status()['message'])
        self.assertNotIn('db:migrate', calls)
        self.commit('newer feature')
        result, calls = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('manual recovery', self.status()['message'])
        self.assertNotIn('db:migrate', calls)

    def test_unhealthy_deploy_rolls_back(self):
        self.commit('feature')
        result, _ = self.run_deploy(HEALTH='502')
        self.assertEqual(result.returncode, 1)
        self.assertIn('no new migrations', result.stdout)
        self.assertIn('rollback failed or could not be verified', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertEqual(self.status('last-deploy.json')['state'], 'failed')
        self.assertIn('needs a human', self.status()['message'])

    def test_status_is_reported_to_the_app_and_readable_by_it(self):
        result, _ = self.run_deploy()
        self.assertEqual(result.returncode, 0)
        status = self.status()
        self.assertEqual((status['state'], status['current'], status['mode']), ('up_to_date', self.old, 'automatic'))
        self.assertFalse(status['install_requested'])
        self.assertEqual((self.tmp / 'state').stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.tmp / 'state' / 'status.json').stat().st_mode & 0o777, 0o644)

        self.set_checks(check_runs(('CI (sqlite3)', 'failure')))
        new = self.commit('feature')
        self.run_deploy()
        self.assertEqual((self.status()['state'], self.status()['target']), ('ci_failed', new))

        self.set_checks(GREEN)
        self.run_deploy()
        self.assertEqual(self.status()['state'], 'deployed')
        self.assertEqual((self.status('last-deploy.json')['state'], self.status('last-deploy.json')['target']), ('deployed', new))

    def test_dry_run_reports_nothing(self):
        self.commit('feature')
        self.run_deploy(DRY_RUN='1')
        self.assertFalse((self.tmp / 'state' / 'status.json').exists())

    def test_manual_mode_waits_for_a_request_then_installs_once(self):
        (self.inbox / 'manual').write_text('')
        new = self.commit('feature')
        result, calls = self.run_deploy()
        self.assertEqual(result.returncode, 0)
        self.assertIn('ready to install', result.stdout)
        self.assertNotIn('systemctl', calls)
        self.assertEqual((self.status()['state'], self.status()['mode']), ('ready', 'manual'))
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

        self.request_install(1_800_000_000)
        result, _ = self.run_deploy()
        self.assertIn(f'deployed {new[:8]}, healthy', result.stdout)
        self.assertFalse(self.status()['install_requested'])

        # The same request is spent: the next commit waits for a new one.
        self.commit('another')
        result, calls = self.run_deploy()
        self.assertIn('ready to install', result.stdout)
        self.assertNotIn('systemctl', calls)

    def test_request_waits_for_green_ci(self):
        (self.inbox / 'manual').write_text('')
        self.set_checks(check_runs(('Product site consistency', 'success')))
        new = self.commit('feature')
        self.request_install(1_800_000_000)
        self.run_deploy()
        self.assertEqual(self.status()['state'], 'waiting_ci')
        self.assertTrue(self.status()['install_requested'])

        self.set_checks(GREEN)
        result, _ = self.run_deploy()
        self.assertIn(f'deployed {new[:8]}, healthy', result.stdout)

    def test_cancel_during_ci_check_does_not_start_manual_install(self):
        (self.inbox / 'manual').write_text('')
        self.commit('feature')
        self.request_install(1_800_000_000)
        result, calls = self.run_deploy(CANCEL_DURING_CHECKS='1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('sqlite3', calls)
        self.assertNotIn('db:migrate', calls)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_switching_to_manual_during_ci_check_stops_automatic_install(self):
        self.commit('feature')
        result, calls = self.run_deploy(MANUAL_DURING_CHECKS='1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('sqlite3', calls)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_request_while_up_to_date_does_not_approve_a_later_commit(self):
        (self.inbox / 'manual').write_text('')
        self.request_install(1_800_000_000)
        self.run_deploy()
        self.commit('feature')
        result, calls = self.run_deploy()
        self.assertIn('ready to install', result.stdout)
        self.assertNotIn('systemctl', calls)

    def test_new_request_in_same_second_is_not_lost(self):
        (self.inbox / 'manual').write_text('')
        request = self.inbox / 'install-requested'
        request.write_text('first')
        first = 1_800_000_000_100_000_000
        os.utime(request, ns=(first, first))
        self.run_deploy()  # Up to date: consume the first request.
        new = self.commit('feature')
        request.write_text('second')
        second = first + 300_000_000
        os.utime(request, ns=(second, second))
        result, _ = self.run_deploy()
        self.assertIn(f'deployed {new[:8]}, healthy', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), new)

    def test_legacy_second_resolution_marker_does_not_replay_request(self):
        (self.inbox / 'manual').write_text('')
        self.commit('feature')
        request = self.inbox / 'install-requested'
        request.write_text('old request')
        os.utime(request, ns=(1_800_000_000_900_000_000, 1_800_000_000_900_000_000))
        (self.tmp / 'state').mkdir()
        (self.tmp / 'state' / 'request-handled').write_text('1800000000\n')
        result, calls = self.run_deploy()
        self.assertIn('manual mode waits for an install request', result.stdout)
        self.assertNotIn('sqlite3', calls)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_unwritable_request_receipt_prevents_install(self):
        (self.inbox / 'manual').write_text('')
        self.request_install(1_800_000_000)
        self.commit('feature')
        not_directory = self.tmp / 'not-a-directory'
        not_directory.write_text('x')
        result, calls = self.run_deploy(RUPERT_AUTODEPLOY_STATE=str(not_directory))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('sqlite3', calls)
        self.assertNotIn('db:migrate', calls)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_missing_state_directory_prevents_automatic_install(self):
        self.commit('feature')
        not_directory = self.tmp / 'not-a-directory'
        not_directory.write_text('x')
        result, calls = self.run_deploy(RUPERT_AUTODEPLOY_STATE=str(not_directory))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('sqlite3', calls)
        self.assertNotIn('db:migrate', calls)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_request_retries_a_failed_commit_once(self):
        new = self.commit('broken migration', path='web/db/migrate/20261020000000_broken.rb')
        self.run_deploy(MIGRATE_EXIT='1')
        self.assertEqual(self.status()['state'], 'failed')
        self.assertEqual(self.status('last-deploy.json')['state'], 'failed')

        self.request_install(1_800_000_000)
        result, _ = self.run_deploy()
        self.assertIn(f'deployed {new[:8]}, healthy', result.stdout)
        self.assertFalse((self.tmp / 'state' / 'failed-sha').exists())

    def test_failed_retry_is_not_repeated_by_the_same_request(self):
        new = self.commit('broken migration', path='web/db/migrate/20261020000000_broken.rb')
        self.run_deploy(MIGRATE_EXIT='1')
        self.request_install(1_800_000_000)
        self.run_deploy(MIGRATE_EXIT='1')
        result, calls = self.run_deploy(MIGRATE_EXIT='1')
        self.assertIn(f'{new[:8]} already failed', result.stdout)
        self.assertNotIn('systemctl', calls)

    def test_inbox_files_are_never_followed_or_changed(self):
        secret = self.tmp / 'secret'
        secret.write_text('do not read')
        (self.inbox / 'install-requested').symlink_to(secret)
        self.run_deploy()
        self.assertTrue((self.inbox / 'install-requested').is_symlink())
        self.assertEqual(secret.read_text(), 'do not read')
        self.assertNotIn('do not read', (self.tmp / 'state' / 'status.json').read_text())

    # --- Failures block promotion: anything but success on every required check ---

    def assert_not_deployed(self, state, word):
        result, calls = self.run_deploy()
        self.assertIn(f'is {word}, not deploying', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertNotIn('sqlite3', calls)
        self.assertNotIn('systemctl', calls)
        self.assertEqual(self.status()['state'], state)
        self.assertNotIn(self.status()['state'], ('deployed', 'deploying', 'ready'))
        self.assertEqual(self.receipts(), [])

    def test_every_non_success_conclusion_blocks_and_reports_red(self):
        self.commit('feature')
        for conclusion in ('skipped', 'neutral', 'cancelled', 'failure', 'timed_out', 'action_required', 'stale'):
            for name in REQUIRED:
                with self.subTest(check=name, conclusion=conclusion):
                    self.set_checks(check_runs(*[(n, conclusion if n == name else 'success') for n in REQUIRED]))
                    self.assert_not_deployed('ci_failed', 'red')

    def test_missing_required_check_blocks_and_waits(self):
        self.commit('feature')
        for name in REQUIRED:
            with self.subTest(missing=name):
                self.set_checks(check_runs(*[(n, 'success') for n in REQUIRED if n != name]))
                self.assert_not_deployed('waiting_ci', 'pending')
        with self.subTest(missing='all'):
            self.set_checks(check_runs())
            self.assert_not_deployed('waiting_ci', 'pending')

    def test_pending_required_check_blocks_and_waits(self):
        self.commit('feature')
        for status in ('queued', 'in_progress', 'waiting', 'requested', 'pending'):
            with self.subTest(status=status):
                self.set_checks(check_runs(*[(n, None, status) if n == 'CI (sqlite3)' else (n, 'success') for n in REQUIRED]))
                self.assert_not_deployed('waiting_ci', 'pending')

    def test_rerun_in_progress_after_a_pass_is_pending_not_green(self):
        self.commit('feature')
        self.set_checks(check_runs(*[(n, 'success') for n in REQUIRED], ('CI (sqlite3)', None, 'queued')))
        self.assert_not_deployed('waiting_ci', 'pending')

    def test_a_later_skipped_rerun_overrides_an_earlier_success(self):
        self.commit('feature')
        self.set_checks(check_runs(*[(n, 'success') for n in REQUIRED], ('Product site consistency', 'skipped')))
        self.assert_not_deployed('ci_failed', 'red')

    def test_unreadable_checks_are_unknown_not_green(self):
        self.commit('feature')
        self.checks.write_text('not json')
        self.assert_not_deployed('waiting_ci', 'unknown')

    def test_skipped_cancelled_or_missing_mobile_validate_blocks(self):
        mobile = self.commit('mobile change', path='mobile/src/task.js')
        for runs, state, word in [((('validate', 'skipped'),), 'ci_failed', 'red'),
                                  ((('validate', 'neutral'),), 'ci_failed', 'red'),
                                  ((('validate', 'cancelled'),), 'ci_failed', 'red'),
                                  ((('validate', None, 'queued'),), 'waiting_ci', 'pending'),
                                  ((), 'waiting_ci', 'pending')]:
            with self.subTest(validate=runs):
                self.set_checks(check_runs(*[(n, 'success') for n in REQUIRED], *runs), sha=mobile)
                self.assert_not_deployed(state, word)

    # --- Release receipts ---

    def receipts(self):
        directory = self.tmp / 'state' / 'receipts'
        return sorted(p.name for p in directory.glob('*.json')) if directory.exists() else []

    def receipt(self, name):
        return json.loads((self.tmp / 'state' / 'receipts' / name).read_text())

    def test_successful_deploy_writes_an_exact_sha_receipt(self):
        migration = 'web/db/migrate/20261025000000_add_thing.rb'
        new = self.commit('add thing', path=migration)
        result, _ = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.receipts(), [f'{new}.json'])
        path = self.tmp / 'state' / 'receipts' / f'{new}.json'
        self.assertEqual(path.stat().st_mode & 0o777, 0o644)
        self.assertEqual((path.parent).stat().st_mode & 0o777, 0o755)
        receipt = self.receipt(f'{new}.json')

        self.assertEqual((receipt['result'], receipt['deployed_sha'], receipt['previous_sha'], receipt['running_sha']),
                         ('deployed', new, self.old, new))
        self.assertIsNone(receipt['failed_stage'])
        checks = receipt['required_checks']
        self.assertEqual((checks['sha'], checks['verdict']), (new, 'green'))
        self.assertEqual([c['name'] for c in checks['checks']], list(REQUIRED))
        for check in checks['checks']:
            self.assertEqual(check['conclusion'], 'success')
            self.assertEqual(check['url'], f"https://github.com/techmore/rupert/runs/{check['id']}")
        self.assertIsNone(receipt['mobile_checks'])
        self.assertEqual(receipt['migrations'], {'new': [migration], 'db_migrate': 'succeeded', 'reverted': False})
        backup = Path(receipt['backup']['path'])
        self.assertTrue(backup.is_file())
        self.assertEqual(backup.parent, self.tmp / 'backups')
        self.assertEqual(receipt['backup']['sha256'], hashlib.sha256(backup.read_bytes()).hexdigest())
        self.assertEqual((receipt['health']['result'], receipt['health']['last_http_code']), ('passed', '200'))
        smoke = receipt['smoke']
        self.assertEqual((smoke['result'], smoke['page'], smoke['page_http_code'], smoke['served_build']),
                         ('passed', '/login', '200', new))
        paths = [a['path'] for a in smoke['assets']]
        self.assertEqual(paths, ['/api/assets/tailwind-' + 'a' * 64 + '.css', '/api/assets/application-' + 'b' * 64 + '.js'])
        for asset in smoke['assets']:
            self.assertEqual(asset['http_code'], '200')
            self.assertEqual(asset['sha256'], hashlib.sha256(f"compiled localhost:3000{asset['path']}".encode()).hexdigest())
        self.assertEqual(receipt['rollback'], 'not_needed')
        self.assertLessEqual(receipt['started_at'][:19], receipt['finished_at'][:19])
        self.assertEqual(self.status('last-deploy.json')['receipt'], str(path))
        self.assertEqual(self.status()['receipt'], str(path))

    def test_receipt_never_contains_secrets(self):
        self.commit('feature')
        self.run_deploy()
        self.commit('broken', path='web/db/migrate/20261020000000_broken.rb')
        self.run_deploy(MIGRATE_EXIT='1')
        self.assertEqual(len(self.receipts()), 2)
        for name in self.receipts():
            text = (self.tmp / 'state' / 'receipts' / name).read_text()
            self.assertNotIn('do-not-leak-this', text)
            self.assertNotIn('SECRET_KEY_BASE', text)

    def test_mobile_deploy_receipt_records_the_validate_sha(self):
        mobile = self.commit('mobile change', path='mobile/src/task.js')
        later = self.commit('web change after it')
        self.set_checks(GREEN, sha=later)
        self.set_checks(check_runs(('validate', 'success')), sha=mobile)
        self.run_deploy()
        receipt = self.receipt(f'{later}.json')
        self.assertEqual((receipt['mobile_checks']['sha'], receipt['mobile_checks']['verdict']), (mobile, 'green'))
        self.assertEqual([c['name'] for c in receipt['mobile_checks']['checks']], ['validate'])
        self.assertEqual(receipt['required_checks']['sha'], later)

    def assert_failure_receipt(self, new, stage, rollback):
        names = self.receipts()
        self.assertNotIn(f'{new}.json', names)
        self.assertEqual(len(names), 1, names)
        self.assertTrue(names[0].startswith(f'{new}.failed-'), names)
        receipt = self.receipt(names[0])
        self.assertEqual((receipt['result'], receipt['deployed_sha'], receipt['target_sha'], receipt['running_sha']),
                         ('failed', None, new, self.old if rollback == 'healthy' else None))
        self.assertEqual((receipt['failed_stage'], receipt['rollback']), (stage, rollback))
        self.assertEqual(self.status('last-deploy.json')['receipt'], str(self.tmp / 'state' / 'receipts' / names[0]))
        return receipt

    def test_failed_migration_writes_a_failure_receipt(self):
        migration = 'web/db/migrate/20261020000000_broken.rb'
        new = self.commit('broken migration', path=migration)
        self.run_deploy(MIGRATE_EXIT='1')
        receipt = self.assert_failure_receipt(new, 'db_migrate', 'healthy')
        self.assertEqual(receipt['migrations'], {'new': [migration], 'db_migrate': 'failed', 'reverted': False})
        self.assertTrue(receipt['backup']['sha256'])
        self.assertEqual(receipt['health']['result'], 'not_run')
        self.assertIsNone(receipt['smoke'])

    def test_unhealthy_deploy_writes_a_failure_receipt(self):
        new = self.commit('feature')
        self.run_deploy(HEALTH='502')
        receipt = self.assert_failure_receipt(new, 'health', 'unhealthy')
        self.assertEqual(receipt['health'], {'url': '/up', 'host': 'herbalhealers.rupertpos.com', 'result': 'failed',
                                             'last_http_code': '502', 'attempts': 15})
        self.assertEqual(receipt['migrations']['db_migrate'], 'succeeded')

    def test_missing_compiled_asset_rolls_back_with_a_failure_receipt(self):
        new = self.commit('feature')
        result, _ = self.run_deploy(BROKEN_ASSET='tailwind')
        self.assertEqual(result.returncode, 1)
        self.assertIn('failed at asset_smoke', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertEqual((self.tmp / 'state' / 'failed-sha').read_text().strip(), new)
        receipt = self.assert_failure_receipt(new, 'asset_smoke', 'healthy')
        self.assertEqual(receipt['health']['result'], 'passed')
        self.assertEqual(receipt['smoke']['result'], 'failed')
        css = receipt['smoke']['assets'][0]
        self.assertEqual((css['http_code'], css['sha256'], css['ok']), ('404', None, False))

    def test_wrong_served_build_or_no_assets_fails_the_smoke_check(self):
        for env in ({'SERVED_BUILD': 'f' * 40}, {'PAGE': '<html>no assets</html>'}, {'PAGE_CODE': '500'}):
            with self.subTest(env=env):
                shutil.rmtree(self.tmp / 'state', ignore_errors=True)
                new = self.commit(f'feature {env}')
                result, _ = self.run_deploy(**env)
                self.assertIn('failed at asset_smoke', result.stdout)
                self.assertEqual(self.head(self.tmp / 'app'), self.old)
                rollback = 'unhealthy' if 'SERVED_BUILD' in env or 'PAGE_CODE' in env else 'healthy'
                self.assert_failure_receipt(new, 'asset_smoke', rollback)

    def test_backup_failure_writes_a_failure_receipt(self):
        new = self.commit('feature')
        self.run_deploy(BACKUP_EXIT='1')
        names = self.receipts()
        self.assertEqual(len(names), 1)
        receipt = self.receipt(names[0])
        self.assertEqual((receipt['result'], receipt['failed_stage'], receipt['target_sha']), ('failed', 'backup', new))
        self.assertIsNone(receipt['backup']['path'])

    def test_retry_after_failure_keeps_both_receipts(self):
        new = self.commit('broken migration', path='web/db/migrate/20261020000000_broken.rb')
        self.run_deploy(MIGRATE_EXIT='1')
        self.request_install(1_800_000_000)
        self.run_deploy()
        names = self.receipts()
        self.assertIn(f'{new}.json', names)
        self.assertEqual(len(names), 2)
        self.assertEqual(self.receipt(f'{new}.json')['result'], 'deployed')
        self.assertTrue(self.receipt(f'{new}.json')['install_requested'])

    def test_failed_retries_in_the_same_second_keep_both_receipts(self):
        new = self.commit('broken migration', path='web/db/migrate/20261020000000_broken.rb')
        self.run_deploy(MIGRATE_EXIT='1', FIXED_DATE='20261026T120000Z')
        self.request_install(1_800_000_000)
        self.run_deploy(MIGRATE_EXIT='1', FIXED_DATE='20261026T120000Z')
        names = self.receipts()
        self.assertEqual(len(names), 2, names)
        self.assertTrue(all(name.startswith(f'{new}.failed-') for name in names))
        backups = [self.receipt(name)['backup']['path'] for name in names]
        self.assertEqual(len(set(backups)), 2)
        self.assertTrue(all(Path(path).is_file() for path in backups))

    def test_no_receipt_without_an_install_attempt(self):
        self.run_deploy()
        self.commit('feature')
        self.run_deploy(DRY_RUN='1')
        (self.inbox / 'manual').write_text('')
        self.run_deploy()
        self.assertEqual(self.receipts(), [])

    def test_printer_shows_the_latest_receipt_read_only(self):
        env = {**os.environ, 'RUPERT_AUTODEPLOY_STATE': str(self.tmp / 'state')}
        printed = subprocess.run(['python3', str(PRINTER)], env=env, capture_output=True, text=True)
        self.assertEqual(printed.returncode, 1)
        self.assertIn('no deploy receipt', printed.stderr)

        first = self.commit('feature')
        self.run_deploy()
        second = self.commit('broken', path='web/db/migrate/20261020000000_broken.rb')
        self.run_deploy(MIGRATE_EXIT='1')
        before = {n: (self.tmp / 'state' / 'receipts' / n).read_text() for n in self.receipts()}

        printed = subprocess.run(['python3', str(PRINTER)], env=env, capture_output=True, text=True)
        self.assertEqual(printed.returncode, 0, printed.stderr)
        self.assertIn(f'FAILED  {second[:12]}', printed.stdout)
        self.assertIn('failed at: db_migrate', printed.stdout)

        printed = subprocess.run(['python3', str(PRINTER), first[:8], '--json'], env=env, capture_output=True, text=True)
        self.assertEqual(json.loads(printed.stdout)['deployed_sha'], first)
        printed = subprocess.run(['python3', str(PRINTER), first[:8]], env=env, capture_output=True, text=True)
        self.assertIn('CI (sqlite3): success (id 1000) https://github.com/techmore/rupert/runs/1000', printed.stdout)
        self.assertIn('smoke:     passed', printed.stdout)

        printed = subprocess.run(['python3', str(PRINTER), '--list'], env=env, capture_output=True, text=True)
        self.assertEqual(len(printed.stdout.splitlines()), 2)
        self.assertEqual(before, {n: (self.tmp / 'state' / 'receipts' / n).read_text() for n in self.receipts()})


if __name__ == '__main__':
    unittest.main()
