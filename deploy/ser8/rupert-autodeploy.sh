#!/usr/bin/env bash
# Auto-deploy origin/main to /opt/rupert when app CI is green. Fast-forward only,
# clean checkout only, DB backup first, health check, code rollback on failure.
# A commit that failed to deploy is remembered and not retried until main moves.
# Every install attempt leaves a release receipt in $STATE/receipts (see
# deploy/ser8/README.md): <sha>.json after a healthy deploy, <sha>.failed-<time>.json
# after a failed or rolled-back one. `rupert-deploy-receipt` prints the latest.
# DRY_RUN=1 reports what it would do without changing anything.
# The RUPERT_AUTODEPLOY_* variables exist for the tests in deploy/ser8/tests.
set -uo pipefail
# Normal umask: git checkout and bundle install run as root here, and the app
# runs as the rupert user, so code and gems must stay world-readable. (umask
# 077 made Gemfile.lock and a new gem unreadable and took the site down on
# 2026-10-21.) Backups get a private umask of their own below.
umask 022
APP=${RUPERT_AUTODEPLOY_APP:-/opt/rupert}
REPO=techmore/rupert
HOST=herbalhealers.rupertpos.com
BACKUPS=${RUPERT_AUTODEPLOY_BACKUPS:-/var/backups/rupert-autodeploy}
STATE=${RUPERT_AUTODEPLOY_STATE:-/var/lib/rupert-autodeploy}
LOCK=${RUPERT_AUTODEPLOY_LOCK:-/run/rupert-autodeploy.lock}
ENV_FILE=${RUPERT_AUTODEPLOY_ENV_FILE:-/etc/rupert.env}
# A page that renders the application layout without signing in. The deploy is
# healthy only when it serves the new build and the CSS/JS it links to.
SMOKE_PATH=${RUPERT_AUTODEPLOY_SMOKE_PATH:-/login}
# Rupert (System → Updates) talks to this script through files only. It reads
# status.json and last-deploy.json from $STATE (root-owned, world-readable), and
# the app user owns $INBOX, where `manual` means "install only when asked" and
# touching `install-requested` asks for an install now (and overrides a
# failed-sha). Only the presence and mtime of those two files are read; nothing
# in $INBOX is ever opened, written or run by root.
INBOX=${RUPERT_AUTODEPLOY_INBOX:-$APP/web/storage/autodeploy}
export RAILS_ENV=production PATH=${RUPERT_AUTODEPLOY_PATH:-/opt/rbenv/versions/4.0.9/bin:/usr/local/bin:/usr/bin:/bin}
log() { echo "autodeploy: $*"; }

