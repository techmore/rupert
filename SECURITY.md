# Security policy

## Reporting a vulnerability

Please report security problems privately. Do not open a public issue.

- **Preferred:** GitHub private vulnerability reporting. Open the repository's **Security** tab and choose **Report a vulnerability**.
- **Email:** `[SECURITY CONTACT EMAIL — owner to confirm]`

Include what you found, where (URL, endpoint or file), how to reproduce it, and the impact you expect. Screenshots or a short proof of concept help.

## What to expect

| Step | Target |
| --- | --- |
| Acknowledge your report | within 3 business days |
| Initial assessment and severity | within 10 business days |
| Fix or mitigation for critical and high issues | as fast as practical; we will keep you updated |
| Public disclosure | coordinated with you after a fix ships |

We will credit reporters who want credit. There is no paid bug bounty at this time.

## Scope

In scope: this repository's application code (`web/`, `mobile/`, `ios/`), its deploy scripts (`deploy/`), and hosted Rupert workspaces under `*.rupertpos.com`.

Out of scope: third-party services Rupert connects to (payment gateways, terminals, Shopify, Square, Google). Report those to the vendor.

## Testing rules

- Use your own test workspace or a local copy. Never access, change or delete another person's data.
- Do not run denial-of-service, spam or social-engineering tests.
- Never enter real card numbers. Use the card networks' published test numbers only.
- Stop and report as soon as you see data that is not yours.

Good-faith research that follows these rules is welcome. We will not pursue legal action over it.

## Payment card data

Rupert is designed never to receive, store, log or transmit full card numbers, track data or security codes. Card entry happens in the payment processor's hosted fields or on the processor's terminal. If you find any path where card data reaches Rupert, treat it as a critical report.

See [docs/security/partner-security-overview.md](docs/security/partner-security-overview.md) for how Rupert handles data.
