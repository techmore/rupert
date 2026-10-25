# Backups and restore

Last checked against `main` at `ec5ae024` on `2026-10-25`.

## Purpose and owner

Keeps recoverable copies of the one SQLite database (which also holds uploaded
files and receipts) and shows whether each backup layer is reporting. Product
owner: the store owner; host scripts are run by the instance operator (platform
super administrator). The full runbooks are
[backups](../ops/backups.md) and the
[backup and restore runbook](../ops/backup-restore-runbook.md).

There is **no `ModuleRegistry` entry** for backups. Backup status is a section
of **System → System health** (`system`, super admins with `system.read`), and
Google Drive backup is a section of **System → Settings** (`settings`).

## Data model

- The source of truth is the database file itself. Upload bytes are stored in
  the database encrypted, so a restore also needs the `RAILS_ENCRYPTION_*` keys
  from the server environment.
- Host and container layers write a JSON status file per layer
  (`storage/backups/<layer>.json`: state, time, message, file, bytes, kept,
  free space). The app only reads them (`BackupStatus::LAYERS`: `frequent`,
  `local`, `offhost`, `offsite`, `verify`).
- Google Drive attempts are `BackupLog` rows (status, file name, Drive link,
  start and finish, error). Instance-wide rows have no tenant.
- Drive connection settings (refresh token, folder, allowed domain) are
  encrypted settings. Drive keeps 7 copies by default
  (`GoogleDriveBackupService::DEFAULT_RETENTION`).

## Permissions and tenant boundary

- Backup status on System health: super admin with `system.read`
  (`SystemController#require_system_access`).
- Settings backup actions (download snapshot, Drive status, logs, connect,
  run now, disconnect, allowed domain): super admin only.
- Full-instance downloads and Drive backup actions are refused from the browser
  when the instance hosts other customers' workspaces
  (`protect_customer_backup_exports`).
- Backups are whole-instance, not per tenant.
- MCP `backup_freshness` (`system:read`) shows ages and names only, for a
  platform administrator or a private workspace owner.

## Routes and API

- `GET /settings/backup` (download a consistent snapshot),
  `POST /settings/restore`, `GET /settings/drive_status`,
  `GET /settings/drive_logs`, `GET /settings/drive_auth`,
  `GET /settings/drive_oauth_callback`, `POST /settings/drive_backup`,
  `POST /settings/drive_disconnect`, `POST /settings/drive_domain`.
- No `/api/v1` endpoint. MCP: `backup_freshness`. See
  [API standards](../api-standards.md).

## Workflow and status transitions

- Each layer shows ok, failed, **Overdue** (no report inside its interval) or
  **Not reporting** (never reported; not installed on this server).
- Drive backup (`BackupJob`, every 6 hours when connected): snapshot, upload,
  verified download, prune to the retention count. Each run is one `BackupLog`.
- Restore from the browser is refused: `BackupService.restore!` raises
  "Database restore requires offline maintenance…" and changes no files.
  Restore is a manual maintenance procedure in the runbook.

## UI patterns

Backup layers are a row list on the System health page; Drive backup is a
section card on the Settings page. Departures from the interface guidelines:
Unknown.

## Integration and sync

- Host scripts under `deploy/` (rolling snapshot every 5 minutes, local set and
  encrypted off-host copy every 6 hours, mirror on a second machine, weekly
  restore drill) and a pre-deploy copy taken by the auto-deployer.
- Google Drive: writes backup files to the owner's Drive folder, no external
  sharing. Not connected: consent fails with `access_denied` while the OAuth
  app is in Testing (see [Google backup verification](../ops/google-backup-verification.md)).
- Nothing here writes to Shopify, Square or other commerce systems.

## Audit history

Activity entries: `drive_backup_run`, `drive_disconnected`, `drive_domain_set`,
`database_restored` (only reachable if a restore ever succeeds), and
`data_exported` ("Full database snapshot") for snapshot downloads. Host layers keep their own JSON status and logs.

## Failure and recovery

- Every host script refuses to run when free disk would fall under
  `MIN_FREE_MB`, and reports **Failed** with the reason.
- A failed Drive run is a `BackupLog` with an error; the next scheduled run
  retries.
- Recovery: restore to a copy, check `PRAGMA integrity_check` and
  `foreign_key_check`, then replace the live file in a maintenance window with
  web and jobs stopped and the same encryption keys. Restoring after business
  writes can lose data and needs the owner's written approval.

## Required tests

- `web/test/services/backup_service_test.rb`, `backup_status_test.rb`,
  `google_drive_backup_service_test.rb`
- `web/test/jobs/backup_job_test.rb`, `web/test/models/backup_log_test.rb`
- `web/test/integration/system_backups_test.rb`, `drive_backup_test.rb`,
  `drive_platform_access_test.rb`, `drive_setup_instructions_test.rb`
- Host backup scripts have no automated tests in `deploy/ser8/tests`; the
  weekly restore drill is their check.

## Open gaps

- #419: Google Drive consent and a verified real upload and restore. Open.
- #418: prove upload bytes are backed up and restorable with their keys. Open.
- #420: prove the daily recovery objective from dated receipts and run a
  restore drill. Open.
- #421: encryption in transit and at rest for uploads, chat, payroll and
  backups. Open.
- Every copy except the mirror is on SER8's single disk.