# write_json FILE STATE MESSAGE: atomic, readable by the app user. No-op on a dry run.
write_json() {
  [ "${DRY_RUN:-0}" = 1 ] && return 0
  mkdir -p "$STATE" && chmod 755 "$STATE"
  python3 - "$STATE/$1" "$2" "$3" "${CUR:-}" "${NEW:-}" "$mode" "$requested" "${RECEIPT:-}" <<'PY' || log "could not write $1"
import datetime, json, os, sys
path, state, message, current, target, mode, requested, receipt = sys.argv[1:]
body = {'state': state, 'message': message, 'current': current, 'target': target, 'mode': mode,
        'install_requested': requested == '1',
        'at': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')}
if receipt:
    body['receipt'] = receipt
with open(path + '.tmp', 'w') as f:
    json.dump(body, f)
os.chmod(path + '.tmp', 0o644)
os.replace(path + '.tmp', path)
PY
}
# report STATE MESSAGE: log it and tell the app.
report() { log "$2"; write_json status.json "$1" "$2"; }
# The request was acted on (installed, failed or nothing to install): forget it.
handle_request() {
  [ "$requested" = 1 ] && [ "${DRY_RUN:-0}" != 1 ] && { mkdir -p "$STATE"; echo "$requested_at" > "$STATE/request-handled"; }
  requested=0
}

exec 9>"$LOCK"
flock -n 9 || { log "another deploy is running"; exit 0; }

mode=automatic; [ -e "$INBOX/manual" ] && mode=manual
requested_at=$(stat -c %Y "$INBOX/install-requested" 2>/dev/null) || requested_at=0
handled_at=$(cat "$STATE/request-handled" 2>/dev/null); [[ $handled_at =~ ^[0-9]+$ ]] || handled_at=0
requested=0; [ "$requested_at" -gt "$handled_at" ] && requested=1

# Scratch space for this run's check-run and smoke evidence.
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

cd "$APP" || exit 1
if [ -n "$(git status --porcelain)" ]; then report blocked "checkout is dirty, skipping"; exit 0; fi
git fetch -q origin main || { report blocked "fetch failed"; exit 0; }
# The build records release totals from full history (NightlyRelease refuses a
# shallow checkout), so a shallow /opt/rupert would fail every deploy and roll back.
if [ "${DRY_RUN:-0}" != 1 ] && [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  git fetch -q --unshallow origin main || { report blocked "could not fetch full git history"; exit 0; }
fi
CUR=$(git rev-parse HEAD); NEW=$(git rev-parse origin/main)
[ "$CUR" = "$NEW" ] && { handle_request; report up_to_date "up to date at ${CUR:0:8}"; exit 0; }
git merge-base --is-ancestor "$CUR" "$NEW" || { report blocked "origin/main is not a fast-forward of ${CUR:0:8}, skipping"; exit 0; }
if [ "$requested" = 0 ] && [ "$(cat "$STATE/failed-sha" 2>/dev/null)" = "$NEW" ]; then
  report failed "${NEW:0:8} already failed to deploy, waiting for a newer commit (rm $STATE/failed-sha or request an install to retry)"; exit 0
fi

# Integrated main commits must pass all three source checks before deployment.
# CLA is a PR-only check. Re-runs leave earlier check runs in the list, so only
# the latest check run by ID for each required name counts. Missing, skipped or
# pending checks never pass the gate.
# A mobile change needs a green exact-SHA `validate` on the newest commit in
# CUR..NEW that touched mobile paths. That workflow only runs on commits that
# change those paths, so it is never required on a later, unrelated commit.
mobile_sha=$(git log -1 --format=%H "$CUR..$NEW" -- mobile bin/check-mobile-sdk.mjs .github/workflows/employee-mobile.yml)
# Only success is green. A completed run with any other conclusion (failure,
# skipped, neutral, cancelled, timed_out, action_required, stale) is red; a
# missing or unfinished one is pending; an unreadable answer is unknown.
gate() { # gate <sha> <comma-separated required check names> <evidence file> -> green|red|pending
  curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$REPO/commits/$1/check-runs?per_page=100" | python3 -c '
import json, sys
required, evidence, sha = sys.argv[1].split(","), sys.argv[2], sys.argv[3]
latest = {}
for r in json.load(sys.stdin)["check_runs"]:
    if r["name"] in required and r["id"] > latest.get(r["name"], {"id": -1})["id"]:
        latest[r["name"]] = r
if any(r.get("status") == "completed" and r.get("conclusion") != "success" for r in latest.values()): verdict = "red"
elif all(name in latest and latest[name].get("status") == "completed" and latest[name].get("conclusion") == "success" for name in required): verdict = "green"
else: verdict = "pending"
# The exact check runs the decision rested on, for the release receipt.
checks = [{"name": name, "id": latest.get(name, {}).get("id"), "status": latest.get(name, {}).get("status", "missing"),
           "conclusion": latest.get(name, {}).get("conclusion"), "url": latest.get(name, {}).get("html_url"),
           "completed_at": latest.get(name, {}).get("completed_at")} for name in required]
with open(evidence, "w") as f:
    json.dump({"sha": sha, "verdict": verdict, "checks": checks}, f)
print(verdict)' "$2" "$3" "$1"
}
ci=$(gate "$NEW" "CI (sqlite3),Product site consistency,Dependency and static scan" "$WORK/checks-main.json") || ci=unknown
gated=$NEW
if [ "$ci" = green ] && [ -n "$mobile_sha" ]; then
  ci=$(gate "$mobile_sha" validate "$WORK/checks-mobile.json") || ci=unknown
  gated=$mobile_sha
fi
case "$ci" in
  green) ;;
  red) report ci_failed "CI for ${gated:0:8} is red, not deploying ${NEW:0:8}"; exit 0 ;;
  *) report waiting_ci "CI for ${gated:0:8} is $ci, not deploying ${NEW:0:8} yet"; exit 0 ;;
