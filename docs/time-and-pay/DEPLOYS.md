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

## 2026-11-11 05:15 UTC — PR #650 multi-workspace audit and switches (`746ccd7f`) — deployed, healthy

- Pre-deploy: `df -h /` 133 GB free (85% used); checkout clean at `0cb2020a`; `rupert-web` and `rupert-jobs` active;
  `rupert-logs errors` empty. SER8 was reached over Tailscale (`ssh ser8-ts`); the LAN address did not answer.
- Install: autodeploy after `CI (sqlite3)`, `Product site consistency` and `Dependency and static scan` passed on the
  merge commit. One additive migration (`tenants.time_zone`, an index on `push_devices.token_digest`). Deployer backup
  `production-20261111-051522-0cb2020a-fe7f4bbf5ea74ab4.sqlite3` (360 MB), `PRAGMA integrity_check` ok.
  `autodeploy: deployed 746ccd7f, healthy`; `X-Rupert-Build: 746ccd7f…`; checkout clean afterwards.
- Smoke (curl with a cookie jar against https://herbalhealers.rupertpos.com, temporary accounts only: the two smoke
  accounts from Nov 6 reactivated with fresh random passwords, plus a temporary `smoke-admin@rupertpos.com`):
  - Staff: sign in → `/employee`, `/employee/schedule`, `/employee/time-off`, `/employee/pay`, `/time_clock`,
    `/people/timesheets`, notification settings and `/clock` all 200; **clock in → break → end break → clock out**
    each redirected back to `/employee`; `/settings/time_rules` refused (403); a wrong PIN from the signed-in phone
    answered "That isn't your PIN. On this device only your own PIN works…".
  - Manager: `/people/approvals`, `/people/timesheets`, `/people/schedule`, `/people/team_schedule`,
    `/people/punch_history`, `/time_clock` 200; `/settings/time_rules` refused.
  - Admin (read only, nothing saved): `/settings/time_rules` 200 with the time zone select, **What is turned on**
    (every switch checked) and **Punch logging** (audit trail unchecked); `/people/pay_periods`, `/people/tips`,
    `/people/clock_devices`, `/activity` 200.
- Cleanup: the one smoke punch (shift 4) and its break deleted; smoke worker 37 terminated again; the three smoke
  accounts deactivated with their passwords replaced by random values (owner may delete them from Accounts). No real
  employee's hours were submitted, approved or changed. The workspace's settings were not touched: no
  `tenant_time_rules` row, time zone blank (instance default), no punch audit lines.
- Post-deploy: `rupert-logs errors` empty, both services active, `/up` and `/login` 200, 132 GB free.
- Not verified live: a second workspace (production has one), the switches in the off position (they would change the
  live workspace; covered by `time_features_settings_test.rb`), and push delivery (no APNs key on the server yet).

## 2026-11-11 18:21 UTC — PR #652 simple backups and short paid breaks (`8fefc13c`, served as `0e6b9e1e`) — deployed, healthy

- Pre-deploy: `df -h /` 236 GB free (73% used); checkout clean at `298470a7`; `rupert-web` and `rupert-jobs` active.
- Install: autodeploy after `CI (sqlite3)`, `Product site consistency` and `Dependency and static scan` passed. #652 and
  the iPhone-only #653 went out in one move (`298470a7 -> 0e6b9e1e`, 0 migrations). Deployer backup
  `production-20261111-182106-298470a7-6e818009efac8741.sqlite3`, `PRAGMA integrity_check` ok.
  `autodeploy: deployed 0e6b9e1e, healthy`; `X-Rupert-Build: 0e6b9e1e…`; checkout clean afterwards.
- Looked at live (one temporary super admin, GET requests only, nothing saved): **Settings → Backups** shows
  "Backups are off" with the two-step **Turn on backups** path; the dashboard carries the "Backups are off" banner;
  the bell shows the alert and Notifications lists it; the status bar reads "Backups off" in red; Time rules shows
  the "20 minutes or less is always paid" line. `/settings/backups.json` answers `{"signature":"::off"}`.
- **No backup key was created.** The recovery kit must go straight to the owner, so backups stay off until the owner
  clicks Settings → Backups → Turn on backups, saves the kit and types its check code. The rolling snapshot then
  runs within 5 minutes, the full set and the copy outside the container within 6 hours, the weekly check on Sunday.
- Host (SER8, outside the container), read only: `rupert-offhost-backup.timer` (every 6 h, plus the 07:17 cron line)
  and `rupert-backup-verify.timer` (Sunday) are installed and firing; both fail only because the container refuses to
  make a backup without a key ("no active backup key"). Nothing was changed on the host and no key was created there.
  The mirror on the second machine last reported Oct 29 (old unencrypted-era set); it is listed under "Extra
  protection" on the Backups page and needs that machine switched on after the first encrypted set exists.
- Cleanup: the temporary account was deleted (not deactivated); the two sign-in lines it left in the access log stay,
  as an audit record. The three smoke accounts from Nov 6 and Nov 11 were already gone.
- Post-deploy: `rupert-logs errors` shows only warnings that were there before this deploy (the boot-time image-variant notice
  and "Scoped order is ignored"), no errors; both services active, `/up` and `/login`
  200, 233 GB free.
- Not verified live: creating a kit, the check code step and the first encrypted backup (owner only; covered by
  `backup_health_alerts_test.rb` and `backup_keys_test.rb`), and the daily notification (the job runs on the hour).
