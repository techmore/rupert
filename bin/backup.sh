#!/usr/bin/env bash
# Rupert PostgreSQL backup: dump the production database (gzip) plus a copy of
# the .env (boot keys + encryption keys) and the encrypted settings table
# (DB-managed credentials such as Square/Shopify tokens). Restoring needs all
# three: .env holds the RAILS_ENCRYPTION_* keys that decrypt the settings dump.
# Runs from a systemd timer (see deploy/rupert-backup.timer).
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

PGPASSWORD="${POSTGRES_PASSWORD:-rupert}" \
  pg_dump -h "${POSTGRES_HOST:-localhost}" -p "${POSTGRES_PORT:-5432}" \
  -U "${POSTGRES_USER:-rupert}" -d "$DB" \
  --table=settings --data-only --column-inserts > "$OUT/settings-$TS.sql"

cp /root/rupert/.env "$OUT/env-$TS"

# Prune to the latest 32 dumps (~8 days at 4x/day) and matching sidecar files.
ls -1t "$OUT"/rupert-*.sql.gz | tail -n +33 | xargs -r rm
ls -1t "$OUT"/settings-* | tail -n +33 | xargs -r rm
ls -1t "$OUT"/env-* | tail -n +33 | xargs -r rm

echo "backup ok: $DUMP ($(du -h "$DUMP" | cut -f1))"
