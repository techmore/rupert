# Phase migration plan — sync Shopify & Square inventory/SKUs

> **SUPERSEDED (2026-08-21).** The operating model changed: Shopify and Square
> are two distinct locations frequently serving the same items from different
> inventories. Inventory no longer syncs "in lock-step" between them — the
> quantity-equalization phases below were never fully executed and the
> machinery was removed. What survives from this plan is the SKU *identity*
> work (shared SKUs, linking), now surfaced on the Catalog Links page.

Goal: a single system where shared products exist on both platforms under the
same SKU, inventory stays in lock-step, and Shopify-only wholesale/bulk items
are tagged so they never sync to Square.

Audit snapshot: 2026-08-18 (live mirrors). Numbers change as catalogs change.

---

## Phase 0 — Shared products & shared SKUs (the sync set)

The sync set is the products that exist on **both** platforms. Measured overlap
is tiny:

- Shopify products: **54** | Square items: **237**
- Shared by name: **2** → `Frosted Grapes (Hybrid)` (already linked in the
  pilot) and `Blue Lotus Sleep Gummies` (already linked earlier).
- Everything else is one-sided.

**Action:**
1. Freeze a canonical list of "shared products" (business-confirmed) — the
   pilot pattern proved the import+link flow for Frosted Grapes.
2. For each shared product: one canonical SKU (Square's), set on both, linked,
   inventory set from Square.
3. Anything confirmed shared but not yet linked → migrate with the pilot
   process, one at a time, verified.

## Phase 1 — SKU drift (linked but SKU differs)

Only **1** drift found among linked variants:
`King Cone Pre-Roll - THCA` (Shopify SKU nil) vs Square `Q188573` (Fusion (Hybrid)).

**Action:** assign Square's SKU to the Shopify variant, re-link. (Small, safe,
do now.)

## Phase 2 — SKU mismatch (same product, different SKU per platform)

**0** mismatches found in the shared set — good baseline. As Phase 0 imports
more shared products, re-run this check each time so new mismatches are caught
immediately.

## Phase 3 — Inventory absence (product exists on one side only)

- **Shopify-only with stock: 81 variants / 2,136 units** (strains, edibles,
  wholesale). These are the **wholesale-tag candidates** (Phase 4) or items to
  intentionally leave Shopify-only.
- **Square-only with stock: 166 variations** — most under generic names
  (`Regular` 731 units, `3.5 Grams` 180, `3 Count` 459, …). Per the model
  (Square ⊂ Shopify) these are what a future Square→Shopify import would bring
  over — but only the **cleanly-named** ones (e.g. `Mango Lemonade 100`,
  `Root Beer`, `Raspberry 50mg`) make sense as Shopify products; the generic
  ones need a naming/decision pass first.

**Action:**
1. Decide per Square-only group: import-as-product (clean names) vs
   leave-as-Square-only (generic/event/wholesale rig).
2. Then apply the pilot process to the clean ones.

## Phase 4 — Wholesale tagging (Shopify-only, never syncs to Square)

Shopify-only tracked products **with stock** that have **no Square link** =
wholesale-tag candidates:

- `Afghan Black Hash — Wholesale` (already titled wholesale)
- **~32 other products** (all the strains + a few edibles), totaling
  **2,136 units** that must never sync to Square.

**Action:**
1. Apply a `wholesale` tag/metafield on Shopify to these (excludes them from
  sync/import in the engine).
2. Make the engine honor the tag: `wholesale`-tagged Shopify products are never
  created/linked in Square and never have their counts pushed to Square.

---

## Order of execution (recommended)

1. **Phase 1 (1 item)** — quick win, do now.
2. **Phase 4 tagging** — tag the ~32 wholesale candidates so they're excluded
   from any sync, before we touch Square imports (safety).
3. **Phase 0 (shared set)** — confirm the business list, then import/link shared
   products via the verified pilot process, one at a time.
4. **Phase 2 checks** — re-run after each import.
5. **Phase 3 (Square-only)** — import cleanly-named Square products; generic ones
   get a naming decision (deferred).

Note: the audit is read-only; nothing was changed to produce it. This plan is
the roadmap — each phase should be executed in small, verified batches with a
sync + verify after each.
