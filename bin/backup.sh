#!/usr/bin/env bash
# Rupert database backup, encrypted (#421). Snapshots the SQLite production database and writes three files, each
# encrypted with age to the instance's backup public key before it is stored:
#   rupert-<stamp>.sqlite3.gz.age   the whole database (gzip, then age)
#   settings-<stamp>.sql.age        the settings table as SQL INSERTs (values stay Active Record encrypted)
#   env-<stamp>.age                 the server environment file (secrets, RAILS_ENCRYPTION_* keys)
# and beside each one a .sha256 (digest of the ciphertext, `sha256sum -c` format) and a .key (fingerprint and public
# key it was encrypted to). age is authenticated encryption: a changed byte makes decryption fail.
#
# The public key is the active row of backup_encryption_keys (Settings → Backups → Create backup key). The private
# key exists only in the owner's recovery kit, so nothing on this server can read these files. Without an active key,
# or without the age tool (apt-get install age), this script REFUSES to run and reports Failed on System → Backups:
# it never falls back to an unencrypted copy.
#
# The only plaintext is the transient snapshot, made in memory-backed /dev/shm when it fits (else beside the output,
# mode 0600) and removed on exit. Restore: bin/backup-decrypt (docs/ops/backups.md).
#
# Runs from a systemd timer (deploy/rupert-backup-ser8.timer) and on demand from the host pull
# (deploy/ser8/rupert-host-backup-pull.sh). Writes STATUS_DIR/local.json for System → Backups.
set -euo pipefail
umask 077

# Env file: ENV_FILE, else /etc/rupert.env (SER8), else the old droplet location.
for f in "${ENV_FILE:-}" /etc/rupert.env /root/rupert/.env; do [ -n "$f" ] && [ -r "$f" ] && { ENV_SRC="$f"; break; }; done
: "${ENV_SRC:?no readable env file found}"
set -a
# shellcheck disable=SC1090
source "$ENV_SRC"
set +a

OUT="${OUT:-/var/backups/rupert}"
APP_DIR="${APP_DIR:-/opt/rupert}"
STATUS_DIR="${STATUS_DIR:-$APP_DIR/web/storage/backups}"
MIN_FREE_MB="${MIN_FREE_MB:-5120}"
KEEP="${KEEP:-32}"
SCRATCH="${SCRATCH:-/dev/shm}"
install -d -m 0700 "$OUT"
chmod 0700 "$OUT"
exec 9>"$OUT/.backup.lock"
flock -w 900 9 || { echo "another backup held the lock for 15 minutes" >&2; exit 1; }

KEY_FPR=""
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }
free_bytes() { df -B1 --output=avail "$1" 2>/dev/null | tail -1 | tr -d ' '; }
write_status() {
  install -d -m 0755 "$STATUS_DIR" 2>/dev/null || return 0
  local tmp="$STATUS_DIR/.local.json.tmp"
  printf '{"layer":"local","state":"%s","at":"%s","message":"%s","file":"%s","bytes":%s,"kept":%s,"free_bytes":%s,"encrypted":%s,"key_fingerprint":"%s"}\n' \
    "$1" "$(date -u +%FT%TZ)" "$(json_escape "$2")" "$(json_escape "${3:-}")" "${4:-0}" "${5:-0}" "$(free_bytes "$OUT")" \
    "$([ -n "$KEY_FPR" ] && echo true || echo false)" "$(json_escape "$KEY_FPR")" > "$tmp"
  chmod 0644 "$tmp" && mv -f "$tmp" "$STATUS_DIR/local.json"
}
fail() { echo "$1" >&2; write_status failed "$1"; exit 1; }

SQLITE_DB="${RUPERT_SQLITE_DATABASE_PRODUCTION:-$APP_DIR/web/storage/production.sqlite3}"

# The public key backups are encrypted to. Validated before it reaches `age -r`.
RECIPIENT="$(sqlite3 -readonly "$SQLITE_DB" "SELECT recipient FROM backup_encryption_keys WHERE activated_at IS NOT NULL AND retired_at IS NULL ORDER BY activated_at DESC, id DESC LIMIT 1" 2>/dev/null || true)"
[[ "$RECIPIENT" =~ ^age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}$ ]] \
  || fail "refused: no active backup key, so no unencrypted backup was written. Create one in Settings → Backups."
command -v age >/dev/null 2>&1 || fail "refused: the age tool is not installed in the container (apt-get install age); no unencrypted backup was written."
KEY_FPR="$(printf '%s' "$RECIPIENT" | sha256sum | cut -c1-16 | sed -E 's/(....)/\1 /g; s/ $//')"

TS="$(date +%Y%m%d-%H%M%S)"
while [ -e "$OUT/rupert-$TS.sqlite3.gz.age" ]; do
  sleep 1
  TS="$(date +%Y%m%d-%H%M%S)"
done
DB_OUT="$OUT/rupert-$TS.sqlite3.gz.age"
SET_OUT="$OUT/settings-$TS.sql.age"
ENV_OUT="$OUT/env-$TS.age"

