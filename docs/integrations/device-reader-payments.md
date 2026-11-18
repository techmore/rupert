# Phone card reader payments: server side

Prepared 2026-11-18. This describes what is in the repository: the server half of a card payment that
the iPhone app starts, built and tested against a **fake** payment provider. No real provider, SDK,
credential or device is involved, and nothing here can run in production (see
[Off by default](#off-by-default)).

The design is vendor-neutral. The provider is called `device_reader` in code. One future implementation
is Dejavoo's phone SDK, described in [dejavoo-tap-to-pay-iphone.md](dejavoo-tap-to-pay-iphone.md); its
compliance items are in [the checklist](../compliance/dejavoo-tap-to-pay-compliance.md).

Keep merchant identifiers, device identifiers and provider documentation out of this public repository.

## The idea

The phone talks to the card reader. Rupert's server is the system of record.

- The **server** fixes the amount, currency, workspace, store and reference before a reader runs.
- The **page** (the register in the app's web view) passes the app one thing: the attempt token.
- The **app** asks the server what to charge, runs the reader, and reports what the reader said.
- The report is a **hint**. The sale is marked paid only when the server looks the payment up with the
  provider and finds an approval for its own reference and exact amount.
- A card number never reaches Rupert. The API takes a short list of result fields and refuses the rest.

It reuses the counter-terminal rules in `Pos::DejavooTerminalPayment`: a durable attempt before any
charge, never a second sale while one is unresolved, an unclear answer becomes "unknown" and is settled
by lookup only, a different amount is held for review, and a partial approval is voided at once.

## Where it lives

| Part | File |
| --- | --- |
| Gateway interface, result fields, on/off rules | `web/app/services/pos/device_reader.rb` |
| Fake provider (tests and development) | `web/app/services/pos/device_reader/fake_gateway.rb` |
| Approved-products guard | `web/app/services/pos/device_reader/approved_list_guard.rb` |
| Open, start, report, cancel, confirm | `web/app/services/pos/device_reader_payment.rb` |
| API for the page and the app | `web/app/controllers/native/reader_attempts_controller.rb` |
| Lookup right after a report | `web/app/jobs/pos_device_reader_confirm_job.rb` |
| Lookup for lost reports (existing sweep) | `web/app/jobs/pos_payment_reconciliation_job.rb` |
| Void and refund (existing service) | `web/app/services/pos/card_reversal.rb` |
| Columns on `pos_payment_attempts` | `web/db/migrate/20261118143000_add_device_reader_to_pos_payment_attempts.rb` |

## Flow

1. The cashier rings up the sale. The checkout is created as today, with tender `card` and the store's
   provider `device_reader`.
2. **Open.** The page posts to `/native/pos_checkouts/:id/reader_attempt`. The server saves a
   `pos_payment_attempts` row (provider `device_reader`, a new reference `RR…`, status `submitting`),
   marks the checkout `processing`, and returns the attempt token. Asking again returns the same
   attempt, so a double tap is harmless. A partial unique index allows one unresolved phone attempt per
   checkout.
3. **Start.** The page sends the token to the app over the bridge. The app posts the token and its
   install identifier to `/native/reader_attempts/start`. The first install to ask owns the attempt.
   The server answers with the reference, amount, currency and an expiry time. The app must not open
   the reader after the expiry (three minutes from open).
4. The customer presents the card to the phone. Card data stays inside the provider's SDK.
5. **Result.** The app posts what the reader said to `/native/reader_attempts/result`. The server
   records it, moves the attempt and checkout to `unknown` (reported, awaiting confirmation), and
   enqueues a lookup.
6. **Confirm.** `PosDeviceReaderConfirmJob` (or the two-minute sweep, if the report never arrived) asks
   the provider about the reference. Only then is the checkout paid or declined.
7. **Status.** The page polls `GET /native/pos_checkouts/:id/reader_attempt` and shows the outcome.

## State transitions

The attempt and checkout use the statuses that already exist. Nothing new was added.

| Event | Attempt | Checkout |
| --- | --- | --- |
| Open | (new) `submitting` | `ready` or `declined` → `processing` |
| Start (app claims it) | `submitting` | `processing` |
| Result or cancel reported | `submitting` → `unknown` | `processing` → `unknown` |
| Lookup: approved, our reference, exact amount, no fee | → `paid` | → `paid` |
| Lookup: declined or cancelled | → `declined` | → `declined` |
| Lookup: no record, and the phone reported declined or cancelled | → `declined` | → `declined` |
| Lookup: no record, nothing reported, under five minutes old | stays `submitting` | stays `processing` |
| Lookup: no record, phone said approved or failed, under five minutes old | stays `unknown` | stays `unknown` |
| Lookup: no record, five minutes or more after open | → `declined` | → `declined` |
| Lookup: approved for another amount, with a fee, or under another reference | → `unknown`, held for review | → `unknown` |
| Lookup: partial approval, void succeeds | → `declined` | → `declined` |
| Lookup: partial approval, void fails | → `unknown`, held for review | → `unknown` |
| Lookup: provider does not answer | stays as it was | stays as it was |
| Late approval for a closed attempt, checkout still unpaid and idle | `declined` → `paid` | `declined` → `paid` |
| Late approval, checkout already paid, cancelled or busy with a newer attempt | stays `declined`, marked for review | unchanged |

A `declined` checkout can start a fresh attempt, with a new reference and token. A checkout held for
review cannot: a manager must look first, exactly as with the counter terminal.

## API

All five routes need a signed-in session, are scoped to the workspace by `TenantScoped`, need
`can_use_pos?`, and limit a cashier to their own checkouts (administrators see all), as the register
does. Responses are JSON with `Cache-Control: no-store`. When the feature is off they answer 404.

| Route | Called by | Body | Answer |
| --- | --- | --- | --- |
| `POST /native/pos_checkouts/:checkout_id/reader_attempt` | page | none | attempt state, with `token` while no result was reported |
| `GET /native/pos_checkouts/:checkout_id/reader_attempt` | page | none | attempt state |
| `POST /native/reader_attempts/start` | app | `{token, device_id}` | `{reference, amount_cents, tip_cents, currency, expires_at, reader}` |
| `POST /native/reader_attempts/result` | app | `{token, device_id, result}` | `{status, reported}` |
| `POST /native/reader_attempts/cancel` | app, or page before start | `{token, device_id}` | `{status, reported}` |

Errors: 404 for an unknown token, another workspace or another cashier's checkout; 403 for a missing
POS permission or the wrong device; 422 with `{error}` for anything else.

### Attempt state

```json
{
  "status": "submitting",
  "reported": false,
  "reference": "RR0123456789abcdef01234567",
  "amount_cents": 1166,
  "currency": "USD",
  "expires_at": "2026-11-18T15:03:00Z",
  "needs_review": false,
  "message": null,
  "checkout": { "id": 1, "status": "processing", "total_cents": 1166 },
  "token": "64 lowercase hex characters"
}
```

`status` is the attempt's status: `submitting`, `unknown`, `paid` or `declined`. `checkout` is the
receipt the register already uses; its `card` block appears only after the provider confirmed the
payment. `message` is cashier-ready wording for a decline or a hold.

### Result

```json
{
  "token": "64 lowercase hex characters",
  "device_id": "the app install identifier, 16 to 64 letters, digits or dashes",
  "result": {
    "status": "approved",
    "provider_reference": "up to 40 letters, digits or dashes",
    "amount_cents": 1166,
    "card_brand": "Visa",
    "last_four": "1111",
    "entry_method": "contactless",
    "auth_code": "A1B2C3"
  }
}
```

- `status` is `approved`, `declined`, `cancelled` or `failed`. Only `status` is required, plus
  `amount_cents` for an approval.
- `amount_cents` must equal the checkout total. A different amount is refused and not recorded, and
  the server looks the payment up at once.
- `card_brand` is Visa, Mastercard, Amex, Discover or JCB. `entry_method` is contactless, chip, swipe
  or manual.
- **Any other field is refused**, in `result` or beside it. So is any request, on any of the five
  routes, that contains something shaped like a card number, track data or a security code
  (`CardData`). Nothing from a refused request is saved. The refusal is written to the activity log
  without the values.
- The report is kept in `device_report_json` as an unverified hint. The brand, last four and approval
  code on the receipt come from the provider lookup, never from the report.
- The same report sent twice changes nothing. A later, different report is ignored.

### What is stored about the phone and the token

- The token is derived from the reference with a server key and is never stored. Only its SHA-256
  digest is kept, in the existing `nonce_digest` column, so a copy of the database cannot report a
  result.
- The install identifier is stored as a digest (`device_digest`).

## Bridge contract for the iPhone app

The app registers one script message handler, `rupertReader`, beside `rupertScanner` and `rupertBanner`.

**Rule: the page passes only the attempt token.** It never passes an amount, a reference or a checkout
id. The app learns what to charge from the server, so a page that was tampered with cannot change it.

**start** (page to app):

```js
window.webkit.messageHandlers.rupertReader.postMessage({ type: "start", token: "<attempt token>" })
```

The app then calls `POST /native/reader_attempts/start` with its own HTTP client and session cookie,
checks `expires_at`, and opens the provider's reader for exactly `amount_cents` in `currency` under
`reference`, with tips and fees switched off in the reader.

**result** (app to page), a DOM event on `window`:

```js
window.dispatchEvent(new CustomEvent("rupert:reader-result", {
  detail: { token: "<attempt token>", state: "reported" }
}))
```

`state` is `reported` (the server accepted the report or the cancel), `unreported` (the app could not
reach the server; the sweep will resolve it) or `unavailable` (this phone cannot run the reader; the
app called cancel). The event carries no payment facts. The page does not trust it; it only starts
polling.

**status** (page to server): `GET /native/pos_checkouts/:checkout_id/reader_attempt`, every second or
two while `status` is `submitting` or `unknown`, then stop. The page shows paid only when `status` is
`paid`.

**cancel** (page to app): `{ type: "cancel", token }`. The app closes the reader and calls
`POST /native/reader_attempts/cancel`. If the reader had already finished, the app reports the result
instead.

The app must: keep the install identifier stable across launches; report every reader outcome,
including after a relaunch if it can; never open the reader twice for one token; never start a reader
after `expires_at`; and never send anything from the provider's result beyond the fields above.

## Failure cases

| What goes wrong | What happens | Double charge? Lost sale? |
| --- | --- | --- |
| Cashier taps twice | The second open returns the same attempt and token. | Neither. |
| Two phones try the same attempt | The first to call start owns it; the other gets 403. | Neither. |
| App is killed or loses network after the card was approved | No report arrives. The sweep looks the reference up and marks the sale paid. | Neither. |
| App is killed before the card was presented | The attempt stays `submitting`. No new attempt can start. After five minutes with no record at the provider, the sweep declines it and the cashier can start again. Cancel resolves it sooner. | Neither. |
| Customer cancels or the card is declined | Reported, confirmed by lookup, declined at once. A fresh attempt is allowed. | Neither. |
| Reader times out with no answer | Same as the app being killed before a card. | Neither. |
| Report says approved but the provider has no record | Stays `unknown`. Never paid on the phone's word. Declined after five minutes with no record. | Neither. |
| Approved for a different amount, or with a fee or tip added | The report is refused; the lookup holds the attempt for review and blocks a new charge. | A manager decides. |
| Partial approval | Voided at once and declined. If the void fails it is held for review. | Neither, unless the void fails: then a manager voids it. |
| Report sent twice | The first is recorded; repeats change nothing and start no lookup. | Neither. |
| Report arrives after the attempt was given up | Recorded for the audit trail and looked up once. A confirmed approval pays the checkout if it is still unpaid and idle. If the checkout was already paid another way, cancelled, or has a newer attempt open, the charge is marked for review and logged. | No double sale is recorded. The customer may have been charged twice by then: a manager must void or refund the late charge. |
| Provider does not answer the lookup | Nothing changes; the next sweep asks again. No sale is retried. | Neither. |
| Two workers confirm at once | The claim on `reconciliation_checked_at` lets one look up. If both did, the checkout lock and the attempt's status let one finalize. | Neither. |
| Wrong token, device, workspace or permission | Refused; nothing recorded. | Neither. |
| Card number or track data in a request | Refused; nothing saved; values never logged. | Neither. |

The one case that needs a person is a late approval for a checkout that has moved on. It can only
happen if a reader finishes after the server gave up, which the expiry time is there to prevent: the
server waits five minutes and the app must stop at three.

## Voids and refunds

`Pos::CardReversal` handles them with the same permission (`sales.write`), reason and amount rules as
every other card payment. The whole sale is voided while the provider allows it. A partial amount, or
a sale the provider says can no longer be voided, is refunded under the reversal's own reference. A
lost answer stays `unknown` and is settled by a read-only recheck. In this change both go to the fake
provider.

## Audit log

| Action | When |
| --- | --- |
| `pos_device_reader_attempt_opened` | A new attempt was saved (not on a repeat) |
| `pos_device_reader_result_reported` | A report was recorded, with its status and whether it was late |
| `pos_device_reader_cancel_requested` | A cancel was recorded |
| `pos_device_reader_card_data_refused` | A request carried card data and was refused |
| `pos_checkout_paid`, `pos_sandbox_checkout_completed` | Existing: the sale was finalized |
| `pos_payment_needs_review` | Existing: a lookup could not settle the attempt, or held it |
| `pos_card_void`, `pos_card_refund`, `pos_card_reversal_needs_review` | Existing: reversals |

## Store setup

The store's `PosSetting` takes `gateway_provider: device_reader` with two encrypted values in
`credentials_json`: `merchant_id` and `reader_profile_id`. These are placeholders for the provider's
merchant-side identifiers. Production needs the same recorded owner sign-off as NMI and Dejavoo, and
new identifiers clear it. The provider and its fields appear in checkout setup only while the
workspace flag is on.

## Off by default

Three things must all be true before any of this can be used:

1. **A provider exists for the environment.** The only one is the fake, which refuses to exist in
   production. `Pos::DeviceReader.gateway_class` is `nil` there, so the feature is off in production
   whatever the settings say.
2. **The deployment switch is on.** `RUPERT_DEVICE_READER_ENABLED`, read once at boot. It defaults to
   off in production and on elsewhere. While off, the five routes do not exist.
3. **The workspace flag is on.** `FeatureFlag` `device_reader`, stored as a setting, absent by default.
   No screen sets it.

While off: the routes answer 404, a `PosSetting` with this provider is invalid, checkout setup does not
offer it, a checkout cannot be prepared for it, and a new attempt cannot be opened. Existing payment
paths are untouched: the only shared code that changed is the sweep's claim, which moved into
`PosPaymentAttempt.claim_reconciliation` with the same query.

Turning the workspace flag off later stops new payments. Lookups, voids and refunds of payments
already taken keep working, so nothing is stranded.

## Approved products

The phone card reader has no processor-approved product list. The `processor_catalogs` table has a
check constraint naming the processors it accepts, and changing it rebuilds the table, which this
change avoids. Until that migration is done, `Pos::DeviceReader::ApprovedListGuard` fails closed: a
workspace that enforces an approved list for any card processor cannot charge on the phone card reader
at all. That includes the hemp/CBD store this is meant for.

## What remains for a real provider

1. A gateway class beside the fake: `lookup`, `void`, `refund`, `verify!` and `reader_params` against
   the provider's API, keeping only the fields in `Pos::DeviceReader::Result`. Register it in
   `gateway_class`.
2. The real names and formats of the merchant-side identifiers, and whether the phone needs any of
   them from `reader_params`.
3. The migration that lets `processor_catalogs` hold a list for this processor, then remove the guard.
4. The iPhone app: the `rupertReader` handler, the provider's SDK, the install identifier, and the
   release items in the compliance checklist.
5. The register page: a button that opens the attempt, posts the token to the bridge and polls status.
6. The confirmed entry method on the receipt. The lookup result carries it, but
   `pos_payment_attempts` has no column for it in this change (another change adds one).
7. Review of the timings against the provider's real reader timeout and how quickly a finished
   payment appears in its lookup: `READER_WINDOW` (three minutes) and `NOT_FOUND_AFTER` (five).
8. Whether refunds need the customer's card on the phone. If so, a refund becomes a second
   phone-started attempt, as it is a terminal job for the counter terminal.
9. Settlement comparison and provider webhooks for this provider. Neither exists; the existing
   screens refuse a store set to it.

## Open question: can the sale carry our reference?

Everything above assumes the provider lets the phone attach Rupert's reference (`RR…`) to the sale and
lets the server look a payment up by it. That is what makes the lookup exact.

If the phone SDK cannot carry an integrator reference, the server would have to find the payment by
**amount, terminal profile and time window**, and then pin the provider's own id (the reported
`provider_reference`) to the attempt. That fallback is **not implemented**, and it is weaker:

- Two sales for the same amount on the same profile within the window cannot be told apart. One
  customer's approval could mark another's checkout paid.
- A phone could report another payment's provider id. The amount would match, and nothing else ties
  it to this checkout.
- A missing match proves less. "No payment for this amount yet" is not "this attempt was not charged".

If it comes to that, the least bad design is: one open attempt per terminal profile at a time (not per
checkout), a short window that starts at `start`, the provider id accepted only once across all
attempts (a unique index), and anything ambiguous held for review. Ask the provider first: a reference
field on the sale, or a lookup by the SDK's own transaction id returned to the app, removes the
problem.

## Decisions for the owner

1. One provider per store. A store is either a counter-terminal store or a phone-reader store today.
   Running both at one store needs a second provider slot.
2. Cancel and decline are closed at once when the phone and the provider agree nothing was charged.
   The alternative is to wait out the five minutes every time, which is safer against a faulty phone
   and slower for the cashier.
3. A late approval on a checkout that has moved on is flagged for a manager. It could instead be
   voided automatically.
4. Staff accounts (`pos.use`) may take a phone payment. Refunds still need `sales.write`.
