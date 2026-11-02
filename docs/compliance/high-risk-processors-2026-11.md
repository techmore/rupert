# High-risk card processors for hemp/CBD merchants (November 2026)

**Prepared:** 2026-11-02 for Herbal Healers (a Rupert customer). **Not legal or financial advice.** Processor terms are set per merchant in underwriting; nothing here replaces a written quote and contract.

Related: [herbal-healers-federal-review-2026-11.md](herbal-healers-federal-review-2026-11.md) (which products stay eligible), [hemp-federal-deadline-2026.md](hemp-federal-deadline-2026.md) (deadline evidence), roadmap F69 (payments) and F70 (guardrails).

## Read this first: how much of this is verified

- **Almost no processor publishes its hemp/CBD terms.** Rates, reserves and contract terms are quoted per merchant. The figures below come from third-party reviews, vendor blogs and complaint sites. Many review sites earn referral fees ("advertiser disclosure"), and many "guides" are written by processors selling CBD accounts. Treat every number as a starting question, not a fact.
- **No Visa or Mastercard bulletin about December 11, 2026 was found.** The network rules cited secondhand (Visa Core Rules 1.1.1.3 / 1.5.1.4; Mastercard Rule 5.12.7) require transactions to be legal; after Dec 11 a product outside the hemp definition is federally marijuana, so acquirers will drop it ([Pulse CRM](https://pulsecrm.com/blog/federal-hemp-redefinition-cbd-merchants-acquirers-2026/), accessed 2026-11-02).
- **No source confirms any card processor will accept THCA flower, THCA concentrates, delta-8 or over-cap THC edibles after Dec 11** ([Adaptiv](https://adaptivpayments.com/blog/hemp-merchant-account), [Adaptiv on delta-8](https://adaptivpayments.com/blog/delta-8-merchant-account), [OpenGate](https://opengatepayments.com/guides/federal-hemp-ban-cbd-card-processing), [Unison](https://www.unisonpayment.com/blog/federal-hemp-definition-change-cbd-payment-processing), all accessed 2026-11-02). Any provider that says otherwise is a red flag (see [Red flags](#red-flags-funny-business)).

## What this means for Herbal Healers

- After Dec 11, the **card-eligible catalog is likely ~9 products** (THC-free CBD, topicals, pets, melatonin), not 47 — and only once their COAs are fixed (federal review, buckets (c) and (d)). Apply to processors **with that list**, not the full catalog.
- **Disclose the Square termination** on every application. Get Square's written termination reason and MATCH status first. A MATCH listing narrows options to a few specialist acquirers and is the biggest single unknown.
- **Shopify Payments must not process hemp/CBD.** The public storefront appears to tokenize Google Pay through Shopify's own gateway; check it now ([Shopify](https://help.shopify.com/en/manual/compliance/legal/hemp/payments)).

## Gateways vs processors

A **gateway** (Authorize.net, NMI, Easy Pay Direct's gateway) only moves the transaction. The **acquiring bank**, reached through an ISO or high-risk processor, decides whether hemp/CBD is allowed and on what terms.

| Gateway | Hemp/CBD position | Card-present | Rupert today |
| --- | --- | --- | --- |
| **Authorize.net** (Visa) | Usable only when connected to a merchant account underwritten for the exact products sold ([PaymentCloud](https://paymentcloudinc.com/blog/authorize-net-cbd/); [Organic Payment Gateways press release](https://prnewswire.com/news-releases/authorizenet-payment-processing-solutions-for-cbd-supplements-and-farm-bill-compliant-seeds-now-supported-by-organic-payment-gateways-302157584.html)). Authorize.net's own acceptable-use text for CBD was not found | Weak: mobile in-person SDKs deprecated (see sibling payments note) | **Built** (hosted capture, reconciliation) |
| **NMI** | Neutral; many CBD ISOs (Valmar, Easy Pay Direct, PayKings and others) board merchants on NMI | Yes, Customer Present Cloud with Lane terminals | Sandbox only; production blocked pending sign-off (F69) |
| **Easy Pay Direct gateway** | Own gateway, used for its own high-risk accounts | Not researched | Not integrated |

## Processor landscape

"CP" = card-present (in store, at shows). "CNP" = card-not-present (online, keyed). Dates are when the source was accessed unless the source shows its own date.

| Provider | Hemp/CBD now; exclusions | CP / CNP | Underwriting asks (reported) | Rates, reserves, contract (reported) | Reputation | Dec 11 stance |
| --- | --- | --- | --- | --- | --- | --- |
| **Valmar Merchant Services** (Williamsville NY, founded 2013) | Lists CBD and hemp among its high-risk sectors ([CB Insights](https://www.cbinsights.com/company/valmar-merchant-services)); exclusions not public | Both, via Authorize.net or NMI plus a PAX terminal (per Rupert's provider catalog) | Not public | Not public | **No independent reviews found** (profile unclaimed). Neither good nor bad evidence | Not public; ask in writing |
| **PaymentCloud** (Encino CA) | Accepts CBD; widely cited for CBD on Authorize.net | Both | COAs, product list, processing statements, site review | Reported 3.8% + $0.30 online and 4.4% + $0.15 keyed for CBD ([FitSmallBusiness](https://fitsmallbusiness.com/paymentcloud-review/)); reserves case by case, ~10% average reported ([Merchant Maverick](https://www.merchantmaverick.com/reviews/paymentcloud-review)); says "no ETF" but complaints report one | **Mixed:** [BBB complaints](https://www.bbb.org/us/ca/encino/profile/payment-processing-services/payment-cloud-llc-1216-924639/complaints) include an undisclosed early-termination fee; a 2026 Trustpilot complaint describes a move to 100% reserve then termination with funds held ([Trustpilot](https://pt.trustpilot.com/review/paymentcloudinc.com)) | Not found |
| **Easy Pay Direct** | Accepts CBD/hemp ([EPD CBD page](https://easypaydirect.com/merchant-accounts/cbd-hemp-merchant-accounts/)) | Both (gateway + NMI) | Established volume preferred | Reported $0 ETF on domestic accounts ([CardPaymentOptions](https://cardpaymentoptions.com/credit-card-processors/easy-pay-direct)); most contracts reportedly 3 years and offshore accounts often carry ETFs ([Merchant Maverick](https://www.merchantmaverick.com/reviews/easy-pay-direct-review)); terms not published | **Fairly good:** 4.1/5 at Merchant Maverick; under 10 online complaints per CardPaymentOptions. One Nov 2025 Trustpilot review describes closure and held funds by its acquirer (Maverick Payments) over disputed document requests ([Trustpilot](https://de.trustpilot.com/review/www.easypaydirect.com)) | Not found |
| **Bankful** | Underwrites hemp/CBD; strict on licences and THC documentation; Shopify names it for hemp ([Shopify](https://help.shopify.com/en/manual/compliance/legal/hemp/payments)) | CNP (Shopify-compatible gateway, hosted payment page) | COAs, product specs, legal docs, ingredient lists and labels, manual review ([Bankful blog](https://bankful.com/?p=10202)) | Not public | Few independent reviews found | Its blog warns THC products remain restricted and requirements may change |
| **DigiPay** | Shopify names it for hemp; in-house underwriting | CNP (Shopify) | Application + underwriting, days to weeks | Promotional "from 0.60%" claim (unreliable); reserves not public ([folio3](https://ecommerce.folio3.com/blog/cbd-payment-processor-shopify/)) | No independent reviews found | Not found |
| **Soar Payments** | Its CBD page now leads with **eCheck**, not cards ([Soar](https://www.soarpay.com/industry/cbd/)). An unverified sales deck describes a Merrick Bank CBD **card-present-only** retail program with holds for breaching CP limits | eCheck; CP program unverified | Bank statements, financials for high volume | Not public | Merchant Maverick review exists ([link](https://www.merchantmaverick.com/reviews/soar-payments-review)) | Not found |
| **PayKings** | Accepts CBD (marketing) | Both | — | Not public | **Mixed:** no BBB rating; complaint themes of held funds and freezes ([Merchant Maverick](https://www.merchantmaverick.com/reviews/paykings-review/), [TheFinRate](https://thefinrate.com/paykings-is-a-scam-an-investigated-story/), unverified) | Not found |
| **eMerchantBroker (EMB)** | Accepts CBD; was one of Shopify's early CBD partners | Both | — | Not public | Claims A+ BBB (unverified); mostly positive informal reviews, latest negative one mentions held funds ([CardPaymentOptions](https://www.cardpaymentoptions.com/credit-card-processors/emerchantbroker-com/)) | Not found |
| **Durango Merchant Services** | High-risk ISO with multiple bank partners; CBD with restrictions (source is from 2019) ([SMB Compass](https://www.smbcompass.com/?p=166067)) | Both | — | Not public | No current data found | Not found |
| **Payroc / North** | Payroc is described as a high-risk/cannabis-adjacent processor (listicles only). **North reportedly reopened its CBD vertical for CP and CNP on 2026-04-01** ([Verifee](https://verifee.com/resources/cbd-processing-is-back-on-the-menu-for-north/)) | Both (reported) | — | Not public | — | Not found |
| **Pay-by-bank: Green.Money, Seamless Chex, Aeropay** | Not card networks, so Visa/MC rules don't apply; still need compliant products. Green.Money explicitly underwrites CBD ([green.money](https://www.green.money/)) | Mostly online; Aeropay has in-store QR | — | Seamless Chex API only on large plans | — | Federal law still applies to the products |
| **Out:** Square, Shopify Payments, Stripe, PayPal | Square exited CBD/hemp (Oct 15 removal deadline); Shopify Payments and PayPal prohibit; Stripe prohibits edibles and over-limit products ([deadline doc](hemp-federal-deadline-2026.md)) | — | — | — | — | Already out |

**Precedent for sudden exits:** in March 2019 Elavon (U.S. Bank) stopped new CBD applications and gave existing CBD merchants about 45 days ([Easy Pay Direct, 2019-03-19](https://www.easypaydirect.com/blog/elavon-cbd-merchant-account-news/)). Plan for any acquirer to leave the category on short notice; keep a second processor and cash ready.

**Typical high-risk economics** (general, not provider-specific): 3.5–5.5% per transaction for CBD, rolling reserves around 5–10% held 90–180 days, monthly gateway and PCI fees, 1–3 week underwriting ([OpenGate](https://opengatepayments.com/guides/federal-hemp-ban-cbd-card-processing), [Payment Nerds](https://paymentnerds.com/blog/cbd-oil-merchant-account-requirements-acceptance-2026/), accessed 2026-11-02).

## Ranking for Herbal Healers

1. **Valmar, on Authorize.net (online) and a PAX terminal (in store).** Already in progress, and Rupert's Authorize.net path is built. No public reviews either way, so the protection is the contract: get the **approved product categories, reserve, fees, term and ETF in writing** before going live. Apply with the post-Dec 11 eligible list.
2. **A second, established ISO in parallel: Easy Pay Direct first, PaymentCloud second.** Both board CBD on gateways Rupert supports (NMI, Authorize.net). Easy Pay Direct has the better reputation evidence and reportedly no domestic ETF; PaymentCloud is widely used but has documented complaints about ETFs and reserves. Insist on month-to-month or a written ETF of $0.
3. **Bankful for the Shopify storefront.** Shopify names it for hemp; hosted payment page keeps card data out of Rupert. Strict documentation is a plus for "no funny business" — it forces the COA clean-up the federal review calls for.
- **Backup tenders:** cash (works in Rupert today) and a pay-by-bank option (Green.Money) for subscriptions and wholesale.
- **Not recommended now:** any provider promising THCA, delta-8 or over-cap THC edibles after Dec 11; offshore placements; Square in any form for hemp.

## Red flags ("funny business")

**Contract terms**
- Contracts over 12 months that **auto-renew**, especially with **liquidated-damages ETFs** (fees equal to estimated future processing revenue).
- "No ETF" from the ISO while the **back-end processor agreement** has one. Ask for every signed document, not a summary.
- **Non-cancellable terminal leases** (often 48 months). Buy the terminal or use a processor-owned rental you can return.
- Monthly minimums, "PCI non-compliance" fees, annual or "regulatory" fees not on the quote; **tiered** (qualified/non-qualified) pricing instead of interchange-plus.

**Reserves and holds**
- No written cap on the reserve, or no stated **release date** for reserved funds.
- Termination clauses that let the processor hold **100% of funds for 180+ days** (reported in PaymentCloud complaints).
- Holds triggered by unanswered document requests: answer within the stated window and keep proof of sending.

**Things that end in MATCH**
- Offers to use a **different MCC**, a generic descriptor or a "nutraceutical" label to hide CBD.
- **"Cashless ATM"** or PIN-debit workarounds.
- Processing products the account wasn't approved for (the likely Square trigger).
- **Load balancing** across several merchant accounts, or a new account opened to get around a termination.

## Questions to put to every processor (in writing)

1. Which of our products are approved? Send the approved list on letterhead. What happens to approval on Dec 11?
2. Acquiring bank name, MCC and the exact descriptor customers will see.
3. Rate, every fee, reserve % and release schedule, term, renewal, ETF, and terminal ownership.
4. How do you treat a prior Square termination and MATCH status?
5. COA requirements: per batch? maximum age? must THC be reported per container?
6. Chargeback ratio thresholds that trigger review, and the notice period before a hold or termination.

## Sources (all accessed 2026-11-02 unless dated)

- [Adaptiv: Hemp merchant account after the 2026 THC ban](https://adaptivpayments.com/blog/hemp-merchant-account); [Delta-8 merchant account: what changes Dec 11](https://adaptivpayments.com/blog/delta-8-merchant-account)
- [OpenGate: Federal hemp ban — what CBD merchants can process by card](https://opengatepayments.com/guides/federal-hemp-ban-cbd-card-processing)
- [Unison: Federal hemp definition change](https://www.unisonpayment.com/blog/federal-hemp-definition-change-cbd-payment-processing)
- [Pulse CRM: what acquirers with CBD merchants need to check](https://pulsecrm.com/blog/federal-hemp-redefinition-cbd-merchants-acquirers-2026/)
- [Evolve Payment: The federal hemp ban is a payments story](https://www.evolvepayment.com/blog/the-federal-hemp-ban-is-a-payments-story/)
- [Payment Nerds: CBD merchant account requirements 2026](https://paymentnerds.com/blog/cbd-oil-merchant-account-requirements-acceptance-2026/)
- [Shopify Help Center: payment options for hemp sales](https://help.shopify.com/en/manual/compliance/legal/hemp/payments)
- [CB Insights: Valmar Merchant Services](https://www.cbinsights.com/company/valmar-merchant-services)
- [FitSmallBusiness: PaymentCloud review](https://fitsmallbusiness.com/paymentcloud-review/); [Merchant Maverick: PaymentCloud review](https://www.merchantmaverick.com/reviews/paymentcloud-review); [BBB: PaymentCloud complaints](https://www.bbb.org/us/ca/encino/profile/payment-processing-services/payment-cloud-llc-1216-924639/complaints); [Trustpilot: PaymentCloud](https://pt.trustpilot.com/review/paymentcloudinc.com)
- [Easy Pay Direct CBD/hemp page](https://easypaydirect.com/merchant-accounts/cbd-hemp-merchant-accounts/); [Merchant Maverick: Easy Pay Direct review](https://www.merchantmaverick.com/reviews/easy-pay-direct-review); [CardPaymentOptions: Easy Pay Direct](https://cardpaymentoptions.com/credit-card-processors/easy-pay-direct); [Trustpilot: Easy Pay Direct](https://de.trustpilot.com/review/www.easypaydirect.com); [Easy Pay Direct: Elavon ends CBD accounts (2019-03-19)](https://www.easypaydirect.com/blog/elavon-cbd-merchant-account-news/)
- [Bankful blog](https://bankful.com/?p=10202)
- [folio3: CBD payment processors for Shopify](https://ecommerce.folio3.com/blog/cbd-payment-processor-shopify/)
- [Soar Payments: hemp & CBD](https://www.soarpay.com/industry/cbd/); [Merchant Maverick: Soar review](https://www.merchantmaverick.com/reviews/soar-payments-review)
- [Merchant Maverick: PayKings review](https://www.merchantmaverick.com/reviews/paykings-review/); [TheFinRate on PayKings](https://thefinrate.com/paykings-is-a-scam-an-investigated-story/)
- [CardPaymentOptions: eMerchantBroker](https://www.cardpaymentoptions.com/credit-card-processors/emerchantbroker-com/)
- [SMB Compass: Durango CBD merchant account (2019)](https://www.smbcompass.com/?p=166067)
- [Verifee: CBD processing back on the menu for North](https://verifee.com/resources/cbd-processing-is-back-on-the-menu-for-north/)
- [PaymentCloud: Authorize.net and CBD](https://paymentcloudinc.com/blog/authorize-net-cbd/); [Organic Payment Gateways press release](https://prnewswire.com/news-releases/authorizenet-payment-processing-solutions-for-cbd-supplements-and-farm-bill-compliant-seeds-now-supported-by-organic-payment-gateways-302157584.html)
- [Green.Money](https://www.green.money/)
