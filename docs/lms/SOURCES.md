# Sources behind "How our card payments work"

Checked 2026-11-06 against official pages where they exist. Items the course could not verify are in
OPEN-QUESTIONS.md or softened to "roughly"/"check the statement".

## Flow, batches, funding
- Authorize.net batches once every 24 hours at the Transaction Cut-Off Time; default 4:00 PM Pacific, changeable;
  funding "within 2–3 business days", handled by the merchant service provider.
  https://support.authorize.net/knowledgebase/article/000001244/en-us
- (Conflicting default of 3:00 PM PST on the Merchant Interface help page.)
  https://account.authorize.net/help/Account/Settings/Business_Settings/Transaction_Cut-Off_Time.htm
- Void before settlement, refund after. https://developer.authorize.net/api/reference/features/payment-transactions.html
- Dejavoo SPIn: settlement request, tip adjustment "before the batch is settled", tip prompt when enabled for the
  TPN, card data "never touches the Host System". https://app.theneo.io/dejavoo/spin-specification/llms.txt,
  https://app.theneo.io/dejavoo/developer-central/spin-specification
- P18 listed in Dejavoo's Android P line. https://dejavoo.io/

## Online gateway and PCI scope
- Accept.js nonce (15 minutes); own-form Accept.js = SAQ A-EP; hosted form / Accept Hosted = SAQ A.
  https://developer.authorize.net/api/reference/features/acceptjs.html,
  https://developer.authorize.net/api/reference/features/accept-hosted.html
- SAQ A / A-EP / B-IP / P2PE definitions: PCI SSC "SAQ Instructions and Guidelines v4.0.1 r1" (April 2025).
- PCI DSS 3.3.1 (no sensitive authentication data after authorization), 3.4.1 (PAN masked: BIN and last four at
  most), 9.5 (POI device inventory, inspection, training). https://www.pcisecuritystandards.org/faqs/1071 and the
  PCI SSC FAQ on physically securing POI devices.

## Refunds
- Authorize.net refunds within **180 days** of settlement (not 120); last four required.
  https://support.authorize.net/knowledgebase/article/000001221/en-us,
  https://support.authorize.net/knowledgebase/article/KA-09355/en-us
- Refund visibility 5–14 days (SoFi, PayPal consumer guides).

## EMV
- US liability shift 1 October 2015; counterfeit card-present fraud; not card-not-present.
  https://www.visa.co.id/dam/VCOM/global/partner-with-us/documents/visa-liability-shift.pdf
- Contactless is EMV. https://www.emvco.com/emv-technologies/contactless/

## Fees
- Visa USA Interchange Reimbursement Fees (effective 24 October 2026): Retail credit Traditional 1.51% + $0.10,
  Traditional Rewards 1.65% + $0.10, Signature Preferred 2.10% + $0.10, Infinite Spend Qualified 2.30% + $0.10;
  CPS/Retail exempt debit 0.80% + $0.15; regulated debit 0.05% + $0.21.
  https://usa.visa.com/content/dam/VCOM/download/merchants/visa-usa-interchange-reimbursement-fees.pdf
- Regulation II cap: 21 cents + 5 basis points + up to 1 cent fraud adjustment, issuers over $10B.
  https://www.federalreserve.gov/newsevents/pressreleases/bcreg20110629a.htm
- Assessments about 0.13–0.14% (Mastercard 0.14% from April 2024; Visa 0.14% credit).
  https://www.paymentsjournal.com/no-reason-to-panic-over-mastercards-assessment-fees/,
  https://paymentcloudinc.com/blog/credit-card-assessment-fees/
- Statement anatomy and typical fees. https://www.helcim.com/guides/how-to-read-your-merchant-statement/,
  https://www.cardfellow.com/blog/7-avoidable-fees-hiding-in-your-merchant-account-statement

## Disputes
- Cardholder window about 120 days; merchant response about 30 days (Visa) and 45 days (Mastercard).
  https://www.chargebackgurus.com/blog/dont-run-out-the-clock-understanding-chargeback-time-limits
- Fees set by the acquirer, commonly $15–$40. https://chargeflow.io/blog/chargeback-fees,
  https://www.helcim.com/guides/how-to-read-your-merchant-statement/
- Compelling evidence examples. https://www.chargebackgurus.com/chargeback-guidelines-for-visa-card-transactions/

## Declines
- "Do not honor" is a generic issuer decline; do not retry at once; the cardholder contacts their bank.
  https://www.securetrust.com/blog/do-not-honor-decline-code-what-it-means-and-how-to-handle-it
- Visa merchant guidance: never complete a declined transaction. Visa Card Acceptance Guide.
- Network limits on re-attempts after declines. https://developers.tabapay.com/docs/network-authorization-best-practices

## In this repository
- `docs/ops/payment-basics.md` (roles, Valmar and Authorize.net public contacts)
- `docs/integrations/dejavoo-spin.md`, `docs/integrations/dejavoo-valmar-meeting-brief.md`
- `web/app/services/pos_provider_catalog.rb` (Square: "previous provider"), `web/app/models/pos_checkout.rb`
