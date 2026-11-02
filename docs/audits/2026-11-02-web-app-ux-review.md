# Signed-in web app UX review, 2026-11-02

Scope: the management web app in `web/` on `main` at 3c534a6d (#612): POS register and customer
screen, inventory, orders, time clock and timesheets, bookkeeping, settings and Team. Reviewed in
the browser with the fictional "Juniper & Pine Market" demo workspace (`rupert:app_review_demo`)
plus a fictional local stock read for the POS, at 1440px and 375px (and 320px for reflow), in all
five appearances: Herbal, Light, Mist, Sepia and Dark. Benchmarks: WCAG 2.2 AA and Rupert's own
[interface guidelines](../ui-standards.md).

Method: screenshots and hands-on flows, plus two in-page checks run on 20 screens: one for page
width, unnamed controls, unlabelled fields, landmarks, headings and targets under 24px, and one for
text contrast in every appearance.

Screenshots: `docs/audits/2026-11-02-web-app-ux/` (before and after).

## What already works well

- **Keyboard and scanner at the register.** Any key typed outside a field goes to the search box,
  `/` focuses it, Enter adds an exact SKU or barcode match straight to the cart (or opens the top
  result), Escape clears and ArrowDown moves into the tiles. Global search (`/`) finds orders by
  number from any page.
- **Contrast.** Every text element passed 4.5:1 (3:1 for large text) on the 14 screens checked in
  Herbal, Light, Mist and Sepia. Dark had one failure (fixed below).
- **Structure.** Every screen has one `h1`, a skip link, `header`/`nav`/`main`/`footer` landmarks, no
  unlabelled form fields and no unnamed buttons or links.
- **Calm pages.** Empty states are sentences, explanations are folded and the primary action is
  clear on most pages.

## Common jobs: steps today

| Job | Path | Steps |
| --- | --- | --- |
| Ring up a sale (scanner) | POS → scan each item → Checkout → tender → confirm | 0 clicks per in-stock item, about 3 to finish |
| Ring up a sale (touch) | POS → tap tile → **Add to cart** → … | 2 taps per item (finding L3) |
| Refund lookup | `/` → order number → Enter → "Process a refund" → amount and method → Refund | 4 actions plus typing for web orders; **no refund path on the order page for POS sales** (L2) |
| Clock in (staff) | My time (`/employee`) → Clock in | 1 tap from the staff home; 3 from the management shell (account menu → My time → Clock in). The demo admin has no linked worker record, so clock-in itself was not exercised |
| Stock check | `/` → SKU, or Stock → Inventory → search | 2 to 3 actions |

## Findings

Ranked by impact. **Fixed** items are in this branch; **Left** items need a behaviour, model or
product decision, or touch files that open PRs are changing.

### P0: breaks a page on a phone

| # | Finding | Status |
| --- | --- | --- |
| F1 | **Top bar overflows on every signed-in page at 375px.** The bar held the menu, the brand and up to seven 44px round buttons (search, Ask, chat, release blockers, release gate, notifications, account), about 440–504px wide. Phones let the whole page pan sideways and could zoom out to fit. | **Fixed.** On phones the release-blocker and release-gate icons step aside (they are still in the rail under System → Release blockers, with the same permission), the utilities lose their gaps, the wordmark folds under 440px and the face folds under 360px. Measured page width: 375px on all 15 screens checked (was 440–591px); 320px at 320. |
| F2 | **Wide tables widen the page.** In `.report-table-scroll` the `sr-only` header labels are absolutely positioned against the page rather than the scroller, so Inventory measured 591px wide at 375. | **Fixed.** The scroller is `position: relative`, matching `.table-region`. |

### P1: accessibility (WCAG 2.2 AA) and clipped controls

| # | Finding | Status |
| --- | --- | --- |
| F3 | **Targets under 24×24px (2.5.8).** Glossary "?" triggers were 20×18px (used across Overview, Sales, Bookkeeping, Reports and Purchasing), table sort buttons 13×12px, and the "How this page works", explainer and calculation disclosures were 17–19px tall. | **Fixed.** At least 24px each; the visible marks are unchanged. |
| F4 | **Timesheet week controls clipped on phones.** The week nav didn't wrap inside an `overflow-hidden` card, so "All weeks" was cut off, and the ‹ › arrows shrank to 21px wide. | **Fixed.** The nav wraps and the arrows keep 36×36px. |
| F5 | **Dark mode: white text on the olive accent, 2.9:1.** This affected today's date in the timesheet calendar and the staff time-off calendar, and the pressed follow-up decision buttons. Olive gets lighter in Dark, so fixed white fails there. | **Fixed.** These use `text-cream`, which flips with the theme. Re-checked: 0 failures in all five appearances. |

### P2: consistency, copy and information architecture

| # | Finding | Status |
| --- | --- | --- |
| F6 | **Ragged filter bands on phones.** On Timesheets the selects were 145–190px wide beside a 178px search box; other pages differed. | **Fixed.** Controls fill their toolbar field, and on phones each field takes a full row. |
| F7 | **Settings opens with raw `.env` keys** (SHOPIFY_/SQUARE_ variables) above the business name and pay rules, the two sections an owner actually changes. | **Fixed.** Business settings and Pay rules come first. Same sections, same content. |
| F8 | **Staff says "No staff yet"** while several people can sign in, and says the same thing when a filter simply matches nothing. | **Fixed.** The empty row explains what a staff record holds and links to Users (when the viewer can read Users); a filtered empty list says so and links to clear the filters. |
| L1 | **Invoices default to a real store's name.** `TenantSettings::DEFAULTS[:business_name]` is a specific business, so every new workspace prints it on invoices until someone changes it. The demo workspace did. | **Left.** This is a model default (out of scope for a view pass). Suggest defaulting to the workspace name. **High priority.** |
| L2 | **POS sales on the order page:** "Paid $0.00 · refundable $0.00" shows on a paid, completed order, there's no refund form, and the "Add shipment" form shows for in-store sales. | **Left.** Needs a decision on where POS refunds live and on what the paid amount means for POS orders. |
| L3 | **Touch ring-up takes 2 taps per item:** tile, then "Add to cart" in the item sheet. Scanning is already 0 taps. | **Left.** Behaviour change. Suggest one tap to add in-stock, fixed-price items and moving details to an info button or long-press. |
| L4 | **The customer screen goes blank when its link is missing or expired.** It returns a bare 404/410, so a paired display shows plain white. | **Left.** The controller is being changed in #611. Suggest a friendly "This screen isn't paired. Open it from the register" page. |
| L5 | **Tab strips scroll sideways on phones with no cue** (Sales, Reports, Customers, Time keeping). | **Left.** Suggest an edge fade or a "More" overflow. |
| L6 | **Settings is long:** 10+ sections with no in-page index. | **Left.** Suggest an "On this page" list or splitting it into System pages. |
| L7 | **Staff vs Users:** two directories under Team for overlapping people. | **Left** (F8 explains it in the empty state). This is a product decision. |
| L8 | **The 404 page ignores the appearance:** a fixed warm background, not the chosen theme. | **Left.** It's a static file. |
| L9 | **Timesheet week toggles put `aria-pressed` on links.** Pressed state belongs on buttons; links should use `aria-current`. | **Left.** Styling depends on the attribute; change both together. |
| L10 | **The "Next" bar on phones** takes about 150px above the page title with three buttons. | **Left.** Suggest one line with a menu on phones. |
| L11 | **The customer screen total reads "~$24.00".** The tilde means "estimated"; say it in words for customers. | **Left.** Copy in a file #611 is changing. |

## Measurements (375px wide, before → after)

| Screen | Page width |
| --- | --- |
| Overview, Sales, Registers, Time clock, Timesheets, Bookkeeping, Settings, Staff, Users, Customers, Reports, Purchasing, Notifications, Counts | 440 → 375 |
| Inventory | 591 → 375 |
| POS register | 375 → 375 (own layout) |

## Not covered

- Real card tenders and PAX/TRX terminals. The demo simulates tenders.
- Clock-in as a linked staff member (the demo admin has no worker record).
- Screen-reader announcements beyond markup inspection (no VoiceOver pass).
