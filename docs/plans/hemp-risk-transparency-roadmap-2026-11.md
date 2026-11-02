# Hemp risk made easy: processor and vendor transparency (roadmap note)

**Prepared:** 2026-11-02. **Status:** proposal. The new items are labelled **R1–R7** here and are **not yet in** `docs/data/product-roadmap.json`, so this note can't collide with the F69/F70 sessions editing that file. Add them as F-numbers once F69/F70 land.

**Goal (owner's words):** make processor and vendor risk "super super easy" and transparent, with no funny business on either side. The merchant should be able to prove, in one click, exactly what it sells and that every card sale matched what the processor approved. The merchant should also be able to see, in one place, exactly what the processor charges and holds.

**Evidence behind this note:** [federal review](../compliance/herbal-healers-federal-review-2026-11.md) (38 of 47 Herbal Healers products likely leave federal hemp on Dec 11; 15 products with stale COAs, 4 mismatched, 1 without potency); [processor landscape](../compliance/high-risk-processors-2026-11.md) (terms aren't published; complaints centre on undisclosed ETFs and reserves).

## What F69 and F70 already cover

| Proposed idea | Covered by | Notes |
| --- | --- | --- |
| Per-processor product eligibility allow-lists | **F69** | Allow-lists per processor via Authorize.net/NMI |
| Locked, owner-approved catalog with compliant names | **F70** | |
| COA per product and batch, required before card sale, receipt QR | **F70** | R2 extends it with expiry and adequacy checks |
| Block custom/open-price items on card; manager override with reason | **F70** | |
| Pre-sale cart check (card eligibility, COA, 21+, ship-to state) | **F70** | R3 adds date-effective rules |
| Show/event mode | **F70** | |
| Audit trail and daily exception report | **F70** | R6 exposes it read-only to the processor |
| Drift check between Rupert's catalog and processor/storefront catalogs | **F70** | R7 extends it to the public website |

## New items (not in F69 or F70)

### R1. Underwriting packet in one click — *Commerce, Phase 0*
Export a dated, signed bundle for a processor application or annual review:
- the approved catalog (name, SKU, category, sizes, price, per-processor eligibility);
- the current COA for each product, with lab, date, batch and the per-container THC calculation;
- the website compliance checklist from R7;
- business documents the owner uploads (licences, statements);
- a cover summary listing what changed since the last packet.

**Done when:** one action produces a PDF + ZIP that matches the live catalog exactly, and the packet's hash is recorded in the audit log.

### R2. COA adequacy and expiry checker — *Commerce, Phase 0*
Builds on F70's COA-per-product. For each COA, store lab, sample name, issue date, batch and cannabinoid results (entered or parsed), then flag:
- **expired** (age limit set per processor; default 12 months), with alerts at 30 and 7 days;
- **mismatch** (sample name or cannabinoid profile doesn't match the product or label claim);
- **no potency** results;
- **per-container THC over 0.4 mg**, computed as Δ9 + 0.877 × THCA × net contents;
- **"ND" that can't prove the cap** because the LOQ × container size exceeds 0.4 mg;
- **label vs COA disagreement** beyond a tolerance.

**Done when:** the federal review's findings for Herbal Healers (15 stale, 4 mismatched, 1 no-potency, LOQ cases) are reproduced automatically from entered COA data.

### R3. Date-effective eligibility rules (auto-delist) — *Commerce, Phase 0*
Rules with an effective date that change card eligibility automatically:
- **Nov 12, 2026:** products flagged as containing non-naturally-producible cannabinoids;
- **Dec 11, 2026:** total-THC and 0.4 mg per-container rules, synthesized-cannabinoid flag, intermediate-sold-to-consumer flag.

At the effective time, matching products become **card-ineligible** in POS and are **proposed** for unpublishing on connected storefronts. Under AGENTS.md, any Shopify or Square write still needs explicit owner sign-off; Rupert prepares the change and the owner approves it. Rules are versioned, and the owner and counsel can override per product with a recorded reason.

**Done when:** a dry run on the Herbal Healers catalog lists the same 38 products the federal review puts in bucket (b), and nothing is written to a platform without approval.

### R4. Processor terms ledger and fee audit — *Finance, Phase 0*
The "no funny business" view from the merchant's side:
- record each processor's quoted terms (rate, per-item fee, monthly fees, reserve %, release schedule, term, renewal date, ETF, terminal ownership, MCC, descriptor) with the signed contract attached;
- reconcile **actual** settlement deductions against the quote, using Rupert's existing Authorize.net/NMI settlement reconciliation;
- alert on unquoted fees, reserve above the agreed %, overdue reserve release, renewal notice windows and descriptor changes.

**Done when:** a month of settlements shows quoted vs charged per fee line, and any difference opens an exception.

### R5. Chargeback, refund and decline monitor — *Finance, Phase 0*
Track chargeback and refund counts and ratios per processor and per product, against thresholds the owner enters from the processor's contract (network thresholds change and differ by program). Warn before a threshold, and link each dispute to the sale, its COA and receipt so evidence can be sent quickly. Include document-request tracking (request date, due date, proof of reply), since unanswered requests are a common reason for holds.

**Done when:** dispute and refund ratios per processor are visible daily, with an alert at a configurable fraction of each threshold.

### R6. Processor-facing read-only compliance view — *Commerce, Phase 1*
A time-limited, revocable link for a named processor contact showing: the approved catalog for that processor, current COAs, R2 status, the F70 exception report summary, sales by product category, and the R1 packet history. No customer personal data, no edit rights, every view logged. This replaces emailing spreadsheets and makes reviews faster and calmer.

**Done when:** a processor can verify "every card sale last month was an approved product with a current COA" without asking the merchant.

### R7. Storefront compliance scan — *Marketing, Phase 1*
Read-only scan of the public website (Shopify storefront) for things underwriters check:
- each product page has a COA link that matches R2's current COA;
- an age gate and the FDA disclaimer are present;
- health or medical claims ("relief", "treat", "cure") and terms like "dispensary";
- product URL/handle vs title mismatches (the review found several "-copy" handles naming other products);
- the payment gateway in use for hemp products (flag Shopify Payments, which doesn't allow hemp/CBD).

**Done when:** the scan reproduces the review's storefront findings and feeds R1's checklist. Fixing the storefront remains an owner-approved action.

## Suggested order

1. **R2 and R3 before Dec 11.** They turn the federal review into enforcement and stop over-cap products being rung up on card.
2. **R1** for the Valmar and backup-ISO applications.
3. **R4 and R5** once the first processor is live.
4. **R6 and R7** after that.

## Transaction descriptors

Clear descriptors (so customers recognise the charge and don't dispute it) are mostly set by the processor. Rupert's part: record the assigned descriptor and MCC in R4, show them on receipts, and alert on changes. **Rupert never chooses or disguises an MCC or descriptor.** No separate roadmap item is needed.
