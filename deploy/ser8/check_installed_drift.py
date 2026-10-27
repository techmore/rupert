#!/usr/bin/env python3
"""Report SER8 scripts and units whose installed copy differs from this checkout.

The updaters, backup scripts and units are hand-copied out of the repository (the
autodeploy does not refresh them), so an installed copy can silently keep running
older logic than the one reviewed and merged. Run from the SER8 host, in a
checkout of the commit that production runs:

    python3 deploy/ser8/check_installed_drift.py

Read-only. Exit 0: every installed file matches. Exit 1: at least one differs
or is missing. Exit 2: the container could not be read.
"""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
DEPLOY = HERE.parent

# (scope, repository file relative to deploy/, installed path)
# `~` expands to the host user's home; container paths are read with `incus exec`.
MANIFEST = (
    ('container', 'ser8/rupert-autodeploy.sh', '/usr/local/sbin/rupert-autodeploy.sh'),
    ('container', 'ser8/rupert-backup-frequent.sh', '/usr/local/sbin/rupert-backup-frequent.sh'),
    ('container', 'ser8/rupert-deploy-receipt', '/usr/local/bin/rupert-deploy-receipt'),
    ('container', 'ser8/rupert-logs', '/usr/local/bin/rupert-logs'),
    ('container', 'ser8/journald-rupert.conf', '/etc/systemd/journald.conf.d/rupert.conf'),
    ('container', 'ser8/rupert-autodeploy.service', '/etc/systemd/system/rupert-autodeploy.service'),
    ('container', 'ser8/rupert-autodeploy.timer', '/etc/systemd/system/rupert-autodeploy.timer'),
    ('container', 'ser8/rupert-autodeploy.path', '/etc/systemd/system/rupert-autodeploy.path'),
    ('container', 'ser8/rupert-backup-frequent.service', '/etc/systemd/system/rupert-backup-frequent.service'),
    ('container', 'ser8/rupert-backup-frequent.timer', '/etc/systemd/system/rupert-backup-frequent.timer'),
    ('container', 'rupert-backup-ser8.service', '/etc/systemd/system/rupert-backup.service'),
    ('container', 'rupert-backup-ser8.timer', '/etc/systemd/system/rupert-backup.timer'),
    ('container', 'rupert-jobs-ser8.service', '/etc/systemd/system/rupert-jobs.service'),
    ('container', 'rupert-web-ser8.service', '/etc/systemd/system/rupert-web.service'),
    ('host', 'ser8/rupert-sync-watch.sh', '~/.local/bin/rupert-sync-watch.sh'),
    ('host', 'ser8/rupert-host-backup-pull.sh', '~/.local/bin/rupert-backup'),
    ('host', 'ser8/rupert-backup-verify.sh', '~/.local/bin/rupert-backup-verify.sh'),
    ('host', 'ser8/rupert-sync-watch.service', '~/.config/systemd/user/rupert-sync-watch.service'),
    ('host', 'ser8/rupert-sync-watch.timer', '~/.config/systemd/user/rupert-sync-watch.timer'),
    ('host', 'ser8/rupert-offhost-backup.service', '~/.config/systemd/user/rupert-offhost-backup.service'),
    ('host', 'ser8/rupert-offhost-backup.timer', '~/.config/systemd/user/rupert-offhost-backup.timer'),
    ('host', 'ser8/rupert-backup-verify.service', '~/.config/systemd/user/rupert-backup-verify.service'),
    ('host', 'ser8/rupert-backup-verify.timer', '~/.config/systemd/user/rupert-backup-verify.timer'),
)


class ContainerError(RuntimeError):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_host(path):
    try:
        return Path(os.path.expanduser(path)).read_bytes()
    except FileNotFoundError:
        return None


def make_container_reader(instance):
    def read(path):
        result = subprocess.run(['incus', 'exec', instance, '--', 'cat', path], capture_output=True)
        if result.returncode == 0:
            return result.stdout
        if b'No such file' in result.stderr:
            return None
        raise ContainerError(result.stderr.decode(errors='replace').strip() or f'incus exec failed for {path}')
    return read


def compare(manifest, readers, deploy=DEPLOY):
    """Yield (status, scope, installed_path) where status is same, drift or missing."""
    for scope, repo_file, installed in manifest:
        expected = (deploy / repo_file).read_bytes()
        actual = readers[scope](installed)
        if actual is None:
            yield 'missing', scope, installed
        elif digest(actual) == digest(expected):
            yield 'same', scope, installed
        else:
            yield 'drift', scope, installed


def main(argv=None, readers=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--instance', default=os.environ.get('INSTANCE', 'rupert'), help='Incus container name')
    parser.add_argument('--quiet', action='store_true', help='print only files that differ')
    args = parser.parse_args(argv)
    readers = readers or {'host': read_host, 'container': make_container_reader(args.instance)}
    try:
        results = list(compare(MANIFEST, readers))
    except ContainerError as error:
        print(f'cannot read container {args.instance}: {error}', file=sys.stderr)
        return 2
    bad = 0
    for status, scope, installed in results:
        if status != 'same':
            bad += 1
        if status != 'same' or not args.quiet:
            print(f'{status.upper():8} {scope:9} {installed}')
    print(f'{bad} of {len(results)} installed files differ from this checkout' if bad else f'all {len(results)} installed files match')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
