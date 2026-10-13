# Moving the live Rupert instance (SER8) from PostgreSQL to SQLite

Status: tooling written and rehearsed against synthetic data (every table, 1,245 cells compared, zero differences).
**Not yet run against the live database.** PostgreSQL is never modified by any step, so rolling back is just switching
the setting back.

## What changed in the code

- `bin/rails db:postgres_to_sqlite` copies a PostgreSQL database into an empty SQLite one. It refuses a non-empty
  target, verifies row counts per table inside one transaction, rebuilds the FTS5 search indexes and reports foreign
  key problems that already existed in the source data.
- `bin/migrate-to-sqlite` wraps it: safety `pg_dump`, schema creation, copy, `PRAGMA integrity_check`.
- `bin/backup.sh` snapshots SQLite (`VACUUM INTO` + integrity check) when `RUPERT_DB_ADAPTER=sqlite3`.
- The app was already SQLite-capable (`config/database.yml`, backups in Settings, system page); the full test suite
  passes on both adapters.

## Before you start

1. Merge and deploy the code that contains these files to the Rupert container (deploying is a separate step from
   merging; see the README's Production section).
2. In the container: `apt install sqlite3`. Confirm free disk is at least twice the database size
   (`du -sh` of the Postgres data directory is a fine upper bound).
3. Keep the existing `.env`. The `RAILS_ENCRYPTION_*` keys must not change, because the settings table (Square and
   Shopify tokens) is copied as-is and decrypted with them.
4. Pick a quiet window. Sync is a read-only mirror, so a short outage loses nothing; the copy takes seconds to minutes.

## Cutover

```bash
# 1. stop the web server and the job worker (unit names are whatever the Incus container uses)
# 2. take the copy
./bin/migrate-to-sqlite
# 3. switch
echo 'RUPERT_DB_ADAPTER=sqlite3' >> .env
# 4. start web + jobs, then check:
#    - sign in, open Dashboard, Inventory, Customers (search), Sync
#    - Sync page: run one source sync and watch it finish
#    - Settings > Backup: download a snapshot
./bin/backup.sh     # confirms the SQLite backup path works on this host
```

## Rollback (any time)

Remove the `RUPERT_DB_ADAPTER=sqlite3` line from `.env` and restart. PostgreSQL still has all data up to the moment you
stopped the app. Anything written to SQLite after cutover is not carried back, so decide within the first day.
The safety dump `pre-sqlite-*.dump` in `/var/backups/rupert` can rebuild PostgreSQL if it is ever needed.

## After a week

- Make sure the timer-driven `bin/backup.sh` has produced SQLite snapshots (`rupert-*.sql.gz` now holds a gzipped
  `.sqlite3` file) and restore one on a scratch machine: `gunzip -c rupert-X.sql.gz > test.sqlite3`.
- Then retire PostgreSQL on the host and drop the `pg` dependency in a follow-up change.

## Known differences

- Search: PostgreSQL used `pg_trgm`; SQLite uses FTS5 trigram for terms of three or more characters.
- One writer at a time: SQLite is configured with WAL and a 5 s busy timeout. The sync and job worker use short
  transactions, so this is fine at current volume; raise `SQLITE_BUSY_TIMEOUT_MS` if you ever see lock errors.
- `System` page shows file size and pool data instead of `pg_stat_*` views.
