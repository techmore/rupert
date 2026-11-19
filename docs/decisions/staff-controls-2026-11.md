# Staff controls: seven decisions for the owner (November 2026)

An audit of what staff accounts can do at the register found seven places where Rupert works as
it was built, but where the owner may want a tighter rule. None is a bug, so none was changed.

**Merging this document changes nothing in the app.** It adds this page and one test per item
that records today's behaviour (`web/test/integration/staff_controls/`). If a later change alters
one of these behaviours by accident, its test fails.

**How to say yes.** Items a to d each have a draft pull request with the recommended change
already built and tested. To accept one, merge its pull request. To decline, close it. Please
turn the off-site backups on before merging any of them: `main` deploys to production by itself.
None of the four needs a database migration. Items e to g have a recommendation here but no pull
request yet; say which you want and they will be built the same way.

| | Decision | Recommended | Pull request |
|---|---|---|---|
| a | Cashier refunds with no approval | A manager PIN for every cashier refund | DRAFT_A |
| b | Custom tip up to $999,999.99 | Cap a custom tip at $20 or half the sale, whichever is more | DRAFT_B |
| c | "Offline" event sales skip item blocks | Only when the block came after the sale | DRAFT_C |
| d | Override PIN: four digits, anyone can lock a manager out | Six digits; wrong guesses count against the cashier | DRAFT_D |
| e | Managers cannot ring a sale | Let managers use the register | not built |
| f | Any register user can run a demo sale | Limit demo mode to managers and owners | not built |
| g | Clock-in at a store the worker is not assigned to | Refuse it, with a message | not built |

Roles in this page are the built-in ones (`ROLE_PERMISSIONS` in `web/app/models/user.rb`): a
*cashier* has `sales.write`, a *staff* account (`employee`) has `pos.use` only, a *manager* has
neither. A workspace that edited its roles under Settings → Permissions may differ.

---

## a. A cashier can refund any amount with no approval

**Today.** A cashier can refund or void a card sale they rang themselves, for any amount up to
the sale's total, by typing an amount and a reason on the receipt page. No second person is
asked. They cannot refund a sale another cashier rang. Staff accounts (`pos.use` only) cannot
refund at all. Cash sales have no refund screen.
Tests: `refund_without_approval_test.rb`, "a cashier refunds the whole of their own card sale
with no approval" and "a cashier cannot refund a sale another cashier rang".

**Risk.** A cashier can ring a card sale on their own card, or a friend's, hand over the goods
and refund the money, and nobody is asked to look.

**Recommended.** Every refund started by someone who is not a manager or owner needs a manager
to pick their name and type their override PIN on the refund form, the same PIN used for blocked
sales. Owners and managers refund as now. Each approval and each refusal goes to the compliance
audit trail and the daily exception report.

**Code change.** `web/app/controllers/pos_checkouts_controller.rb#reverse`: when
`Current.user.can_approve_pos_override?` is false, call a new
`Compliance::SaleGate.approve_refund!` (approver, PIN, reason, lockout; writes
`override_granted` / `override_refused` with `source: refund`) before `Pos::CardReversal.call`.
`web/app/views/pos_checkouts/show.html.erb`: add the manager list and PIN field to the refund
form for those accounts. No migration. Pull request: DRAFT_A.

---

## b. A custom tip can be as large as $999,999.99

**Today.** The tip is chosen on the customer screen. On one phone the cashier opens that screen
and hands the phone over, so the cashier can also make the choice. A custom tip is accepted up
to $999,999.99 whatever the sale is worth. On a **Card (A920)** sale Rupert charges nothing: it
records what the cashier says was run on the terminal, tip included. Tips on Rupert sales are
later shared among the people clocked in at that moment (or kept by the cashier, where the store
uses direct tips), so a cashier working alone is credited with all of it.
Tests: `custom_tip_cap_test.rb`, "a custom tip of 999,999.99 is accepted on a 10.05 cart; one
cent more is refused" and "a 500.00 custom tip on a 10.05 Card (A920) sale is recorded and
shared to the cashier who rang it".

**Risk.** A cashier can record a large tip the customer never gave and have it show as tips
owed to them, and an honest slip of the finger (500 for 5.00) goes straight through.

**Recommended.** A custom tip may be at most $20.00 or 50% of the sale before tax, whichever is
more. Above that the customer screen says what the largest custom tip is. The 10/15/20% buttons
and "No tip" are unchanged, and no sum is calculated differently.

**Code change.** `web/app/models/pos_display_session.rb#choose_tip!`: two constants
(`CUSTOM_TIP_FLOOR_CENTS`, `CUSTOM_TIP_MAX_PERCENT`) and a `:too_large` answer for a custom
amount above the cap. `web/app/controllers/customer_displays_controller.rb#tip`: turn
`:too_large` into the message. No migration. Pull request: DRAFT_B.

---

## c. An event sale marked "offline" skips the item checks

**Today.** The event register keeps selling when the connection drops and sends the sales later,
each marked `offline: true` with the time the device says it happened. For those, Rupert does
not refuse an item that has since been suspended, lost its lab report or been pulled; it records
the sale and flags it for review, because the customer has already paid. But Rupert takes the
device's word for it: any seller on the event can send a sale with `offline: true` and a recent
time, and an item that was *already* blocked at that time is recorded all the same. (The ID
check, the event's staff list, the event's own frozen cash-only rule and the 72-hour limit still
apply.)
Tests: `event_offline_flag_test.rb`, "an item suspended an hour ago is refused online" and "the
same sale marked offline and timed after the suspension is recorded and flagged".

