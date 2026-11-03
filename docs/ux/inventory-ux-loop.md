# Inventory and sync UX loop, 2026-11-02

Five review-and-fix loops over Rupert's stock and sync screens, judged the way a product designer and an
inventory-ops lead would judge them. The fixes are in this branch. It is stacked on #620, the Rupert stock
ledger, which is still waiting on owner decisions. Nothing here writes to Shopify, C-Trax or Square.

**Result:** the fifth loop found no high- or medium-severity issues. The automated checks pass on all
30 screens at 1440 and 375 px in all five appearances (300 page views): no page overflow, no text under
WCAG AA contrast, no unlabelled fields and no page targets under 24 px. The 24 px check leaves out shared
components that #623 already fixes. The low-severity items still open are listed at the end.

## Scope and method

- **Screens:**
  - Inventory, with its search answer, and Store comparison.
  - Movements, Stock review, Stock alerts and Physical counts, including the scan count.
  - Transfers & backorders and Reservations.
  - The product page and C-Trax stock.
  - Rupert stock: the list, an item, count, receive, adjust and transfer, the ledger, the push preview and
    setup.
  - Sync, Credentials & sync, C-Trax setup and Locations.
  - The register's empty state.
- **Demo data:** `bin/rails rupert:inventory_ux_demo` runs after `rupert:app_review_demo`. Everything in it
  is made up:
  - 60 variants, with sizes and scents, some with no SKU and one SKU shared by two variants.
  - Three shops and a stockroom.
  - Shopify and C-Trax stock reads: Main Street was read minutes ago, Riverside two and three days ago.
  - C-Trax readings with drift, a negative, a fractional bulk unit and an untracked item.
  - Shopify sync failures (a throttle and a missing location), and C-Trax credential and timeout failures.
  - Transfers, a backorder and two weeks of Rupert stock movements by three people.
  - Barcodes in the 200 in-store range and IDs from 9100000 up.
- **Review:**
  - Headless Chrome screenshots of every screen at 1440 and 375 px, in Herbal and Dark, with in-page checks
    for overflow, contrast, labels and targets. Light, Mist and Sepia got the checks only.
  - Hands-on flows in the built-in browser: keyboard and wedge-scanner typing.
- **Overlap with #623:** #623, the app-wide UX pass, fixes the top bar that widens phones to 440 px and
  the 18 px disclosure and sort targets. Those were left out here. Phone captures hide the top bar overflow
  so page content is measured at 375 px. The 375 px "before" shots are 440 px wide for that reason.

## The top jobs, before and after

| Job | Before | After |
| --- | --- | --- |
| Is it in stock? | Searching Inventory for "field guide" or a barcode found nothing: search matched only a variant's SKU or its own title ("S"). A hit gave one row per location, Shopify only. | Search matches product names, variant titles, SKUs and exact barcodes. One card per item shows what Shopify can sell at each location, C-Trax's stock per store and Rupert's number per site. Old reads are marked, and on phones the answer sits right under the search. |
| Count a shelf (Rupert stock) | Opened on the stockroom, chosen alphabetically. Per item: scan, click Count, type, Save. The code stayed in the box, so the next scan was appended to it. | With "Start a count", a scan opens the count and saving returns to an empty, focused search: scan, type the number, Enter, with no clicks. The count is blind and the notice gives the difference afterwards. |
| Receive a delivery | Find the item, then Receive. The four buttons overflowed the card on desktop. | Same steps; the buttons fit. The site is remembered, and the reference field takes the PO or invoice. |
| Fix a mismatch | No platform numbers next to Rupert's. Store comparison opened on a red error with every row unknown, and the push preview was a long list of cards. | The list and the item page show "Shopify 6 · 20 fewer" or "C-Trax 4 · matches · 3 h old". Store comparison opens on the mapped pair. The preview table puts the biggest changes first and flags large ones for a recount. |
| See why a sync failed | The Sync page listed Shopify runs only, with raw words, no C-Trax, no read age per store and no fix. | Stock sources sits at the top of Sync: every store's read age, the latest failure with its SyncFailure guidance, and whether it has worked since. |
| Trust the numbers | A typo like 2 for 20, or a barcode scanned into the quantity box, was saved. Ledger rows showed emails, and "+12" for a first count. | A barcode is refused. A count far from Rupert's number asks for a recount first. After saving, the page offers Count again, Adjust and See in ledger. The ledger shows names and "Set". |

