# Website partner-readiness audit (2026-11-02)

What a payment processor (ISO), terminal maker or prospective merchant checks when vetting Rupert as an integrated POS
vendor, compared with what rupertpos.com showed on November 2, 2026. Screenshots are in
[website-partner-readiness-2026-11-02](website-partner-readiness-2026-11-02/).

## What serves what

- `rupertpos.com/` is the Rails landing page, generated from `docs/index.html` by `bin/build-product-site`. Every other
  path on rupertpos.com redirects to `pos.rupertpos.com`, where `PublicPagesController` serves the policy pages.
- `techmore.github.io/rupert/` (GitHub Pages, `docs/`) holds the product guides and roadmap.

## Checklist

| Expectation | Source | Before | After this change |
| --- | --- | --- | --- |
| Business name and description of what is sold | Stripe activation FAQ; Stripe website checklist | Name only in privacy policy and pricing notes | Footer company line; support page "Who runs Rupert" |
| Customer service contact: more than one method | Stripe website checklist | Email only | Email plus phone and hours fields (placeholders until set) |
| Business address, not a PO box | Visa, *Providing the proper location of your merchant business*; Stripe checklist | None | Address field on support and terms (placeholder until set) |
| Refund and cancellation policy, readable before paying | Stripe checklist and FAQ | None; checkout asked customers to accept unpublished "billing terms" | `/refunds` draft, linked from pricing and checkout |
| Terms of service, acceptable use | Stripe checklist (terms of promotions, legal restrictions) | None | `/terms` draft with acceptable use, linked from footer and checkout |
| Privacy policy | Stripe checklist | Yes | Unchanged, now links the other policies |
| Security of payment data | Stripe checklist; PCI SSC FAQ 1588 and 1604 | One landing paragraph | `/security`: card data path, PCI scope, encryption, hosting, backups, access |
| No unverifiable claims | — | None found on the landing page | `/security` states that no PCI DSS attestation or SOC 2 report is held |
| Integrations page | Partner expectation | Link to the GitHub Pages overview | `/integrations` with Available / Partial / Planned per connection; terminals listed as planned without naming a partner |
| HTTPS | Stripe checklist | Valid Let's Encrypt certificate, HSTS, strong headers | Unchanged |
| Accessibility basics | WCAG 2.2 | Skip link, alt text, semantic headings, no horizontal scroll at 375 px | Policy pages reuse the app's accessible layout; nav labels no longer wrap at 375 px |
| Uptime / status | Partner expectation | No status page | Stated plainly; placeholder for a status link |
| Domain email | Partner expectation | Google Workspace MX and SPF | Unchanged; DMARC missing (owner) |
| Metadata | — | Title, description, canonical | Adds Open Graph description, image and Twitter card |
| Customers and their compliance details kept private | Owner instruction | Roadmap text described one merchant's payment status | Roadmap text neutralized; operator guides still need an owner decision |

## Sources

- Stripe, [Website checklist](https://docs.stripe.com/get-started/checklist/website) and
  [Business website for account activation FAQ](https://support.stripe.com/questions/business-website-for-account-activation-faq).
- Visa, [Providing the proper location of your merchant business](https://ae.review.visa.com/content/dam/VCOM/global/support-legal/documents/providing-the-proper-location-of-your-merchant-business-vbs.pdf):
  a PO box or mail-forwarding address is not a merchant location; card-absent sales use the principal place of business.
- PCI Security Standards Council, [FAQ 1588](https://www.pcisecuritystandards.org/faqs/1588) (SAQ A script criterion
  for pages that embed a provider's payment iframe; requirements 6.4.3 and 11.6.1) and
  [FAQ 1604](https://www.pcisecuritystandards.org/faqs/1604) (ASV scans apply to iframe merchants).
- iPOSpays / Dejavoo, [SPIn specification](https://docs.ipospays.com/spin-specification): semi-integrated, card data
  stays on the terminal. Its "eliminates PCI compliance" wording is the vendor's and is not repeated on Rupert's pages.
- W3C, [WCAG 2.2](https://www.w3.org/TR/WCAG22/), W3C Recommendation, 12 December 2024.
- Not reachable on November 2: Dejavoo's SPIn marketing page (DNS failure) and Helcim's card-brand website summary (404).