db_bytes="$(stat -c %s "$SQLITE_DB")"
avail="$(free_bytes "$OUT")"
need=$(( db_bytes + db_bytes / 4 + MIN_FREE_MB * 1024 * 1024 ))
[ "$avail" -ge "$need" ] || fail "skipped: $(( avail / 1048576 )) MB free on $OUT, need $(( need / 1048576 )) MB. Free disk space."

# Transient plaintext snapshot: memory-backed when it fits, never kept.
if [ -d "$SCRATCH" ] && [ "$(free_bytes "$SCRATCH" || echo 0)" -ge $(( db_bytes * 2 )) ]; then
  WORK="$(mktemp -d -p "$SCRATCH" rupert-backup.XXXXXX)"
else
  WORK="$(mktemp -d -p "$OUT" .work.XXXXXX)"
fi
SNAP="$WORK/snapshot.sqlite3"
trap 'rm -rf "$WORK"; for dest in "$DB_OUT" "$SET_OUT" "$ENV_OUT"; do rm -f "$dest.partial" "$dest.sha256.partial" "$dest.key.partial"; done' EXIT

# encrypt DEST: stdin → DEST (age), then DEST.sha256 and DEST.key. The ciphertext must start with the age header.
encrypt() {
  local dest="$1"
  age -r "$RECIPIENT" -o "$dest.partial" || return 1
  [ "$(head -c 21 "$dest.partial")" = "age-encryption.org/v1" ] || return 1
  ( cd "$(dirname "$dest")" && sha256sum "$(basename "$dest").partial" | sed 's/\.partial$//' > "$(basename "$dest").sha256.partial" ) || return 1
  printf 'fingerprint %s\nrecipient %s\n' "$KEY_FPR" "$RECIPIENT" > "$dest.key.partial" || return 1
  chmod 0600 "$dest.partial" "$dest.sha256.partial" "$dest.key.partial" || return 1
  # The data filename appears only after both metadata files are in place.
  mv -f "$dest.sha256.partial" "$dest.sha256" && mv -f "$dest.key.partial" "$dest.key" && mv -f "$dest.partial" "$dest"
}

# Consistent snapshot while the app is writing (VACUUM INTO never blocks readers/writers for long).
sqlite3 "$SQLITE_DB" "VACUUM INTO '$SNAP'" || fail "VACUUM INTO failed"
[ "$(sqlite3 "$SNAP" 'PRAGMA integrity_check')" = "ok" ] || fail "snapshot failed integrity_check"
sqlite3 "$SNAP" ".mode insert settings" "SELECT * FROM settings" | encrypt "$SET_OUT" || fail "encrypting the settings dump failed"
encrypt "$ENV_OUT" < "$ENV_SRC" || fail "encrypting the env copy failed"
# Publish the database last: its presence marks a complete set for copy scripts.
gzip -c "$SNAP" | encrypt "$DB_OUT" || fail "encrypting the database snapshot failed"
rm -rf "$WORK"

# Plaintext sets from before encryption are moved aside (not deleted: the owner decides when, docs/ops/backups.md),
# so nothing that pulls "the newest set" can pick one up again.
legacy="$(find "$OUT" -maxdepth 1 -type f -regextype posix-extended \
  -regex '.*/(rupert-[0-9]{8}-[0-9]{4}\.sql\.gz|settings-[0-9]{8}-[0-9]{4}\.sql|env-[0-9]{8}-[0-9]{4})' | wc -l)"
if [ "$legacy" -gt 0 ]; then
  install -d -m 0700 "$OUT/legacy-plaintext"
  find "$OUT" -maxdepth 1 -type f -regextype posix-extended \
    -regex '.*/(rupert-[0-9]{8}-[0-9]{4}\.sql\.gz|settings-[0-9]{8}-[0-9]{4}\.sql|env-[0-9]{8}-[0-9]{4})' \
    -exec mv -t "$OUT/legacy-plaintext/" {} +
  echo "moved $legacy unencrypted files from before #421 to $OUT/legacy-plaintext (delete them when ready)" >&2
fi

# Prune to the newest KEEP sets (~8 days at 4x/day); every file of an older set goes with it.
mapfile -t sets < <(ls -1t "$OUT"/rupert-*.sqlite3.gz.age 2>/dev/null || true)
for f in "${sets[@]:$KEEP}"; do
  stamp="${f##*/rupert-}"; stamp="${stamp%%.sqlite3.gz.age}"
  for base in "rupert-$stamp.sqlite3.gz.age" "settings-$stamp.sql.age" "env-$stamp.age"; do
    rm -f "$OUT/$base" "$OUT/$base.sha256" "$OUT/$base.key"
  done
done

kept="$(ls -1 "$OUT"/rupert-*.sqlite3.gz.age | wc -l)"
write_status ok "database, settings and env encrypted to key $KEY_FPR; $kept sets kept" "$DB_OUT" "$(stat -c %s "$DB_OUT")" "$kept"
echo "backup ok: $DB_OUT ($(du -h "$DB_OUT" | cut -f1)), key $KEY_FPR"