esac

migration_files=$(git diff --name-only --diff-filter=A "$CUR" "$NEW" -- web/db/migrate)
migrations=$(printf '%s' "$migration_files" | grep -c .)
if [ "$mode" = manual ] && [ "$requested" = 0 ]; then
  report ready "${NEW:0:8} is ready to install ($migrations new migration(s)); manual mode waits for an install request"; exit 0
fi
log "deploying ${CUR:0:8} -> ${NEW:0:8} ($migrations new migration(s))"
[ "${DRY_RUN:-0}" = 1 ] && { log "dry run, stopping"; exit 0; }
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
backup=""; stage=backup; migrate_ran=0; health_result=not_run; health_code=""; health_attempts=0
rollback_result=not_needed; RECEIPT=""
# write_receipt RESULT MESSAGE: the durable record of this install attempt. It
# holds commit IDs, check-run IDs/URLs, file names, checksums and HTTP results
# only; nothing from $ENV_FILE, the database or the request inbox goes in it.
write_receipt() {
  local dir="$STATE/receipts" name
  mkdir -p "$dir" && chmod 755 "$dir"
  if [ "$1" = deployed ]; then name="$NEW.json"; else name="$NEW.failed-$(date -u +%Y%m%dT%H%M%SZ).json"; fi
  RECEIPT="$dir/$name"
  R_RESULT=$1 R_MESSAGE=$2 R_CUR=$CUR R_NEW=$NEW R_MOBILE=$mobile_sha R_MODE=$mode R_REQUESTED=$install_request \
  R_STARTED=$started_at R_STAGE=$stage R_MIGRATIONS=$migration_files R_MIGRATE_RAN=$migrate_ran R_BACKUP=$backup \
  R_HEALTH=$health_result R_HEALTH_CODE=$health_code R_HEALTH_ATTEMPTS=$health_attempts R_ROLLBACK=$rollback_result \
  R_WORK=$WORK R_HOST=$HOST R_SMOKE_PATH=$SMOKE_PATH python3 - "$RECEIPT" <<'PY' || log "could not write receipt $RECEIPT"
import datetime, hashlib, json, os, sys
e = os.environ
def load(name):
    try:
        with open(os.path.join(e['R_WORK'], name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None
backup = e['R_BACKUP']
digest = None
if backup and os.path.isfile(backup):
    h = hashlib.sha256()
    with open(backup, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    digest = h.hexdigest()
body = {
    'schema': 1,
    'result': e['R_RESULT'],
    'message': e['R_MESSAGE'],
    'deployed_sha': e['R_NEW'] if e['R_RESULT'] == 'deployed' else None,
    'target_sha': e['R_NEW'],
    'previous_sha': e['R_CUR'],
    'running_sha': e['R_NEW'] if e['R_RESULT'] == 'deployed' else e['R_CUR'],
    'mode': e['R_MODE'],
    'install_requested': e['R_REQUESTED'] == '1',
    'failed_stage': None if e['R_RESULT'] == 'deployed' else e['R_STAGE'],
    'required_checks': load('checks-main.json'),
    'mobile_checks': load('checks-mobile.json') if e['R_MOBILE'] else None,
    'migrations': {'new': [m for m in e['R_MIGRATIONS'].splitlines() if m],
                   'db_migrate': 'succeeded' if e['R_MIGRATE_RAN'] == '1' else
                                 ('failed' if e['R_STAGE'] == 'db_migrate' else 'not_run'),
                   'reverted': False},
    'backup': {'path': backup or None, 'sha256': digest,
               'bytes': os.path.getsize(backup) if digest else None},
    'health': {'url': '/up', 'host': e['R_HOST'], 'result': e['R_HEALTH'],
               'last_http_code': e['R_HEALTH_CODE'] or None, 'attempts': int(e['R_HEALTH_ATTEMPTS'] or 0)},
    'smoke': load('smoke.json'),
    'rollback': e['R_ROLLBACK'],
    'started_at': e['R_STARTED'],
    'finished_at': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
}
tmp = sys.argv[1] + '.tmp'
with open(tmp, 'w') as f:
    json.dump(body, f, indent=2)
    f.write('\n')
os.chmod(tmp, 0o644)
os.replace(tmp, sys.argv[1])
PY
}
# Recorded before the attempt so a failure is not retried by the same request.
install_request=$requested
handle_request
write_json status.json deploying "installing ${NEW:0:8} ($migrations new migration(s))"

mkdir -p "$BACKUPS" "$STATE"; chmod 700 "$BACKUPS"; chmod 755 "$STATE"
backup="$BACKUPS/production-$(date +%Y%m%d-%H%M%S)-${CUR:0:8}.sqlite3"
if ! ( umask 077; sqlite3 web/storage/production.sqlite3 ".backup $backup" ); then
  backup=""; write_receipt failed "backup failed, aborting"; report failed "backup failed, aborting"; exit 1
fi
# shellcheck disable=SC2012 # names are our own production-<timestamp>-<sha>.sqlite3; ls -t gives newest-first
ls -1t "$BACKUPS"/*.sqlite3 | tail -n +6 | xargs -r rm -f

health() {
  health_attempts=0
  for _ in $(seq 1 15); do
    health_attempts=$((health_attempts + 1))
    health_code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -H "Host: $HOST" -H 'X-Forwarded-Proto: https' localhost:3000/up)
    [ "$health_code" = 200 ] && systemctl is-active --quiet rupert-web rupert-jobs && return 0
    sleep 2
  done; return 1
}
# asset_smoke: the rendered layout serves the new build (X-Rupert-Build), and
# every compiled stylesheet plus the application script it links to answer 200
# with a non-empty body. Writes $WORK/smoke.json for the receipt.
asset_smoke() {
  local page="$WORK/smoke-page.html" headers="$WORK/smoke-headers" list="$WORK/smoke-assets" code path body
  code=$(curl -s --max-time 10 -D "$headers" -o "$page" -w '%{http_code}' -H "Host: $HOST" -H 'X-Forwarded-Proto: https' "localhost:3000$SMOKE_PATH")
  python3 - "$page" > "$list" <<'PY'
import re, sys
import os
html = open(sys.argv[1], errors='replace').read() if os.path.isfile(sys.argv[1]) else ''
seen = []
for path in re.findall(r'(?:href|src)="(/[^"?#]*assets/[^"?#]+-[0-9a-f]{20,}\.(?:css|js))"', html):
    name = path.rsplit('/assets/', 1)[-1]
    if (path.endswith('.css') or name.startswith('application-')) and path not in seen:
        seen.append(path)
print('\n'.join(seen))
PY
  : > "$WORK/smoke-results"
  while read -r path; do
    [ -n "$path" ] || continue
    body="$WORK/smoke-asset"; rm -f "$body"
    printf '%s %s\n' "$path" "$(curl -s --max-time 10 -o "$body" -w '%{http_code}' -H "Host: $HOST" -H 'X-Forwarded-Proto: https' "localhost:3000$path")" >> "$WORK/smoke-results"
    if [ -s "$body" ]; then sha256sum "$body" | cut -d' ' -f1 >> "$WORK/smoke-results"; else echo - >> "$WORK/smoke-results"; fi
  done < "$list"
  python3 - "$code" "$headers" "$WORK/smoke-results" "$NEW" "$SMOKE_PATH" > "$WORK/smoke.json" <<'PY'
import json, os, sys
code, headers, results, want, page = sys.argv[1:]
build = None
try:
    for line in open(headers, errors='replace'):
        if line.lower().startswith('x-rupert-build:'):
            build = line.split(':', 1)[1].strip()
except OSError:
    pass
lines = open(results).read().splitlines()
assets = []
for head, digest in zip(lines[::2], lines[1::2]):
    path, status = head.rsplit(' ', 1)
    assets.append({'path': path, 'http_code': status, 'sha256': None if digest == '-' else digest,
                   'ok': status == '200' and digest != '-'})
kinds = {a['path'].rsplit('.', 1)[-1] for a in assets}
ok = code == '200' and build == want and {'css', 'js'} <= kinds and all(a['ok'] for a in assets)
json.dump({'page': page, 'page_http_code': code, 'served_build': build, 'build_matches': build == want,
           'assets': assets, 'result': 'passed' if ok else 'failed'}, sys.stdout)
PY
  grep -q '"result": "passed"' "$WORK/smoke.json"
}
# The build runs as root; hand anything it wrote back to the app user.
fix_owner() { chown -R rupert:rupert web/storage web/public web/tmp web/log 2>/dev/null; return 0; }
# shellcheck source=/dev/null # the env file is host config, not in the repo
rails_env() { set -a && . "$ENV_FILE" && set +a; }
in_web() { ( cd "$APP/web" && rails_env && "$@" ); }

stage=checkout; git checkout -q --detach "$NEW" \
  && stage=bundle_install && in_web bundle install --quiet \
  && stage=db_migrate && in_web bundle exec rails db:migrate && migrate_ran=1 \
  && stage=assets_precompile && in_web bundle exec rails assets:precompile >/dev/null \
  && stage=restart && fix_owner && systemctl restart rupert-web rupert-jobs \
  && stage=health && health_result=failed && health && health_result=passed \
  && stage=asset_smoke && asset_smoke
# shellcheck disable=SC2181 # the && chain above records $stage; one status check keeps it readable
if [ $? -ne 0 ]; then
  echo "$NEW" > "$STATE/failed-sha"
  if [ "$migrations" -gt 0 ]; then
    failure="${NEW:0:8} failed at $stage; $migrations migration(s) may have run and are NOT reverted, pre-deploy backup: $backup"
  else
    failure="${NEW:0:8} failed at $stage (no new migrations)"
  fi
  log "FAILED, rolling code back to ${CUR:0:8}; $failure"
  # Keep the failed attempt's health result for the receipt; the rollback check reuses health().
  attempt_health_code=$health_code attempt_health_attempts=$health_attempts
  git checkout -q --detach "$CUR"
  ( cd "$APP/web" && rails_env && bundle install --quiet && bundle exec rails assets:precompile >/dev/null ) || log "rollback rebuild failed"
  fix_owner
  systemctl restart rupert-web rupert-jobs
  if health; then
    log "rollback healthy"; failure="$failure; rolled back to ${CUR:0:8}"; rollback_result=healthy
  else
    log "ROLLBACK ALSO UNHEALTHY, needs a human"; failure="$failure; rollback to ${CUR:0:8} is ALSO UNHEALTHY, needs a human"
    rollback_result=unhealthy
  fi
  health_code=$attempt_health_code health_attempts=$attempt_health_attempts
  write_receipt failed "$failure"
  write_json last-deploy.json failed "$failure"
  write_json status.json failed "$failure"
  exit 1
fi
rm -f "$STATE/failed-sha"
write_receipt deployed "deployed ${NEW:0:8}, healthy"
# The receipt keeps the previous SHA; from here on the running revision is NEW.
CUR=$NEW
write_json last-deploy.json deployed "deployed ${NEW:0:8}, healthy"
report deployed "deployed ${NEW:0:8}, healthy"