## Loop 1: the Rupert stock screens, Store comparison and Sync

Ranked findings:

1. **High.** The Rupert stock list's four action buttons overflowed their card on desktop. `.btn-lg` has a
   12 rem minimum width, and four don't fit in the narrow page.
2. **High.** No platform numbers beside Rupert's, so staff could not tell whether a number was trustworthy
   without opening the push preview.
3. **High.** Store comparison opened on a red "choose both sources" error with 60 rows of "Unknown".
4. **High.** The Sync page had no C-Trax, no per-store freshness, no failure guidance and raw status words
   ("failed", "scheduled").
5. **Medium.** Rupert stock opened on the alphabetically first site, the stockroom, not the shop.
6. **Medium.** The push preview was 42 cards of about 100 px each in alphabetical order, under a red alarm
   box for an informational note, with no hint of which changes were suspicious.
7. **Medium.** The count form showed Rupert's number, which steers counters (counts should be blind).
8. **Medium.** The ledger showed emails, "+12" for a first count and had no item search. The item page
   showed raw link IDs and emails.

Fixes (commits `bf268e81` to `96d4ffc6`): all eight. The push preview now has status tabs with counts and a
calm notice. Large changes are flagged for a recount: 10 or more units, and at least half the stock.

| Before | After |
| --- | --- |
| ![Rupert stock before](inventory-ux-loop/l1-rs-items-before.jpg) | ![Rupert stock after](inventory-ux-loop/l1-rs-items-after.jpg) |
| ![Item before](inventory-ux-loop/l1-rs-item-before.jpg) | ![Item after](inventory-ux-loop/l1-rs-item-after.jpg) |
| ![Push preview before](inventory-ux-loop/l1-rs-preview-before.jpg) | ![Push preview after](inventory-ux-loop/l1-rs-preview-after.jpg) |
| ![Store comparison before](inventory-ux-loop/l1-stock-comparison-before.jpg) | ![Store comparison after](inventory-ux-loop/l1-stock-comparison-after.jpg) |
| ![Sync before](inventory-ux-loop/l1-syncs-before.jpg) | ![Sync after](inventory-ux-loop/l1-syncs-after.jpg) |
| ![Ledger before](inventory-ux-loop/l1-rs-ledger-before.jpg) | ![Ledger after](inventory-ux-loop/l1-rs-ledger-after.jpg) |

At 375 px: the list, the count form (now blind) and the preview.

| Before | After |
| --- | --- |
| ![List on a phone before](inventory-ux-loop/l1-rs-items-375-before.jpg) | ![List on a phone after](inventory-ux-loop/l1-rs-items-375-after.jpg) |
| ![Count before](inventory-ux-loop/l1-rs-count-375-before.jpg) | ![Count after](inventory-ux-loop/l1-rs-count-375-after.jpg) |
| ![Preview on a phone before](inventory-ux-loop/l1-rs-preview-375-before.jpg) | ![Preview on a phone after](inventory-ux-loop/l1-rs-preview-375-after.jpg) |

## Loop 2: search, the scanner flow and C-Trax

Ranked findings:

1. **High.** Inventory and Reservations search could not find a product by name or barcode.
2. **High.** After a scan, the code stayed unselected in the box, so the next scan was appended to it
   ("JP-2003JP-2004").
3. **High.** A barcode scanned into the quantity box was cut to 8 digits by `maxlength`. Codes with leading
   zeros could be saved as plausible counts.
