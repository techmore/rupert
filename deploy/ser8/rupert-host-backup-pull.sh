#!/usr/bin/env bash
# Off-container copy of Rupert's ENCRYPTED backups (#421). Runs on the SER8 HOST as the normal user. Replaces both
# the old host cron ~/.local/bin/rupert-backup (which copied plaintext dumps and the env file) and the old
# rupert-offhost-backup.sh (AES-CBC with a key file on this host):
#   - asks the container for a fresh backup set (rupert-backup.service, bin/backup.sh), which is already encrypted
#     with age to the owner's backup public key; the private key is only in the owner's recovery kit;
#   - pulls only the encrypted database and settings files and their .sha256/.key sidecars. It never copies the env
#     file, encrypted or not: its secrets stay in the container and the database keys are in the recovery kit;
#   - REFUSES to run when the container's newest backup is not age-encrypted, or a pulled file lacks the age header
#     or does not match the digest the container wrote;
#   - prunes every artifact type here to the same KEEP sets (default 35), by set;
#   - reports to System → Backups (layer "offhost"). There is no key on this host and nothing to decrypt with.
#
# Install (one script, two triggers; the existing crontab line `17 7 * * * ~/.local/bin/rupert-backup` stays as is):
#   install -Dm755 deploy/ser8/rupert-host-backup-pull.sh ~/.local/bin/rupert-backup
#   install -Dm644 deploy/ser8/rupert-offhost-backup.service deploy/ser8/rupert-offhost-backup.timer -t ~/.config/systemd/user/
#   systemctl --user daemon-reload
# Overlapping runs (cron and timer) wait on a lock instead of interleaving.
set -euo pipefail
umask 077

OUT="${OUT:-$HOME/backups/rupert}"
INSTANCE="${INSTANCE:-rupert}"
SOURCE_DIR="${SOURCE_DIR:-/var/backups/rupert}"
KEEP="${KEEP:-35}"
MIN_FREE_MB="${MIN_FREE_MB:-5120}"
STATUS_PATH="${STATUS_PATH:-/opt/rupert/web/storage/backups/offhost.json}"
AGE_HEADER="age-encryption.org/v1"

KEY_FPR=""
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }
free_bytes() { df -B1 --output=avail "$1" 2>/dev/null | tail -1 | tr -d ' '; }
write_status() { # STATE MESSAGE [FILE BYTES KEPT]
  printf '{"layer":"offhost","state":"%s","at":"%s","message":"%s","file":"%s","bytes":%s,"kept":%s,"free_bytes":%s,"encrypted":%s,"key_fingerprint":"%s"}\n' \
    "$1" "$(date -u +%FT%TZ)" "$(json_escape "$2")" "$(json_escape "${3:-}")" "${4:-0}" "${5:-0}" "$(free_bytes "$OUT")" \
    "$([ -n "$KEY_FPR" ] && echo true || echo false)" "$(json_escape "$KEY_FPR")" \
    | incus file push --mode 0644 --uid 0 --gid 0 --create-dirs - "$INSTANCE$STATUS_PATH" 2>/dev/null || true
}
fail() { echo "$1" >&2; write_status failed "$1"; exit 1; }
in_container() { incus exec "$INSTANCE" -- "$@"; }

install -d -m 0700 "$OUT"
exec 9>"$OUT/.pull.lock"
flock -w 900 9 || fail "another backup pull held the lock for 15 minutes"

# A backup must never be what fills the disk; refuse early and say so where the app shows it.
avail=$(free_bytes "$OUT")
[ "$avail" -ge $(( MIN_FREE_MB * 1024 * 1024 )) ] || fail "skipped: $(( avail / 1048576 )) MB free on $OUT, need ${MIN_FREE_MB} MB. Free disk space."

in_container systemctl start rupert-backup.service \
  || fail "rupert-backup.service failed inside the container (no active backup key, or age missing?). Nothing was copied."

# The newest database file of any kind must be an encrypted one, or this host would be keeping stale data.
newest_any=$(in_container sh -c "ls -1t $SOURCE_DIR/rupert-* 2>/dev/null | grep -v -e '\.sha256\$' -e '\.key\$' | head -1" || true)
case "$newest_any" in
  *.sqlite3.gz.age) ;;
  "") fail "refusing to run: no backups found in the container at $SOURCE_DIR" ;;
  *) fail "refusing to run: the container's newest backup ($(basename "$newest_any")) is not encrypted. Create a backup key in Settings → Backups and install age in the container." ;;
esac
stamp="${newest_any##*/rupert-}"; stamp="${stamp%%.sqlite3.gz.age}"
[[ "$stamp" =~ ^[0-9]{8}-[0-9]{4,6}$ ]] || fail "refusing to run: unexpected backup name $(basename "$newest_any")"

# pull NAME: SOURCE_DIR/NAME → OUT/NAME, checked against the container's digest and the age header, with sidecars.
pull() {
  local name="$1" src="$SOURCE_DIR/$1" dest="$OUT/$1" expected actual header key
  expected=$(in_container cat "$src.sha256" | cut -d' ' -f1) || fail "missing $name.sha256 in the container"
  key=$(in_container cat "$src.key") || fail "missing $name.key in the container"
  grep -Eq '^recipient age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}$' <<<"$key" || fail "refusing to run: $name.key names no age public key"
  in_container cat "$src" > "$dest.partial" || { rm -f "$dest.partial"; fail "could not copy $name"; }
  header=$(head -c ${#AGE_HEADER} "$dest.partial")
  [ "$header" = "$AGE_HEADER" ] || { rm -f "$dest.partial"; fail "refusing to keep $name: it is not age-encrypted"; }
  actual=$(sha256sum "$dest.partial" | cut -d' ' -f1)
  [ "$expected" = "$actual" ] || { rm -f "$dest.partial"; fail "digest mismatch for $name: the copy differs from the container's file"; }
  mv -f "$dest.partial" "$dest"
  printf '%s  %s\n' "$actual" "$name" > "$dest.sha256"
  printf '%s\n' "$key" > "$dest.key"
  chmod 0600 "$dest" "$dest.sha256" "$dest.key"
  KEY_FPR=$(sed -n 's/^fingerprint //p' <<<"$key")
}

pull "rupert-$stamp.sqlite3.gz.age"
pull "settings-$stamp.sql.age"

# Same retention for every artifact type: the newest KEEP sets, each set removed whole. Files from before #421
# (plaintext, or .enc from the old AES copy) are not touched here; the owner deletes them (docs/ops/backups.md).
mapfile -t sets < <(ls -1t "$OUT"/rupert-*.sqlite3.gz.age 2>/dev/null || true)
for f in "${sets[@]:$KEEP}"; do
  old="${f##*/rupert-}"; old="${old%%.sqlite3.gz.age}"
  for base in "rupert-$old.sqlite3.gz.age" "settings-$old.sql.age"; do
    rm -f "$OUT/$base" "$OUT/$base.sha256" "$OUT/$base.key"
  done
done

# shellcheck disable=SC2012 # counting our own rupert-<timestamp> files; no odd names
kept=$(ls -1 "$OUT"/rupert-*.sqlite3.gz.age | wc -l)
dest="$OUT/rupert-$stamp.sqlite3.gz.age"
write_status ok "encrypted set $stamp copied to the SER8 host and checked (age header, digest); key $KEY_FPR; $kept sets kept" "$dest" "$(stat -c %s "$dest")" "$kept"
echo "backup ok: $dest ($(du -h "$dest" | cut -f1)); key $KEY_FPR; $kept sets kept"
