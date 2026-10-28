#!/usr/bin/env bash
# Weekly check of Rupert's encrypted off-container backups (#421). Runs on the SER8 HOST as the same user as the
# backup pull (~/.local/bin/rupert-backup). Since backups are age-encrypted to a key whose private half is only in the
# owner's recovery kit, this host CANNOT decrypt them, by design. What it checks without the key:
#   - every set on this host still matches the ciphertext digest written when it was made (bit rot, tampering);
#   - every file starts with the age header, so nothing unencrypted slipped in;
#   - the newest set is under MAX_AGE_H hours old and was encrypted to the key that is active now in the container
#     (a set made with a retired key still opens with that key's kit, but new sets should use the new key).
# The decrypt-and-restore drill needs the recovery kit and runs on a trusted computer with bin/backup-decrypt; see
# docs/ops/backups.md "Restore drill". Result goes to System → Backups (layer "verify") and the journal.
#
#   install -Dm755 deploy/ser8/rupert-backup-verify.sh ~/.local/bin/rupert-backup-verify.sh
#   install -Dm644 deploy/ser8/rupert-backup-verify.service deploy/ser8/rupert-backup-verify.timer -t ~/.config/systemd/user/
#   systemctl --user daemon-reload && systemctl --user enable --now rupert-backup-verify.timer
set -euo pipefail
umask 077

OUT="${OUT:-$HOME/backups/rupert}"
INSTANCE="${INSTANCE:-rupert}"
MAX_AGE_H="${MAX_AGE_H:-30}"
STATUS_PATH="${STATUS_PATH:-/opt/rupert/web/storage/backups/verify.json}"
SQLITE_DB="${SQLITE_DB:-/opt/rupert/web/storage/production.sqlite3}"
AGE_HEADER="age-encryption.org/v1"

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }
write_status() { # STATE MESSAGE [FILE BYTES]
  printf '{"layer":"verify","state":"%s","at":"%s","message":"%s","file":"%s","bytes":%s,"kept":0,"free_bytes":0,"encrypted":true}\n' \
    "$1" "$(date -u +%FT%TZ)" "$(json_escape "$2")" "$(json_escape "${3:-}")" "${4:-0}" \
    | incus file push --mode 0644 --uid 0 --gid 0 --create-dirs - "$INSTANCE$STATUS_PATH" 2>/dev/null || true
}
fail() { echo "$1" >&2; write_status failed "$1" "${NEWEST:-}"; exit 1; }

mapfile -t sets < <(ls -1t "$OUT"/rupert-*.sqlite3.gz.age 2>/dev/null || true)
[ "${#sets[@]}" -gt 0 ] || fail "no encrypted backup found in $OUT"
NEWEST="${sets[0]}"

checked=0
for db in "${sets[@]}"; do
  stamp="${db##*/rupert-}"; stamp="${stamp%%.sqlite3.gz.age}"
  for f in "$db" "$OUT/settings-$stamp.sql.age"; do
    [ -f "$f" ] || fail "set $stamp is missing $(basename "$f")"
    [ "$(head -c ${#AGE_HEADER} "$f")" = "$AGE_HEADER" ] || fail "$(basename "$f") is not age-encrypted"
    ( cd "$OUT" && sha256sum -c --quiet "$(basename "$f").sha256" ) >/dev/null 2>&1 || fail "ciphertext digest mismatch for $(basename "$f")"
    grep -q '^fingerprint ' "$f.key" 2>/dev/null || fail "$(basename "$f") has no .key file naming its key"
    checked=$((checked + 1))
  done
done

now_s=$(date +%s)
newest_s=$(stat -c %Y "$NEWEST")
[ "$newest_s" -le $((now_s + 60)) ] || fail "newest encrypted set has a future timestamp"
age_h=$(( ( now_s - newest_s ) / 3600 ))
[ "$age_h" -le "$MAX_AGE_H" ] || fail "newest encrypted set is ${age_h}h old (limit ${MAX_AGE_H}h): the backup pull is not running"

newest_fpr=$(sed -n 's/^fingerprint //p' "$NEWEST.key")
newest_recipient=$(sed -n 's/^recipient //p' "$NEWEST.key")
active=$(incus exec "$INSTANCE" -- sqlite3 -readonly "$SQLITE_DB" \
  "SELECT recipient FROM backup_encryption_keys WHERE activated_at IS NOT NULL AND retired_at IS NULL ORDER BY activated_at DESC, id DESC LIMIT 1" 2>/dev/null || true)
[ -n "$active" ] || fail "no active backup key in the container; new backups are being refused"
[ "$active" = "$newest_recipient" ] || fail "newest set uses key $newest_fpr, not the active key: has the pull run since the key was rotated?"

msg="$checked encrypted files in ${#sets[@]} sets match their digests; newest is ${age_h}h old with active key $newest_fpr. Decrypt drill needs the recovery kit (docs/ops/backups.md)."
write_status ok "$msg" "$NEWEST" "$(stat -c %s "$NEWEST")"
echo "$msg"