4. **Medium.** Answering "is it in stock?" took one row per location and never showed C-Trax, the count
   reference, or Rupert stock.
5. **Medium.** Counting took a click per item, with no scan-first mode.
6. **Medium.** Search and filter buttons said "Saving…" while loading. This is the app-wide `form_busy`.
7. **Medium.** C-Trax stock showed the read date without a time or an age, and did not flag negative or
   untracked stock.
8. **Medium.** The register said "No products match these filters" when nothing was filtered: every item
   was hidden for lack of a website image.

Fixes (commits `1d290fd9` to `d123dcfc`): all eight. The scan-first mode is "When a scan matches one item:
Start a count". A count far from Rupert's number asks for a blind recount before saving. The iPhone app's
camera scanner can fill the Rupert stock search, as it already can on the scan count.

| Before | After |
| --- | --- |
| ![Inventory search before](inventory-ux-loop/l2-inventory-search-before.jpg) | ![Inventory search after](inventory-ux-loop/l2-inventory-search-after.jpg) |

![Scan mode switch](inventory-ux-loop/l2-rs-items-scan-mode.jpg)

![Recount prompt](inventory-ux-loop/l2-recount-prompt.jpg)

## Loop 3: the older stock screens and orientation

Ranked findings:

1. **High.** Count worksheets listed items by variant title only ("Speckled", "12 oz bag"), and the scan
   page listed SKUs only.
2. **Medium.** Movements named items by SKU only (many have none), put the variant title first and wrapped
   SKUs at the hyphen.
3. **Medium.** The product page, C-Trax stock and Rupert stock setup lit Overview in the rail. The count,
   receive and transfer forms lit the ledger.
4. **Medium.** Physical counts and Rupert stock counts sat side by side with no word on how they differ.
5. **Low.** Inventory row actions were 19 px tall, Locations said "Ctrax", and Stock review showed a red
   error for a "results limited" caution.

Fixes (commits `d9ed4270` to `a98a5f61`): all five. The note on Physical counts only describes each kind of
count. Which one is official is owner decision 4 below.

| Before | After |
| --- | --- |
| ![Count sheet before](inventory-ux-loop/l3-count-sheet-before.jpg) | ![Count sheet after](inventory-ux-loop/l3-count-sheet-after.jpg) |

## Loop 4: undo, and phones

Ranked findings:

1. **Medium.** There was no path from a saved mistake to its correction. Ledger rows are never edited, but
   nothing said so or offered the fix.
2. **Medium.** An Inventory search on a phone put a screen of queue cards and filters before the answer.
3. **Medium.** On phones the Rupert stock ledger scrolled sideways, and C-Trax stock put the stock figure
   in the last column, off-screen.
4. **Low.** Negative platform readings used a hyphen instead of a minus sign.

Fixes (commits `86467316` and `5920fd9b`): all four. After recording, the list offers Count again, Adjust and
See in ledger. The ledger and the push preview share a `.stack-table` that stacks rows on phones.

| Before | After |
| --- | --- |
| ![Search on a phone before](inventory-ux-loop/l4-inventory-search-375-before.jpg) | ![Search on a phone after](inventory-ux-loop/l4-inventory-search-375-after.jpg) |
| ![Ledger on a phone before](inventory-ux-loop/l4-rs-ledger-375-before.jpg) | ![Ledger on a phone after](inventory-ux-loop/l4-rs-ledger-375-after.jpg) |
| ![C-Trax stock on a phone before](inventory-ux-loop/l4-ctrax-stock-375-before.jpg) | ![C-Trax stock on a phone after](inventory-ux-loop/l4-ctrax-stock-375-after.jpg) |

![Just recorded, with the correction links](inventory-ux-loop/l4-just-recorded.jpg)

## Loop 5: verification

