# Hemp/CBD card payments: admin setup (F69)

Implemented November 2, 2026 for [#601](https://github.com/techmore/rupert/issues/601). This guide is for the Rupert administrator setting up card payments for a hemp/CBD store on a processor that underwrites hemp (an ISO on **Authorize.net** or **NMI**). The merchant's side is in the [onboarding checklist](../compliance/hemp-payments-onboarding-checklist.md).

Not legal advice. Rupert enforces the product list the merchant and its processor approved; it does not decide product legality. Keep real merchant IDs, keys, statements and approval letters out of this public repository.

## What Rupert does

| Area | Authorize.net | NMI |
| --- | --- | --- |
| In-store card, customer-entered | Customer types the card on the paired customer screen in Authorize.net's hosted form (Accept). Rupert gets a one-use token, never the card number. | Same, with NMI Collect.js hosted fields. |
| In-store card, processor terminal | Run the card on the processor's standalone terminal, then record it with the terminal card tender (shown as **Card (A920)** today). No gateway call. | Same. |
| Online | Rupert's own online checkout (vendor/warehouse links) charges through Authorize.net. A Shopify storefront uses Shopify's own third-party gateway settings, not Rupert (see below). | Not wired to Rupert's online checkout. |
| Refund and void | From the receipt: void before settlement (whole sale), refund after (part or all). | Same. |
| Receipts | Card brand, last four, approval code, gateway reference, refunds. Taken from the gateway's verified record. | Same. |
| Declines | Short customer-safe reason (issuer declined, CVV, expired, insufficient funds, held for review). | Same. |
| Uncertain outcomes | A lost response stays "needs verification". Rechecks are read-only; nothing is resent. A scheduled sweep and webhooks recheck automatically. | Same. |
| Webhooks | Signed with the Signature Key (HMAC-SHA512). | Signed with the webhook signing key (HMAC-SHA256 of nonce.body). |
| Settlement check | Settled batches vs Rupert card sales and refunds. | Same, from Query API settle actions. |
| Approved products | Per-processor list of SKUs and categories. Unlisted items are refused on that processor. | Same. |

**Not built:** integrated EMV/PAX terminal control (the terminal and Rupert don't talk to each other; F57), NMI for Rupert's online checkout, and enforcing the approved list inside Shopify's own checkout.

## 1. Approved products (do this first)

Open **Processor-approved products** from any store's Checkout setup page (`/processor_catalogs`). Needs settings, sales and inventory write permissions.

1. For the processor in use (Authorize.net, NMI, or the standalone card terminal), add the **approved categories** and/or **approved SKUs**, one per line, exactly as the processor approved them. Use **excluded SKU** for a product inside an approved category that the processor did not approve (for example a full-spectrum item).
2. Enter the **processor approval reference** (for example "ISO approval email 2026-11-20") and tick **Enforce**. Rupert records who approved it and when.
3. Open "N of M current register products would be refused" and check the list. Anything listed there will be blocked at the register on that processor.

Once enforced, an unlisted item is refused when the cashier prepares a card checkout, again just before the charge, and at online checkout. The cashier is told which item and to take cash or remove it. Rupert only suggests another card processor if that processor's own enforced list approves the item. It never routes a refused item to an unrestricted processor.

Matching ignores letter case and extra spaces. Categories are matched against the C-Trax category on the register and the Shopify product type online. **Prefer SKU entries** where you can: they match the same way everywhere, including the F70 locked catalog (whose category is the owner-approved compliance category, not the C-Trax one). Until a follow-up makes the payment check read the locked catalog's approved category, category entries on a locked store should use names that match both. Products with neither a SKU nor a category are refused on an enforced processor. Every change is in the activity log.

For other guardrails (COA, custom items, event mode), F70 adds rules to the same check (`Payments::ItemEligibility.register_rule`), so every tender path gives the same answer.

## 2. Authorize.net

Open the store's **Checkout setup** (`/pos_settings/<store>`).

1. Choose **Authorize.net**, environment **Sandbox** first. Save.
2. Enter the **API Login ID** and **Transaction Key** (Authorize.net: Account → Settings → API Credentials & Keys) and the **Gateway ID**. Save. Keys are encrypted and never shown again.
3. **More → Check gateway.** Rupert confirms the Gateway ID, USD and the public client key, and that a production account is not in test mode.
4. Tick **Enable card charges** and save.
5. **Webhooks (recommended):** in Authorize.net, Account → Settings → Webhooks, add the webhook URL shown on the setup page, subscribed to `net.authorize.payment.authcapture.created`, `.void.created`, `.refund.created`, `.fraud.held`, `.fraud.approved` and `.fraud.declined`. Generate a **Signature Key** (Account → Settings → API Credentials & Keys) and paste it into the setup page. A new Signature Key replaces the old one for all integrations on that account, including Rupert's read-only reporting connection; update both.
6. Run the sandbox acceptance (below). Then switch the environment to **Production**, enter the production keys, check and enable again.

Rupert's own online checkout uses the Authorize.net credentials saved on the **Valmar** connection (POS & payment connections), or the legacy settings values. Use the same merchant account.

## 3. NMI

1. Choose **NMI**, environment **Sandbox**. Save. Enter the private **security key**, public **tokenization key**, the **merchant company** exactly as the NMI profile shows it, and the Gateway ID. Save, **Check gateway**, enable.
2. Webhooks: in NMI, Settings → Webhooks, add the setup page's webhook URL for `transaction.sale.*`, `transaction.void.*` and `transaction.refund.*`, and paste the **signing key** into Rupert.
3. **Production needs owner sign-off.** An admin chooses **Production**, ticks the confirmation that the processor approved this merchant account for the listed products, and writes who approved it and when. Changing the environment, provider or Gateway ID clears the sign-off. Then enter production keys, check and enable.

Rupert uses NMI's Payment API (`transact.php`) and Query API (`query.php`) on `sandbox.nmi.com` or `secure.nmi.com`, and Collect.js from the same host. If the ISO gives a white-label gateway address instead, confirm with NMI that the keys work on `secure.nmi.com` before going live.

## 4. Refunds and voids

On the receipt (`/pos_checkouts/<id>`), **Void or refund** with an amount and a reason (needs sales write permission). Rupert asks the gateway for the payment's status:

- **Not settled yet** (usually same day): only the whole sale can be **voided**.
- **Settled**: **refund** part or all, up to what is left.

The refund is recorded on the sale, so reports and books follow. Restock returned goods separately. If the gateway response is lost, the refund shows **Needs recheck**; use **Recheck refund with gateway**. Rupert never resends a refund to find out what happened. Refunds of standalone-terminal sales are done on the terminal and recorded on the order, as before.

## 5. Settlement check

**Card settlement check** (link on the setup page, `/pos_settlements/<store>`). Pick a date range (up to 31 days). Rupert reads settled batches from the gateway and lists:

- **Amount differs**, **Missing at the gateway**, **Voided or refunded at the gateway only**: investigate.
- **Not settled yet**: normal for the last day.
- **Not from a Rupert checkout**: settled at the gateway without a Rupert card checkout. If the standalone terminal runs on the same gateway account, compare this total with "Standalone terminal sales recorded in Rupert".

It is read-only.

## 6. Sandbox acceptance

Automated tests cover the gateway contracts with fixtures. To run Rupert's payment services against a **live Authorize.net sandbox** (approve, receipt, partial-void refusal, void, decline, approved-list block, online charge, settlement read):

```bash
AUTHORIZE_NET_SANDBOX_LOGIN_ID=... AUTHORIZE_NET_SANDBOX_TRANSACTION_KEY=... bin/rails test test/sandbox/authorize_net_sandbox_acceptance_test.rb
```

Use your own sandbox account (free at developer.authorize.net/hello_world/sandbox). It only contacts `apitest.authorize.net`. Refunds need a settled charge, which the sandbox produces once a day, so verify a refund the next day from a receipt in a sandbox store.

For NMI, a sandbox account from NMI or the ISO is needed; follow [the NMI checkout notes](nmi-sandbox-checkout.md).

## Shopify storefront

Shopify Payments does not support hemp/CBD. To take cards on the Shopify store, the merchant adds the approved processor as a **third-party payment provider** in Shopify (Settings → Payments) and makes sure Shopify Payments and Shop Pay are not active for those products. Rupert's approved-product list does not control Shopify's checkout: only list approved products for sale on the Shopify store.

## Troubleshooting

| Message | Meaning |
| --- | --- |
| "… can't take this item … not on the … approved list" | The approved-products list refused it. Take cash, remove it, or add it after the processor approves it. |
| "NMI production needs owner sign-off" | Record the sign-off on the setup page. |
| "Payment outcome needs verification" | Recheck from the receipt. Do not charge again until it resolves. |
| "Only the whole sale can be voided today" | The payment hasn't settled. Void it all, or refund part after settlement. |
| "Voided or refunded outside Rupert" | Someone reversed it in the gateway portal. Record the refund on the order if it isn't there. |
