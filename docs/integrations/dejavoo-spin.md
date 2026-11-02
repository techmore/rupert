# Dejavoo terminals (SPIn) for Rupert: research and gap analysis

Prepared 2026-11-02. Every source below was read on 2026-11-02. Dejavoo's docs are
public but incomplete in places; anything marked **unverified** must be confirmed
with Dejavoo or the processor before production. The meeting questions are in
[dejavoo-valmar-meeting-brief.md](dejavoo-valmar-meeting-brief.md).

## 1. What Dejavoo offers

### Integration options

| Option | What it is | Fit for Rupert |
| --- | --- | --- |
| **SPIn REST (cloud)** | Semi-integrated. Rupert's server posts JSON to Dejavoo's SPIn cloud, which drives the terminal. The terminal reads the card and returns only the result. [S1][S2] | **Best fit.** Server-to-server, works with Rupert's web register on any device, keeps card data out of Rupert. Started on this branch. |
| SPIn SOAP/XML | Older XML/GET interface to the same terminals (`cgi.html`). [S3] | No. REST covers the same functions. |
| SPIn USB, "USB as fallback" | Direct USB link from the POS device to the terminal; fallback when the cloud is down. [S4] | Poor fit: Rupert runs in a browser. Possibly useful at events if cloud is down (unverified). |
| SPIn local (LAN) | Mentioned only in a docs note ("direct to the terminal, needs the terminal IP"); no section describes it. [S4] | **Unverified.** Ask. |
| "SPIn Proxy" | In the docs this is the portal's connection-troubleshooting tool (POS ↔ terminal), not a separate API. [S2] | Use when testing. |
| iPOSpays Hosted Payment Page, Freedom to Design.js, iPOS Transact | Online card-not-present checkout and token charges. [S5] | Online store only. Out of scope here. |
| Terminal app / deep linking (DvPayLite, DVStore) | Rupert would run as an Android app on the terminal. [S6] | Not now. Large effort and an app-store listing. |
| Batch Report API, Transaction Status Check API, FEED webhooks (HMAC) | iPOSpays reporting and event push. [S5] | Later, for settlement reconciliation. |

### Terminals

- Dejavoo's UAT guide names the **Android P line (P1, P3, P5, P8, P12, P17, P18)** and **Android QD line (QD1–QD5)** with DvPayLite and DVStore. [S6]
- The **Z line (Z8, Z9, Z11)** runs Linux ("Aura" software). A 2021 Dejavoo brochure calls Z8/Z11 good for SPIn, but no current iPOSpays page lists them. Z8 is reported discontinued. [S7][S8] **Ask which model Valmar ships and whether it is iPOSpays-powered.**
- No per-model SPIn support matrix is published. SPIn's prerequisite is an "iPOSpays-powered Dejavoo terminal". [S2]

### Credentials a developer needs

- An **iPOSpays sandbox (UAT) merchant** and a valid **TPN** (terminal profile number). No TPN: ask the ISO or Dejavoo developer support. [S2]
- In the iPOSpays portal: S.T.E.A.M → Edit Parameters → the TPN → Integrations → Type = SPIn, SPIn Mode = Cloud, then copy the **Register ID** and **Auth Key**. [S2]
- REST requests carry `Tpn` and `Authkey` in the JSON body. There is no auth header. REST marks `RegisterId` obsolete ("required if no Tpn"). [S1]
- A UAT terminal is switched to the test host through DVStore (Host Setup → UAT). [S6]
- Hosts: SPIn REST production `https://api.spinpos.net`, sandbox `https://test.spinpos.net/spin`. [S1] The method pages hide the base URL, so **confirm the sandbox host**.

### Certification

**Not documented anywhere public.** No ISV certification, approval or review process for SPIn appears in Dejavoo's docs. SPIn lists supported processors: TSYS, Fiserv North, Fiserv Omaha, Worldpay, EPX, Elavon, RS2 (P line only). [S4] Who holds EMV certification (normally the terminal application in a semi-integrated setup) is also not stated. **Ask Dejavoo and Valmar.**

### PCI scope

Dejavoo states that card data (PAN, expiry) "never touches the Host System" with SPIn. [S2][S4] That is the main benefit: Rupert receives a result, not a card. It is a vendor claim. The merchant still completes a PCI self-assessment; **ask Valmar which SAQ applies**. Rupert never calls SPIn `GetCard` (it returns track and account data) and never stores receipts, tokens, BIN, name, expiry or EMV data.

### Transactions and features (SPIn REST) [S1]

