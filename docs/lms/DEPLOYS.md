# Learning center: deploy log

Production is SER8, deployed by `rupert-autodeploy` from green `main` (see `docs/ops/release-process.md`).
Each entry records what shipped, the backup, the checks, and what was verified live.

## 2026-11-06 · `1750f0ab` · PR #643 · first release

- **What**: Learning center (reusable LMS) and the course *How our card payments work*. One additive migration
  (`20261106120000_create_lms`, eight `lms_*` tables). Nothing runs on boot.
- **Before**: `main` at `eb246e60` was deployed and healthy. The production checkout had been left dirty by a
  generated one-line `web/db/schema.rb` drift (an index name), which blocks the updater; restored it to the
  committed file under the updater lock (`flock /run/rupert-autodeploy.lock git checkout -- web/db/schema.rb`).
  Host disk was at 99%; the owner's session freed space to ~64 GB before this install.
- **Backup**: the updater's pre-deploy copy `production-20261106-142211-eb246e60-….sqlite3` (SHA-256 in the
  receipt). The previous copy (`…-141146-b7fdbf63-…`) was opened read-only and checked by hand before the merge:
  `integrity_check` ok, 276 tables, 16 users.
- **Install**: receipt `1750f0ab07a7….json`, started 14:22:11Z, finished 14:22:28Z, `db:migrate` succeeded
  (1 new), `/up` 200, asset smoke passed, `X-Rupert-Build` = `1750f0ab…`.
- **After**: `/up/ready` reports database, worker, last sync and disk ok; `rupert-web` and `rupert-jobs` active;
  no errors in the web journal since the deploy. `/learning-center` answers 302 → `/login` for a signed-out
  request (the controller logged the request normally). Ran `bin/rails lms:seed` as the app user with the
  service environment: the Herbal Healers workspace now has the course (8 lessons, 24 questions, 3 rules,
  0 enrollments; managers are enrolled when they first open the Learning center).
- **Not yet verified live**: a signed-in walk through a lesson on production. The same flow is covered by the
  integration tests and was checked in a browser against the demo workspace before merge; the owner's first
  visit is the live check. Roll back with `rupert-rollback` if anything looks wrong; the migration is additive,
  so the previous build runs against the migrated database.
