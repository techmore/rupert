# SER8 auto-update verification — November 2, 2026

SER8 was already running `main` (`d86e5fe2a10ec4cdb21dcea0ed52a0760f781fc0`), installed by the existing
[auto-updater](../../deploy/ser8/README.md#auto-deploy-rupert-autodeploy). This pass added an operator pause,
the one-command `rupert-rollback` and a forced-failure test switch
([pause and roll back](../../deploy/ser8/README.md#pause-and-roll-back)), installed them, and proved the full cycle
on the live host with the owner's approval. A fresh private database and configuration backup was taken first.

| Test (UTC) | What ran | Result |
| --- | --- | --- |
| No-op, 12:39 | `systemctl start rupert-autodeploy.service` at `main` | `up to date at d86e5fe2`; no restart |
| Pin back, 12:44–12:45 | `rupert-rollback 085dc778` | paused the updater, rebuilt, restarted; `/login` served `X-Rupert-Build: 085dc778…`; the next timer run reported `paused by operator` |
| Forced failure, 12:45–12:46 | `RUPERT_AUTODEPLOY_FORCE_HEALTH_FAIL=1 rupert-autodeploy.sh` | backup, install of `d86e5fe2`, health check failed on purpose, automatic rollback verified healthy on `085dc778`; failure receipt written (`failed_stage: health`, `rollback: healthy`) |
| Real update, 12:46 | `rm failed-sha`, `systemctl start rupert-autodeploy.service` | green exact-SHA CI gate, backup, `085dc778 → d86e5fe2`, `deployed d86e5fe2, healthy` in 8 s; success receipt written |
| No-op again, 12:46 | same unit | `up to date at d86e5fe2` |

During the forced-failure run the 5-minute timer fired and backed off (`another deploy is running`), confirming the
lock. The two commits involved have no migrations between them. Final state: checkout clean at `d86e5fe2`, web
and jobs active, timer and path units active, automatic mode, no pause or failed-commit marker. Public `/up` and
`/login` returned HTTP 200 with the `d86e5fe2` build header; protected pages redirected signed-out visitors and the
inventory API returned 401. The web log had no errors after the tests. Pre-existing C-Trax sync errors continued and
are unrelated.

Command output and the backup location are kept privately, outside Git.

Not covered here: the scheduled `rupert-backup` and `rupert-backup-frequent` runs refuse to write without an active
backup key (Settings → Backups). The pre-deploy backups taken by the updater are separate and worked.
