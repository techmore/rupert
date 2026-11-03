# Compliant ring-up guardrails and event mode (F70)

Card processors that accept hemp and CBD approve specific products, names and
categories. One sale rung up the wrong way (a prohibited product, a renamed or
custom item, a missing lab certificate) can get a merchant account held or
closed. F70 makes the compliant path the easy one at the register and at shows.

Rupert enforces the list the owner approves. Which products are legal to sell,
and where, is for the owner and counsel to decide.

## Owner setup (Sell → Compliance)

1. **Categories.** Add the categories your processor approved. Tick **Card** only
   for categories the processor accepts for card in writing. Tick **Prohibited**
   for anything that must never ring up (for example vapes).
2. **Approve items.** Show **Not yet approved**, then **Approve** each C-Trax item
   the store may sell. Give it a compliant register name (an optional shorter
   receipt name), its approved category, whether card is allowed, whether it needs
   a 21+ ID check and a current COA, total THC per container (from the COA) and
   the approved price. Names with health or marijuana claims (relief, heal, treat,
   pain, dispensary, weed…) are refused.
3. **Lab certificates (COA).** On an item, **Add certificate**: an https link to the
   lab report, lab, report number, optional batch, test date and optional expiry.
   A COA is current for the policy's age limit (365 days by default) or until its
   expiry, whichever is sooner. Withdrawn certificates stay for the record.
4. **Lock the register.** Under **Register rules**, tick **Sell approved items only**.
   The POS then shows approved items only, under their compliant names and
   approved categories, and every checkout passes the pre-sale check.
5. **Override PINs.** Each manager sets their own 4–8 digit PIN under
   **Compliance → More → Override PIN** (password required).

Every one of these changes is written to the **Audit log** tab with who, when and
the before/after values.

## The pre-sale check

| Rule | Cash | Card |
| --- | --- | --- |
| Not on the approved list, suspended, or a prohibited category | Blocked | Blocked |
| Over 0.4 mg THC per container, from Dec 11, 2026 | Blocked | Blocked |
| Not approved for card (item or category) | Sells | Blocked, manager may override |
| Not on the card processor's allow-list (F69) | Sells | Blocked |
| No current COA (when the item needs one) | Sells with a warning | Blocked, manager may override |
| ID not confirmed (age-restricted items) | Blocked | Blocked |
| Custom, open-price or renamed items | Not possible at the register | Not possible |

Before Dec 11, 2026 items over the THC limit show a warning; items with no THC
figure recorded show a warning from that day.

A blocked sale shows the reasons in the checkout panel. When every reason accepts
an override, a manager picks their name, enters their PIN and a reason (8+
characters). Five wrong PINs lock that manager for 15 minutes. Every block,
refusal and approval is logged; the receipt shows the approving manager.

The check runs before Rupert reads C-Trax stock, so a blocked cart never reaches
the source. Repeating the same checkout returns the same receipt.

## Event mode (Sell → Shows and pop-ups)

1. **Add event**: name, venue, dates, the store whose approved catalog and stock it
   draws from, the local sales tax rate, the opening cash float, and the staff who
   sell. Managers with an override PIN can also sell.
2. Add approved items with preset prices and units loaded. Prohibited items are
   not offered.
3. **Pre-event checklist** and **Open event**. Opening checks every item again and
   freezes the list, prices, card eligibility (card only when the item passes the
   card rules and has a current COA) and COA links.
4. Staff open the **event register** (from the event page, or the POS **More**
   menu). It has large tiles, a Cash / Card (terminal) choice, an ID check, quick
   cash and change. Card means the card was run on the event's own terminal; Rupert
   does not charge cards here. Card on a cash-only item needs a manager override.
5. A manager can **Pull** an item mid-event (with a reason); registers drop it within
   a minute.
6. **Close event**: counted cash (float included), the card terminal's batch total,
   and optionally units left per item. The event page then shows cash and card
   differences and per-item expected versus counted units. **Download CSV** gives
   every line with staff, tender, ID check and override.

