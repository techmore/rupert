# Audit — Inventory PDF report integrity (Shopify vs Square columns)

Date: 2026-08-17
Scope: read-only audit of the inventory PDF report data source ("what is stored" vs "what is queried"), and why Shopify/Square info can appear in the wrong column, or be missing / not-all-SKUs.

Files examined:
- `web/app/services/inventory_pdf.rb` (report builder + queries)
- `web/app/models/inventory_level.rb` (quantity aggregation)
- `web/app/models/sku_link.rb`, `shopify_variant.rb`, `shopify_product.rb`, `square_variation.rb`, `location.rb`
- `web/app/services/catalog_syncer.rb` (Shopify mirror writer)
- `web/app/services/square_syncer.rb` (Square mirror writer + SKU linking)
- `web/app/services/inventory_maintainer.rb` (pool sync)
- `web/app/services/reconciler.rb`
- `web/app/services/syncer clients` (`shopify_client.rb`, `square_client.rb`)
- `db/schema.rb`, `db/migrate/*`

---

## 1. Where the PDF gets its numbers

`InventoryPdf#load_rows` is the single source for the catalog table:

```
shopify_map = InventoryLevel.shopify_totals    # { shopifyVariantId  => sum(quantity) }
square_map  = InventoryLevel.square_totals     # { squareVariationId => sum(quantity) }
link_map    = SkuLink.linked.index_by(&:shopifyVariantId)
```

Per variant:
- **Shopify column** = `shopify_map.fetch(variant.id, 0)`
- **Square column** = `link ? square_map.fetch(link.squareVariationId, 0) : nil` (nil renders as "—")
- **Drift column** = `square - shopify`

### What is stored (the mirror)
- `InventoryLevel` rows are written only by `CatalogSyncer` (source `shopify`) and `SquareSyncer` (source `square`).
  - `quantity` = the platform's current on-hand at that location; `available` = same value at mirror time.
- `ShopifyVariant.inventoryQuantity` is also written from Shopify's `inventoryQuantity` field.
- `SkuLink` maps a Shopify variant → a Square variation by matching `sku` (case-insensitively), created automatically in `SquareSyncer#sync_links!`.

### What is queried
- `InventoryLevel.shopify_totals` = `WHERE source='shopify' GROUP BY shopifyVariantId SUM(quantity)` — **across every Shopify location**.
- `InventoryLevel.square_totals` = `WHERE source='square' GROUP BY squareVariationId SUM(quantity)` — **across every Square location**.
- Rows are enumerated from the **Shopify catalog only** (`ShopifyProduct.order(:title).includes(:variants)`).

---

## 2. Root causes of the observed symptoms