| Need | SPIn | Notes |
| --- | --- | --- |
| Sale | `POST /v2/Payment/Sale` | `Amount`, optional `TipAmount`, `PaymentType`, `ReferenceId` (unique within a batch). |
| Status after a timeout | `POST /v2/Payment/Status` | The documented recovery: "If the transaction timeout, please use the Transaction Status Request". [S3] |
| Void | `POST /v2/Payment/Void` | Before settlement only. Needs the original `ReferenceId` and amount. Debit void is not listed in the XML matrix. [S3] |
| Refund | `POST /v2/Payment/Return` | Independent of the sale, with a new `ReferenceId`. The card is presented again. |
| Tip | `TipAmount` on Sale; `POST /v2/Payment/TipAdjust` | Terminal tip prompt behavior not documented. |
| Auth / capture | `/v2/Payment/Auth`, `/Capture` | Not needed for retail. |
| Partial approval | Status code `0001` | No request flag and no approved-amount field documented. Rupert voids partials. |
| EBT, gift | `PaymentType` `EBT_Food`, `EBT_Cash`, `Gift`; `/v2/Payment/Balance` | Not needed for this store. |
| Cancel a waiting sale | `POST /v2/Payment/AbortTransaction` | Semantics not documented. |
| Batch close | `POST /v2/Payment/Settle` (`Close`, `Clear`, `Force`) | Returns batch totals. Auto-close vs manual is not documented. |
| Reports | `/v2/Report/Summary`, `/v2/Report/Daily`, `/v2/Payment/StatusList` | For end-of-day checks. |
| Offline / store-and-forward | `/v2/Payment/OfflineStatus`; code `1021 Pending SnF Transactions` | Behavior not documented. |
| Receipts | `PrintReceipt`, `GetReceipt`, `/v2/Common/Printer` | Terminal can print; Rupert prints its own receipt. |
| Cart on terminal screen | `/v2/Payment/Cart` | Optional. |
| Callbacks | `CallbackInfo.Url` on payment requests | Payload, retries and signing not documented. |
| Timeouts | `SPInProxyTimeout` 1–720 | Default 120 s for transactions, 420 s for settlement. [S9] |

Status codes Rupert relies on [S1][S9]: `0000` approved, `0001` partial approval, `1012` canceled, `1015` declined, `1011` duplicate reference, `1000`/`2008` terminal busy, `2001` terminal not connected, `1009`/`2002` authentication failed, `2007` timed out, `2009` transaction not found, `2010` communication error ("send request one more time"). Responses carry `GeneralResponse.ResultCode`, `StatusCode`, `Message`, `DetailedMessage` and `DelayBeforeNextRequest`.

### High-risk and hemp/CBD

Dejavoo's docs say nothing about merchant categories, high-risk merchants or hemp/CBD. Acceptance is the acquirer's decision, through the ISO. One reseller notice (2022, third-party, possibly outdated) says TSYS does not process hemp/CBD under its sponsor-bank rules. [S10] Rupert's existing [NAB/IRIS reporting notes](../ops/iris-reporting.md) show the store's current merchant portal includes Dejavoo quick-reference PDFs and a TSYS funding document. **So the key question is which front end and sponsor bank the Dejavoo TPN will be boarded on, and whether hemp/CBD is approved there in writing.**

### Valmar

Valmar publishes no integration-partner requirements. Public listings describe card, ACH, push-to-card, eCheck and Check 21 services. [S11] Rupert already records Valmar as the store's processor, on Authorize.net or NMI gateway arrangements. What an ISO usually expects from an integrated POS (not Valmar-documented): a partner or ISV registration, an integration their front end supports (here, Dejavoo's certified terminal app), correct MCC and descriptors, the merchant's underwriting file (including product list and COAs for hemp), and the merchant's PCI self-assessment.

## 2. Gap analysis

### What Rupert has (F69 #611, F70 #612)

- Processor abstraction: `PosSetting.gateway_provider` with encrypted credentials, `Pos::Gateway` (Authorize.net), `Pos::NmiGateway`, per-provider payment services, and a store-level fingerprint so a changed account stops in-flight payments.
- Safe payment flow: a durable attempt before any request, no database lock across the network, `unknown` on a lost response, read-only recovery, and a background sweep (`PosPaymentReconciliationJob`).
- Processor-approved product lists per processor, checked at ring-up and again just before the charge. F70's compliance check (COA, ID, override, audit) runs at ring-up and at events.
- Refunds and voids (`Pos::CardReversal`), webhooks and settlement reconciliation for Authorize.net and NMI.
- `card_a920`: a sale run on a standalone terminal and recorded by the cashier. Event mode records "Card (terminal)" the same way and asks for the terminal batch total at close.

### Added on this branch (sandbox only)

