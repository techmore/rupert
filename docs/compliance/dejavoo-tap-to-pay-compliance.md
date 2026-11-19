# Card payments with Dejavoo: compliance checklist

Audited 2026-11-17, ahead of the **Take payment** button described in
[../integrations/dejavoo-tap-to-pay-iphone.md](../integrations/dejavoo-tap-to-pay-iphone.md). Every
source below was read that day unless a line says otherwise.

This is an engineering checklist, **not legal advice**. Items marked **Owner/Legal** need the owner,
Valmar, Dejavoo or a lawyer to answer before they can be closed.

Status words:

- **Done**: in the repository now (file named).
- **Ready-when-ships**: written down here, to apply in the release that turns Take payment on.
- **Owner/Legal**: a named person has to answer the exact question given.

Keep TPNs, merchant codes, contacts, device IDs and the store's product approvals out of this public
repository. Dejavoo's SDK or library binaries, package credentials and sample code stay out as well
(see the [integration notes](../integrations/dejavoo-tap-to-pay-iphone.md#vendor-code-stays-out-of-this-repository)).

## Correction, 2026-11-18: two routes, and which one is not confirmed

This checklist was written on the assumption that Take payment would use Dejavoo's **deep linking**:
Rupert opens Dejavoo's own app, iPOSgo!, which takes the tap. Dejavoo's public pages describe a second,
different route, the **in-app SDK**, in which Dejavoo's framework runs inside Rupert's app and Rupert
itself needs Apple's Tap to Pay on iPhone entitlement on an organization developer account [D3][D4][A6].

**Intended route: in-app SDK; pending Dejavoo's written confirmation and Apple's entitlement
approval** (owner, 2026-11-18). The approval Dejavoo gave was worded "Native SDK", a term its public
pages do not use, so **which product was granted is not yet confirmed** (question Q10). The two routes
are set side by side, with the four things that must happen before the SDK can be added, in the
[integration notes](../integrations/dejavoo-tap-to-pay-iphone.md#two-routes-and-which-one-is-not-yet-confirmed).

Items that hold for both routes are unchanged. Items that were true only for deep linking now say so
and give the in-app SDK answer: A6, A8, A9, P6, V8, S3, S5, S6, the `Info.plist` section, and
questions Q1, Q3, Q6 and Q8.

## Where things stand

- No payment code is in the iPhone app. Version 1.1.0 (time, schedule and pay) was approved by App
  Review and is **Pending Developer Release** (checked 2026-11-17, App Store Connect API, read-only).
- The Dejavoo counter-terminal adapter (SPIn), hosted payment page and FEED webhooks exist and run on
  Dejavoo's test system only. Live use needs the owner's recorded sign-off.
- Taking a contactless payment needs an **iPhone**. It does not work on iPad (Apple's Human Interface
  Guidelines: "Not supported in iPadOS"). An iPad register needs a counter terminal.

## 1. Apple: Tap to Pay on iPhone naming, marketing and trademarks

| # | Item | Status |
|---|---|---|
| A1 | The feature is always called **Tap to Pay on iPhone**. Never "Apple Tap to Pay", never shortened in marketing [A1]. | **Done.** No public page, in-app text or App Store listing names it. `bin/release-audit` (rule `tap-to-pay-name`) blocks a wrong name on public pages, views, `ios/AppStore/listing.md` and `mobile/App.tsx`. Internal docs were corrected (`docs/integrations/dejavoo-tap-to-pay-iphone.md`, `docs/ios/app-review-readiness.md`). |
| A2 | Do not market it before it is generally available in the app [A1]. | **Done.** Public pages describe it only as planned, without the Apple name: `web/app/views/public_pages/privacy.html.erb`, `security.html.erb`, `integrations.html.erb`, `support.html.erb`. Rule `tap-to-pay-availability` blocks the name on public pages unless it is worded as planned, until `docs/security/evidence/tap-to-pay-on-iphone-live.md` exists. Test: `web/test/integration/public_policy_pages_test.rb`. |
| A3 | Never promise tap payments on iPad [A2]. | **Done.** Support, security and integrations pages say it will not work on iPad. Rule `tap-to-pay-ipad`. |
| A4 | No Apple logo, no drawings or photos of iPhone or of the feature, no stock imagery [A1][A3]. | **Done.** None in the repository. |
| A5 | Trademark credit where Apple's marks are named, and no implied endorsement [A3]. | **Done.** Credit line on every public policy page: `web/app/views/public_pages/_policy_links.html.erb`. |
| A6 | Use only Apple-approved marketing assets from the Tap to Pay on iPhone Marketing Toolkit [A1]. | **Ready-when-ships.** Depends on the route. Deep linking: the entitlement holder is Dejavoo's iPOSgo!, not Rupert, so any assets would come through Dejavoo. In-app SDK: Rupert would hold the entitlement itself and Apple's marketing guidelines apply to Rupert directly [A1][D4]. Until approved assets are in hand, marketing is text only. |
| A7 | Press releases, blog posts and investor notes that mention the feature go to Apple for review first, through the payment provider. Reviews can take weeks [A1]. | **Owner/Legal** (question Q1). |
| A8 | Button label: where several ways to pay are offered, the button that starts it is labelled "Tap to Pay on iPhone" ("Tap to Pay" only if space is tight), with the `wave.3.right.circle` symbol and no Apple logo. Refund and lookup buttons do not use the name [A2]. | **Ready-when-ships.** Plan: **Take payment** opens the tender choice, and the contactless choice carries Apple's label. Hide it on iPad, on unsupported iPhones and outside the US. With the in-app SDK this rule binds Rupert without question, because the tap screen is opened from Rupert's own interface; with deep linking it is question Q8. |
| A9 | Merchant terms and the how-to tutorial are shown by the payment app; only an administrator accepts the terms [A2]. | **Ready-when-ships.** Deep linking: these happen inside iPOSgo!; Rupert's in-app help should send staff there and not re-create Apple's screens. In-app SDK: Rupert is the payment app, so the terms acceptance and the tutorial are reached from Rupert's own screens, following [A2]; Dejavoo's page says Apple's terms are accepted when the terminal number is entered [D4]. |
| A10 | App Store listing text and screenshots do not mention the feature before it ships; keywords are not packed with trademarks (guideline 2.3.7) [A4]. | **Done.** `ios/AppStore/listing.md` has no payment wording; the live listing was checked through the API on 2026-11-17. |

## 2. Dejavoo and iPOSpays: brand and claims

| # | Item | Status |
|---|---|---|
| D1 | No Dejavoo or iPOSpays logo anywhere. | **Done.** None in the repository. |
| D2 | No "certified", "approved", "official" or "preferred" partner wording without written permission. | **Done.** None found. Rule `partner-claim` in `bin/release-audit` blocks it until `docs/security/evidence/partner-permission.md` records the permission. |
| D3 | Dejavoo is described accurately: the terminal and payment-page provider, used through the merchant's own processor. | **Done.** `privacy.html.erb`, `security.html.erb`, `integrations.html.erb` ("on Dejavoo's test system only"). |
| D4 | No claim that any processor approved hemp or CBD. | **Done.** Terms say "Your payment processor decides which products it will accept." Nothing public says a processor approved them. |
| D5 | Dejavoo's own rules for an ISV naming it in public. | **Owner/Legal** (question Q2). No public Dejavoo brand guideline was found. |

## 3. PCI and card data

| # | Item | Status |
|---|---|---|
| P1 | Public PCI wording is accurate: Rupert does not store card numbers, holds no PCI attestation, and each merchant still completes its own self-assessment. | **Done.** `security.html.erb` ("does not currently hold a PCI DSS attestation", "Each merchant completes its own PCI DSS self-assessment"), terms, landing page FAQ. `bin/release-audit` blocks "PCI compliant/certified" without evidence. |
| P2 | No card data in logs. | **Done, verified.** `web/app/services/card_data.rb` redacts card numbers, track data and security codes from logs, errors, chat and AI prompts; `web/test/integration/card_data_logging_test.rb`. |
| P3 | Request-log filtering covers payment result fields. | **Done (added).** `web/config/initializers/filter_parameter_logging.rb` now hides `AcntFirst4`, `First4`, `BIN`, `maskedPan`, `chName`, cardholder, EMV and signature fields, every `…token` (iPOSToken, cardToken) and whole result containers (`Spin_Response`, `ExtData`, `CardData`, `cardInfo`, `iposHPResponse`). Last four, approval code, RRN, batch, amounts and entry type still log. Tested. |
| P4 | Payment-page lockdown intact (PCI DSS 6.4.3 and 11.6.1). | **Done, verified.** `web/app/controllers/warehouse_checkouts_controller.rb`: scripts and connections only from Rupert and the named providers, no framing, forms only to Rupert and Dejavoo's payment page. |
| P5 | The terminal adapter keeps only whitelisted fields. | **Done, verified.** `web/app/services/pos/dejavoo_spin_gateway.rb` (`Response`): status, reference, amounts, approval code, processor reference, batch, brand, last four, entry type. Test "only whitelisted fields survive parsing". FEED (`pos/dejavoo_feed.rb`) and the hosted page (`dejavoo_hosted_page.rb`) do the same. |
| P6 | Take payment keeps the same list and nothing more. | **Ready-when-ships.** Keep: `AcntLast4`, `AuthCode`, `RRN`, `BatchNum`, `Amount`, `Tip`, `Fee`, `TotalAmt`, card brand, `EntryType`, `TxnType`, `DateTime`, `PNRef`/`RefId`. Never store: `AcntFirst4`, `iPOSToken`, `HostTxnId` beyond what reconciliation needs, or the raw response. Parse into a fixed structure as the SPIn adapter does. Both routes return the same result fields [D4][D5], so the list does not depend on the route. |
| P7 | The result returned through the app is never trusted alone. | **Ready-when-ships.** The server confirms with Dejavoo (status lookup or a matching FEED event) before a sale is marked paid, and the returned amount must equal the amount the server set. |
| P8 | Which self-assessment form applies to the store for each way of paying. | **Owner/Legal** (question Q3). |

## 4. Privacy policy, terms and support

| # | Item | Status |
|---|---|---|
| V1 | Privacy policy says who processes card payments, what Rupert receives and keeps, why, for how long, that card numbers never reach Rupert, and who to contact. | **Done.** `web/app/views/public_pages/privacy.html.erb` (`#card-payments`). |
| V2 | It is truthful about live versus planned. | **Done.** Same section: Dejavoo on its test system only; the app takes no card payments; the iPhone option is planned. |
| V3 | The App Store privacy policy URL points at that page. | **Done, verified.** `https://pos.rupertpos.com/privacy` in App Store Connect and `ios/AppStore/listing.md`. |
| V4 | Staff app privacy page. | **Done.** `web/app/views/employee_app/privacy.html.erb` (`#card-payments`). |
| V5 | Terms: the merchant is the merchant of record and owns its PCI self-assessment, receipts, refund policy and surcharge notices. | **Done (draft).** `web/app/views/public_pages/terms.html.erb`. The terms are still a draft awaiting counsel. |
| V6 | Support page: who to ask about a card payment; no card payments in the app today; iPhone only. | **Done.** `web/app/views/public_pages/support.html.erb`. |
| V7 | Landing page card FAQ. | **Done.** `web/app/views/landing/index.html.erb`. |
| V8 | When Take payment ships: name the feature, add Apple's credit line for it, say who takes the payment, and update the date. | **Ready-when-ships.** Deep linking: the payment is taken in Dejavoo's iPOSgo! app under Dejavoo's privacy policy. In-app SDK: it is taken inside Rupert's app by Dejavoo's software, so the policy must say that Dejavoo's component runs in the app and what it sends to Dejavoo. |
| V9 | Retention period for payment records after a workspace closes. | **Owner/Legal** (question Q4). The terms page still shows an owner placeholder for it. |

## 5. App Store

No payment code or URL scheme was added to the app, and nothing was changed in App Store Connect.

| # | Item | Status |
|---|---|---|
| S1 | In-person payments for physical goods do not use in-app purchase. Guideline 3.1.3(e): "If your app enables people to purchase physical goods or services that will be consumed outside of the app, you must use purchase methods other than in-app purchase to collect those payments, such as Apple Pay or traditional credit card entry." [A4] | **Ready-when-ships.** Quote it in the review notes. |
| S2 | App Privacy label changes (below). | **Ready-when-ships.** `ios/AppStore/checklist.md`. |
| S3 | Review notes: what the feature does, in detail, and how the reviewer can see it (guidelines 2.3.1(a) and 2.1(a)) [A4]. | **Ready-when-ships.** Draft in `ios/AppStore/review-notes.md`. The draft describes deep linking (Rupert opens iPOSgo!); rewrite it if the in-app SDK is the route. |
| S4 | No hidden or dormant features (guideline 2.5.19) [A4]. | **Ready-when-ships.** Do not ship payment code switched off and undescribed. Ship it in the version whose notes describe it; the per-workspace switch is described in those notes. |
| S5 | `Info.plist` and entitlement changes (below; they differ by route). | **Ready-when-ships.** Not added now. |
| S6 | Privacy manifest. | **Ready-when-ships.** `PrivacyInfo.xcprivacy` lists no collected data types today. In the Take payment build, list the same types as the label, and check whether Dejavoo's library ships its own manifest. This matters more with the in-app SDK, where Dejavoo's payment framework is part of Rupert's binary. |
| S7 | Guideline 1.4.3 and the store's catalog. | **Owner/Legal.** Already recorded in `docs/ios/app-review-readiness.md`; card acceptance in the app makes it more visible (question Q5). |
| S8 | Third-party marks in the listing (guideline 5.2.1) [A4]. | **Ready-when-ships.** Name iPOSgo! and Dejavoo in the listing only with Dejavoo's permission (question Q2). |

### App Privacy label when Take payment ships

Apple counts data that leaves the device and is kept by Rupert or its partners [A5]. Today the label
says financial info and purchases are not collected. With Take payment, Rupert's server receives
payment results through the app, so:

| Data type | Answer | Why |
|---|---|---|
| Financial Info → **Payment Info** | Collected · App Functionality · not used for tracking · linked to identity: Yes | Apple's definition: "form of payment, payment card number, or bank account number". Apple's exemption applies only when "you as the developer never have access to the payment information". Rupert never gets the card number, but it does keep the card brand and last four digits, so the cautious answer is to declare it. "Linked" because the payment is stored with the sale, the staff account that took it and sometimes a customer record. |
| Purchases → **Purchase History** | Collected · App Functionality · not used for tracking · linked: Yes | "An account's or individual's purchases". A card sale taken in the app creates a purchase record that can be attached to a named customer. Sales already sit under "Other User Content"; declaring this too is the cautious choice. |
| Financial Info → Credit Info, Other Financial Info | Not collected | No credit scores, income or balances. |
| Everything else | Unchanged | |

Over-declaring carries no penalty; under-declaring can. The owner confirms these on the App Privacy
page (there is no API for it).

### App changes by route

The in-app SDK set is the one the owner intends; the deep-linking set is kept as the fallback. Add
neither until Dejavoo confirms the route in writing (Q10).

#### Deep linking: `Info.plist` entries the hand-off will need

Dejavoo's deep-linking page shows its URL-scheme setup only as images, and names two case-sensitive
keys, `invokeApplink` and `ogApplink` [D1]. Take the exact values from the library Dejavoo sends.

```xml
<!-- Lets Rupert check that iPOSgo! is installed before offering the button. -->
<key>LSApplicationQueriesSchemes</key>
<array><string>IPOSGO-SCHEME-FROM-DEJAVOO</string></array>

<!-- The scheme iPOSgo! uses to hand the result back to Rupert. -->
<key>CFBundleURLTypes</key>
<array><dict>
  <key>CFBundleURLName</key><string>com.rupertpos.Rupert.payment-return</string>
  <key>CFBundleURLSchemes</key><array><string>RETURN-SCHEME-AGREED-WITH-DEJAVOO</string></array>
</dict></array>

<!-- Dejavoo's two keys, spelled exactly like this. -->
<key>invokeApplink</key><string>VALUE-FROM-DEJAVOO</string>
<key>ogApplink</key><string>VALUE-FROM-DEJAVOO</string>
```

This would be the app's first registered URL scheme. Any app can open a URL scheme, so the handler
treats what arrives as a hint, accepts it only for a payment attempt the server already opened, and
lets the server decide (item P7). No new usage string is needed on this route: Rupert does not use NFC
itself, and it needs no Apple entitlement [D3].

#### In-app SDK: entitlement and `Info.plist`

No hand-off URL scheme is needed, because nothing leaves Rupert's app. Instead:

- An eligible developer account. Apple's form needs an organization-level account [A6]. Rupert's
  App Store listing shows a person's name as seller (checked 2026-11-18), which is what Apple shows
  for an individual enrollment [A7], so the enrollment type must be confirmed and may need
  converting through Apple Developer Support [A7].
- Apple's entitlement. The Account Holder of an organization Apple Developer account requests it,
  naming the payment service provider;
  Apple reviews the request; a first grant covers testing, and TestFlight and App Store builds need a
  second request for the entitlement that allows distribution [A6].
- The Tap to Pay on iPhone capability on the App ID, a provisioning profile that includes it, and
  `com.apple.developer.proximity-reader.payment.acceptance` set to true in
  `ios/RupertApp/RupertApp.entitlements` [A6].
- Dejavoo's `Environment` entry in `Info.plist`, set to its test or live value [D4].
- Dejavoo's framework linked into the app. It is not committed to this repository; the build fetches
  it or a private companion repository supplies it.
- Whether any usage string is needed was not established today; check Apple's setup page [A6] and
  Dejavoo's sample project when the framework is in hand.

On this route the result arrives as a callback in the app instead of through a URL. It is still only
the phone's report, so item P7 applies unchanged.

## 6. Receipts, surcharges and card network basics

| # | Item | Status |
|---|---|---|
| R1 | Card receipt shows merchant, date, amount, transaction type, card brand, last four digits and approval code. | **Done (added).** `web/app/views/pos_checkouts/show.html.erb` now shows merchant and location, date and time, and "Sale" with the amount, beside the card and approval code it already showed. |
| R2 | No more than the last five digits of the card and no expiry date on a receipt (federal law, 15 U.S.C. §1681c(g)). | **Done, verified.** Rupert only ever holds the last four and never the expiry. |
| R3 | Entry method ("Contactless") on the receipt. | **Ready-when-ships.** The adapters read the entry type but `pos_payment_attempts` has no column for it. Add the column and print it. |
| R4 | Merchant street address or city on the receipt. | **Ready-when-ships.** The receipt shows the store name; a store address is not printed. Add it where the store's address is recorded. |
| R5 | Refund and void receipts, and the chip/contactless fields (application label, AID) some receipts carry. | **Owner/Legal** (question Q6). |
| R6 | Rupert adds no surcharge. | **Done, verified.** Hosted page is created with `calculateFee: false`; a terminal sale whose total differs from Rupert's, or that carries a fee, is held for review (`web/app/services/pos/dejavoo_terminal_payment.rb`). Rupert has no surcharge or dual-pricing setting. |
| R7 | Take payment keeps fees off in iPOSgo!, or holds a sale with a fee for review. | **Ready-when-ships.** Dejavoo's sample result carries `Fee` and `FeeLabel` [D2]. |
| R8 | If the store ever wants a surcharge or dual pricing. | **Owner/Legal** (question Q7). What was confirmed today: Visa requires 30 days' notice to the acquirer before surcharging [N1], and Pennsylvania has no surcharge statute, with bills pending [N2]. Widely stated but **not re-read in the network rules today**: no surcharge on debit or prepaid cards, a cap (commonly cited as 3% for Visa), notice at the entrance and the register, and the surcharge as its own line on the receipt. |
| R9 | Event receipts. | **Done, no change.** `web/app/views/pos_event_sales/receipt.html.erb`: the card is run on the event's own terminal, which prints the card receipt. |

## Questions that need a person

1. **Q1, Dejavoo:** On the route Rupert is granted (Q10), how does Rupert get Apple's Tap to Pay on
   iPhone Marketing Toolkit and review path: through Dejavoo as a deep-linking integrator, or
   directly as the entitlement holder with the in-app SDK? Who submits a launch announcement to
   Apple, and how long does it take?
2. **Q2, Dejavoo and Valmar:** May Rupert name Dejavoo, iPOSpays and iPOSgo! on its website and App
   Store listing, and in what words? Is there a brand guideline or a written permission to file? May
   Rupert say "works with Dejavoo terminals"?
3. **Q3, Valmar:** Which PCI self-assessment form does the store complete for (a) a counter terminal
   driven by Rupert, (b) the hosted payment page, (c) contactless payments taken on an iPhone through
   iPOSgo!, and (d) the same taken inside Rupert's app with Dejavoo's in-app SDK? Dejavoo's overview
   says neither iPhone route adds a compliance burden for the developer or the merchant [D3]; ask for
   that in writing for the route chosen. Does Rupert count as a service provider for the store, and does Valmar need anything from
   Rupert for it?
4. **Q4, lawyer:** How long must payment records (amount, last four, approval code, references) be kept,
   and how long may they be kept after a workspace closes? Is the privacy policy's "as long as the
   workspace exists" acceptable?
5. **Q5, lawyer:** With card acceptance in the app, does App Store guideline 1.4.3 change anything for a
   shop whose catalog includes products that stop being federal hemp on 2026-12-11?
6. **Q6, Valmar:** What must a contactless receipt carry on this account (application label, AID, entry
   method, terminal ID, merchant address)? Does iPOSgo! (deep linking) or Dejavoo's framework (in-app SDK)
   issue the cardholder receipt, or must Rupert's receipt meet the full list? What is required on refund and void receipts?
7. **Q7, Valmar and lawyer:** Is the store's pricing a surcharge, dual pricing or neither? If either,
   what do the card networks and Pennsylvania require, and should iPOSgo! or Rupert apply it?
8. **Q8, Dejavoo:** Dejavoo's overview says deep linking needs no Apple entitlement for the
   integrator and the in-app SDK needs the integrator's own [D3]. Confirm that for Rupert's route. On
   deep linking, is Rupert bound by Apple's button-label rules when it only opens iPOSgo!? On the
   in-app SDK, does each store need anything from Apple, or only Rupert?
9. **Q9, Valmar, in writing:** Which processor will the production account use, and is each of the
   store's product categories approved there? (Nothing in Rupert's public text may say so until then.)
10. **Q10, Dejavoo, in writing (added 2026-11-18):** Does the "Native SDK" approval cover the in-app
    SDK (Dejavoo's framework inside Rupert's app), the route the owner intends, or deep linking
    (Rupert opens iPOSgo!)?
11. **Q11, Owner (added 2026-11-18):** Is Rupert's Apple Developer account an organization enrollment?
    Only the Account Holder of an organization account can request Apple's entitlement [A6]. If it
    is an individual enrollment, converting it goes through Apple Developer Support and needs a
    legal entity [A7].

## Sources

- [A1] Apple, Tap to Pay on iPhone marketing guidelines: <https://developer.apple.com/tap-to-pay/marketing-guidelines/>
- [A2] Apple, Human Interface Guidelines, Tap to Pay on iPhone: <https://developer.apple.com/design/human-interface-guidelines/tap-to-pay-on-iphone>
- [A3] Apple, Guidelines for Using Apple Trademarks and Copyrights: <https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html>
- [A4] Apple, App Review Guidelines (1.4.3, 2.1, 2.3.1, 2.3.7, 2.5.19, 3.1.3(e), 5.1.1, 5.2.1): <https://developer.apple.com/app-store/review/guidelines/>
- [A5] Apple, App privacy details on the App Store: <https://developer.apple.com/app-store/app-privacy-details/>
- [A6] Apple, Setting up Tap to Pay on iPhone (read 2026-11-18): <https://developer.apple.com/documentation/proximityreader/setting-up-the-entitlement-for-tap-to-pay-on-iphone>
- [A7] Apple, Program enrollment (read 2026-11-18): <https://developer.apple.com/help/account/membership/program-enrollment/>
- [D1] Dejavoo, iOS deep linking v2: <https://app.theneo.io/dejavoo/tap-to-pay-on-iphone/deep-linking/v2>
- [D2] Dejavoo, sample responses: <https://app.theneo.io/dejavoo/tap-to-pay-on-iphone/deep-linking/v2/tpn-register/sample-responses>
- [D3] Dejavoo, Tap to Pay on iPhone overview, the two integration options (read 2026-11-18): <https://docs.ipospays.com/tap-to-pay-on-iphone>
- [D4] Dejavoo, iPhone in-app SDK integration (read 2026-11-18): <https://docs.ipospays.com/tap-to-pay-on-iphone/in-app-sdk>
- [D5] Dejavoo, iPhone deep linking V2 on Developer Central (read 2026-11-18): <https://docs.ipospays.com/tap-to-pay-on-iphone/deep-linking/V2>
- [N1] Visa, rules and fees for businesses (surcharging): <https://www.visa.com/en-us/support/business/regulation-fees>
- [N2] Pennsylvania surcharge status, secondary sources found by web search on 2026-11-17 (a lawyer
  should confirm against the General Assembly's site): <https://www.nickel.com/surcharge-laws/pennsylvania>
