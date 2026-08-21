# Two-location pivot — implementation record (2026-08-21)

The operating model changed: **Shopify and Square are two distinct locations
frequently serving the same items from different inventories.** The codebase
was built on the opposite assumption ("one shared pool, inventory stays in
lock-step" — see the superseded `docs/plans/migration_phase_plan.md`). This
document records what changed, why, and what to check after deploying.

## Commits (oldest first)

| Commit | Change |
| --- | --- |
| `4e05010` | Reconcile planning gated behind flag; product sync paginated past 250; lookup indexes; money-handling fixes; drift-migration WIP completed |
| `5bd1e87` | Shopify inventory mirrored **per location** (Square already was); explicit `primary_location` on `Location`; `SHOPIFY_LOCATION_ID` pin |
| `d906ef1` | Reconcile → **Catalog Links** (read-only SKU identity audit); Reconciler/PlanApplier/InventoryMaintainer/InventoryPolicy removed; scheduled sync became a pure read-only mirror |
| `203edcb` | Location-first Inventory view (per-location columns, per-platform totals, identity chips) |
| `a692b8a` | Alerts → **restock queue** (velocity, days of cover, suggested reorder) |
| `fb1992b` | Nav regrouped around operator workflows (Sell / Stock / Money / Work / Team / System) |
| `2d10aa0` | Incremental order imports via per-source watermarks + 48h refresh tail |
| `6a1ccbe` | Nightly data retention (movements 180d, ledger 365d, logs 90d) |
| `8272d15` | Batched sync writes; fixed NULL-tenant mirror rows (+ healing migration) |
| `038bd5d` | Query hot spots: customer LTV, PDF sums, Sales presenter, warehouse portal cache |
| `6cb94d5` | pg_trgm GIN indexes for global search |

## The model now

- The sync loop is a **read-only mirror**: catalog, per-location stock,
  orders → canonical ERP core. It never equalizes quantities.
- `SkuLink` means "same sellable item", nothing more. Quantity differences
  across locations are normal and are not counted as problems anywhere.
- Outbound stock writes exist only in explicit, owner-approved flows
  (size-family derives, remediation tasks). SKU writes require owner sign-off.

## Post-deploy checklist

1. `bundle install`, `db:migrate` (lookup indexes, primary_location,
   trgm indexes, tenant-id healing), restart web + jobs.
2. First sync after deploy re-baselines Shopify levels per location — expect
   one-time movement-ledger churn and pruned stale rows. Expected, not a bug.
3. If your primary selling location is not Shopify's first ACTIVE location,
   set `SHOPIFY_LOCATION_ID` (Settings → env import, or `.env`).
4. Sync run details now include `oversold_variants` when Shopify reports
   negative stock (mirrored as 0 by design).
5. Watermarks: first sync backfills with the default window; afterwards only
   watermark-minus-48h. Full re-imports: `ops:backfill[DAYS]`.

## Deliberately not done

- **solid_cache**: evaluated and skipped — cached blobs (PDFs) fit the file
  store fine at this scale; moving them into Postgres adds churn without a
  win here.
- **InventoryPolicy / ReconcileRun tables** remain in the database (historical
  data) but are no longer written or read by app code.
