# Rupert backups: what exists, what each layer is for, how to restore

Rupert runs on one SQLite file (`/opt/rupert/web/storage/production.sqlite3`) inside the `rupert` Incus container on
SER8. Uploaded statements, exports and receipts are stored inside that file too (base64 in `reconciliation_documents`,
`purchase_receipts` and `training_attachments`), so one file holds everything a restore needs except the encryption keys in `/etc/rupert.env`
and the settings dump. Every layer below copies that one file.

**System → Backups** (super admins with `system.read`) shows each layer's last report. Each script writes a small JSON
file to `storage/backups/<layer>.json` after every run (`state` ok/failed, `at`, `message`, `file`, `bytes`, `kept`,
`free_bytes`, `encrypted`, `key_fingerprint`); the app only reads them. A layer that has not reported inside its usual interval shows **Overdue**; one
that has never reported shows **Not reporting**, which means it is not installed on this server. The MCP tool
`backup_freshness` reports the same layers to connected assistants.

## Encryption and the recovery kit (#421)

Every backup file is encrypted with [age](https://age-encryption.org) (X25519, ChaCha20-Poly1305: authenticated, so
a changed or truncated file fails to decrypt) **before it is written**. The server holds only the **public** key. The
private key exists only in the owner's **recovery kit**, a PDF downloaded once from **Settings → Backups**. Nothing on
SER8 (container or host) can decrypt a backup, which is the point: a copy of the backup folder, the host disk or the
mirror is useless without the kit.

- **Install age** in the container (and on any computer that will restore): `apt-get install age`.
- **Create the key**: Settings → Backups → *Create backup key* (super admin with `settings.write`, signed in within the
  last 15 minutes, or a password re-entry for password accounts). The server makes the key pair in memory, stores the
  public key in `backup_encryption_keys`, and answers with the kit PDF. The private key is never stored, logged or
  shown again (`test/integration/backup_keys_test.rb` checks every table and the log after creating one).
- **The kit** holds the age private key, the three `RAILS_ENCRYPTION_*` values a restored database needs, the key
  fingerprint, creation date, a check code and the restore steps. Save it in the password manager as a **separate
  secure note** titled `Rupert backup recovery kit — <workspace>`. It is not a login: sign-in uses Google, so there is
  no rupertpos.com password, and the PDF has no form fields a password manager could mistake for one. Keep a second,
  offline copy (printed, in a safe).
- **Activate** by typing the kit's check code on Settings → Backups within the hour. Until then backups keep using the
  previous key (or keep being refused when there is none), so no backup ever depends on a kit that was not saved.
- **No key, no backup.** `bin/backup.sh` and the frequent snapshot refuse to run without an active key or without the
  `age` tool, and System → Backups shows **Failed** with the reason. They never fall back to an unencrypted copy.
- **Rotation**: create a new key the same way. Older backups stay readable with the old kit: every encrypted file has
  a `.key` file beside it naming the fingerprint and public key it was encrypted to, and Settings → Backups lists every
  fingerprint with its state. Keep an old kit until the last backup made with it has aged out (about 35 days).
- **Every file** comes with `<file>.sha256` (digest of the ciphertext; `sha256sum -c` checks it without any key) and
  `<file>.key`.
- The only plaintext is the transient `VACUUM INTO` snapshot, made in memory-backed `/dev/shm` when it fits and removed
  when the run ends.

What stays unencrypted, on purpose: the live database itself, and the auto-deploy pre-deploy copy (last 5 in
`/var/backups/rupert-autodeploy`, used for an immediate rollback without the kit). Settings → *Download backup* gives
a super admin a plaintext snapshot in the browser; the Google Drive layer (not connected) would upload one too (#421
gap 5).

## The layers

