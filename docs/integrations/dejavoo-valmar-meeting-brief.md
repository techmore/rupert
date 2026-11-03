# Dejavoo + Valmar meeting brief

For Rupert's developer, for the Dejavoo ISV Integration Review on 2026-11-03 (Valmar
joins as the ISO). Research details, sources and the earlier gap list are in
[dejavoo-spin.md](dejavoo-spin.md).
Keep merchant IDs, TPNs, auth keys, contact details, statements and the store's
product approvals out of this public repository.

## Where we stand (2026-11-03)

| Item | Status |
| --- | --- |
| SPIn REST public docs | Read. Public, but using them needs an authorized merchant, terminal and credentials. |
| UAT sandbox request + ISV questionnaire | Submitted. Dejavoo confirmed receipt. |
| Sandbox TPN | Added to our iPOSpays store. **Auth key not yet copied, terminal not yet in UAT mode.** |
| Access verified | **No.** No "Check gateway" or SPIn call has run against the TPN yet. |
| Successful sandbox test | **No.** Needs a UAT terminal (P1) and the auth key. |
| Rupert SPIn adapter | Built and tested against the docs, sandbox only; production host refused in code. |
| Online (card-not-present) payments through Dejavoo | **Not built. Not covered by SPIn.** See below. |

**Do not claim** in the meeting that Rupert is "integrated" or "certified". The accurate
line is: *adapter built to the public SPIn REST spec; sandbox access requested; first
live test pending.*

## The key point: in-person and online are different APIs

The store wants a **Dejavoo P1** at the counter **and** online payments. These are two
integrations, and the terminal API does not cover online checkout.

| | In person (P1 at the counter) | Online (website checkout) |
| --- | --- | --- |
| Dejavoo product | **SPIn** (REST, cloud mode) | **Hosted Payment Page (HPP)** or **Freedom to Design (FTD)** JS fields; **iPOS Transact** for token sales, voids and refunds |
| Who reads the card | The terminal | Dejavoo's page or JS fields in the shopper's browser |
| Card data on Rupert's server | Never | Never (with HPP or FTD) |
| Rupert today | Adapter built (sandbox) | Uses Authorize.net Accept.js; no Dejavoo code |
| Credentials | TPN + SPIn auth key | **Not stated in the public docs.** Same TPN or a separate e-commerce TPN? |

We will **not** use the Clear Card Encryption API: it sends raw card numbers through
our own UI and puts Rupert in full PCI scope.

**Online setup facts (FTD docs, read 2026-11-03):** FTD needs a **CloudPOS TPN**
(likely separate from the P1's TPN), an **Ecom Token** generated in iPOSpays
Settings → Merchant Keys/Ecom Token, and Rupert's domain added under Manage
Whitelisted Domain. Requests from localhost are refused. FTD only returns a
single-use `paymentTokenId` (24 h); the charge is a separate iPOS Transact call with
a `token` header. Rupert now has a sandbox-only client for that sale call
(`Pos::IposTransactGateway`). Void, refund and status endpoints are not in the public
docs, so those wait for Dejavoo.

## PCI DSS: keep Rupert's scope as small as possible

| Channel | Choice | Expected SAQ | Why |
| --- | --- | --- | --- |
| In person | P1 via SPIn | **SAQ P2PE** if the P1 is on a PCI-listed P2PE solution; otherwise **SAQ B-IP** | The card is read and encrypted on the terminal. The iPad running Rupert never sees it. |
| Online | **Hosted Payment Page (redirect)** or FTD only if its fields are Dejavoo-served iframes | **SAQ A** | The card is entered on a page Dejavoo serves. |
| Online | FTD with fields as plain inputs on Rupert's page (as in Dejavoo's sample) | **SAQ A-EP** (much larger) | Rupert's page holds the inputs, and its script reads them. Same as today's Accept.js checkout. |

What Rupert does already, and on this branch:

- Never receives, logs or stores card numbers, expiry, CVV, track or EMV data; only
  last four, brand, approval code and references.
- Production Dejavoo hosts refused in code until sign-off.
- **New:** the online payment page only allows scripts from Rupert, Authorize.net,
  Google Pay and Dejavoo, cannot be framed, and can only submit to Rupert (PCI DSS 4.0
  6.4.3 / 11.6.1, against card-skimming scripts). Before this, any https script host
  was allowed.

What the store does for in-person: nothing special. No private network is required.
The P1 encrypts the card itself and talks to Dejavoo over its own internet link. Good
hygiene still applies: password-protected WPA2/WPA3 Wi-Fi, not an open guest network,
default passwords changed, and the terminal checked for tampering. Any iPad running
Rupert works because it never handles card data.

Ask Dejavoo: **Is the P1 part of a PCI-validated P2PE solution?** That decides SAQ P2PE
(minimal) vs B-IP. **Do FTD fields render in Dejavoo iframes?** That decides SAQ A vs
A-EP; if not, we use the Hosted Payment Page. **Does our P1 have LTE or Wi-Fi only?**

## All the data comes into Rupert

Rupert is the store's book of record, so every Dejavoo transaction must land in it,
in person and online, and be matched against deposits. Three sources:

1. **Per-transaction result.** SPIn returns approval, amount, brand, last four, auth
   code, batch number. Rupert already keeps these (and nothing sensitive).
