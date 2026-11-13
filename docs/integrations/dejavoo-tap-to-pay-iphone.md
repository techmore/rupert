# Tap to Pay on iPhone with Dejavoo (iPOSgo!)

Prepared 2026-11-13 from Dejavoo's public developer docs (read that day). Owner decision recorded the
same day. Related: [dejavoo-spin.md](dejavoo-spin.md) (counter terminals) and
[dejavoo-valmar-meeting-brief.md](dejavoo-valmar-meeting-brief.md).

Keep TPNs, merchant codes, auth keys, device UDIDs, contact details and the store's product approvals
out of this public repository.

## Decision

Build card acceptance into the **existing Rupert iPhone app** as a **Take payment** button on the
register, not a separate "Rupert: POS" app. The register already runs inside the app, and a second app
would need its own App Store review. A POS-only app for store-owned phones can come later.

## How it works

Dejavoo's iPhone option is "deep linking": Rupert's app does not read the card itself. It hands the
amount to Dejavoo's own payment app, **iPOSgo!**, which takes the tap and hands the result back.

1. The cashier rings up the sale in Rupert and taps **Take payment**.
2. Rupert's server records a payment attempt and the amount **before** anything is charged.
3. The Rupert app calls Dejavoo's Swift library (`import DeepLinking`, `Wrapper().startTransaction`),
   which opens iPOSgo!.
4. The customer taps a contactless card or phone wallet on the iPhone. iPOSgo! can show its own tip,
   amount breakdown and approval screens, each switchable.
5. iPOSgo! returns to Rupert with the result (approval code, last four digits, RRN, batch number,
   amounts).
6. Rupert's server **confirms the payment with Dejavoo** before marking the sale paid, then prints or
   sends the receipt.

The store's phone needs both apps installed: Rupert and iPOSgo!.

## Videos (Dejavoo's own, about 30–40 seconds each)

- [A payment from start to finish](https://s3.us-east-1.amazonaws.com/assets.ipospays.com/Deeplinking+V2_1.mp4)
- [Adding Dejavoo's library to an iPhone app](https://media.publit.io/file/iOSDeepLinkingConfigureSDK/iOS-Deep-Linking-Configure-SDK.mp4)
- [Connecting the phone to the merchant account (TPN register)](https://s3.us-east-1.amazonaws.com/assets.ipospays.com/V2+Registration+Video.mp4)

## What it supports

Sale, refund (standalone, after settlement), void (before settlement, by RRN), pre-authorization and
ticket (capture by RRN), and batch settlement. Optional tip and fee amounts. Contactless only: no chip
insert or swipe on the iPhone.

## Requirements

- iPhone XS or later, iOS newer than 16.9, device region set to **US**.
- A merchant onboarded on iPOSpays (sandbox for testing, production for live) with a **Tap on Phone
  (TOP) TPN**, and the **merchant code** from the portal: Settings → Generate ECOM/TOP Merchant Keys →
  pick the TOP TPN.
- Accept Apple's Tap to Pay terms on the device (in iPOSgo!).
- Dejavoo supplies the library and a demo app through a Diawi install link after receiving the test
  device's UDID. Use a separate test device and don't change its date or time during testing.
- URL scheme keys `invokeApplink` and `ogApplink` (case sensitive) in the app's configuration.
- Processors listed for iPhone Tap to Pay: TSYS, Fiserv Omaha, Fiserv North. **Confirm with Valmar in
  writing** that a Tap to Pay account on one of these is approved for the store's hemp/CBD products.

## Security: who handles what

**Apple and Dejavoo:** reading the card, encryption, and keeping card numbers out of Rupert. Rupert
receives only the result fields; it never sees a card number. The store still completes its yearly PCI
self-assessment (Valmar says which form).

**Rupert:**

- **Never trust the returned "approved" by itself.** The result comes back through a URL scheme that
  any app could open with a fake approval. The server marks a sale paid only after confirming the
  transaction with Dejavoo (transaction status lookup or a matching FEED event, which Rupert already
  receives).
- **Amount:** the server sets the amount; the returned amount must match.
- **No double charges:** a durable attempt before the tap; a lost or unclear result is looked up,
  never retried as a new charge. Reuse the rules in `Pos::DejavooTerminalPayment`.
- **Permissions and audit:** who may take payments and refunds, and a log of every attempt.
- **Keep only whitelisted fields** (as the SPIn adapter does). Do not store `AcntFirst4`, tokens or
  anything beyond what reconciliation needs.
- The merchant code and TPN live in encrypted per-workspace settings, never in the app binary.
- Per-workspace switch, off by default.

## Plan and timing

| Step | Needs | Rough time |
| --- | --- | --- |
| Tap with Dejavoo's demo app on the owner's iPhone | Library and demo app from Dejavoo | Same day it arrives |
| Test tap from Rupert's register (sandbox) | Library in hand, TOP TPN and merchant code | 1–2 days |
| Full version: refunds, voids, batch close, server confirmation, settings, tests | — | About a week more |
| Live payments at the store | Production TOP TPN boarded by Valmar with hemp/CBD approval; App Store update review | Valmar's timeline; review about 1–2 days |

Sandbox payments move no money.

## Status (2026-11-13)

- iPOSpays sandbox merchant account is set up (from the ISV sandbox request, 2026-11-03).
- No written confirmation yet of approval for the iOS deep linking SDK; ask Dejavoo's ISV team to
  confirm and send the library and demo app.
- Separately, a P18 Android terminal is being ordered in developer mode for terminal deep linking
  (the Android counter-terminal path). It is not needed for iPhone Tap to Pay.
- Rupert has no payment code in the iPhone app yet.

## Open questions for Dejavoo and Valmar

1. Written confirmation that Rupert is approved for iPhone Tap to Pay deep linking (V2).
2. Does the sandbox account need a separate Tap on Phone TPN? Is one issued per phone?
3. Does Rupert's app need Apple's Tap to Pay entitlement, or only iPOSgo!? (Docs suggest only iPOSgo!.)
4. Which processor will the production TOP TPN use, and is hemp/CBD approved there in writing?
5. Is PIN debit supported on tap, and what happens above the contactless limit?
6. Can iPOSgo! return to Rupert automatically after approval (no extra taps for the cashier)?

## Sources

- [iOS deep linking v2](https://app.theneo.io/dejavoo/tap-to-pay-on-iphone/deep-linking/v2) and its
  [TPN register](https://app.theneo.io/dejavoo/tap-to-pay-on-iphone/deep-linking/v2/tpn-register),
  [perform transactions](https://app.theneo.io/dejavoo/tap-to-pay-on-iphone/deep-linking/v2/tpn-register/perform-transactions)
  and [sample responses](https://app.theneo.io/dejavoo/tap-to-pay-on-iphone/deep-linking/v2/tpn-register/sample-responses) pages
- [Tap to Pay on iPhone overview](https://app.theneo.io/dejavoo/tap-to-pay-on-iphone/deep-linking)
- [iPOSpays Developer Central](https://docs.ipospays.com/)
- [Dejavoo ISV presentation](https://dejavoo.io/wp-content/uploads/2025/08/Dejavoo_Presentation_for_ISVs.pdf)
