# Project loops

## Sync Health Loop

Saved 2026-08-09. One-sentence explanation: after each scheduled sync, the loop
observes sync/reconcile/alert health and either fixes the smallest actionable
failure or stops when the pipeline is clean, keeping inventory-count writes
human-approved.

Prompt:
> After each scheduled sync, read SyncRun failures, reconcile drift, and open
> StockAlerts. Pick the single highest-cost actionable failure, trace it to its
> root cause using only in-scope code and logs, and apply the smallest reversible
> fix (config, scoped data repair, or code change). Re-run the sync and check the
> same metric improved. Stop when no sync has failed in the last two runs and
> actionable drift is zero; if the failure is a credential or external outage,
> escalate with evidence instead of retrying.

Source: unpublished design (checked live Loop Library catalog 2026-08-09; closest
published loop is The production error sweep).

### Change log

- 2026-08-09 (debrief, run 1): added baseline guidance — treat failures
  *after the last successful sync* as the working signal, and ignore
  historical failures (already-triaged rows accumulate and never clear on
  their own). This stops the loop from re-auditing the same old failures every
  run. When a fix resolves a failure class, record it here so the next run
  skips that class.

- 2026-08-09 (debrief, run 1): resolved failure classes —
  - `PG::UniqueViolation customers_pkey` → debug customer rows from Phase A;
    sequence is far ahead of max id, no recurrence expected.
  - `undefined method 'order_attrs'` → fixed in Phase A importer refactor.
  - Pre-Postgres `SQLite3`/`SkuLink` errors → historical, pre-migration.
  - One-time `GraphQL 401` → transient token; no recurrence in the last 3 runs.
