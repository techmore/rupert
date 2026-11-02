# Rupert as the primary inventory: plan for owner approval

Status: **proposal, 2026-11-02**. Parts 1–3 below are built on this branch and change no platform stock. Part 4 (live push) waits for owner approval, item by item.

Owner goal: "make Rupert the primary inventory that pushes to the rest of them and set them up so they can input inventory in it."

## 1. What exists today (investigated)

| Question | Answer today |
| --- | --- |
| Where stock lives | Only as **mirrors** of each platform. `InventoryLevel` holds legacy Shopify/Square pools per location (Shopify value is *available*, sometimes an aggregate fallback). `ShopifyStockSnapshot` holds native signed `on_hand`/`available`/`committed` per Shopify location. `CtraxStockSnapshot` holds each C-Trax store's native variant records with signed `quantity`. There is no Rupert-owned quantity. |
| Locations | `Location` rows are per platform (`source` = shopify / square / ctrax). Nothing says "Shopify location A and C-Trax store B are the same shop". |
| Item identity across platforms | `SkuLink` links Shopify variants to Square variations (legacy). Shopify ↔ C-Trax pairing exists only as read-only *candidates* in Stock comparison (`StockIdentityMatcher`); nothing is saved. C-Trax records can carry the exact Shopify variant ID (`website_variant_id`). Many items have no SKU; native IDs are the only reliable key. |
| Staff entry | Counts are audit worksheets compared with mirrors (never applied). Transfers/backorders reserve against mirrors and ask staff to adjust the platform by hand. Purchase receiving records local evidence only. |
| Writes that exist | `InventoryWriter` (Shopify `inventoryAdjustQuantities`, Square `PHYSICAL_COUNT`) used by older remediation tasks, gated by `PlatformPushGuard.authorize!` which **refuses unless** `PUSH_CONFIRM=yes` or a UI confirmation is set. C-Trax: `Ctrax::Client#remove_stock` used by `PosInventoryJob` for paid Rupert POS sales (claim once, durable comment marker, unknown outcomes are read, never resent). |
| How sales come back | Shopify orders import into `orders`/`order_lines` with `source_variant_id`, `source_line_id` and the retail `location_id`. C-Trax daily sales import keeps per-unit native lines (encrypted per store/day). Rupert POS sales are canonical `rupert_pos` orders. None of these move a Rupert quantity today. |

### Platform write contracts (checked 2026-11-02)

- **Shopify** (Admin GraphQL `2026-07`, scope `write_inventory` already granted). `inventorySetQuantities` sets `available` or `on_hand`. From 2026-04, every quantity must carry `changeFromQuantity` (write applies only if Shopify still holds that value, else `CHANGE_FROM_QUANTITY_STALE`), and an `@idempotent(key:)` directive is **required** (keys honoured 24 h; same key with different input → `IDEMPOTENCY_KEY_PARAMETER_MISMATCH`). `inventoryAdjustQuantities` applies deltas under the same rules. Arrays max 250 items; standard plan restores 100 cost points/s, about 10 points per mutation. **Gap found:** `InventoryWriter.adjust_shopify!` sends `changeFromQuantity` only when known, and the existing callers would need checking against 2026-07 before any reuse.
- **Square** (`2026-07-15`). `POST /v2/inventory/changes/batch-create`, up to 100 changes, atomic batch, `idempotency_key` ≤128 chars (reuse with a different body → `IDEMPOTENCY_KEY_REUSED`). Square's own guidance: **do not send computed levels as `PHYSICAL_COUNT`**; use `ADJUSTMENT` (`NONE→IN_STOCK` to add, `IN_STOCK→NONE`/`SOLD` to remove) and `PHYSICAL_COUNT` only for a real count with its true `occurred_at`. `TRANSFER` is retired in this version. Limits are unpublished; back off on 429 with jitter. Square sales decrement `IN_STOCK` automatically. Square is currently **disabled** for this store.
- **C-Trax** (observed Serv 2.0 admin contract, not a published partner API). Only `inventoryAdjustments` with `action: remove` has been exercised in code, with comment-marker recovery from the adjustment history. **No "set quantity" call is known. `action: add` is unverified.** Rate limits are unknown; the client already caps pages, bytes and time.

## 2. Recommended design

**Rupert keeps a movement ledger per item and Rupert site. Each movement fans out to the other linked platforms. A count becomes a guarded "set", and everything else becomes an adjustment.**

### 2.1 Data (built)

- **Rupert site** (`stock_sites`): a physical shop or stockroom, mapped to at most one Shopify location, one C-Trax store and one Square location.
- **Rupert item** (`stock_items`): name plus optional SKU/barcode. Native IDs live on links.
- **Platform link** (`stock_item_links`): exact native item for one platform at one site (Shopify variant GID, C-Trax variant ID in that store, Square variation ID). One link per item/site/platform, and one item per native ID per site. Links are explicit decisions. The only automatic link is the exact `website_variant_id` a C-Trax record already carries. SKUs are never invented or written.
- **Balance** (`stock_balances`): Rupert on-hand per item/site. It starts unknown and the first movement must be a count, so Rupert never assumes zero.
- **Movement ledger** (`stock_ledger_entries`): append-only. Kinds: `count`, `receive`, `adjust` (reason required), `transfer_out`/`transfer_in` (paired), and later `sale` and `return`. Each row stores before/after, actor, reason, note, reference, origin (`rupert`, `shopify`, `ctrax`, `square`) and a unique request token, so a retried phone submission records once.