| Layer | Where it runs | How often | Keeps | Protects against | Script / unit |
| --- | --- | --- | --- | --- | --- |
| Rolling snapshot (`frequent`) | container, root | every 5 min | all for 2 h, then hourly to 24 h | the last day of mistakes: a bad import, a deleted record, a bad migration (restoring one needs the kit) | `deploy/ser8/rupert-backup-frequent.sh`, `.timer` |
| Local backup set (`local`) | container, root | every 6 h | 32 sets (~8 days) | needing database + settings dump + env file together | `bin/backup.sh`, `deploy/rupert-backup-ser8.*` |
| Encrypted copy outside the container (`offhost`) | SER8 host, user timer + the daily cron line | every 6 h and daily 07:17 | 35 sets | loss or corruption of the container | `deploy/ser8/rupert-host-backup-pull.sh` (installed as `~/.local/bin/rupert-backup`), `rupert-offhost-backup.timer` |
| Mirror on another machine (`offsite`) | a second computer, user timer | every 6 h while that machine is on | 14 sets (and a cloud bucket when `RCLONE_REMOTE` is set) | loss of the SER8 disk, the host or the building | `deploy/offsite/rupert-backup-mirror.sh`, `.timer` |
| Encrypted copy check (`verify`) | SER8 host, user timer | weekly (Sunday 04:30) | nothing; never decrypts (no key on the host) | damaged, altered or unencrypted copies; a pull that stopped; a rotation not yet picked up | `deploy/ser8/rupert-backup-verify.sh`, `.timer` |
| Restore drill | a trusted computer, by hand, with the recovery kit | monthly, and after every key rotation | a non-secret receipt | backups that cannot be decrypted or fail SQLite integrity checks | `bin/backup-decrypt` (see "Restore drill") |
| Auto-deploy pre-deploy copy | container, root | before each deploy | last 5 | a bad release | `deploy/ser8/rupert-autodeploy.sh` |
| Google Drive (`BackupJob`) | app | every 6 h, when connected | 7 | off-site copy without a second machine | Settings → Backup. **Not connected**: the OAuth app is in Testing (see `google-backup-verification.md`). |

Every copy except the mirror lives on SER8's single NVMe disk. The mirror is what survives that disk. Until the mirror
or Drive is running, a lost SER8 means a lost database.

### Growth and disk space

Each snapshot is a full copy (SQLite `VACUUM INTO`), so backup space grows with the database times the number kept.
The rolling snapshot therefore thins to hourly after two hours (about 46 copies a day instead of 288). The host pull
checks the encrypted set size, and the mirror estimates the pending transfer, before reserving `MIN_FREE_MB` (5 GB on
SER8, 2 GB on the mirror). These preflight checks cannot account for concurrent disk use or a source that grows after
the estimate; keep monitoring free space independently. A full disk stops the live database.
If System → Backups shows "skipped: … MB free", free disk space first; the next tick resumes by itself.

Ad-hoc copies taken by hand during deployments live under `/var/backups/rupert/<name>/` in the container and are not
pruned by anything. Review and delete them when the disk is tight (`du -sh /var/backups/rupert/* | sort -h`).
The backup scripts remove their own specifically named on-disk temporary work directories after acquiring their locks,
including leftovers from an interrupted run. Older generic `.work.*` directories are not automatically deleted because
their provenance is not certain; review them privately. Memory-backed scratch is cleared on reboot.

## Install

Inside the container (as root), after merging a change to the scripts:

```sh
apt-get install -y age
cd /opt/rupert
install -m 0755 deploy/ser8/rupert-backup-frequent.sh /usr/local/sbin/
install -m 0644 deploy/ser8/rupert-backup-frequent.service deploy/ser8/rupert-backup-frequent.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now rupert-backup-frequent.timer rupert-backup.timer
systemctl start rupert-backup.service   # bin/backup.sh runs from the checkout; the deployer keeps it current
```

On the SER8 host (as the normal user; `loginctl enable-linger $USER` once). One script does the off-container copy;
the existing crontab line (`17 7 * * * ~/.local/bin/rupert-backup >> ~/backups/rupert/backup.log 2>&1`) and the
6-hourly timer both run it, and a lock keeps them from overlapping:

```sh
install -Dm755 deploy/ser8/rupert-host-backup-pull.sh ~/.local/bin/rupert-backup
install -Dm755 deploy/ser8/rupert-backup-verify.sh ~/.local/bin/rupert-backup-verify.sh
install -Dm644 deploy/ser8/rupert-offhost-backup.service deploy/ser8/rupert-offhost-backup.timer \
  deploy/ser8/rupert-backup-verify.service deploy/ser8/rupert-backup-verify.timer -t ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now rupert-offhost-backup.timer rupert-backup-verify.timer
```

The host pull copies only `rupert-<stamp>.sqlite3.gz.age` and `settings-<stamp>.sql.age` with their `.sha256` and
`.key` files. It never copies the env file (its database keys are in the kit; the other secrets come from their
providers). It refuses to run when the container's newest backup is not age-encrypted, when a copy lacks the age
header, or when it does not match the container's digest, and it prunes everything it writes to the newest 35 sets.
There is no key on the host any more: `~/.config/rupert/offhost.key` is only needed to open the old `.enc` sets.

On the mirror machine (any Linux box with `rsync`, `ssh sdolbec-ser8` working in BatchMode, and linger enabled):

```sh
install -Dm755 deploy/offsite/rupert-backup-mirror.sh ~/.local/bin/rupert-backup-mirror.sh
install -Dm644 deploy/offsite/rupert-backup-mirror.service deploy/offsite/rupert-backup-mirror.timer -t ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now rupert-backup-mirror.timer
```

Settings live in the unit's environment (`systemctl --user edit rupert-backup-mirror.service`): `SSH_HOST`, `OUT`,
`KEEP`, `MIN_FREE_MB`, `MAX_AGE_H` (default 30 hours), and `RCLONE_REMOTE` for a cloud copy (`rclone config` first, e.g. a Backblaze B2 or S3 bucket;
the mirror then runs `rclone sync` of the encrypted files after each pull). The mirror only ever holds ciphertext and
its sidecars (`*.age`, `*.age.sha256`, `*.age.key`, and the older `*.enc` sets until they age out).
The mirror checks the newest set's age and verifies each database and matching settings file before reporting success.
An age-encrypted database and settings file must have the same recorded recipient; legacy sets also need their encrypted
environment file. The separate, manual restore drill below is still required to test decryption and recovery.

## Moving from the old, unencrypted host copies

Before #421 a host cron job copied plaintext database dumps, settings dumps and **copies of the env file (with the
Active Record encryption keys)** to `~/backups/rupert` every day and never pruned the env and settings copies. The new
`bin/backup.sh` moves the container's own pre-encryption sets into `/var/backups/rupert/legacy-plaintext/` on its
first encrypted run, so nothing can pull them by mistake. Neither script deletes old plaintext: that is the owner's
call, once the first encrypted run has succeeded and the kit is saved (see the PR for the exact commands).

## Restore

Never restore over the live database as a test. Restore to a copy, check it, then plan a maintenance window.

1. Pick a set. Container: `/var/backups/rupert/rupert-<stamp>.sqlite3.gz.age` with `settings-<stamp>.sql.age` and
   `env-<stamp>.age`. Host or mirror: the same database and settings files (no env copy). Each has `.sha256` and `.key`.