### 2a. "SKUs missing / not all SKUs in the report"
The report is driven entirely by the **Shopify catalog**. Any inventory that only exists in Square (or whose Shopify row can't be SKU-linked) never renders:

- **Unlinked Shopify variants** show `—` for Square (by design), but
- **Square variations with no matching Shopify variant/SKU are absent from the report entirely** — they are never iterated in `load_rows`.
- **Square variations whose SKU matches nothing** (Square order lines commonly carry junk SKUs like "Regular") get no `SkuLink`, so the linked Shopify variant (if any) shows `—` even though the Square stock is mirrored.

So the report can under-report: some SKUs exist in the data but are not reflected in the PDF.

### 2b. "Square quantity appears on the wrong variant / wrong column"
Root cause is **shared-SKU collisions in `SquareSyncer#sync_links!`**:

```ruby
by_sku = {}
catalog.each { |v| by_sku[v[:sku].downcase] = v[:variationId] if v[:sku].present? }  # Hash keyed by SKU
ShopifyVariant.where.not(sku: [nil, ""]).find_each do |variant|
  square_id = by_sku[variant.sku.downcase]
  ...
  link.squareVariationId = square_id
end
```

- **Multiple Square variations sharing one SKU:** `by_sku[sku]` keeps only the **last** variation in the loop; the others are silently dropped. Every Shopify variant with that SKU links to that single (last) Square variation, and the other variation's mirrored stock never appears. This directly produces "square" data that lands on the wrong row / only some SKUs show.
- **Multiple Shopify variants sharing one SKU:** each variant gets its own `SkuLink` → the **same** `squareVariationId`. `square_map.fetch(link.squareVariationId)` then returns the **same aggregate Square total on every one of those variant rows**. Reading down the PDF, the Square column appears to repeat a value across several rows that don't individually own it — the classic "Shopfiy data in the wrong column / Square value where it shouldn't be" impression.

Note that the rest of the system knows these are ambiguous:
- `InventoryMaintainer.run!` **skips** SKUs that link to >1 Shopify variant (`shared_skus`) and size-family SKUs — it refuses to reconcile them.
- `InventoryPdf#load_rows` computes `shared_skus` / `duplicate_product_skus` and flags the *sold* count with `†`.
- But the PDF still emits the **shared Square total** into the Square/drift columns of every such variant — no `†`-style guard on the quantity columns.

### 2c. Multi-location double counting (Shopify column can look wrong)
`InventoryLevel.shopify_totals` and `.square_totals` **sum across all locations** of the source. If a SKU is mirror at more than one location:

- the "Shopify" column shows the **sum**, not the online-store count,
- the "Square" column shows the **sum** across all Square locations.

The maintainer/setup model is a **single primary location**:
- `InventoryMaintainer` pushes Shopify to `Location.shopify_primary` only.
- `Reconciler` uses `variant.inventoryQuantity` for Shopify and `InventoryLevel.square_totals` for Square.

So the two consumers (PDF vs Reconciler/Maintainer) use *different* "Shopify qty" sources:
- PDF: `SUM(InventoryLevel) WHERE source='shopify'` (all locations)
- Reconciler/Maintainer: `ShopifyVariant.inventoryQuantity` (single value)

If more than one Shopify location exists, or a level was not kept in sync with the variant column, the PDF's Shopify column will not match the numbers the workflow actually reconciles — making the values appear to be in the wrong column.

### 2d. LocationId convention inconsistency (latent)
- **Shopify** levels are written with `locationId = location["id"]` — the **Shopify external gid** (`gid://shopify/Location/…`) from the raw API node passed in.
- **Square** levels are written with `locationId = location_record.id` — the **internal Location record CUID**.

The `InventoryLevel#belongs_to :location, foreign_key: "locationId"` only resolves for Square rows. This doesn't break the PDF totals (they don't join Location), but it's an inconsistency that can bite any future location-aware query/filter.

### 2e. Staleness after maintainer pushes
`InventoryMaintainer` adjusts Shopify (and Square) via the APIs but does **not** write `ShopifyVariant.inventoryQuantity` or the shopify `InventoryLevel` immediately. Those only refresh on the next mirror. Between a maintainer push and the next syncy, the PDF reflects the old mirrored value — a transient "incorrect" number, more likely around the Square/Shopify columns when drift is non-zero.

---

## 3. Confirmed data-flow trace

```
Shopify API ──► CatalogSyncer ──► ShopifyVariant.{inventoryQuantity,...}
                              └─► InventoryLevel(source=shopify, locationId=external gid)
Square API ──► SquareSyncer ──► SquareVariation
                              ├─► InventoryLevel(source=square, locationId=CUID)
                              └─► SkuLink (by case-insensitive SKU match; LAST wins on dup)
                                              │
      InventoryPDF.load_rows ─────────────────┤
        inventory via Shopify catalog          │
        Square via SkuLink → square_totals     │
        Shopify via shopify_totals (all loc)   │
```

---

## 4. Fixes and recommendations

### Applied (read-only report-layer — no SKU or platform writes)

