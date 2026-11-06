# Time & pay: production deploy log (SER8)

Production: Incus container `rupert` on SER8 (`ssh ser8`, then `incus exec rupert -- …`), app at
`/opt/rupert`, served as herbalhealers.rupertpos.com. Merging to `main` deploys through
`rupert-autodeploy` (see `deploy/ser8/README.md`). Each entry: what, when (UTC), backup, result, smoke.

## 2026-11-06 13:10 — pre-flight findings (no deploy)

- Running build `f10b74f9` (PR #639), healthy. Autodeployer was **blocked: "checkout is dirty"** since
  the Nov 3 deploy: `web/db/schema.rb` in `/opt/rupert` differed from `main` by one auto-generated index
  name (`idx_on_tenant_id_external_reference_id_e26edee850` vs the 65-character name in the repo). Stashed
  it in the container (`git stash` "autodeploy-blocker schema.rb index name 2026-11-06"); deployer now
  reports `up_to_date`. Root cause: SQLite's 62-character index-name limit renames that index when the
  migration runs on a fresh database; the committed `schema.rb` carries the long name. Fix in a follow-up
  migration/schema touch-up so it does not recur.
- **Scheduled backups are failing** (`frequent`, `local` since at least Nov 1; `verify` finds no encrypted
  backup): "refused: no active backup key … Create one in Settings → Backups". Only the deployer's own
  unencrypted pre-deploy copy (`/var/backups/rupert-autodeploy`) is being taken. **Owner action**: create
  the backup key in Settings → Backups and store the recovery kit; until then every deploy here is
  preceded by a manual `sqlite3 .backup` + `integrity_check` inside the container (recorded below).

## 2026-11-06 13:30 UTC — PR #640 foundation (`b7fdbf63`) — deployed, healthy

- Pre-deploy: manual `sqlite3 .backup` to `/var/backups/rupert-manual/production-20261106-132414-pre-timepay.sqlite3`
  (sha256 `88a4f7b0…0f67`), `PRAGMA integrity_check` ok, foreign keys clean; the deployer's own backup
  `production-20261106-133001-f10b74f9-15e212e5fe97ea85.sqlite3` was also taken.
- Install: autodeploy, 3 additive migrations applied, `/up` healthy, smoke passed, `X-Rupert-Build: b7fdbf63`.
- Post-deploy: checkout clean (no schema.rb drift this time), `rupert-logs errors` empty for the window, `rupert-web`
  and `rupert-jobs` active, `/login` and `/up` 200 (staff pages redirect to sign-in as expected). No user-facing
  change in this deploy.

## 2026-11-06 14:12 UTC — PR #642 clock, scheduling, tips, manager (`eb246e60`) — deployed, healthy

- Pre-deploy: manual `sqlite3 .backup` to `/var/backups/rupert-manual/production-20261106-140603-pre-pr642.sqlite3`
  (sha256 `756b98a1…`), integrity ok; deployer backup `production-20261106-141146-b7fdbf63-09c7fa9af6f4b569.sqlite3`.
- Install: autodeploy, 1 additive migration (`pay_period_adjustments`, `leave_accruals`, two employee columns), `/up` healthy,
  smoke passed, `X-Rupert-Build: eb246e60`, checkout clean afterwards (the FEED index name in `schema.rb` now matches what
  migrate generates, so the Nov 3 drift cannot recur).
- Live smoke test (Playwright against https://herbalhealers.rupertpos.com) with two temporary accounts created in the
  workspace for the test (`smoke-staff@`, `smoke-manager@rupertpos.com`): staff **clock in → break → end break → clock out**
  on `/employee` (EST times shown), `/employee/schedule`, `/employee/time-off`, `/employee/pay`, `/time_clock` all render;
  manager `/people/approvals`, `/people/timesheets`, `/people/schedule` render. `/people/tips`, `/people/pay_periods`,
  `/settings/time_rules`, `/people/clock_devices` refused the `manager` role as designed (payroll/settings/hr.write are
  admin permissions). `rupert-logs errors` empty for the window. The smoke punch and break were deleted, the smoke worker
  terminated and both accounts deactivated (owner may delete them from Accounts).
- Host disk: 99% used (15 GB free) on SER8's root volume; the deployer keeps five 300 MB backups. Worth a cleanup soon.

## 2026-11-06 15:00 UTC — host note (owner)

The owner's session freed 49 GB on SER8 (root volume now 93%, ~64 GB free) and set a keep-newest-10 retention on
`rupert-model-audit`. Rules from here on: check `df -h /` before any deploy or backup and do not deploy under ~25 GB free;
create no large artifacts on SER8; rely on the deployer's own pre-deploy backup (verified after the install with
`PRAGMA integrity_check`) instead of extra manual copies. The two manual copies taken earlier today were removed. Deploys
are serialized by the updater's own `flock` on `/run/rupert-autodeploy.lock` and always come from `origin/main`.
