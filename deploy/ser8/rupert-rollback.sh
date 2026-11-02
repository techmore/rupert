#!/usr/bin/env bash
# One-command rollback of /opt/rupert. Run as root INSIDE the SER8 `rupert` Incus container.
#
#   rupert-rollback                      code back to the commit before the last healthy auto-deploy
#   rupert-rollback <sha>                code back to <sha>
#   rupert-rollback <sha> --restore-db <file.sqlite3>
#                                        also replace the live database with that backup (for example the
#                                        pre-deploy backup named in the deploy receipt)
#
# It first pauses the auto-updater ($STATE/paused), or the next poll would move the checkout forward again,
# then takes the updater's lock, checks out the commit, rebuilds, restarts and verifies that /up answers and
# that /login serves the requested build. It stays paused afterwards; `rm /var/lib/rupert-autodeploy/paused`
# resumes automatic updates (do that once main has a fix).
#
# --restore-db discards every write made since that backup. It stops web and jobs, keeps the current database
# as pre-rollback-<time>-<sha>.sqlite3 in the backup directory, then restores. Use it only when the code
# rollback alone is not enough (a migration the old code cannot run with), and only with the owner's approval
# of the data loss (docs/ops/release-process.md).
# The RUPERT_AUTODEPLOY_* variables are shared with rupert-autodeploy.sh and exist for the tests.
set -uo pipefail
umask 022
APP=${RUPERT_AUTODEPLOY_APP:-/opt/rupert}
HOST=herbalhealers.rupertpos.com
BACKUPS=${RUPERT_AUTODEPLOY_BACKUPS:-/var/backups/rupert-autodeploy}
STATE=${RUPERT_AUTODEPLOY_STATE:-/var/lib/rupert-autodeploy}
LOCK=${RUPERT_AUTODEPLOY_LOCK:-/run/rupert-autodeploy.lock}
ENV_FILE=${RUPERT_AUTODEPLOY_ENV_FILE:-/etc/rupert.env}
SMOKE_PATH=${RUPERT_AUTODEPLOY_SMOKE_PATH:-/login}
export RAILS_ENV=production PATH=${RUPERT_AUTODEPLOY_PATH:-/opt/rbenv/versions/4.0.9/bin:/usr/local/bin:/usr/bin:/bin}

