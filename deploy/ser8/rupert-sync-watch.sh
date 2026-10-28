#!/usr/bin/env bash
# Run on the SER8 host. Fail when any configured tenant/source acquisition is stale
# (default 45 minutes; syncs run every 15), or when the job service is not running.
# Why it lives outside the container: the in-app monitors run on the same job worker, so they cannot report
# that worker being down (it was down from 2026-10-02 to 2026-10-13 unnoticed). Read-only: it never restarts anything.
# Also fails when free disk on the database volume inside the container drops below MIN_FREE_MB (default 1024),
# or when the app's readiness endpoint answers anything but 200.
set -euo pipefail

MAX_AGE_MIN="${MAX_AGE_MIN:-45}"
MIN_FREE_MB="${MIN_FREE_MB:-1024}"
INSTANCE="${INSTANCE:-rupert}"
DB="${DB:-}"
READY_URL="${READY_URL:-}"

if [ -z "$DB" ]; then
  # shellcheck disable=SC2016 # expanded by the container's shell, not here
  DB="$(incus exec "$INSTANCE" -- /bin/sh -c '
    . /etc/rupert.env || exit 1
    printf "%s" "${RUPERT_SQLITE_DATABASE_PRODUCTION:-storage/production.sqlite3}"
  ' 2>/dev/null)" || { echo "UNKNOWN DISK: could not read the database path" >&2; exit 1; }
  case "$DB" in /*) ;; *) DB="/opt/rupert/web/$DB" ;; esac
fi

free_mb="$(incus exec "$INSTANCE" -- df -Pm "$(dirname "$DB")" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
if ! [[ "$free_mb" =~ ^[0-9]+$ ]]; then
  echo "UNKNOWN DISK: could not read free space on the Rupert database volume" >&2
  exit 1
fi
if [ "$free_mb" -lt "$MIN_FREE_MB" ]; then
  echo "LOW DISK: ${free_mb} MB free on the Rupert database volume (floor ${MIN_FREE_MB} MB)" >&2
  exit 1
fi

if [ -n "$READY_URL" ]; then
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$READY_URL" || true)"
else
  READY_URL='container localhost /up/ready'
  # The local request bypasses the TLS proxy; preserve its HTTPS indication so
  # Rails checks readiness rather than redirecting the probe to HTTPS.
  code="$(incus exec "$INSTANCE" -- curl -s -o /dev/null -m 10 -w '%{http_code}' -H 'X-Forwarded-Proto: https' http://127.0.0.1:3000/up/ready 2>/dev/null || true)"
fi
if [ "$code" != "200" ]; then
  echo "NOT READY: $READY_URL answered HTTP ${code:-none}" >&2
  exit 1
fi

jobs_state="$(incus exec "$INSTANCE" -- systemctl is-active rupert-jobs 2>/dev/null || true)"
if [ "$jobs_state" != "active" ]; then
  echo "STALE: rupert-jobs is ${jobs_state:-unknown}" >&2
  exit 1
fi

# Rails can read encrypted per-tenant settings and check each configured source.
# It only reads local data; no sync or external request is made.
if ! [[ "$MAX_AGE_MIN" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid MAX_AGE_MIN" >&2
  exit 1
fi
# shellcheck disable=SC2016 # expanded by the container's shell, not here
timeout 90s incus exec "$INSTANCE" -- /bin/sh -c '
  set -a
  . /etc/rupert.env || exit 1
  set +a
  cd /opt/rupert/web || exit 1
  exec runuser -u rupert -- env RAILS_ENV=production MAX_AGE_MIN="$1" \
    PATH=/opt/rbenv/versions/4.0.9/bin:/usr/local/bin:/usr/bin:/bin \
    /opt/rbenv/versions/4.0.9/bin/bundle exec bin/rails runner script/sync_watch.rb
' sh "$MAX_AGE_MIN"