2. **FEED webhooks.** Real-time transaction and settlement events pushed to a Rupert
   endpoint, signed with HMAC or Basic auth. This is the only way to see online
   (HPP/FTD) payments and anything run on the terminal outside Rupert.
3. **Batch Report and Transaction Status Check APIs.** End-of-day pull to catch
   anything the feed missed, and to tie batches to bank deposits.

## Features Rupert needs

**Before the first sandbox test** (small; mostly done):

- Nothing new in code. Enter the TPN and auth key on Checkout setup, press "Check
  gateway", then run a sale, decline, cancel, timeout/recovery, void, return and settle.
- Confirm the auth-key format. Rupert currently expects 10 letters or digits; widen it
  if the real key differs.

**Before in-person go-live:**

1. **Register "Send to terminal" flow**: waiting screen, cancel (`AbortTransaction`),
   and a background job so a 2-minute terminal wait doesn't hold a web request.
2. **Refunds and voids through SPIn**, with the card type (credit/debit) stored.
3. **Terminal per register / per event** (one TPN per device).
4. **Tips and pricing**: one place prompts for tips; terminal surcharge/dual pricing off.
5. **Production switch** after Dejavoo and Valmar sign-off (owner approval recorded).

**Before online go-live through Dejavoo** (new work, larger):

6. **Online checkout adapter** (HPP redirect or FTD fields) replacing Accept.js for this
   processor, with the processor-approved product check before payment.
7. **iPOS Transact client** for online refunds and voids.

**Data ingestion (both channels):**

8. **FEED webhook receiver**: verify the signature, store the event, dedupe by
   transaction ID, link to the Rupert sale.
9. **Batch report import and reconciliation**: pull daily batches, match to Rupert sales
   and to the bank deposits, flag anything unmatched.

## Ask Dejavoo (ISV review)

1. **Which APIs for us.** Confirm SPIn REST cloud for the P1, and **which product for
   online**: HPP, FTD, or both? Does online need its own TPN or merchant profile?
2. **Credentials.** Where exactly is the SPIn auth key in the portal for our TPN? Do we
   send `RegisterId` or only `Tpn`? Credentials for HPP/FTD/iPOS Transact?
3. **UAT terminal.** Do we get a UAT P1 (loaner or purchase)? Steps to put it in UAT
   mode on DVStore? Can we test without hardware?
4. **Certification.** What is the ISV review/certification for SPIn and for online?
   Test script, who signs off, timing, fees. Do we need an `IsvId`?
5. **Data out.** FEED: payload schema, exact HMAC header and field order, retries,
   whether it covers both terminal and online payments. Batch Report and Transaction
   Status Check API access and credentials.
6. **P1 behaviour.** Does P1 support SPIn cloud today? Turn off its tip prompt and
   surcharge/dual pricing per TPN? Store-and-forward when offline? Batch auto-close time?
7. **Edge cases.** Is `Amount` before or after `TipAmount`? Partial approval on by default?
   What does `AbortTransaction` do mid-card? Is `ReferenceId` enough to make retries safe?
8. **Hemp/CBD.** Any Dejavoo or iPOSpays restriction on hemp/CBD merchants or MCCs?

## Ask Valmar (ISO)

1. **Underwriting.** Is the account approved for hemp/CBD **on the network and sponsor
   bank this TPN uses**, for both card-present and card-not-present? In writing.
2. **Approved product list** in a form Rupert can load (SKUs or categories), and whether
   online sales have a narrower list.
3. **Federal hemp change.** From 12 November 2026 and 11 December 2026 some products
   leave the hemp definition. Re-underwriting before 11 December? Documents needed?
4. **Integration approval.** Do you need to approve Rupert as an integrated POS and
   online checkout? Partner agreement?
5. **PCI.** Which SAQ applies to SPIn (in person) and HPP/FTD (online)?
6. **Fees and timing.** P1 cost, SPIn/gateway fees, online rates, batch time, funding.
7. **Reporting.** Will the reporting portal show Dejavoo batches? Any API for deposits?

## Rupert summary to share

> **Rupert** is the store's own point-of-sale and back-office system: register,
> customer display, inventory, online orders, timesheets and bookkeeping. It is a web
> app hosted on the business's own server.
>
> **Payments today:** cash, and Authorize.net / NMI card gateways. Card data is only
> entered in the gateway's hosted fields; Rupert never sees or stores a card number.
>
> **Compliance controls:** each processor has an approved product list, and Rupert
> blocks any item not on it before a card is charged. Products carry certificates of
> analysis, card-eligibility and THC data, with ID checks and audited manager overrides.
>
> **Dejavoo plan:** SPIn REST (cloud) for the P1 at the counter; Dejavoo's hosted page
> or JS fields for online. A unique reference per attempt, a status check before any
> retry, and every transaction and batch brought back into Rupert for reconciliation.
> The SPIn adapter is built against the public spec; we need sandbox access and a UAT
> terminal to run the first live test.

## What the store owner needs to provide

- Permission for Dejavoo/Valmar to give the developer sandbox and portal access.
- The written hemp/CBD approval and the approved product list from Valmar.
- A decision on tips (terminal or Rupert's display) and surcharging (off, or priced in).
- Whether online sales should move to Dejavoo or stay on the current gateway.
