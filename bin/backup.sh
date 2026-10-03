#!/usr/bin/env bash
# Rupert PostgreSQL backup: dump the production database (gzip) plus a copy of
# the .env (boot keys + encryption keys) and the encrypted settings table
# (DB-managed credentials such as Square/Shopify tokens). Restoring needs all
# three: .env holds the RAILS_ENCRYPTION_* keys that decrypt the settings dump.
# Runs from a systemd timer (see deploy/rupert-backup.timer).
set -euo pipefail
umask 077

set -a
# shellcheck disable=SC1091
source /root/rupert/.env
set +a
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in /root/rupert/.env}"

OUT="/var/backups/rupert"
DB="${POSTGRES_DB:-rupert_production}"
install -d -m 0700 "$OUT"
chmod 0700 "$OUT"

TS="$(date +%Y%m%d-%H%M)"
DUMP="$OUT/rupert-$TS.sql.gz"
DUMP_TMP="$DUMP.partial"
SETTINGS_TMP="$OUT/settings-$TS.sql.partial"
ENV_TMP="$OUT/env-$TS.partial"

PGPASSWORD="$POSTGRES_PASSWORD" \
  pg_dump -h "${POSTGRES_HOST:-localhost}" -p "${POSTGRES_PORT:-5432}" \
  -U "${POSTGRES_USER:-rupert}" -d "$DB" \
  | gzip > "$DUMP_TMP"

PGPASSWORD="$POSTGRES_PASSWORD" \
  pg_dump -h "${POSTGRES_HOST:-localhost}" -p "${POSTGRES_PORT:-5432}" \
  -U "${POSTGRES_USER:-rupert}" -d "$DB" \
  --table=settings --data-only --column-inserts > "$SETTINGS_TMP"

cp /root/rupert/.env "$ENV_TMP"
mv "$DUMP_TMP" "$DUMP"
mv "$SETTINGS_TMP" "$OUT/settings-$TS.sql"
mv "$ENV_TMP" "$OUT/env-$TS"
chmod 0600 "$DUMP" "$OUT/settings-$TS.sql" "$OUT/env-$TS"

# Prune to the latest 32 dumps (~8 days at 4x/day) and matching sidecar files.
ls -1t "$OUT"/rupert-*.sql.gz | tail -n +33 | xargs -r rm
ls -1t "$OUT"/settings-* | tail -n +33 | xargs -r rm
ls -1t "$OUT"/env-* | tail -n +33 | xargs -r rm

echo "backup ok: $DUMP ($(du -h "$DUMP" | cut -f1))"
