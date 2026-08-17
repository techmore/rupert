# Plan — SKU assignment for the "Liquid Flower" THCA Live Resin Disposable Vape

Status: **APPLIED 2026-08-17 (owner-authorized).** The 9-variant SKU assignment
was applied to Shopify via `productVariantsBulkUpdate` (nested
`inventoryItem.sku`), then Shopify + Square syncs were run to auto-link, and the
family was confirmed 0-drift. The previously-flagged EOL variant (Kosher Kush x
ChemDawg, `§2b`) was deleted from Shopify and its stale mirror cleaned.
Scope: SKU-assignment/relink proposal for the `"Liquid Flower" THCA Live Resin
Disposable Vape` product (Shopify product `gid://shopify/Product/7348065959991`).

This plan proposes Shopify SKUs for the 9 SKU-less variants so the existing
`SquareSyncer#sync_links!` auto-links them to their Square counterparts by
case-insensitive SKU match.

**Applied:** Y. The 9 SKUs were written to Shopify on 2026-08-17 (owner
sign-off lifting the "No SKU changes" freeze for this apply), the Shopify +
Square syncs were run, and all 9 variants auto-linked to the correct Square
variations with 0 drift. Kosher Kush x ChemDawg (`§2b`) was intentionally left
unlinked and unassigned.

Data was pulled live from the Square v2 API (production) on 2026-08-17: all 14
strain variations of the `"Liquid Flower" Live Resin` item
(`BIJVT2OPTLSBPS6Y2XLJFKTO`).

---

## 1. The verified mapping

Every Shopify variant below maps to its Square variation **by exact strain name**
within the one Square item `BIJVT2OPTLSBPS6Y2XLJFKTO`. The proposed Shopify SKU
**is the Square variation's own SKU**, so once applied the next sync will auto-link
them (0-drift, tracked, reconcileable). No collisions: all 10 proposed SKUs are
unique across the product.

| Shopify variant id | Title | Current Shopify SKU | **Proposed SKU** (Square's) | Square variation |
|---|---|---|---|---|
| 42146850668599 | Biscotti (Indica) | — | `795560P` | Biscotti |
| 41902606090295 | Blue Cookies (Indica) | `689745640766` **(wrong)** | `S865085` | Blue Cookies |
| 42275787374647 | Cantalope Haze (Sativa) THCA 51.95% CBGA 2.62% | — | `H314526` | Cantalope Haze |
| 42274785132599 | Kush Krasher (Indica-Dominant Hybrid) THCA 53.03% CBGA 3.73% | — | `KKLF` | Kush Krasher (Indica) |
| 42065889558583 | Orangeade (Sativa- 53.33% THCA) | — | `453934M` | Orangeade |
| 42084553719863 | Papaya Punch (Indica) | — | `5497069` | Papaya Punch |
| 42084532453431 | Strawnana (Indica) | — | `799286E` | Strawnana |
| 42146850439223 | Trop Z (Sativa) THCA 52.02% CBGA 2.06% | — | `872082S` | Trop Z |
| 42093648773175 | White Bubba (Indica) | — | `W408225` | White Bubba |

## 2. Flagged items (need a decision, not a blind SKU)

### 2a. Blue Cookies is mis-linked today
Blue Cookies currently carries Shopify SKU `689745640766`, which is actually the
**"Orange Runtz (Hybrid)"** variation (`DY7JBQFV7FHG5VY5F66IRBX2`) — not Blue
Cookies (`I2T27GD5BYFWPSBZOD6EXT7W`, sq SKU `S865085`). So the live link points
at the wrong Square stock. Fix: set Shopify SKU to `S865085` (per the table). After
relink, verify the old `689745640766` link is released and not duplicated.

### 2b. "Kosher Kush x ChemDawg (Indica)" — REMOVED (EOL)
The Shopify variant `42203009613879` had no matching strain in Square and was an
**end-of-life SKU**. On owner authorization it was **deleted from Shopify**
(`productVariantsBulkDelete`) and its stale local mirror rows were cleaned up
(InventoryLevel × 1, open "Out of stock" StockAlert × 1, ShopifyVariant × 1).
Verified safe before removal: 0 order lines, 0 movements, 0 links, 0 stock, 0
ledger references. The product now mirrors Shopify's live 9 variants.

## 3. Current quantity status (post-Strawnana reconcile)

All five in-stock strains already match Square quantities (verified live API +
Shopify mirror). Strawnana was reconciled 30→29 on 2026-08-17 (journaled
`push_strawnana_drift`). SKU assignment is **not** required to fix quantities — it
is required to make these variants `SkuLink`-linked so the maintainer/reconciler can
see and auto-drift them in the future.

## 4. Why apply this (benefit)

Once the 9 variants carry SKUs, `sync_links!` auto-links them to Square. They then:
- appear in the Reconcile report as matched rows with real drift,
- become reconcileable by `InventoryMaintainer` (no longer "Shopify-only / invisible"),
- stop being a blind spot for in-store Square sales (the Strawnana −1 class of drift).

## 5. Explicitly out of scope / not auto-assigned

The broader **117 tracked, SKU-less variants across ~40 products** (flower strains,
live-resin strains, wholesale bulk products like `— Wholesale` lines) were **not**
given blind SKUs: a trial name-match across that set produced collisions (e.g.
flower sizes all collapsing to one Square `3.5 Grams` SKU, wholesale bulk sizes
matching a generic `NERDZ` "1 ct"). Those need per-item catalog review (and the
wholesale bulk products may intentionally have no retail Square SKU). Recommend the
inventory agents handle that group with per-item confirmation rather than bulk
assignment.

## 6. To apply (blocked — requires lifting the "No SKU changes" freeze)

1. Update the 9 Shopify variants' SKUs per the table (1 SKU change + 9 additions).
2. Run `ops:sync_source[shopify]` then `ops:sync_source[square]` so `sync_links!`
   auto-links.
3. Run `ops:reconcile`; confirm the 10 (soon 9-linked) Liquid Flower rows now appear
   matched with 0 drift (Blue Cookies after its corrected link).
4. Resolve 2a (Blue Cookies) and 2b (Kosher Kush x ChemDawg) as a human catalog step.

*Author: inventory ops agent (2026-08-17). Companion to `docs/audits/inventory_pdf_integrity.md`. No writes performed.*