### 2.2 Outbound push (preview built, live push waits for approval)

1. **Dry-run preview** (built): for every linked item at a site, compare Rupert on-hand with each platform's latest stored observation and show the exact write: "Shopify: set on hand 12 → 10 (changeFromQuantity 12)", "C-Trax: remove 2 (12 → 10)", or a block reason (stale, unknown, untracked, fractional, missing location mapping, add not verified, Square disabled). It includes the request body Rupert would send, minus credentials. It reads only stored snapshots and never contacts a platform.
2. **Queue** (to build): a `stock_push_jobs` outbox row per (movement or count) × target platform, excluding the platform where the movement originated. Fields: idempotency key (derived from movement ID + platform, ≤128 chars), payload digest, status `pending → claimed → applied | conflict | failed | unknown`, attempts and last error.
3. **Write rules:**
   - Shopify: counts use `inventorySetQuantities name: on_hand` with `changeFromQuantity` = the observation used in the preview. Other movements use `inventoryAdjustQuantities` deltas on `on_hand` (they commute with concurrent web sales). Always send `@idempotent`.
   - C-Trax: always adjustments (`remove`, plus `add` once verified), with a durable `Rupert stock <movement> …` comment marker and recovery from the adjustment history, like `PosInventoryJob`. Never resend after an unclear reply.
   - Square (if re-enabled): `ADJUSTMENT` for movements and `PHYSICAL_COUNT` only for real counts with the count's own timestamp.
4. **Safety:** one **kill switch per platform** (default off). `PlatformPushGuard.authorize!` confirmation on every write. A fresh read of the target value within one hour before claiming. A mismatch becomes a `conflict` for review, never a retry with new numbers. Batches stay small: Shopify ≤50 items per call; C-Trax one call per item. Back off on throttling. Every attempt goes to `ActivityLogger` and the job row.
5. **Rollout:** one platform (recommended: Shopify, the only platform with compare-and-set), one test item, one site, run by hand from the preview, then read back. Then one site, then all.

### 2.3 Inbound sales and adjustments (to build before turning on automatic push)

Platform sales are applied to Rupert as `sale`/`return` movements, keyed by exact source order/line (Shopify `source_line_id`, C-Trax native order line, Rupert POS line), never by overwriting a balance. The movement's origin is the platform that already changed its own stock, so it is pushed only to the *other* platforms. Shopify on-hand changes at fulfilment, not at sale, so the Shopify feed applies fulfilment quantities. Until this exists, the preview warns that sales after the last count are not yet in Rupert's number. A set pushed long after a count would then erase those sales, so live pushes should run right after a count.

### 2.4 Drift and conflicts

- **Drift** = platform observation − (Rupert on-hand adjusted for movements not yet pushed). The preview shows it per link. A nonzero drift is a review item, fixed by a recount, never auto-corrected.
- **Conflict** = `changeFromQuantity` stale, C-Trax remaining quantity not as expected, or a marker ambiguity. The job stops for that item, and a person recounts or accepts.
- Native platform edits made outside Rupert surface as drift, because staff should stop adjusting stock in the platforms once Rupert is primary.

### 2.5 Where a platform cannot accept writes

- C-Trax without a verified `add`: Rupert can only lower C-Trax stock automatically. Increases show in the preview as "enter +N in C-Trax by hand" with a checklist item, until C-Trax confirms the add contract or a supported API.
- Square disabled: links and preview only.
- An item with no platform link stays Rupert-only. This is valid for stockroom-only goods.

## 3. Built in this branch (no platform writes)

- **Stock → Rupert stock** (`/master_stock`): phone-first list per site with search (keyboard-wedge scanner friendly: SKU, barcode or exact native ID), then **Count**, **Receive**, **Adjust** (signed, reason required) and **Transfer** (site to site, atomic out/in pair). Large numeric inputs.
- **Movement ledger** (`/master_stock/movements`): every movement, who, why, before → after, filter by site/item/kind, CSV export.
- **Push preview** (`/master_stock/push_preview`): per site and platform, exact proposed writes and block reasons, with stored observation age.
- **Setup** (`/master_stock/setup`): create sites and map platform locations; start tracking items from a C-Trax store snapshot or a Shopify location (exact native links, with an exact Shopify link when C-Trax carries `website_variant_id`); add or remove individual links.
- Permissions: `inventory.read` to view; `inventory.write` to record movements; `inventory.write` + `settings.write` for setup.

## 4. Owner decisions needed

1. **Approve the design**, especially: counts set Shopify **on hand** (physical units including unfulfilled orders), not *available*.
2. **First live test**: platform (recommend Shopify), site, and one specific item. I will show its preview line and the exact request first.
3. **Starting balances**: recount everything in Rupert (cleanest), or seed Rupert from the C-Trax snapshot as labelled opening counts (fast, inherits C-Trax errors). The import offers seeding as an explicit opt-in.
4. **C-Trax as count reference**: from approval on, staff count in Rupert and stop adjusting stock in C-Trax/Shopify directly. Who is allowed to adjust (store staff vs managers)?
5. **C-Trax increases**: ask C-Trax to confirm `inventoryAdjustments action: add` (or a supported stock API and rate limits). Until then increases are manual in C-Trax.
6. **Square**: stay out (links/preview only) or come back later?
7. **Transfers**: record as one instant move when stock arrives (built), or add an in-transit state?
8. **Adjustment reasons**: proposed damaged, expired, theft/loss, sample/staff use, vendor return, found, correction, other. Add or rename any?
