# Herbal Healers: product-by-product federal hemp review (draft for counsel)

**Prepared:** 2026-11-02, from public sources only. **Status:** draft for the customer's attorney. **This is not legal advice.** Every bucket below is a reading of public lab reports against the statute text; the attorney decides what may be sold, shipped or card-processed.

Related: [hemp-federal-deadline-2026.md](hemp-federal-deadline-2026.md) (deadline evidence), [high-risk-processors-2026-11.md](high-risk-processors-2026-11.md) (processors), [../plans/hemp-risk-transparency-roadmap-2026-11.md](../plans/hemp-risk-transparency-roadmap-2026-11.md) (Rupert features).

## Plain-English summary (for the owner)

- **47 products** are listed on herbalhealerscbd.com today (plus a shipping-insurance line). We matched each one to the lab reports (COAs) in the store's public COA folder.
- **38 products (about 4 in 5) look like they stop being federal "hemp" on December 11, 2026.** That includes all THCA flower, pre-rolls, vapes and concentrates, all THC gummies and drinks, the full-spectrum tinctures, and even the seven "CBDA live resin" products. Most are hundreds to thousands of times over the new 0.4 mg-per-container THC cap.
- **None looks affected on November 12, 2026.** We found no HHC, THC-O, THCP or other lab-made cannabinoids on any public COA. But most COAs don't test for them, so the supplier should confirm in writing.
- **Only 1 product is clearly fine:** the melatonin sleep gummies, which contain no cannabinoids.
- **8 products can't be confirmed from the public paperwork:** the THC-free CBD tincture, softgels, pet tincture, pet treats, muscle cream, face serum, CBN sleep microgels and the CBD drink enhancer. Six of them will probably qualify once each has a **current COA that reports THC in mg per container** with a test sensitive enough to prove it is under 0.4 mg. Two raise open legal questions (CBN, and drink "enhancers" that are mixed into other things).
- **Paperwork problems processors will notice:** several COAs are over a year old, four don't match the product they're posted for, one has no potency results, and several product web addresses don't match their names.
- **One storefront risk:** the public checkout setup on the product pages appears to use Shopify's own payment gateway. Shopify Payments doesn't allow hemp/CBD. The owner should check this now.

## Method