- `Pos::DejavooSpinGateway`: SPIn REST client (Sale, Status, Void, Return, TipAdjust, Abort, Settle, setup check). Production host refused. Only whitelisted result fields are kept.
- `Pos::DejavooTerminalPayment`: runs a register checkout on the terminal with the same safety rules. It also handles partial approval (voided at once), surcharges or terminal-added tips (held for review), "not found" (proves nothing until 5 minutes have passed) and debit status lookups.
- `dejavoo_spin` provider on the checkout setup page (TPN and auth key, sandbox only, "Check gateway" runs no card) and its own processor-approved list.
- Clear refusals where Dejavoo is not wired yet (browser card form, refunds, settlement check).

### Still missing

| # | Gap | Effort |
| --- | --- | --- |
| 1 | **Register UI**: "Send to terminal" button, waiting screen, cancel (`AbortTransaction`) and a background job so a 2-minute terminal wait does not hold a web request. Customer display shows "Follow the terminal". | M |
| 2 | **Terminal per register**: today one setting (one TPN) per store. Map each register, and each event, to its own TPN. | M |
| 3 | **Refunds and voids through SPIn**: void before settlement, return after. Store the card's payment type (credit/debit) on the attempt. | M |
| 4 | **Batch close and settlement check**: settle (or confirm auto-close), read Summary/Batch Report, match against Rupert sales and the NAB/IRIS deposits. | M |
| 5 | **Tips and pricing**: decide whether the terminal or Rupert's display asks for the tip, and turn off terminal surcharge/dual pricing (or model it). Today a mismatch is held for review. | S |
| 6 | **Receipts**: whether EMV receipt fields (application label, AID) must appear on Rupert's receipt, or the terminal prints the card receipt. | S |
| 7 | **Callbacks/FEED**: use them once the payload and signing are documented. Status polling works without them. | S–M |
| 8 | **Production**: owner sign-off (reuse NMI's sign-off fields), Dejavoo/Valmar approval, production host. | S after approval |
| 9 | **Live sandbox run** against a real UAT terminal: approve, decline, cancel, timeout and recovery, partial, void, return, settle. | S once a TPN exists |

### Event sales (F70 show mode) on a terminal

F70's event register is built for weak connectivity: it queues sales offline and records "Card (terminal)" as a tender the staff ran on the event's own terminal. Rupert never charges a card there.

- **Now, no code:** keep that flow with the Dejavoo terminal running standalone. At close, staff type in the terminal's batch total.
- **Next (S):** once the event has its own TPN (gap 2), fill the close-out batch total from SPIn `Summary`/`Settle`, and flag differences.
- **Then (M–L):** when the event device is online, send card sales to the terminal through SPIn before recording them. Tie the event `client_sale_id` to the SPIn `ReferenceId`, so a replay never charges twice. Offline, fall back to the standalone flow. Cloud SPIn needs both the event device and the terminal online; ask whether the terminal can store and forward.

The processor-approved list and F70's event list are checked before any card sale. The only items a terminal sale can include are ones the processor approved.

## Sources (read 2026-11-02)

- [S1] Dejavoo SPIn REST API methods: <https://app.theneo.io/dejavoo/spin> (method pages `…/spin-rest-api-methods/sale`, `status`, `void`, `return`, `settle`, `tip-adjust`, `abort-transaction`)
- [S2] SPIn specification (onboarding, prerequisites, SPIn Proxy): <https://app.theneo.io/dejavoo/spin-specification/spin-specification-api>
- [S3] SPIn transaction and status requests (XML): <https://app.theneo.io/dejavoo/spin-specification/server-register-pos-to-terminal-request-format/transaction-request>, <https://app.theneo.io/dejavoo/spin-specification/server-register-pos-to-terminal-request-format/transaction-status-request>
- [S4] iPOSpays SPIn overview: <https://docs.ipospays.com/spin-specification>
- [S5] iPOSpays developer central index: <https://app.theneo.io/dejavoo/developer-central/llms.txt>
- [S6] Payment terminal integrations and UAT mode: <https://docs.ipospays.com/payment-terminals-integrations>, <https://docs.ipospays.com/how-to-change-your-payment-terminal-to-uat-mode>
- [S7] Dejavoo countertop brochure (2021): <https://cdn.shopify.com/s/files/1/0593/8426/6940/files/dejavoo-countertop-terminals_NB_jun-2021_LR.pdf>
- [S8] Z-line notes (reseller): <https://support.xplorpay.com/knowledge-base/dejavoo-z-line/>, <https://www.discountcreditcardsupply.com/collections/dejavoo-countertop-terminals>
- [S9] SPIn error codes and messages: <https://app.theneo.io/dejavoo/spin/error-codes-and-messages>
- [S10] Third-party TSYS hemp/CBD notice (2022): <https://support.arryved.com/portal/en/kb/articles/merchant-cbd-hemp-compliance-9-5-2022>
- [S11] Valmar directory listing: <https://slashdot.org/software/p/Valmar-Merchant-Services/>