1. ✅ **Guard shared-SKU quantity columns** (`inventory_pdf.rb`). Added `Row#shared_qty`; when a Square variation is linked to >1 Shopify variant, the Square column renders `40†` and Drift renders `†` instead of repeating the aggregate on every row, and those rows no longer amber-highlight. Production has **10** such shared Square variations → meaningful.
2. ✅ **Surface Square-only inventory** (`inventory_pdf.rb`). Added a `write_square_only` section listing mirrored Square stock (home/physical location, qty > 0) with **no** Shopify link. Production has **179** such SKUs that were previously invisible.
3. ✅ **Transparency on the Square column.** The footer now states the Square column sums every active Square location (physical shop + mobile Vendor Events), so a combined number isn't read as "just the shelf." Production: 2 Square locations (Herbal Healers LLC physical + Vendor Events mobile), `SQUARE_LOCATION_ID=LQ0X40MM4FYAZ` (home).

### Data-grounded findings that change the earlier recommendations

- **Auto-linking is NOT dropping SKUs.** Every Shopify variant whose SKU exists in Square is already linked (0 unmatched). The low link rate is real catalog structure: only 33/708 Square variations have a Shopify counterpart; 133 tracked Shopify variants have no SKU; 5 tracked+SKU'd variants have no Square match. So "missing SKUs" = **Square-only inventory** (now surfaced), not a linker bug.
- **Do NOT change the Square column to home-only.** `InventoryMaintainer` builds the sellable pool from `square_totals` (all locations) and pushes that to Shopify's single location, so the PDF's combined Square figure is consistent with the operative model; narrowing it would make Drift misleading. Transparency (applied) is the correct fix.
- **Single Shopify location** (1 in production) → no Shopify-side multi-location double count today.

### Remaining (higher risk / data-mutating — intentionally not applied)

4. **Fix `sync_links!` collisions.** When a SKU matches multiple Square variations (the `by_sku` Hash keeps only the last) the other variation is silently dropped. Safest fix: split into per-variation SKUs (Square variation SKUs are often unique batch codes) and surface collisions rather than auto-link — but this touches the reconcile/maintainer path, so it needs explicit sign-off before any re-link.
5. **`locationId` convention inconsistency** (Shopify stores external gid, Square stores CUID; `belongs_to :location` only resolves for Square). Fixing it means flipping the stored convention, which would create duplicate levels for existing rows unless data is migrated — defer.
6. **Staleness after maintainer pushes** — shopify levels/variant qty refresh on the next mirror; acceptable within a 15-min cycle.

---

## Follow-up fixes (2026-08-17)

Applied after the audit (owner-authorized; see git log `d4a3c39`, `d49b307`):

- **Shared-SKU reconciliation guard.** `Reconciler.actionable_rows` now skips
  rows whose SKU is linked to >1 Shopify variant (`Reconciler.shared_skus`,
  mirroring `InventoryMaintainer`), and `PlanApplier.apply!` raises
  `SafetyLocked` if a shared-SKU row ever reaches it. Previously all 9
  actionable rows were shared SKUs and `689745640858` (same target on two
  variants) could be half-applied.
- **Cache false-failure.** `SyncEngine` wraps `DataCache.bump!` so a file-cache
  store error (observed as `Permission denied @ …/data_version` ~7×/24h) can no
  longer flip a successful sync to `failed` or fire a spurious "Sync failed"
  notification. Also normalized `tmp/cache` ownership to `rupert`.
- **Archive-awareness.** 9 products archived (DRAFT/UNLISTED) on Shopify stayed
  `ACTIVE` in the mirror with ~1,430 phantom units and 22 phantom alerts, and
  fed reconcile drift on dead SKUs. The 9 mirror products were set
  `status=ARCHIVED`, their 22 open alerts resolved, and reconcile/alerts/PDF
  reconciliation surfaces now only consider `ACTIVE` products. The write hazard
  on the dead Afghan SKUs was already neutralized by the shared-SKU guard.
