#!/usr/bin/env bash
# Rupert PostgreSQL backup: dump the production database (gzip) plus a copy of
# the .env (needed to restore secrets/encryption keys), pruned to a rolling
# window. Runs from a systemd timer.
set -euo pipefail

set -a
# shellcheck disable=SC1091
source /root/rupert/.env
set +a

OUT="/var/backups/rupert"
DB="${POSTGRES_DB:-rupert_production}"
mkdir -p "$OUT"

TS="$(date +%Y%m%d-%H%M)"
DUMP="$OUT/rupert-$TS.sql.gz"

PGPASSWORD="${POSTGRES_PASSWORD:-rupert}" \
  pg_dump -h "${POSTGRES_HOST:-localhost}" -p "${POSTGRES_PORT:-5432}" \
  -U "${POSTGRES_USER:-rupert}" -d "$DB" \
  | gzip > "$DUMP"

cp /root/rupert/.env "$OUT/env-$TS"

# Prune to the latest 32 dumps (~8 days at 4x/day) and matching env copies.
ls -1t "$OUT"/rupert-*.sql.gz | tail -n +33 | xargs -r rm
ls -1t "$OUT"/env-* | tail -n +33 | xargs -r rm

echo "backup ok: $DUMP ($(du -h "$DUMP" | cut -f1))"
