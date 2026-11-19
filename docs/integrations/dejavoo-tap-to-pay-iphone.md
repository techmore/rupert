# Tap to Pay on iPhone with Dejavoo (iPOSgo!)

Prepared 2026-11-13 from Dejavoo's public developer docs (read that day). Owner decision recorded the
same day. Status updated 2026-11-17. **Corrected 2026-11-18:** Dejavoo documents two different iPhone
routes, and this page had treated them as one; see [Two routes](#two-routes-and-which-one-is-not-yet-confirmed).
**Intended route (owner, 2026-11-18): in-app SDK; pending Dejavoo's written confirmation and Apple's
entitlement approval.**
Related: [dejavoo-spin.md](dejavoo-spin.md) (counter terminals),
[dejavoo-valmar-meeting-brief.md](dejavoo-valmar-meeting-brief.md) and the
[compliance checklist](../compliance/dejavoo-tap-to-pay-compliance.md) (Apple naming, Dejavoo brand, PCI,
privacy, App Store and receipts).

Apple's name for the feature is **Tap to Pay on iPhone**. Write it in full, never "Apple Tap to Pay", and
do not put it on a public page before it ships (see the checklist).

Keep TPNs, merchant codes, auth keys, device UDIDs, contact details and the store's product approvals
out of this public repository. Dejavoo's libraries, sample code and package credentials stay out too;
see [Vendor code stays out of this repository](#vendor-code-stays-out-of-this-repository).

## Decision

Build card acceptance into the **existing Rupert iPhone app** as a **Take payment** button on the
register, not a separate "Rupert: POS" app. The register already runs inside the app, and a second app
would need its own App Store review. A POS-only app for store-owned phones can come later.

## Two routes, and which one is not yet confirmed

Dejavoo's public pages describe **two** ways for another company's iPhone app to take a contactless
payment [V1]. They are different integrations with different Apple requirements. The pages call them
**Deep Linking** and **In-App SDK**; neither page uses the words "Native SDK".

| | Deep linking | In-app SDK |
| --- | --- | --- |
| What runs where | Rupert hands the amount to Dejavoo's own payment app, iPOSgo!, on the same phone. iPOSgo! takes the tap and hands the result back to Rupert. A small Dejavoo library in Rupert's app does the hand-off [V3]. | Dejavoo's payment framework runs **inside Rupert's app**. The tap happens on Rupert's own screen and the result comes back as a callback in the app. iPOSgo! does not need to be installed [V1][V2]. |
| Apps on the store's phone | Rupert and iPOSgo! [V1][V3]. | Rupert only [V1]. |
| Apple requirements for Rupert | None stated: Dejavoo says this route needs no entitlement from Apple [V1]. iPOSgo! holds it. | Rupert's app needs Apple's **Tap to Pay on iPhone entitlement**. The request form is open only to the Account Holder of an **organization** Apple Developer account, and Apple reviews each request [P1]. Testing and distribution use separate entitlements: TestFlight and App Store builds need the one that allows distribution, requested again after testing [P1]. Dejavoo says to pick the US region and its SDK as the payment provider on the form, and that approval typically takes around two weeks [V1]. |
| Device and iOS, as Dejavoo states them | iPhone XS or later; iOS "above 16.9"; device region set to US [V3]. | iPhone XS or later; iOS "16.9 or later", latest recommended; device region set to US [V2]. |
| Device, as Apple states it | The device must be an iPhone XS or newer [P2], and Apple's overview asks for the latest version of iOS [P3]. | The same. |
| iPad | Neither Dejavoo page mentions iPad [V2][V3]. Apple's reader check passes only on an iPhone XS or newer [P2], and Apple's interface guidelines say the feature is not supported in iPadOS (compliance checklist source [A2]). Treat this route as **iPhone only**. | The same: **iPhone only**. |
| What changes in Rupert's iPhone app | Dejavoo's hand-off library; a URL scheme so iPOSgo! can return the result, with two case-sensitive configuration keys (`invokeApplink`, `ogApplink`) [V3]; a handler for the returned result. No entitlement. | Dejavoo's payment framework added to the app; an `Environment` entry in `Info.plist` (`UAT` or `PROD`) [V2]; the capability on the App ID, a provisioning profile that carries it, and `com.apple.developer.proximity-reader.payment.acceptance` in the app's entitlements file [P1]. No hand-off URL scheme. |
| Who shows Apple's screens | iPOSgo! shows the merchant terms and the tap screen. | Rupert's app is the payment app: Apple's interface and marketing guidelines for the feature apply to Rupert's own screens, and Dejavoo's page points integrators at both [V2]. |
| App Review | Rupert opens another app to take the payment; the reviewer needs iPOSgo! or a recording. | Rupert's own build carries the entitlement; a build without the distribution entitlement cannot go to TestFlight or the App Store [P1]. |
| Merchant setup | A Tap on Phone TPN and merchant code on iPOSpays, sandbox or production [V3]. | The same [V2]. |
| Processors listed | TSYS, Fiserv Omaha, Fiserv North, EPX [V3]. | The same [V2]. |
| What the result carries | Approval code, last four digits, references, amounts, card brand and an entry type [V3]. | The same fields [V2]. This page also documents key-in, QR and pay-by-link sales, which are not taps. |

Dejavoo says neither route adds a compliance burden for the developer or the merchant [V1]. That is
Dejavoo's statement, not a finding of this document; the PCI questions in the compliance checklist
still need written answers.

**Intended route: in-app SDK; pending Dejavoo's written confirmation and Apple's entitlement
approval.** The owner stated on 2026-11-18 that the in-app SDK is the route he intends: Dejavoo's
framework inside the Rupert app, the cashier never leaving Rupert.

**Which product Dejavoo granted is still not confirmed.** The approval recorded on 2026-11-17 was
worded "Native SDK". This page then assumed that meant deep linking. Dejavoo's public pages do not use
that term. Until Dejavoo says in writing which route the approval covers (question 1 below), the route
is an intention, not a grant, and the rest of this page is marked where it depends on the route.

What the choice means for Rupert:

- **In-app SDK (intended)** keeps the cashier in Rupert, but Rupert must hold Apple's entitlement on
  an organization developer account, follow Apple's screen and wording rules in its own interface,
  and build Dejavoo's framework into the app.
- **Deep linking (fallback)** needs nothing from Apple and little app code, but the store's phone
  needs two apps and the cashier leaves Rupert for the tap.

### What must happen before the SDK can be added

No payment code goes into the app until all four are done, in this order.

1. **The Apple Developer account must be eligible for the entitlement.** Apple's setup page says the
   request form needs an organization-level Apple Developer account, signed in as the Account Holder
   [P1]. Rupert's public App Store listing currently shows a person's name as the seller, not a
   company's (checked 2026-11-18). Apple lists an individual's legal name as seller for an individual
   enrollment and the legal entity's name for an organization [P4], so the enrollment type **must be
   confirmed** in the developer account and may need converting. Apple's enrollment page says
   conversion from individual to organization is done by contacting Apple Developer Support, and
   that an organization must be a legal entity with a D-U-N-S Number, a work email address on its
   own domain and a public website; a sole proprietor has to enroll as an individual [P4]. Allow
   time for this before step 2.
2. **The Account Holder requests the entitlement from Apple**, naming the payment service provider.
   Dejavoo says to choose the US region and its SDK as the provider, and that approval typically
   takes around two weeks [V1]. Apple reviews each request against its own criteria; the first grant
   covers testing, and a second request is needed before TestFlight or the App Store [P1].
3. **Dejavoo supplies** the framework, a sandbox terminal profile (a Tap on Phone TPN) and the
   merchant code [V2], and confirms in writing that the in-app SDK is what it approved.
4. **The Dejavoo-backed reader implementation lives outside this public repository** (next section).
   Only the protocol and a fake implementation are committed here.

## Vendor code stays out of this repository

This repository is public. Whichever route is chosen, these are **never committed here**: Dejavoo's
SDK or library binaries, private package or repository credentials, and Dejavoo's sample code. Dejavoo
hands some of these out privately; for example its Android SDK page describes library files plus a
private package repository whose address and access keys come from Dejavoo support [V4].

The intended pattern:

- **In this repository:** a small Swift protocol (working name `CardReader`) with the few calls the
  register needs (prepare, take a payment for an amount the server set, cancel) and a fixed result
  type holding only the whitelisted fields. A **fake implementation** returns canned results, so the
  app builds, the tests run and CI passes without any vendor code.
- **Outside this repository:** the Dejavoo-backed implementation of that protocol, in a private
  companion repository or fetched at build time on the release machine. Its credentials live with the
  release machine's secrets, never in a file here.
- A build without the private piece falls back to the fake and never offers **Take payment**.

The same protocol fits either route: one implementation hands off to iPOSgo!, the other calls the
in-app framework.

## How the deep-linking route works

This section describes deep linking only, kept as the fallback. With the in-app SDK, the intended
route, steps 3 to 5 happen inside Rupert's app and iPOSgo! is not involved; steps 1, 2 and 6 are the
same.

In deep linking Rupert's app does not read the card itself. It hands the amount to Dejavoo's own
payment app, **iPOSgo!**, which takes the tap and hands the result back.

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

With deep linking the store's phone needs both apps installed: Rupert and iPOSgo!. On either route it
must be an **iPhone**: Tap to Pay on iPhone does not work on iPad, so an iPad register needs a counter
terminal ([SPIn](dejavoo-spin.md)).

## Videos (Dejavoo's own, about 30–40 seconds each; all three show deep linking)

- [A payment from start to finish](https://s3.us-east-1.amazonaws.com/assets.ipospays.com/Deeplinking+V2_1.mp4)
- [Adding Dejavoo's library to an iPhone app](https://media.publit.io/file/iOSDeepLinkingConfigureSDK/iOS-Deep-Linking-Configure-SDK.mp4)
- [Connecting the phone to the merchant account (TPN register)](https://s3.us-east-1.amazonaws.com/assets.ipospays.com/V2+Registration+Video.mp4)

## What it supports

Sale, refund (standalone, after settlement), void (before settlement, by RRN), pre-authorization and
ticket (capture by RRN), and batch settlement. Optional tip and fee amounts. Contactless only: no chip
insert or swipe on the iPhone.

## Requirements

Both routes:

- iPhone XS or later, iOS newer than 16.9 as Dejavoo states it [V2][V3] (Apple asks for the latest
  iOS [P3]), device region set to **US**.
- A merchant onboarded on iPOSpays (sandbox for testing, production for live) with a **Tap on Phone
  (TOP) TPN**, and the **merchant code** from the portal: Settings → Generate ECOM/TOP Merchant Keys →
  pick the TOP TPN.
- Accept Apple's Tap to Pay on iPhone terms on the device: in iPOSgo! with deep linking, in Rupert's
  own app with the in-app SDK.
- Use a separate test device and don't change its date or time during testing.
- Processors listed for Tap to Pay on iPhone: TSYS, Fiserv Omaha, Fiserv North and EPX (the notes of
  2026-11-13 listed the first three). **Confirm with Valmar in writing** that an account on one of
  these is approved for the store's hemp/CBD products.

Deep linking only:

- Dejavoo supplies the library and a demo app through a Diawi install link after receiving the test
  device's UDID.
- URL scheme keys `invokeApplink` and `ogApplink` (case sensitive) in the app's configuration.

In-app SDK only:

- Apple's Tap to Pay on iPhone entitlement for Rupert's app, requested by the Account Holder of an
  organization Apple Developer account; first for testing, then again for distribution [P1].
- A sandbox Apple account on the test device for Dejavoo's test system [V2].
- Dejavoo's framework, obtained from Dejavoo and kept out of this repository.

## Security: who handles what

**Apple and Dejavoo:** reading the card, encryption, and keeping card numbers out of Rupert. Rupert
receives only the result fields; it never sees a card number. The store still completes its yearly PCI
self-assessment (Valmar says which form).

**Rupert:**

- **Never trust the returned "approved" by itself.** With deep linking the result comes back through
  a URL scheme that any app could open with a fake approval. With the in-app SDK it comes back as a
  callback inside the app, which is harder to forge from outside but is still only the phone's word.
  On either route the server marks a sale paid only after confirming the transaction with Dejavoo
  (transaction status lookup or a matching FEED event, which Rupert already receives).
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
| Confirm that the in-app SDK is what Dejavoo approved | Dejavoo's written answer (question 1) | Before any build work |
| Confirm the Apple Developer enrollment type; convert to an organization if it is an individual one | Owner; Apple Developer Support for a conversion [P4] | Unknown; Apple gives no figure |
| Apple's entitlement | Account Holder submits Apple's form, naming the payment provider; a second request before TestFlight or the App Store [P1] | Dejavoo says about two weeks is typical [V1]; Apple gives no figure |
| Tap with Dejavoo's demo app on the owner's iPhone | Library and demo app from Dejavoo | Same day it arrives |
| Test tap from Rupert's register (sandbox) | Library in hand, TOP TPN and merchant code | 1–2 days |
| Full version: refunds, voids, batch close, server confirmation, settings, tests | — | About a week more |
| Live payments at the store | Production TOP TPN boarded by Valmar with hemp/CBD approval; App Store update review; the "when Take payment ships" items in the compliance checklist | Valmar's timeline; review about 1–2 days |

Sandbox payments move no money.

## Status (2026-11-17)

- **Dejavoo approved Rupert's "Native SDK" integration.** Correction, 2026-11-18: this line used to
  add "(the iOS deep-linking library, V2)". That was an assumption. Dejavoo's public pages describe
  deep linking and an in-app SDK as two separate routes and call neither "Native SDK", so **which
  route was approved is not confirmed** (question 1). The owner intends the in-app SDK (2026-11-18). Keep the written approval with the owner's
  private records, not in this repository.
- **The P18 counter terminal is paused until after 2026-12-12** (store decision, 2026-11-16), pending the
  hemp/CBD processor decision, how many terminals are needed and the cost.
- **Work continues in Dejavoo's test system (UAT) only.** Dejavoo says UAT is free. No money moves.
- **iPhone only, not iPad.** The store hopes to use "the existing Rupert app and iPad". Tap to Pay on
  iPhone does not work on iPad; an iPad register needs a counter terminal (SPIn) instead.
- iPOSpays sandbox merchant account is set up (from the ISV sandbox request, 2026-11-03).
- Rupert has no payment code in the iPhone app yet. Version 1.1.0 (no payments) is approved and
  waiting for the owner to release it.
- Compliance work done ahead of the build is in the
  [compliance checklist](../compliance/dejavoo-tap-to-pay-compliance.md).

## Open questions for Dejavoo and Valmar

1. **Reopened 2026-11-18.** Does the "Native SDK" approval cover the in-app SDK (Dejavoo's framework
   inside Rupert's app), which is the route the owner intends, or deep linking (Rupert opens
   iPOSgo!)? Ask for the answer in writing and file it privately.
2. Does the sandbox account need a separate Tap on Phone TPN? Is one issued per phone?
3. Apple's entitlement. Dejavoo's overview answers the general case: deep linking needs none for the
   integrator, the in-app SDK needs Rupert's own [V1]. Still to ask for the in-app SDK:
   what Dejavoo means by merchants having to obtain the entitlement to use it as their payment
   provider [V2], and whether each store needs anything from Apple or only Rupert does.
4. Which processor will the production TOP TPN use, and is hemp/CBD approved there in writing?
5. Is PIN debit supported on tap, and what happens above the contactless limit?
6. Deep linking only: can iPOSgo! return to Rupert automatically after approval (no extra taps for
   the cashier)?
7. In-app SDK only: how is the framework delivered (package, download, private repository), may it be
   fetched at build time, and does it ship its own privacy manifest?
8. Is Rupert's Apple Developer account an organization enrollment? The App Store listing suggests it
   may be an individual one. (Owner to check in the developer account; step 1 of the list above.)

## Sources

Read 2026-11-18 for the correction:

- [V1] Dejavoo, Tap to Pay on iPhone overview (the two integration options): <https://docs.ipospays.com/tap-to-pay-on-iphone>
- [V2] Dejavoo, iPhone in-app SDK integration: <https://docs.ipospays.com/tap-to-pay-on-iphone/in-app-sdk>
- [V3] Dejavoo, iPhone deep linking V2: <https://docs.ipospays.com/tap-to-pay-on-iphone/deep-linking/V2>
- [V4] Dejavoo, Android in-app SDK integration (how SDK files and package credentials are handed out): <https://docs.ipospays.com/tap-to-pay-on-android/in-app-sdk>
- [P1] Apple, Setting up Tap to Pay on iPhone (entitlement request and project setup): <https://developer.apple.com/documentation/proximityreader/setting-up-the-entitlement-for-tap-to-pay-on-iphone>
- [P2] Apple, `PaymentCardReader.isSupported` (device model): <https://developer.apple.com/documentation/proximityreader/paymentcardreader/issupported>
- [P3] Apple, Tap to Pay on iPhone for developers: <https://developer.apple.com/tap-to-pay/>
- [P4] Apple, Program enrollment (individual and organization enrollment, seller name, converting an account): <https://developer.apple.com/help/account/membership/program-enrollment/>

Read 2026-11-13 for the original notes:

- [iOS deep linking v2](https://app.theneo.io/dejavoo/tap-to-pay-on-iphone/deep-linking/v2) and its
  [TPN register](https://app.theneo.io/dejavoo/tap-to-pay-on-iphone/deep-linking/v2/tpn-register),
  [perform transactions](https://app.theneo.io/dejavoo/tap-to-pay-on-iphone/deep-linking/v2/tpn-register/perform-transactions)
  and [sample responses](https://app.theneo.io/dejavoo/tap-to-pay-on-iphone/deep-linking/v2/tpn-register/sample-responses) pages
- [Tap to Pay on iPhone overview](https://app.theneo.io/dejavoo/tap-to-pay-on-iphone/deep-linking)
- [iPOSpays Developer Central](https://docs.ipospays.com/)
- [Dejavoo ISV presentation](https://dejavoo.io/wp-content/uploads/2025/08/Dejavoo_Presentation_for_ISVs.pdf)
