# Hemp/CBD card processing: merchant onboarding checklist

**For the merchant.** Use this when applying to a hemp/CBD-underwriting processor (an ISO on the Authorize.net or NMI gateway) so Rupert can take cards in store and online. Written November 2, 2026 for roadmap F69 ([#601](https://github.com/techmore/rupert/issues/601)).

This is not legal or financial advice. Which products you may sell, ship or card-process after **November 12** and **December 11, 2026** is a decision for your own attorney. See [the federal deadline summary](hemp-federal-deadline-2026.md).

## Before you apply

- [ ] **Previous processor, in writing.** If an account was closed (for example Square), get the reason, the date any held funds or reserve will be released, and whether the account was reported to the MATCH/TMF list. Every application asks about prior terminations. Answer honestly: a MATCH listing changes which processors will accept you, and hiding it can end card acceptance everywhere.
- [ ] **Counsel's product list.** Ask your attorney which products stay federal "hemp" after December 11, 2026 (total THC including THCA at most 0.3%; at most 0.4 mg total THC per container; no synthesized cannabinoids). Apply only for that list, so the approval survives the deadline.
- [ ] **Never miscode.** Do not describe products, categories or the business differently from what you sell, and never ask for a different merchant category code (MCC). The processor assigns the MCC.

## What to send the processor

| Item | Notes |
| --- | --- |
| Business documents | Legal name, EIN letter, business license or registration, owner ID(s), voided business check or bank letter. |
| Processing history | Last 3 to 6 months of card processing statements, if you have them. New or previously terminated merchants should say so. |
| Bank statements | Usually the last 3 months of business bank statements. |
| **Product list** | One row per product you want to card-process: product name, SKU, category, size, cannabinoid content per container (mg CBD, mg total THC), price. Export it from Rupert's catalog so names and SKUs match what the register charges. |
| **COAs** | A current third-party lab Certificate of Analysis for every product and batch, showing total THC (including THCA) and cannabinoid profile. Link each COA from the website product page. |
| Website | URL. The processor reviews it. Before review, make sure it has: age gate (21+) if you sell anything intoxicating; no medical or health claims ("cures", "treats", "relief from"); the FDA disclaimer; terms, privacy, refund and shipping policies; contact details; COA links on product pages; a list of states you do not ship to. |
| In-store details | Store address, photos if requested, expected average ticket and monthly volume, card-present vs online split. |
| Hardware | Ask which terminal they supply and whether it runs on the **same gateway account** as online payments (it makes settlement reconciliation in Rupert simpler). |

## Questions to ask the processor

- [ ] Which **gateway**: Authorize.net or NMI? Rupert supports both.
- [ ] Exactly which **products and categories** are approved, and which are excluded? Get it in writing (email is fine). You will enter this list in Rupert.
- [ ] Will approval continue after **December 11, 2026**? What happens to products that stop qualifying?
- [ ] Rates, reserve, payout schedule, monthly fees, early-termination fee.
- [ ] Are online (card-not-present) and in-store (card-present) sales both covered? Subscriptions?
- [ ] For Authorize.net: will they enable the **Transaction Details API** and **Accept.js / Accept Hosted**? For NMI: will they enable **Collect.js** tokenization and the **Query API**?

## When you are approved, send Rupert's administrator

Send credentials only through Rupert's encrypted setup form or a password manager share. **Never by email, chat or GitHub.**

- **Authorize.net:** API Login ID, Transaction Key, Signature Key (for webhooks), Gateway ID, and the approved product list.
- **NMI:** private API security key, public tokenization key (Collect.js), webhook signing key, the merchant company name exactly as shown in the NMI profile, and the approved product list.
- The approval email (date and reference), so it can be recorded against the approved list.

## Ongoing

- Ring up only approved products on card. Rupert blocks the rest and tells the cashier to take cash or remove the item.
- Before adding a product to the card-approved list, get the processor's OK and a COA.
- Keep COAs current for each new batch.
- Review Rupert's card settlement check weekly for differences.