1. **Catalog:** the store's public Shopify catalog (`/products.json`, 47 products, fetched 2026-11-02) and product page text (stated strengths, pack sizes, variants).
2. **COAs:** the "3rd-party lab tests" page links a public Google Drive folder (229 files in Concentrates, Drinks, Edibles/Injestibles, Flower, Pets and Topicals). We downloaded the 57 files that plausibly match listed products and read them as text, or by OCR for scanned files. COA files and raw data are not stored in this repository.
3. **Math:** total THC = Δ9-THC + 0.877 × THCA (the 0.877 factor converts THCA mass to THC). Per-container THC = concentration × net content of the **smallest variant sold**. When a COA reports mg per unit (gummy, bottle), we multiply by units per package.
4. **Statute:** read from the enrolled public laws on congress.gov (see [Statute](#statute-verified-from-congressgov)).
5. **Judgment calls** are marked **⚖** throughout.

### Rules used for "COA current" and "COA matches" ⚖

- **Current** means issued on or after 2025-11-02, i.e. no more than 12 months old at review. Common processor practice, not a legal rule; some processors want a COA per batch regardless of age.
- **Matches** means the COA's sample name and cannabinoid profile correspond to the listed product and its label claims. Supplier or white-label names (for example "Max Relax Gummy" for "Rest") count as a match when the cannabinoid profile matches the label, with a note.
- A **"not detected" (ND) THC result does not prove ≤ 0.4 mg per container** unless the lab's limit of quantitation (LOQ) is low enough for the container size. Example: the muscle cream COA's THC LOQ is 0.015%, so a 122.5 g jar could legally hold up to 18.4 mg of THC and still read "<LOQ". A 30 mL tincture tested at a typical 0.01% LOQ could hold about 2.8 mg. ⚖ We therefore do not put "THC ND" products in bucket (c) unless the COA reports a per-container figure or an adequate LOQ.

## Statute (verified from congress.gov)

**P.L. 119-37, division B, §781** ([PDF](https://www.congress.gov/119/plaws/publ37/PLAW-119publ37.pdf), signed 2025-11-12, effective 365 days later) rewrites 7 U.S.C. 1639o. Relevant text (quoted from the enrolled law):

- **(1)(A) Hemp:** the plant and its derivatives "with a total tetrahydrocannabinols concentration (including tetrahydrocannabinolic acid) of not more than 0.3 percent on a dry weight basis."
- **(1)(C) Exclusions:** hemp does not include:
  - (ii) *intermediate* hemp-derived cannabinoid products containing (I) cannabinoids "not capable of being naturally produced" by the plant, (II) plant-natural cannabinoids "synthesized or manufactured outside the plant", or (III) more than 0.3% combined total THC (incl. THCA) and similar-effect cannabinoids;
  - **(iii) "any intermediate hemp-derived cannabinoid products which are marketed or sold as a final product or directly to an end consumer for personal or household use"**;
  - (iv) *final* hemp-derived cannabinoid products containing (I) non-naturally-producible cannabinoids, (II) plant-natural cannabinoids synthesized outside the plant, or **(III) "greater than 0.4 milligrams combined total per container"** of total THC (incl. THCA) and cannabinoids with similar effects (as determined by HHS).
- **(3)(A) Hemp-derived cannabinoid product:** any intermediate or final product derived from hemp that contains cannabinoids and is "intended for human or animal use through any means of application or administration, such as inhalation, ingestion, or topical application." **So topicals and pet products are covered.**
- **(3)(B) Intermediate product** includes "a powder, liquid, tablet, oil, or other product form which is intended or marketed to be mixed, dissolved, formulated, or otherwise added to or prepared with or into any other substance prior to administration or consumption."
- **(3)(C) Container:** "the innermost wrapping, packaging, or vessel in direct contact with a final hemp-derived cannabinoid product … such as a jar, bottle, bag, box, packet, can, carton, or cartridge."
- **FDA lists:** FDA was to publish, within 90 days, lists of naturally produced cannabinoids, THC-class cannabinoids and similar-effect cannabinoids, plus more detail on "container". As of CRS's 2026-10-28 legal sidebar, FDA had **not** published them ([CRS LSB11496](https://www.everycrsreport.com/reports/LSB11496.html); [Marijuana Moment, 2026-02-18](https://www.marijuanamoment.net/fda-misses-deadline-to-publish-cannabinoid-list-and-define-hemp-containers-drawing-industry-criticism); [CRS IF13136](https://www.congress.gov/crs-product/IF13136)).

**P.L. 119-103, §2019** ([PDF](https://www.congress.gov/119/plaws/publ103/PLAW-119publ103.pdf), signed 2026-09-02): "Until December 11, 2026, the amendments made by section 781 … shall only apply with respect to products described in paragraphs (1)(C)(ii)(I) and (1)(C)(iv)(I)". So:

| Date | What applies |
| --- | --- |
| **2026-11-12** | Only (ii)(I) and (iv)(I): products containing cannabinoids **not capable of being naturally produced** by the plant |
| **2026-12-11** | Everything else: total-THC (incl. THCA) plant test, synthesized-but-natural cannabinoids, the 0.3% intermediate cap, the 0.4 mg per-container cap, and the (iii) exclusion of intermediates sold to consumers |

## Buckets

| Bucket | Meaning | Count |
| --- | --- | --- |
| **(a)** | Non-naturally-producible cannabinoids; out **Nov 12, 2026** | **0** |
| **(b)** | Over the total-THC test or the 0.4 mg per-container cap; out **Dec 11, 2026** | **38** |
| **(c)** | Likely still eligible after Dec 11 | **1** |
| **(d)** | Can't tell from public records (missing/mismatched/stale COA or unresolved legal question) | **8** (6 likely move to (c) with a fresh, adequate COA) |

⚖ **(a) is zero on the evidence available, not proven zero.** The flower COAs (FESA Labs) test 10 cannabinoids and the Badger Labs panels 11–12; neither lists HHC, THC-O-acetate or THCP. Only one older gummy COA (Delta9 Analytical, Aug 2025) screened HHC (ND). No product is marketed with a synthetic cannabinoid. Ask each supplier for a written statement that no non-naturally-producible cannabinoid is present.

⚖ **Converted cannabinoids.** If the Δ9-THC in the gummies, drinks or tinctures was made by converting CBD (common in the industry), it is a plant-natural cannabinoid "synthesized or manufactured outside the plant" and is excluded from **Dec 11** under (iv)(II), not Nov 12. The labels claim "plant-derived" / "plant-made" THC. These products are in (b) on THC content anyway. One older Wild Cherry gummy COA (Delta9 Analytical, 2025-08-07) found 0.0178% Δ8-THC (about 1.9 mg per gummy) alongside Δ9; Δ8 at that level is a common sign of conversion. Ask the supplier.

## Product table

Abbreviations: **TTHC** total THC (Δ9 + 0.877 × THCA). **Smallest container** = smallest variant sold. "×" = multiple of the 0.4 mg cap. Labs: **FESA** = FESA Labs; **Badger** = Badger Labs (ISO/IEC 17025, accreditation #115522); **SC** = SC Labs; **ACS** = ACS Laboratory; **GLL** = Green Leaf Labs; **Marin** = Marin Analytics; **ICAL** = Infinite Chemical Analysis Labs; **D9A** = Delta9 Analytical. COA file names are as they appear in the store's public Drive folder.

### Flower (THCA) — 9 products, all (b)

The plant test alone fails: TTHC is ~25–29% against a 0.3% limit. Per container (7 g, the smallest size), TTHC is roughly 1.7–2.0 **grams**.

| # | Product (listing) | Cannabinoids on COA | TTHC / smallest container | COA (lab · issued · batch) | Current / matches | Bucket |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Cheetah Pu**y (Hybrid, 29.44% THCA) | Δ9 0.22%, THCA 29.44%, Δ8 ND, CBGA 0.33% | 26.04% → 1,823 mg / 7 g (×4,557) | `Cheetah_Pussy.pdf` · FESA · 2026-07-30 · batch "TX - 25635", sample 80160715-167 | Yes / Yes | **b** |
| 2 | Jack Frosty Sparrow (32.40% THCA) | Δ9 0.16%, THCA 32.40% | 28.58% → 2,000 mg / 7 g (×5,001) | `Jack_Frosty_Sparrow.pdf` · FESA · 2026-07-30 · "TX - 25635" | Yes / Yes | **b** |
| 3 | GodZilla (31.02% THCA) | Δ9 0.06%, THCA 31.02% | 27.26% → 1,908 mg (×4,771) | `GodZilla.pdf` · FESA · 2026-07-30 · "QC - 34225" | Yes / Yes | **b** |
| 4 | Secret Affair (28.81% THCA) | Δ9 0.27%, THCA 28.81% | 25.53% → 1,787 mg (×4,468) | `Secret_Affair.pdf` · FESA · 2026-07-24 · "FL - 883221" | Yes / Yes | **b** |
| 5 | Marley Green (28.72% THCA) | Δ9 0.29%, THCA 28.72% | 25.48% → 1,783 mg (×4,458) | `Marley_Green.pdf` · FESA · 2026-07-24 · "FL - 883221" | Yes / Yes | **b** |
| 6 | Alien Taffy (31.85% THCA) | Δ9 0.20%, THCA 31.85% | 28.13% → 1,969 mg (×4,923) | `Alien_Taffy.pdf` · FESA · 2026-07-24 · "AZ - 52141" | Yes / Yes | **b** |
| 7 | Candy Comet (28.23% THCA) | Δ9 0.17%, THCA 28.23% | 24.92% → 1,744 mg (×4,361) | `Candy_Comet.pdf` · FESA · 2026-07-24 · sample 80160715-61 | Yes / Yes | **b** |
| 8 | Electric WiFi Indoor (30.69% THCA) | Δ9 0.26%, THCA 30.69% | 27.17% → 1,902 mg (×4,755) | `Electric Wifi` (JPEG scan; two other same-name files would not download) · FESA · 2026-07-30 · sample 80160715-113 | Yes / Yes | **b** |
| 9 | Astro Haze (29.67% THCA) | Listing only: THCA 29.67% | ≥ 26.0% → ≥ 1,821 mg (×4,554), from the listing | **None found** (`Astronaut.pdf` is a different strain) | — / — | **b** ⚖ (from the store's own label; COA missing) |

Note: FESA flower COAs say "For R&D Use Only – Not a California Compliance Certificate". Processors that want compliance-grade COAs may ask for a different lab report.

### Pre-rolls (THCA) — 2 products, both (b)

⚖ Container: if each pre-roll sits in its own tube, the tube is the container; otherwise the pack is. Either way the result is the same.

| # | Product | Variants / COA evidence | TTHC / smallest container | COA | Current / matches | Bucket |
| --- | --- | --- | --- | --- | --- | --- |
| 10 | Premium Mini Prerolls (6 × 0.5 g) | Double Runtz: TTHC 21.57% (listing says 24.24%). Ice Cream Cake: printed TTHC 31.79% (THCa 32.89%, Δ9 0.18%). Fusion, Pineapple Donut: no COA found | Double Runtz 108 mg per 0.5 g pre-roll (×270); 647 mg per 6-pack | `Double_Runtz.pdf` · SC · 2025-05-19 · batch RT-66585. `Ice Cream Cake.pdf` · GLL · 2026-01-05 | DR: stale, % differs from listing. ICC: current; printed 31.79% doesn't equal the formula from its own table (29.0%) — ask the lab. Two variants: none | **b** |
| 11 | King Cone Pre-Roll – THCA (1.5 g) | Slurricane: Δ9 0.28%, THCA 25.87%, THCV 0.35%. Apple'n Banana: Δ9 0.22%, THCA 24.06%. Ice Cream Cake (as above). Fusion, Pineapple Donut: none | Slurricane 22.97% → 345 mg (×861); Apple'n Banana 21.33% → 320 mg (×800) | `SLURRICANE THCA_Flower.pdf` · FESA · 2026-06-23 · batch "N/A". `Apples_n_Bananas.pdf` · Badger · 2026-05-04 · lab ID 56025738 | Current / mostly (listing says 24.62% for Apple'n Banana vs COA THCA 24.06%) | **b** |

### Vape — 1 product, (b)

| # | Product | Cannabinoids | TTHC / 1 g cartridge | COA | Current / matches | Bucket |
| --- | --- | --- | --- | --- | --- | --- |
| 12 | "Liquid Flower" THCA Live Resin Disposable Vape (1 g) | Biscotti Live Oil: THCA 51.68%, Δ9 0.18%. Kush Krasher HTE: THCA 53.04%, Δ9 0.07%. Guavaz Live Oil: THCA 82.08%, Δ9 0.07%. Grape Fritter extract: THCA 80.29%, Δ9 0.31% | 455–721 mg per cartridge (×1,138–×1,801) | `Biscotti Live Oil.pdf` · Badger · 2026-03-09. `Kush Krasher HTE.pdf` · Badger · 2025-06-30. `Guavaz Oil COA.pdf` · Badger · 2026-09-15. `Grape_Fritter_Extract.pdf` · Marin · 2026-03-03 | Biscotti, Guavaz, Grape Fritter current; Kush Krasher stale. Kush Krasher % matches the listing exactly | **b** |

### THCA concentrates — 10 products, all (b)

| # | Product | Cannabinoids | TTHC / smallest container | COA | Current / matches | Bucket |
| --- | --- | --- | --- | --- | --- | --- |
| 13 | Guavaz Live Resin (78.03% THCA) | THCA 78.03%, Δ9 0.11%, CBGA 1.71% | 68.55% → 1,714 mg / 2.5 g (×4,284) | `Guavaz Live Resin` and `Guavaz Resin COA.pdf` (identical) · Badger · 2026-09-15 · lab ID 56050100 | Yes / Yes | **b** |
| 14 | Fruit Bowl Live Resin (81.60% THCA) — URL handle says "grape-fritter" | THCA 81.60%, Δ9 0.11% | 71.67% → 1,792 mg / 2.5 g (×4,479) | `Fruit Bowl Resin COA.pdf` · Badger · 2026-09-15 · 56050099 | Yes / Yes | **b** |
| 15 | Afghan Black Hash (79.12% THCA) | THCA 79.12%, Δ9 0.25%, THCVa 0.26% | 69.63% → 1,393 mg / 2 g (×3,482) | `Afghan Black Hash.pdf` (scan) · Marin · **2024-10-17** · sample 564-101324-630, **sample name "Moonrocks"** | **Stale; name mismatch** (percent matches the listing) | **b** |
| 16 | Trop Cherry Tier 2 Rosin (72.69%) | THCA 72.69%, Δ9 0.10% | 63.85% → 638 mg / 1 g (×1,596) | `Trop Cherry Rosin COA.pdf` · Badger · 2026-09-15 · 56050093 | Yes / Yes | **b** |
| 17 | Apple Tart Tier 2 Rosin (73.20%) | THCA 73.20%, Δ9 0.10% | 64.29% → 643 mg (×1,607) | `Apple Tart Rosin COA.pdf` · Badger · 2026-09-15 · 56050096 | Yes / Yes | **b** |
| 18 | Banana Punch Tier 2 Rosin (75.20%) — handle says "apple-tart" | THCA 75.20%, Δ9 0.12%, CBD 0.44% | 66.07% → 661 mg (×1,652) | `Banana Punch Rosin COA.pdf` · Badger · 2026-09-15 · 56050094 | Yes / Yes | **b** |
| 19 | Hash Burger Tier 2 Rosin (76.07%) | THCA 76.07%, Δ9 0.11% | 66.83% → 668 mg (×1,671) | `Hash Burger Rosin COA.pdf` · Badger · 2026-09-15 · 56050097 | Yes / Yes | **b** |
| 20 | Peach Ringz Tier 2 Rosin (75.40%) — handle says "apple-tart" | THCA 75.40%, Δ9 0.09% | 66.22% → 662 mg (×1,655) | `Peach RIngz Rosin COA.pdf` · Badger · 2026-09-15 · 56050098 | Yes / Yes | **b** |
| 21 | Grape Gas Tier 2 Rosin (74.34%) | THCA 74.34%, Δ9 0.13% | 65.32% → 653 mg (×1,633) | `Grape Gas Rosin COA.pdf` · Badger · 2026-09-15 · 56050095 | Yes / Yes | **b** |
| 22 | Small Diamonds (99.17% THCA) | THCA 99.18%, Δ9 ND | 86.98% → 1,740 mg / 2 g (×4,349) | `THCA-diamonds-coa-.pdf` · Badger · **2025-04-17** · 55019332 | **Stale** / Yes | **b** ⚖ also arguably an intermediate sold to consumers ((1)(C)(iii)) |

### "CBDA" live resins — 7 products, all (b) ⚖

These are marketed as CBD products, but each 2.5 g jar (smallest size) holds roughly 4–33 mg of total THC: **11 to 83 times** the 0.4 mg cap. At the plant-level test, six are under 0.3% TTHC; **Apricot is already 1.32%**. All COAs: Badger, issued 2026-03-09 (current), sample names match.

⚖ They also contain about 0.8–1.9% **THCV** (tetrahydrocannabivarin). If THCV counts as a "tetrahydrocannabinol" or a similar-effect cannabinoid (FDA has not published its list), the totals rise further. It doesn't change the bucket.

| # | Product | Δ9 / THCA / THCV | TTHC → per 2.5 g | Bucket |
| --- | --- | --- | --- | --- |
| 23 | Sour Warheads Live Resin (69.68% CBDA) | 0.11% / 0.19% / 0.98% | 0.272% → 6.8 mg (×17) | **b** |
| 24 | Super Suver Live Resin (69.70% CBDA) | 0.05% / 0.18% / 1.11% | 0.207% → 5.2 mg (×13) | **b** |
| 25 | Apricot Live Resin (68.46% CBDA) | 0.09% / 1.41% / 0.80% | 1.322% → 33.1 mg (×83) | **b** |
| 26 | Cherry Diesel Live Resin (67.86% CBDA) | 0.03% / 0.20% / 1.02% | 0.207% → 5.2 mg (×13) | **b** |
| 27 | Purple Gas Live Resin (69.14% CBDA) | 0.09% / 0.13% / — | 0.200% → 5.0 mg (×12) | **b** |
| 28 | Chem Berry Live Resin (51.75% CBDA) | 0.04% / 0.25% / 1.93% | 0.259% → 6.5 mg (×16) | **b** |
| 29 | Mango Fire Live Resin (63.63% CBDA) | 0.03% / 0.17% / — | 0.175% → 4.4 mg (×11) | **b** |

The listings quote "THC" figures (for example "0.199% THC", "0.259% THC") that are total THC from these COAs. That's accurate, but processors may read "CBD" products listing THC above zero as a red flag.

### THC edibles — 6 products, all (b)

| # | Product | COA result | TTHC / smallest package | COA | Current / matches | Bucket |
| --- | --- | --- | --- | --- | --- | --- |
| 30 | 30mg THC Gummies – Blood Orange (2 ct, 12 ct) | Δ9 31.01 mg/gummy | 62 mg / 2-ct (×155); 372 mg / 12-ct (×930) | `30mg Blood Orange Gummy.pdf` · Badger · 2026-03-09 · 56015345. Older: ACS 2025, batch 02D25002 (27.8 mg) | Yes / Yes | **b** |
| 31 | 30mg THC Gummies – Blue Raspberry (12 ct) | Δ9 26.33 mg/gummy (12% under label) | 316 mg / 12-ct (×790) | `30mg Blue Raz COA.pdf` · Badger · **2025-07-11** · 55035087 ("Blue Razz Sativa Live Resin Gummy") | **Stale**; potency below label | **b** |
| 32 | 30mg THC Gummies – Wild Cherry (2 ct, 12 ct) | Δ9 31.32 mg/gummy | 63 mg / 2-ct (×157) | `30mg Wild Cherry Gummy.pdf` · Badger · 2026-03-09 · 56015346. Older: D9A 2025-08-07 (Δ9 31 mg, **Δ8 0.0178%**, HHC ND) | Yes / Yes | **b** |
| 33 | Rest – Wild Berry Nighttime Gummies (CBD+CBN+THC, 15 ct) | Δ9 10.66 mg, CBD 145.5 mg, CBN 57.3 mg per gummy | 160 mg / 15-ct (×400) | `Rest - Wild Berry Nighttime Gimmies.pdf` · Badger · **2025-08-13** · 55040362 (sample "Max Relax Gummy") | **Stale**; supplier name, profile matches label | **b** |
| 34 | Rise – Mango Daytime Gummies (CBD+CBG+THC, 15 ct) | Δ9 5.31 mg, CBD 113 mg, CBG 115 mg per gummy | 80 mg / 15-ct (×199) | `Rise - Mango Daytime Gummies.pdf` · Badger · **2025-04-17** · 55019339 (sample "Serenergy Max Awake CBD Gummy") | **Stale**; supplier name, profile matches | **b** |
| 35 | 10mg THC + CBD Gummy Squares (3 ct, 10 ct) | **No potency on COA** (safety panel only). Label: 10 mg THC + 10 mg CBD per gummy | 30 mg / 3-ct (×75), from the label | `10mg THC:CBD Gummy Squares.pdf` · SC · 2025-08-22 · batch WPFSASG-052025 ("Assorted HD9/CBD Gummy Full panel"; "Not a Regulatory Hemp Lab Test Report") | **Stale; no potency** | **b** ⚖ (from the label) |

### Tinctures — 3 products: 2 (b), 1 (d)

| # | Product | COA result | TTHC / bottle | COA | Current / matches | Bucket |
| --- | --- | --- | --- | --- | --- | --- |
| 36 | 3,500mg CBD Oil Drops – Full Spectrum, Natural (30 mL) | Δ9 50.56 mg, CBD 3,593 mg per 30 mL | 50.6 mg (×126) | `3,500mg … Full Spectrum - Natural Flavor.pdf` · Badger · **2025-09-18** · 55047670 ("Whole Plant Oil") | **Stale** (6 weeks past 12 months) / Yes | **b** |
| 37 | 3,500mg CBD Oil Drops – Full Spectrum, Orange (30 mL) | Δ9 82.61 mg, CBD 3,473 mg per 30 mL | 82.6 mg (×207) | `3,500mg … Full Spectrum - Orange Flavor.pdf` · Badger · **2025-04-17** · 55019336 | **Stale** / Yes | **b** |
| 38 | 3,500mg CBD Oil Drops – Broad Spectrum / THC Free (30 mL) | Δ9, THCA ND; CBD 3,595 mg; CBN 77 mg | ND, **LOQ not stated** ("available upon request") | `3,500mg CBD Oil Drops THC FREE.pdf` · Badger · **2025-09-18** · 55047672 | **Stale** / Yes | **d** → likely **c** with a fresh COA stating mg THC per 30 mL and an LOQ ≤ ~0.0014% |

### Beverage enhancers — 2 products: 1 (b), 1 (d)

⚖ **Intermediate-product question.** Both are sold as liquids to be added to drinks. §781 (3)(B)(ii) defines an *intermediate* product to include a liquid "intended or marketed to be mixed … or otherwise added to … any other substance prior to … consumption", and (1)(C)(iii) excludes intermediates "marketed or sold as a final product or directly to an end consumer". Read literally, a THC-free drink enhancer sold at retail could fall outside "hemp" on Dec 11 regardless of THC. Counsel should decide. Pennsylvania's position on THC in food and drinks is a separate state question.

| # | Product | COA result | TTHC / container | COA | Current / matches | Bucket |
| --- | --- | --- | --- | --- | --- | --- |
| 39 | Liquid Harmony – THC Beverage Enhancer (6 oz, 1 oz) | 6 oz: Δ9 408.7 mg per 180 mL bottle. 1 oz: Δ9 78.3 mg per 30 mL | 409 mg (×1,022); 78 mg (×196) | `Liquid Harmony - THC Beverage Enhancer.pdf` · Badger · **2025-04-17** · 55019328 ("Nano THC Beverage Enhancer"). `Mini Liquid Harmony….pdf` · Badger · **2025-09-18** · 55047671 | **Stale.** The listing says 5 mg per teaspoon × 36 servings (180 mg), elsewhere "2.5 mg per serving" and a "75 mg bottle"; the COA shows 409 mg per 180 mL. **Label and COA disagree** | **b** |
| 40 | Liquid Serenity – CBD Beverage Enhancer, THC Free (6 oz) | COA is for the **ingredient** "CBD Nano" (CBD 418.6 mg/g, THC ND), not the finished bottle. Label: 450 mg CBD per bottle | Unknown | `Liquid Serenity CBD Beverage Enhancer` · Badger · 2025-11-13 · 55058542 | Current / **mismatch (ingredient, not product)** | **d** ⚖ (no finished-product COA; intermediate-product question) |

### Capsules — 1 product, (d)

| # | Product | COA result | TTHC / container | COA | Current / matches | Bucket |
| --- | --- | --- | --- | --- | --- | --- |
| 41 | 50mg CBD Softgels – Broad Spectrum (30 ct) | CBD 50.43 mg per capsule; THC ND (LOQ not stated) | Unknown; 30 capsules × any trace | `Softgels_CBD_50MG 2025.pdf` · Badger · **2024-12-23** · 55002955 ("Daily Relief Softgels 50MG CBD") | **Stale** / Yes | **d** → likely **c** with a fresh COA |
| 42 | Deep Sleep Microgels – THC Free | Label: CBN 20 mg, CBD 20 mg, CBDV 4 mg | Unknown | **None found** | — | **d** ⚖ CBN is often made by converting other cannabinoids (synthesized outside the plant → Dec 11 exclusion); whether CBN is a "similar effect" cannabinoid awaits FDA's list |

### Topicals — 2 products, both (d)

Topicals are inside the statute ("topical application"), so the 0.4 mg per-container cap applies to them.

| # | Product | COA result | TTHC / container | COA | Current / matches | Bucket |
| --- | --- | --- | --- | --- | --- | --- |
| 43 | Max Strength 10,000mg Full Spectrum CBD Muscle & Joint Cream | COA is for **"Gold Edition 12,000mg CBD Cream, 4 oz"**: total CBD 16,856 mg; Δ9 and THCA **<LOQ (LOQ 0.015%)** | Up to 18.4 mg could hide under that LOQ in a 122.5 g jar; can't prove ≤ 0.4 mg | `10000mg Muscle and Joint Cream 2025.pdf` · ACS · completed **2025-02-04** · batch 3-67914112K | **Stale; product mismatch** (12,000 vs 10,000 mg). "Full spectrum" usually means some THC | **d** → **c** only with a matching COA proving ≤ 0.4 mg per jar |
| 44 | CBD + CBG Hyaluronic Face & Neck Serum (300 mg) | Label: broad spectrum, THC-free | Unknown | **None found** | — | **d** → likely **c** with a COA |

(The folder also holds a COA for a 1,000 mg Lavender & Eucalyptus balm — SC Labs, 2025-08-18, total THC ND per 60 g unit — but that product isn't listed for sale.)

### Pet products — 2 products, both (d)

Pet products are covered ("human or animal use").

| # | Product | COA result | TTHC / container | COA | Current / matches | Bucket |
| --- | --- | --- | --- | --- | --- | --- |
| 45 | 250mg CBD Healthy Pet Broad Spectrum Tincture | CBD 265 mg per 30 mL, CBN 7 mg, Δ9 and THCA ND. Label says 50 mg CBG was added; **COA shows CBG ND** | ND, LOQ not stated | `Pet Tincture 2025.pdf` · Badger · **2025-04-17** · 55019333 ("Healthy Pet Oil Drops") | **Stale; formulation changed since** | **d** → likely **c** with a fresh COA |
| 46 | CBD Pet Treats (Peanut Butter Pumpkin, 25 mg × 30) | **No matching COA.** The Pets folder holds "40mg CBD Beef Healthy Pet Sticks" (ICAL, 2025-01-21, "QA sample – informational only") and a file named "CBD Pet Nuggets 5mg" that is actually **another brand's product** ("Bailey's Omega XS 6mg", SC Labs, 2025-07-03, 0.288 mg THC per unit) | Unknown | — | **Mismatch** | **d** → likely **c** with a matching COA |

### Non-cannabinoid — 1 product, (c)

| # | Product | Notes | Bucket |
| --- | --- | --- | --- |
| 47 | Blue Lotus Sweet Dream Sleep Gummies – 5 mg melatonin, THC & CBD free | No cannabinoids claimed, so it isn't a hemp-derived cannabinoid product. No COA needed for this question (other FDA/food rules still apply) | **c** |

## Paperwork issues a processor will flag

1. **Stale COAs** (older than 12 months) for 15 listed products (for two of them, some variants only): Premium Mini Prerolls (Double Runtz), the vape (Kush Krasher), Afghan Black Hash, Small Diamonds, Blue Raz, Rest, Rise, the gummy squares, all three tinctures, Liquid Harmony, the softgels, the cream and the pet tincture.
2. **Mismatched COAs:** Afghan Black Hash → "Moonrocks"; 10,000 mg cream → "Gold Edition 12,000 mg"; pet treats → beef sticks and another brand's chew; Liquid Serenity → ingredient only.
3. **No potency result:** 10 mg THC + CBD Gummy Squares.
4. **Label vs COA disagreements:** Liquid Harmony (180 vs 409 mg per bottle); Blue Raz (30 vs 26.3 mg); Double Runtz (24.24% vs 21.57%); pet tincture CBG.
5. **No COA at all:** Astro Haze, Deep Sleep Microgels, face serum, two pre-roll strains (Fusion, Pineapple Donut).
6. **Catalog hygiene:** product URLs that name a different product (for example "Banana Punch" at `/products/apple-tart-…-copy`, "Fruit Bowl" at `/products/grape-fritter-…-copy`, "Astro Haze" at `/products/upgrade-…-copy`). Underwriters compare the site to the product list; mismatches look like relabeling.
7. **COA folder** has 229 files, mostly for products not currently listed, with several duplicate names. A per-product COA link (QR or button on each product page) is what processors expect.
8. **Storefront payment setup.** ⚖ The public product-page checkout config (fetched 2026-11-02) shows Google Pay tokenizing through gateway `"shopify"`, which normally means Shopify Payments is active. [Shopify Payments doesn't support hemp, CBD or THC sales](https://help.shopify.com/en/manual/compliance/legal/hemp/payments). If Shopify Payments is processing these products, the account is at risk of a hold or termination. The owner should check Shopify Admin → Settings → Payments today.

## Questions for counsel

1. Confirm the reading that only (ii)(I)/(iv)(I) apply from Nov 12 and everything else from Dec 11 (P.L. 119-103 §2019).
2. **Container** for multi-unit packs (pre-roll 6-packs, gummy bags) given the "innermost wrapping … in direct contact" definition; FDA's promised detail hasn't been published.
3. **THCV** and **CBN**: tetrahydrocannabinols or similar-effect cannabinoids? (No FDA list yet.)
4. **Beverage enhancers and diamonds:** "intermediate" products sold to consumers under (1)(C)(iii)?
5. What COA standard (age, per-batch, per-container figure, LOQ) the merchant should require from suppliers so that ND results prove ≤ 0.4 mg per container.
6. **Inventory wind-down** for bucket (b) products before Dec 11, and treatment of stock on hand.
7. **Pennsylvania** and destination-state rules for shipped orders (separate from federal law; PA's position on THC in food and drinks matters for Liquid Harmony).
8. Health/wellness claims on product pages ("relief", "recovery", "sleep") under FDA rules — a frequent processor termination trigger.

## Sources

- Store catalog: `https://herbalhealerscbd.com/products.json` and product pages; COA page `https://herbalhealerscbd.com/pages/3rd-party-lab-tests` → public Google Drive folder. All fetched 2026-11-02.
- [P.L. 119-37 (enrolled PDF), div. B §781](https://www.congress.gov/119/plaws/publ37/PLAW-119publ37.pdf), read 2026-11-02.
- [P.L. 119-103 (enrolled PDF), §2019](https://www.congress.gov/119/plaws/publ103/PLAW-119publ103.pdf), read 2026-11-02.
- [CRS LSB11496, Delay in Changes to Hemp Definition](https://www.everycrsreport.com/reports/LSB11496.html) (FDA lists unpublished as of 2026-10-28).
- [CRS IF13136, Changes to the Statutory Definition of Hemp](https://www.congress.gov/crs-product/IF13136).
- [Marijuana Moment, FDA misses deadline to publish cannabinoid list (2026-02-18)](https://www.marijuanamoment.net/fda-misses-deadline-to-publish-cannabinoid-list-and-define-hemp-containers-drawing-industry-criticism).
- [Shopify Help Center: payment options for hemp sales](https://help.shopify.com/en/manual/compliance/legal/hemp/payments).
