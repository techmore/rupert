#!/usr/bin/env bash
set -euo pipefail
umask 077
nas=${RUPERT_NAS_MOUNT:?Set RUPERT_NAS_MOUNT to the mounted NAS directory}
out="$nas/rupert-recovery"
expected=${RUPERT_NAS_SOURCE:?Set RUPERT_NAS_SOURCE to the expected NFS source}
container=${RUPERT_NAS_CONTAINER:?Set RUPERT_NAS_CONTAINER to the Incus container}
reader_uid=${RUPERT_NAS_READER_UID:?Set RUPERT_NAS_READER_UID to the mapped container UID}
[[ "$container" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ && "$reader_uid" =~ ^[0-9]+$ ]] || { echo "Invalid container or reader UID" >&2; exit 1; }
mount_source=$(findmnt -rn -t nfs,nfs4 -T "$nas" -o SOURCE | tail -n 1)
[ "$mount_source" = "$expected" ] || { echo 'NAS not mounted as expected; refusing backup' >&2; exit 1; }
[ -d "$out" ] || { echo 'NAS recovery directory missing' >&2; exit 1; }
exec 9>"$HOME/.local/share/rupert-nas-recovery.lock"
flock -n 9 || { echo 'NAS backup already running'; exit 0; }
incus exec "$container" -- systemctl start rupert-backup.service
latest=$(incus exec "$container" -- sh -c 'ls -1t /var/backups/rupert/rupert-*.sqlite3.gz.age 2>/dev/null | head -1')
[ -n "$latest" ] || { echo 'No encrypted backup found' >&2; exit 1; }
stamp=${latest##*/rupert-}; stamp=${stamp%.sqlite3.gz.age}
[[ "$stamp" =~ ^[0-9]{8}-[0-9]{4,6}$ ]] || { echo 'Invalid backup timestamp' >&2; exit 1; }
final="$out/age-$stamp"
[ ! -e "$final" ] || { echo "Backup already present: $stamp"; exit 0; }
tmp=$(mktemp -d "$out/.partial-$stamp.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
for name in "rupert-$stamp.sqlite3.gz.age" "settings-$stamp.sql.age" "env-$stamp.age"; do
  for suffix in '' .sha256 .key; do
    incus exec "$container" -- cat "/var/backups/rupert/$name$suffix" > "$tmp/$name$suffix"
  done
  [ "$(head -c 21 "$tmp/$name")" = 'age-encryption.org/v1' ] || { echo "Invalid encryption header: $name" >&2; exit 1; }
  (cd "$tmp" && sha256sum -c -- "$name.sha256")
done
setfacl -m "u:$reader_uid:rx" "$tmp"
setfacl -m "u:$reader_uid:r--" "$tmp"/*
mv -- "$tmp" "$final"
trap - EXIT
printf 'NAS recovery set verified: %s\n' "$final"