- **Automated checks:** 300 page views (30 screens × 2 widths × 5 appearances): 0 overflow, 0 contrast
  failures, 0 unlabelled fields, 0 page targets under 24 px.
- **Hands-on flows:**
  - Wedge scan, then count, then Enter, back to a focused empty search.
  - A barcode in the quantity box is refused and the box clears.
  - A far-off count asks for a recount, then saves.
  - "Field guide", "candle 8 oz" and a barcode all find their items.
  - Sync shows the C-Trax credential failure with its fix, and says it worked again since.
- **Fixed in this loop:** legacy Movements now also stacks on phones (commit `cb33065b`).
- **Not seen in this loop:** no high or medium issues.

Dark, at both widths:

![Rupert stock, Dark, phone](inventory-ux-loop/l5-rs-items-375-dark.jpg)
![Sync, Dark, phone](inventory-ux-loop/l5-syncs-375-dark.jpg)
![Push preview, Dark](inventory-ux-loop/l5-rs-preview-dark.jpg)

## Still open (low severity)

- Store comparison is dense and uses review jargon ("explicit package missing"). It is a manager's
  investigation tool. A plainer "what to do" column would help.
- Stock alerts scrolls sideways on phones. It is a planning table with a labelled scroll region.
- Rupert stock setup is one long form per site. It is rare work, but a compact table with an edit view
  would be faster.
- The glossary popover (`.term-panel`) opens left-aligned. Near the right edge of a page (for example
  "Received" on a stock request) it can run off-screen. This is the shared component.
- Rupert stock items are per site after an import: importing a second store's C-Trax read creates new
  items instead of linking existing ones. The demo links Riverside to Main Street's items by hand. A
  "link to an existing item" step in setup would prevent duplicates. This touches #620's importer and is
  worth deciding with the owner decisions below.

## Owner decisions still waiting (from #620, `docs/plans/rupert-master-inventory.md` §4)

None of these were made here. The screens work either way:

1. **Counts set Shopify on hand or available.**
   - Today: the chips and the preview compare with Shopify's stored `on_hand`, as #620 proposes.
   - If the owner picks available: only the observation key in `MasterStock::PushPreview` changes. The
     words on screen ("Shopify 6") stay right either way.
2. **First live platform, site and test item.**
   - Today: the preview has a tab per platform and a site picker.
   - Either way: a live push button would sit beside one row, and nothing in this branch assumes which.
3. **Starting balances: recount everything or seed from C-Trax.**
   - Today: setup offers both. Seeded counts are labelled in the ledger, and a first count shows "Set".
4. **Which count is official, and who may adjust.**
   - Today: Physical counts and Rupert stock counts each say what they do. Recording needs `inventory.write`.
   - Either way: a manager-only adjust would be a permission change, not a screen change.
5. **C-Trax increases.**
   - Today: the preview blocks them with "enter +N in C-Trax by hand" until C-Trax confirms `add`.
6. **Square.**
   - Today: the preview tab reads "Square (not mapped)" and the Sync card says no Square stock is read.
7. **Transfers in one step or with an in-transit state.**
   - Today: one step, as built.
8. **Adjustment reasons.**
   - Today: the reason list comes from `StockLedgerEntry::REASONS`. Renaming or adding one changes the
     select with no view work.

## Follow-ups outside this task

- A real store's web domain is hardcoded as an allowed image host in
  `web/app/services/ctrax/catalog_images.rb`. This is a public repo. Moving the allowed hosts into tenant
  settings or env would keep store names out of the code.
- The register's tip field (`tip_percentage`) has no programmatic label.

## Reproduce

```bash
cd web
REVIEW_PASSWORD='<12+ characters>' bin/rails rupert:app_review_demo
bin/rails rupert:inventory_ux_demo
```

Sign in as the demo reviewer. Rupert stock is under Stock → Rupert stock, and the source health panel is
under System → Connections → Sync. `test/integration/stock_ux_test.rb` covers the visible behaviour from
these loops.