**Risk.** A seller who knows the trick can sell an item the owner has suspended, and it shows
up only as a flagged line on the next day's exception report.

**Recommended.** Keep the offline allowance only for its purpose: a block that appeared *after*
the sale was made. If the item's approval, category and lab reports were last changed before the
time the device gives, the item was already blocked when it was sold, and the sale is refused
like an online one. The device keeps a refused sale in its "refused" list so the money can be
dealt with by a manager.

**Code change.** `web/app/services/pos/event_sale_recorder.rb#record!`: the "record and flag"
branch additionally requires that every blocking line's catalog item (or its category or
certificates) has `updated_at` later than `occurred_at`; otherwise it goes through
`Compliance::SaleGate.enforce!` as an online sale does. No migration. Pull request: DRAFT_C.

---

## d. The manager override PIN: four digits, and anyone can lock a manager out

**Today.** A manager's override PIN is 4 to 8 digits. Wrong guesses are counted against the
manager whose name was picked, whoever typed them. Five wrong PINs in 15 minutes lock that
manager's PIN at every register for 15 minutes. There is no other limit.
Tests: `override_pin_lockout_test.rb`, "a four digit PIN is accepted and three digits are
refused" and "five wrong PINs typed by one cashier lock the manager out for every cashier for
15 minutes".

**Risk.** Any cashier can stop a manager approving anything by typing five wrong PINs, and a
cashier guessing five at a time can work through every four-digit PIN in about three weeks.

**Recommended.** New PINs must be 6 to 8 digits (existing shorter PINs keep working until the
manager next changes theirs; ask managers to do so). Wrong guesses count against the signed-in
cashier who typed them: five in 15 minutes, or ten in a day, stop *that cashier* asking for
overrides, and the manager's PIN keeps working for everyone else.

**Code change.** `web/app/models/user.rb#pos_override_pin=`: require `\d{6,8}` for a new PIN.
`web/app/services/compliance/sale_gate.rb#locked_out?`: count `override_refused` / `wrong_pin`
rows by `user_id` (the cashier) instead of `approver_id`, plus a 24-hour count.
`web/app/views/compliance/override_pins/edit.html.erb`: the wording. No migration. Pull
request: DRAFT_D.

---

## e. Managers can approve overrides but cannot ring a sale

**Today.** The manager role appears in the register's "approving manager" list and can approve a
blocked sale with a PIN, but opening the register sends a manager back to the home page with
"You don't have permission to use the POS preview." The role has neither `pos.use` nor
`sales.write`.
Test: `manager_register_access_test.rb`, "a manager can approve overrides but is refused the
register and cannot pair a customer screen".

**Risk.** A manager covering the counter cannot take a sale, which invites sharing a cashier's
sign-in.

**Recommended.** Let managers use the register, and refuse a manager approving their own
blocked sale so an override always involves two people.

**Code change.** `web/app/models/user.rb`: add `'pos.use'` to `ROLE_PERMISSIONS['manager']` (a
workspace that customised the manager role adds it under Settings → Permissions instead).
`web/app/services/compliance/sale_gate.rb#refusal_for`: refuse when the approver is the
signed-in seller and is not an owner. No migration.

---

## f. Any register user can run a demo sale

**Today.** Anyone who can open the register, staff accounts included, can start **Demo both
screens** and complete a practice sale. It needs no open register and no checkout setup. The
screens and the receipt say "Demo", and nothing is recorded: no order, no payment, no stock
change, nothing in the register's totals.
Test: `demo_mode_sales_test.rb`, "a staff account completes a demo cash sale that records no
order, payment or stock change".

**Risk.** A cashier can ring a real customer through demo mode and keep the cash, and the sale
appears in no report.

**Recommended.** Keep demo mode for training, but only for managers and owners. (If staff need
to practise alone, the alternative is to leave it open and list demo checkouts on the daily
exception report.)

**Code change.** `web/app/controllers/pos_displays_controller.rb#create`: refuse `demo=1`
unless `Current.user.can_approve_pos_override?`. `web/app/views/ctrax_pos/_topbar.html.erb`: hide the "Demo both
screens" entry for other accounts. No migration.

---

## g. A worker can clock in at a store they are not assigned to

**Today.** A worker's profile can list the stores they work at. Clocking in saves whichever
store came with the punch (from the page or the clock device) and does not compare it with that
list.
Test: `clock_in_unassigned_store_test.rb`, "a worker assigned to one store clocks in at a
different store".

**Risk.** Hours and labour cost land on the wrong store, and where tips are pooled by store the
worker joins a tip pool they were not scheduled into.

**Recommended.** Refuse the punch with "You are not assigned to this store. Ask a manager to
add it to your profile." Workers with no stores listed (the default) can still clock in
anywhere, as now. If covering shifts at short notice matters more, the softer option is to
allow the punch and put it on the manager's review list.

**Code change.** `web/app/services/time_clock_service.rb#clock_in`: raise `Error` when
`location_id` is present and `worker.works_at?(location_id)` is false (the web page, the app,
the API and the PIN clock all pass through it). No migration.
