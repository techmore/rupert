#!/usr/bin/env bash
set -euo pipefail
umask 077
out=${RUPERT_BENCHMARK_OUTPUT:?Set the private host evidence directory}
db=/tmp/rupert-120-benchmark.sqlite3
exec 8>"$out/.compare.lock"
flock -n 8 || exit 0
get_run() {
  incus exec rupert-test -- python3 - "$db" "$1" "$2" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); agent=None if sys.argv[3]=='rupert' else sys.argv[3]
r=c.execute("select run_key from chat_battery_runs where tenant_id=? and set_name like ? and agent is ? and status='done' order by id desc limit 1",('test-tenant-default',sys.argv[2]+'-cohort-%',agent)).fetchone()
print(r[0] if r else '')
PY
}
for set in default finance cross bank; do
  for reference in qwen rupert; do
    baseline=$(get_run "$set" "$reference")
    [ -n "$baseline" ] || continue
    for agent in lfm3-text lfm3-vl lfm3-audio lfm3-omni qwen rupert; do
      [ "$agent" != "$reference" ] || continue
      candidate=$(get_run "$set" "$agent")
      [ -n "$candidate" ] || continue
      output="$out/comparison-$set-$agent-vs-$reference-$baseline-$candidate.json"
      [ ! -e "$output" ] || continue
      if incus exec rupert-test --env PATH=/opt/rbenv/versions/4.0.6/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin --env BUNDLE_PATH=/tmp/rupert-benchmark-gems --env RAILS_ENV=test --env "RUPERT_SQLITE_DATABASE_TEST=$db" --env TENANT_ID=test-tenant-default --env "BASELINE=$baseline" --env "CANDIDATE=$candidate" -- sh -c 'cd /tmp/rupert-benchmark-audit/web && bundle exec rails team_chat:battery_compare' > "$output.partial"; then
        mv "$output.partial" "$output"
        printf 'Compared %s with %s on %s\n' "$agent" "$reference" "$set"
      else
        rm "$output.partial"
        printf 'Comparison failed for %s against %s on %s\n' "$agent" "$reference" "$set" >&2
      fi
    done
  done
done
