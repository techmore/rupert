# Release process

Production does not wait for a release. SER8's updater
(`deploy/ser8/rupert-autodeploy.sh`) installs the tip of `main` once that exact
SHA is green: in **Automatically** mode (the default) on its next 5-minute poll,
in **Only when I click Install** mode when an operator requests it from
**System → Updates**. A stable `v*` tag is a separately gated product milestone:
creating one does not install anything, and a `main` install is neither a stable
release nor operator acceptance. The end-to-end policy is the canonical
[development and deployment workflow](../development-and-deployment-workflow.md);
the updater's gates, receipts and files are in the
[SER8 updater runbook](../../deploy/ser8/README.md#auto-deploy-rupert-autodeploy).

Each PR must pass the current required checks: `CI (sqlite3)`, `Product site
consistency`, `Dependency and static scan`, and `cla`. The updater then waits
for the newest exact-SHA `CI (sqlite3)`, `Product site consistency`, and
`Dependency and static scan` checks on the integrated `main` SHA (plus mobile
`validate` on the newest mobile commit when mobile paths changed). Missing or
pending results wait; any completed non-success result blocks. `cla` remains a
pull-request check, not an integrated-main check.

## 1. Install a change on SER8 (normal path)

Merge the PR. The updater fast-forwards `/opt/rupert` to the green `main` SHA,
takes a pre-deploy SQLite backup, runs `bundle install`, `db:migrate` and
`assets:precompile`, restarts `rupert-web` and `rupert-jobs`, checks `/up` and
smoke-checks the rendered layout and its assets. Any failure rolls the code
back to the previous commit (migrations stay applied) and records the SHA in
`failed-sha` so it is not retried every poll. Every install attempt writes a
release receipt. Nobody runs `git checkout`, `db:migrate` or a restart by hand
for a normal change.

Before merging a migration, follow the migration safety rules below: the
updater does not revert migrations and a running scheduled job is interrupted
by the restart.

## 2. Verify

Inside the `rupert` container:

```bash
rupert-deploy-receipt                       # newest receipt: result, deployed/previous SHA, check-run URLs, backup, /up, smoke
cat /var/lib/rupert-autodeploy/status.json  # state, mode, current/target commit
journalctl -u rupert-autodeploy -n 50
```

From anywhere:

```bash
curl -sI https://herbalhealers.rupertpos.com/up | grep -i x-rupert-build     # equals the deployed main SHA
curl -s  https://herbalhealers.rupertpos.com/up/ready                          # "ready" once the worker heartbeats and the next sync lands
```

Then sign in, open the changed feature, Dashboard and the Sync page; wait for
the next 15-minute sync to succeed. A receipt and a healthy `/up` prove what the
updater installed and checked, not operator acceptance; record acceptance
separately as the [workflow guide](../development-and-deployment-workflow.md#5-deployment-receipt-and-recovery)
describes.

## 3. Cut a stable release (on a laptop)

A stable release names a commit that is already on `main` and already
installed and verified. It does not change what SER8 runs.

```bash
git checkout main && git pull
# bump VERSION (semver), move CHANGELOG "Unreleased" under a dated heading, land it through a PR
git tag -a v0.3.0 <merged release-commit SHA> -m "Rupert 0.3.0" && git push origin v0.3.0
```

The `Release` workflow creates the GitHub release with notes from the commits.
The tag must target the intended exact SHA whose integrated checks passed. If
the Shopify app configuration changed (`shopify.app.toml`), run
`shopify app deploy` from the repo root with the owner's Partner account.
Nightly prereleases follow [nightly releases](nightly-releases.md).

## 4. Roll back

- **Failed deploy:** the updater has already rolled the code back; the failed
  receipt's `rollback` field says whether the previous code came back
  `healthy`. Fix forward with a new PR; a newer `main` SHA clears the
  `failed-sha` hold.
- **Bad change that deployed healthy:** revert it with a PR (`git revert`) and
  let the updater install the revert. This keeps `/opt/rupert` on `main`.
- **Emergency manual rollback:** first switch System → Updates to **Only when I
  click Install** (or `systemctl disable --now rupert-autodeploy.timer
  rupert-autodeploy.path`), otherwise the next poll fast-forwards back to the
  `main` tip. Then, under the updater's lock, check out the previous good SHA
  from the latest receipt's `previous_sha`, rebuild assets and restart:

  ```bash
  flock /run/rupert-autodeploy.lock sh -c 'cd /opt/rupert && git checkout -q --detach <previous_sha>'
  # as rupert, with /etc/rupert.env loaded, in /opt/rupert/web:
  bin/rails tailwindcss:build && bin/rails assets:precompile
  sudo systemctl restart rupert-web rupert-jobs
  ```

  The updater does not write a receipt for a manual rollback; record it in the
  operator log. Return to automatic mode only after the fix is merged and green.

Additive migrations can stay in place (the previous code ignores new
tables/columns). A migration that changed existing columns needs its `down`
rehearsed on a restored copy before rolling back, or restore the pre-deploy
backup named in the receipt following the [backup runbook](backup-restore-runbook.md)
— only if no business writes happened since, or with the owner's written
approval of the data loss.

## Migration safety rules

- Prefer additive migrations (new tables, nullable columns, new indexes). Backfill in a separate step; drop old columns in a later release.
- Never run a migration that rewrites a large table during opening hours; SQLite holds the write lock for its duration. In automatic mode a merge installs within minutes, so merge such a change after hours or switch to **Only when I click Install** and request the install then.
- `db/schema.rb` is the single SQLite schema dump and changes with every migration; CI loads it.
- Rehearse every migration on a restored copy (`bin/restore-drill --keep`, then `RUPERT_SQLITE_DATABASE_PRODUCTION=<copy> bin/rails db:migrate`) before merging.