log() { echo "rollback: $*"; mkdir -p "$STATE" && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$STATE/rollback.log"; }
die() { log "FAILED: $*"; exit 1; }
usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

target_arg="" restore=""
while [ $# -gt 0 ]; do
  case "$1" in
    --restore-db) [ $# -ge 2 ] || usage; restore=$2; shift 2 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [ -z "$target_arg" ] || usage; target_arg=$1; shift ;;
  esac
done

exec 9>"$LOCK"
flock -w 900 9 || die "the updater lock is still held after 15 minutes"
cd "$APP" || die "no checkout at $APP"
[ -z "$(git status --porcelain)" ] || die "checkout is dirty; resolve it by hand first"
CUR=$(git rev-parse HEAD)

if [ -z "$target_arg" ]; then
  # The newest healthy auto-deploy names the commit it replaced.
  target_arg=$(python3 - "$STATE/last-deploy.json" "$CUR" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(0)
if d.get('state') == 'deployed' and d.get('current') == sys.argv[2] and d.get('previous'):
    print(d['previous'])
PY
)
  [ -n "$target_arg" ] || die "no healthy auto-deploy of the current checkout is recorded; name the commit to roll back to"
fi
TARGET=$(git rev-parse --verify --quiet "$target_arg^{commit}") || die "unknown commit $target_arg"

db_path=""
if [ -n "$restore" ]; then
  [ -f "$restore" ] || die "no backup file $restore"
  [ "$(sqlite3 -readonly "$restore" 'PRAGMA quick_check;' 2>/dev/null)" = ok ] || die "$restore fails its integrity check"
  # shellcheck source=/dev/null # the env file is host config, not in the repo
  db_path=$(cd "$APP/web" && set -a && . "$ENV_FILE" && printf '%s' "${RUPERT_SQLITE_DATABASE_PRODUCTION-storage/production.sqlite3}") || db_path=""
  case "$db_path" in /*) ;; '') die "cannot resolve the production database path" ;; *) db_path="$APP/web/$db_path" ;; esac
  [ -f "$db_path" ] || die "no production database at $db_path"
elif [ "$TARGET" = "$CUR" ]; then
  log "already at ${CUR:0:8}; nothing to do"
  exit 0
fi

# Pause before changing anything, so a failed rollback is not overwritten by the next poll either.
{ mkdir -p "$STATE" && chmod 755 "$STATE"; } || die "cannot write $STATE"
printf 'rollback from %s to %s at %s\n' "${CUR:0:8}" "${TARGET:0:8}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE/paused" \
  || die "could not pause the auto-updater"
log "auto-update paused; rolling back ${CUR:0:8} -> ${TARGET:0:8}${restore:+ with database $restore}"

# shellcheck source=/dev/null # the env file is host config, not in the repo
in_web() { ( cd "$APP/web" && set -a && . "$ENV_FILE" && set +a && "$@" ); }
fix_owner() { chown -R rupert:rupert web/storage web/public web/tmp web/log 2>/dev/null; return 0; }
# Processes (any user) that still hold the database or its WAL open.
db_holders() {
  python3 - "$1" <<'PY'
import os, sys
names = {os.path.realpath(sys.argv[1] + s) for s in ('', '-wal', '-shm')}
for pid in filter(str.isdigit, os.listdir('/proc')):
    try:
        if any(os.path.realpath(os.path.join('/proc', pid, 'fd', fd)) in names for fd in os.listdir(f'/proc/{pid}/fd')):
            print(pid)
    except OSError:
        pass
PY
}

if [ -n "$restore" ]; then
  systemctl stop rupert-web rupert-jobs || die "could not stop rupert-web/rupert-jobs"
  for _ in $(seq 1 30); do [ -z "$(db_holders "$db_path")" ] && break; sleep 1; done
  if [ -n "$(db_holders "$db_path")" ]; then
    systemctl start rupert-web rupert-jobs
    die "processes $(db_holders "$db_path" | tr '\n' ' ')still hold the database; nothing was restored or checked out"
  fi
  mkdir -p "$BACKUPS" && chmod 700 "$BACKUPS"
  keep="$BACKUPS/pre-rollback-$(date +%Y%m%d-%H%M%S)-${CUR:0:8}.sqlite3"
  ( umask 077; sqlite3 "$db_path" ".backup '$keep'" ) && [ "$(sqlite3 -readonly "$keep" 'PRAGMA quick_check;')" = ok ] \
    || { systemctl start rupert-web rupert-jobs; die "could not save the current database; nothing was restored"; }
  log "current database saved to $keep"
  sqlite3 "$db_path" ".restore '$restore'" && [ "$(sqlite3 "$db_path" 'PRAGMA quick_check;')" = ok ] \
    || die "database restore failed; the database before this attempt is $keep (services are stopped)"
  chown rupert:rupert "$db_path" "$db_path-wal" "$db_path-shm" 2>/dev/null
  log "database restored from $restore"
fi

git checkout -q --detach "$TARGET" || die "checkout of ${TARGET:0:8} failed"
in_web bundle install --quiet || die "bundle install failed at ${TARGET:0:8}"
in_web bundle exec rails assets:precompile >/dev/null || die "assets:precompile failed at ${TARGET:0:8}"
fix_owner
systemctl restart rupert-web rupert-jobs || die "restart failed"

healthy=0
for _ in $(seq 1 30); do
  code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -H "Host: $HOST" -H 'X-Forwarded-Proto: https' localhost:3000/up)
  if [ "$code" = 200 ] && systemctl is-active --quiet rupert-web && systemctl is-active --quiet rupert-jobs; then healthy=1; break; fi
  sleep 2
done
[ "$healthy" = 1 ] || die "${TARGET:0:8} is checked out but /up is not healthy (last HTTP ${code:-none}); the auto-updater stays paused"
headers=$(mktemp) || die "mktemp failed"
trap 'rm -f "$headers"' EXIT
curl -s --max-time 10 -D "$headers" -o /dev/null -H "Host: $HOST" -H 'X-Forwarded-Proto: https' "localhost:3000$SMOKE_PATH" >/dev/null
build=$(tr -d '\r' < "$headers" | awk -F': ' 'tolower($1)=="x-rupert-build"{print $2}' | tail -n 1)
[ "$build" = "$TARGET" ] || die "${TARGET:0:8} is checked out but $SMOKE_PATH serves build '${build:-none}'"
log "rolled back to ${TARGET:0:8}, healthy and serving that build; auto-update stays paused (rm $STATE/paused to resume)"