Event sales are canonical orders (source `rupert_pos`, order numbers `EV-…`) at the
event's store, so they count in sales, tax and bookkeeping. Rupert changes no
C-Trax stock for them; move event stock in C-Trax as usual.

### Offline tolerance

Each sale is named on the device (`client_sale_id`) before it is sent, so a retry
or resend records it once. If the connection drops, a sale the frozen list allows
(cash, or card on a card-approved item, ID checked) is kept on that device and sent
when the connection returns; the top bar shows **Offline** and the number of unsent
sales. Overrides need a connection and are never offered offline. If the catalog
changed before a queued sale synced (item suspended, COA lapsed, item pulled after
the sale), the sale is still recorded, flagged, and listed on the daily exception
report. A queued sale the server refuses (for example the event was closed) stays on
the device under **Offline sales the server refused** for a manager. The page itself
must stay open: there is no installed offline app (F48).

## Reports

- **Audit log**: every catalog, category, COA, policy and PIN change, blocked sale,
  override (approved or refused) and event action.
- **Daily exceptions**: blocked sales, overrides, refusals and flagged event sales
  for a day, seven-day counts, and card sales that needed an override.
- **Catalog drift** (read-only): approved items whose C-Trax variant disappeared,
  was hidden, renamed or repriced since approval.
- **Event page and CSV**: who rang what, tenders, overrides, reconciliation.

## For developers: the eligibility interface (shared with F69)

`Compliance::ItemEligibility` is the one place the rules live. F69 (hemp payment
acceptance) plugs a processor allow-list into it rather than writing its own.

```ruby
lines  = Compliance::ItemEligibility.lines_for_ctrax(location:, variant_ids: %w[101 102])
result = Compliance::ItemEligibility.check(lines, tender: 'card', processor: allow_list, policy:, on: Date.current)
result.allowed?      # no blocking issue
result.overridable?  # every blocking issue accepts a manager PIN override
result.blocking      # [Issue(code:, severity: :block, overridable:, item_key:, item_name:, message:)]
result.as_json       # { allowed:, overridable:, tender_kind:, issues: [...] }
```

- `lines`: `ItemEligibility::Line(key:, name:, catalog_item:)`; `catalog_item` is a
  `ComplianceCatalogItem` or `nil` (not approved). Build lines for other sources the
  same way.
- `tender`: any string. Only `cash` counts as cash; every other tender (including
  ones added later) gets the card rules, so a new tender fails safe.
- `processor`: any object with `#name` and `#permits?(catalog_item)`. It is consulted
  for card tenders only. `ItemEligibility::CategoryAllowList.new(name:, category_names:)`
  is a ready-made allow-list by approved category name.
- Issue codes: `not_approved`, `suspended`, `category_prohibited`, `cash_ineligible`,
  `card_ineligible`, `processor_not_allowed`, `coa_missing`, `coa_expired`,
  `thc_over_federal_limit`, `thc_over_federal_limit_soon`, `thc_unknown`.

`Compliance::SaleGate.evaluate` adds the cart-level 21+ ID issue (`id_not_checked`),
and `SaleGate.enforce!(result, override:, location_id:)` logs and raises
`Compliance::Blocked` (a `Pos::Error`, with `#payload` for JSON) or returns the
approving manager. Call it before the sale's own transaction so refusals are kept.

`Pos::Checkout.prepare!(…, compliance: { id_checked:, override_user_id:, override_pin:, override_reason: })`
applies it to the C-Trax register when the store's `CompliancePolicy` is locked;
`Pos::EventSaleRecorder` applies it to every event sale.

## Not built yet

- Destination-state rules for shipped (online) orders.
- Drift checks against Shopify and Square catalogs (C-Trax only today).
- Event discounts (preset prices only), voids and refunds from the event register.
- Owner alert delivery (email/notification) for exceptions; the report is in-app.
- COA file upload and the full COA library (#549); certificates are links today.
- An installed offline app (F48); the event register must stay open to queue.
