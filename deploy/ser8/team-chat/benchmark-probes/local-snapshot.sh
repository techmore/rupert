#!/usr/bin/env bash
set -euo pipefail
umask 077
out=${RUPERT_BENCHMARK_OUTPUT:?Set the local evidence directory}
container=${RUPERT_BENCHMARK_CONTAINER:?Set the isolated benchmark container}
[[ "$container" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || { echo 'Invalid container name' >&2; exit 1; }
[ -d "$out" ] || { echo 'Local evidence directory missing' >&2; exit 1; }
# Fixed isolated-fixture paths; do not point this at a production database.
db=/tmp/rupert-120-benchmark.sqlite3
snapshot=/tmp/rupert-benchmark-audit/limited-20261027/periodic.sqlite3
exec 9>"$out/.local-snapshot.lock"
flock -n 9 || exit 0
incus exec "$container" -- sqlite3 "$db" ".backup $snapshot"
incus file pull "$container$snapshot" "$out/progress.sqlite3.partial"
chmod 600 "$out/progress.sqlite3.partial"
mv -f "$out/progress.sqlite3.partial" "$out/progress.sqlite3"