2. Open the recovery kit whose fingerprint matches the `.key` file (`cat rupert-<stamp>.sqlite3.gz.age.key`).
3. On a trusted computer with `age` installed and a Rupert checkout, decrypt and check:
   ```sh
   install -m 600 /dev/null kit.key && "$EDITOR" kit.key      # paste the AGE-SECRET-KEY-1… line from the kit
   bin/backup-decrypt --identity-file kit.key --out restored.sqlite3 rupert-<stamp>.sqlite3.gz.age
   # or: bin/backup-decrypt --identity-stdin --out restored.sqlite3 rupert-<stamp>.sqlite3.gz.age   (paste, Ctrl-D)
   ```
   It checks the `.sha256` digest, refuses a kit with the wrong fingerprint, decrypts (a tampered file fails here),
   decompresses, and runs `PRAGMA integrity_check` and `PRAGMA foreign_key_check`. The key is read from a file or
   standard input, never from the command line (shell history). The same command opens `settings-<stamp>.sql.age`
   and `env-<stamp>.age`. Without the script: `age -d -i kit.key rupert-<stamp>.sqlite3.gz.age | gunzip -c > restored.sqlite3`.
4. Check it further if needed: `sqlite3 restored.sqlite3 'SELECT COUNT(*) FROM payments;'`.
5. Maintenance window, inside the container: `systemctl stop rupert-web rupert-jobs`, move the live
   `production.sqlite3`, `-wal` and `-shm` aside, copy `restored.sqlite3` to `/opt/rupert/web/storage/production.sqlite3`
   (`chown rupert:rupert`, mode 0600), make sure `/etc/rupert.env` has the `RAILS_ENCRYPTION_*` values printed on the
   kit (encrypted settings, tokens and uploads are unreadable otherwise), then
   `systemctl start rupert-web rupert-jobs` and check `/up` and Settings → Connections.
6. The settings dump is only needed if the settings table alone has to be rebuilt; the snapshot already contains it.
7. Delete `kit.key` and the decrypted files when done (`shred -u kit.key`).

Sets made before #421 (`*.enc` on the host and mirror) still open with the old host key:
`openssl enc -d -aes-256-cbc -pbkdf2 -pass file:$HOME/.config/rupert/offhost.key -in rupert-sqlite-<stamp>.sql.gz.enc | gunzip -c > restored.sqlite3`.

## Restore drill (#420)

The weekly host check proves the encrypted copies are intact, fresh and made with the active key, but it cannot
decrypt them. A real drill needs the kit, so it is done by hand on a trusted computer (not SER8), monthly and after
every key rotation:

1. Copy the newest host set (`rupert-<stamp>.sqlite3.gz.age` plus `.sha256` and `.key`) to the trusted computer.
2. Run `bin/backup-decrypt --identity-stdin --out drill.sqlite3 --receipt restore.json rupert-<stamp>.sqlite3.gz.age` and paste the key
   from the kit. It must print `digest ok`, `sqlite integrity_check ok, foreign_key_check clean` and `restored …`.
   Choose a new receipt path for each drill; the command will not overwrite one from an earlier run.
3. Optionally boot a non-production copy with the kit's `RAILS_ENCRYPTION_*` values and open Settings → Connections
   to prove encrypted settings read back.
4. Copy only `restore.json` to the SER8 host over a private channel, then run
   `incus file push --mode 0644 --uid 0 --gid 0 restore.json rupert/opt/rupert/web/storage/backups/restore.json`.
   The receipt records the time, backup filename and public-key fingerprint; it contains no key or restored data.
   System → Backups marks it overdue after 35 days or a key rotation. It proves decryption and SQLite checks, not
   that the application was booted or its encrypted settings opened.
5. Record the date, set stamp, key fingerprint, how long it took and the result in #420 (no hostnames, keys or data).
6. `shred -u drill.sqlite3` and close the note.

## Known gaps

- Google Drive backup is configured but has never uploaded: the Google OAuth app is in Testing and the owner has not
  granted consent. Until then the mirror is the only off-site copy.
- The weekly host check cannot decrypt (by design); only the manual drill with the kit proves a restore.
- The mirror depends on the second machine being switched on; its allowance before **Overdue** is 48 hours for that
  reason. A cloud bucket (`RCLONE_REMOTE`) removes that dependency.
- SER8's disk was at 91% on 2026-10-21 with about 30 GB of backups in the container, about 20 GB of them ad-hoc
  copies from earlier deployments. See "Growth and disk space".
