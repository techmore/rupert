# Rupert security and data-handling overview

For payment partners (ISOs, processors, terminal providers) evaluating Rupert as an integrated POS.

Prepared: 2026-11-02 · Product version: `[CONFIRM: release or build shown in the app footer]`

> **Placeholders.** Text in `[CONFIRM: …]` must be filled in or confirmed by the owner before this document is shared. Everything else describes the system as built and tested on the date above.

## 1. Company and contacts

| | |
| --- | --- |
| Vendor (legal name) | `[CONFIRM: legal entity name, state of formation]` |
| Address | `[CONFIRM]` |
| Security contact | `[CONFIRM: name, email, phone]` |
| Cyber / tech E&O insurance | `[CONFIRM: carrier, policy type, limits, expiry — or "none"]` |
| Merchant reviewed | `[CONFIRM: merchant name and MID(s), shared privately]` |

## 2. Summary

Rupert is a point-of-sale and back-office application: register, inventory, sales history, reconciliation, staff time and bookkeeping. **Rupert is not a payment gateway or processor, and it does not store, process or transmit cardholder data.** Card numbers are entered into the processor's terminal or the processor's hosted payment form. Rupert receives only payment tokens, transaction ids, amounts, approval results and, where a processor report provides it, card brand and last four digits.

**Certifications.** Rupert has **not** been assessed by a QSA. It holds no PCI DSS Attestation of Compliance (AOC) or Report on Compliance, is not listed under any PCI SSC program (Secure Software, P2PE), and has no SOC 2 report or ISO 27001 certificate. The statements below describe design and testing, not a certification.

## 3. How payment data flows

| Channel | Where the card is read | What Rupert receives | Status |
| --- | --- | --- | --- |
| In-store, standalone terminal | Processor-supplied terminal, run separately | Tender "card (terminal)" and amount, recorded by staff | In use |
| In-store, semi-integrated terminal (e.g. Dejavoo) | Terminal; card data goes directly to the processor | Amount and reference out; approval result, transaction id, brand, last four and token back | `[CONFIRM: planned / in development; target date]` |
| Register customer display (card not present) | Authorize.net hosted payment form (AcceptUI) | One-time payment token, then transaction id and result | Available when the merchant's gateway is connected |
| NMI hosted fields (Collect.js) | NMI iframes | One-time token | Sandbox only; production disabled |
| Processor reports (Authorize.net, SwipeSimple, NAB/IRIS) | n/a | Settled amounts, transaction ids, brand, last four, cardholder name where the report includes it | Read-only imports |

Controls that keep card data out:

- **Architecture.** Card fields are processor iframes or a processor-hosted form; Rupert's own forms contain no card inputs. Payment tokens are single-use and are stored only as a SHA-256 digest (to stop a token being submitted twice).
- **Backstop redaction** (code in `web/app/services/card_data.rb`). Any card number (13–19 digits, Luhn-checked), magnetic-stripe track data or labelled security code is removed from application logs, error reports, stored operations events, bug reports, team chat messages and text sent to AI assistants. Card-related parameter names (`cardNumber`, `cvc`, `pan`, `track2`, …) are filtered from request logs.
- **Imports refuse card numbers.** A processor export whose card columns hold more than the last four digits is rejected whole and not stored.
- **Tests** push test card numbers and track data through requests, errors, logs, chat and imports and fail if any of it survives (`web/test/services/card_data_test.rb`, `web/test/integration/card_data_logging_test.rb`).

Rupert does store payment gateway API credentials that the merchant enters (encrypted, see §5). Those can start refunds or charges through the gateway, so they are treated as secrets. Merchants should issue Rupert its own credentials, so they can be rotated without affecting other systems.

## 4. PCI DSS scope

**Rupert's position.** Rupert does not store, process or transmit account data. It does host web pages that load the processor's payment form, and it sends amounts to integrated terminals. A merchant may therefore list Rupert as a third-party service provider that *could affect* the security of payments (PCI DSS v4.0.1 Requirement 12.8). Rupert will acknowledge in writing which requirements it is responsible for (12.9) `[CONFIRM: owner agrees to sign a TPSP acknowledgement]`.

**Likely merchant SAQs.** The acquirer decides; these are typical outcomes.

| Merchant setup | Typical SAQ |
| --- | --- |
| Standalone or semi-integrated terminal on a PCI-listed P2PE solution | SAQ P2PE |
| Standalone or semi-integrated terminal, IP-connected, not P2PE | SAQ B-IP |
| Standalone dial-out terminal | SAQ B |
| Card-not-present payments through the processor's hosted form or iframes only | SAQ A |

A merchant using both terminals and online payments may need more than one SAQ. `[CONFIRM with Dejavoo / Valmar: is the proposed terminal and key-injection setup a PCI-listed P2PE solution?]`

**Responsibility matrix (summary).**

| Area | Rupert | Merchant | Processor / terminal provider |
| --- | --- | --- | --- |
| Card capture, encryption, authorization | none | Use approved terminals and hosted forms only | Yes |
| Integrity of Rupert pages that load the payment form | Yes | — | Hosted form itself |
| Rupert accounts, roles and sign-in | Platform controls | Assign roles, remove leavers | — |
| Gateway credentials stored in Rupert | Encrypt and restrict | Issue dedicated credentials, rotate | Credential scope |
| Terminal inventory, tamper checks (Req. 9.5) | — | Yes | Supplies devices |

## 5. Application security

**Sign-in and sessions.**

- Two ways to sign in: Google sign-in, or email and password. Passwords are stored as bcrypt hashes and must be at least 8 characters.
- Rupert has no built-in second factor. Owners and admins can use Google sign-in, so MFA follows their Google account policy `[CONFIRM: MFA is enforced on every owner/admin Google account]`.
- Failed logins are limited per account and per address (5 per account and 10 per address in 15 minutes, then a 15-minute lockout), with request-rate limits in front.
- Session cookies are encrypted and signed, and marked `Secure`, `HttpOnly` and `SameSite=Lax`. The session is replaced at sign-in and expires after 14 days without use.
- A password change ends all other sessions. A deactivated user is signed out on their next request.
- Sensitive actions (creating a backup key) require a sign-in within the last 15 minutes.

**Roles.**

- Nine roles: super admin, admin, manager, shift leader, cashier, inventory, reporting, reader and employee.
- Each role has a permission matrix. Admins can adjust permissions per role or per person. The employee role always keeps its fixed, limited list.
- Policy objects check every controller action. Employees are limited to an allow-list of screens.
- Only admins can manage accounts and roles, and only a super admin can grant admin rights.

**API and support access.**

- API and assistant (MCP) tokens are shown once and stored as SHA-256 digests. They are scoped, can expire, are rate-limited and lose access as soon as the issuing user's permission is removed.
- Vendor support access needs a grant from the merchant. The grant lasts at most 24 hours, can be revoked and is logged.

**Multi-tenant isolation.** Every business record carries its workspace id. A model-level default scope limits every query to the signed-in workspace and assigns the workspace on create. Workspace hostnames are enforced at sign-in. Automated tests check isolation across workspaces, admins and API/MCP tools. A merchant can also run on a dedicated, isolated instance `[CONFIRM: offered]`.

**Web protections.**

- Rails CSRF protection is on.
- A Content Security Policy is set: `object-src 'none'`, framing limited, and form targets restricted to HTTPS.
- Inbound webhooks are verified by signature (Authorize.net HMAC-SHA512, Shopify HMAC) before anything is queued.

## 6. Data protection

- **In transit.**
  - TLS 1.3 with Let's Encrypt certificates.
  - HSTS for 2 years, including subdomains.
  - The application forces HTTPS. All outbound calls to processors and platforms use HTTPS.
- **At rest.**
  - Field-level encryption (Active Record encryption, AES-256-GCM) covers stored credentials and tokens, uploaded financial documents, raw import files, payroll amounts, tax ids, personal staff details and chat messages.
  - Production refuses to start without its encryption keys. Keys live in a root-only environment file on the server and never in source control.
  - The database file and host disk: `[CONFIRM: full-disk encryption on the production host — yes/no]`.
- **Secrets.**
  - Merchant credentials (gateway, platform and bank-report logins) are entered in the app, stored encrypted and never shown again in full.
  - The public repository has GitHub secret scanning and push protection enabled.
- **Backups.**
  - The full database is copied every 5 minutes (kept 2 hours), then hourly (kept 24 hours), plus 6-hourly sets kept about 8 days.
  - Encrypted copies go off the container and to a second machine.
  - Every backup is encrypted with [age](https://age-encryption.org) before it is written. The private key exists only in the owner's offline recovery kit, so a stolen backup cannot be read.
  - A weekly job checks that the copies are intact. A restore drill is defined for monthly runs and after each key rotation.
  - Last successful restore test: `[CONFIRM: date]`.

## 7. Logging and audit trail

- **Structured request log.** One JSON line per request records who, which workspace, what action, status and timing. **Values are never logged**: no parameter values, bodies, cookies, card or bank numbers, tokens or email addresses. Error text is redacted (see §3).
- **Retained records.**
  - Sign-in attempts (access log): 2 years.
  - Business actions (activity log): 7 years.
  - Support-access, approval, timesheet and stock-request events are kept in their own audit tables.
- **System page.** Recent errors, denials and sign-in failures for operators (14 days).
- **Host log.** Capped at 30 days and 400 MB.

## 8. Secure development and change management

- **Every pull request and every merge to `main`** runs:
  - the test suite (about 3,700 tests)
  - Brakeman static analysis, which fails on any new warning
  - bundler-audit for vulnerable gems
  - shellcheck on deploy scripts
- **Security scan schedule.** The security scan also runs weekly. Dependabot opens weekly dependency updates.
- **Pinned CI.** GitHub Actions are pinned to commit SHAs.
- **Protected `main`.** It requires passing checks and applies to admins. Force pushes are blocked.
- **Deploy.**
  - Production deploys only a commit whose CI passed.
  - A database backup is taken first, and the deploy is health-checked after.
  - If the health check fails, the previous build is restored automatically.
- **Review policy.** `[CONFIRM: second-person review policy — currently a single maintainer]`.
- **Past security reviews** are kept in `docs/audits/maintenance/security/`. No external penetration test has been performed `[CONFIRM / planned date]`.

## 9. Incident response

The process runs in five steps:

1. **Detect.** Signals come from the System page error and denial counts, sign-in failure events, backup and deploy health checks, and reports to the security contact.
2. **Contain.** Revoke sessions and API tokens, disable the affected integration, pause automatic deploys, roll back, and rotate gateway and platform credentials.
3. **Assess.** Use the request and activity logs to find which workspaces, records and credentials were affected.
4. **Notify.** Tell affected merchants within `[CONFIRM: 72 hours]` of confirming an incident that affects their data, and help them make any notices required by their acquirer, the card brands or law.
5. **Review.** Write up the root cause and fixes. Keep the evidence for at least `[CONFIRM: 1 year]`.

Incident owner and backup: `[CONFIRM: names, phone]`. A written, rehearsed incident plan is being formalized `[CONFIRM: date]`.

## 10. Data retention and deletion

| Data | Retention |
| --- | --- |
| Business records (sales, inventory, books) | Life of the account; exported or deleted at the merchant's request `[CONFIRM: deletion SLA after termination]` |
| Sign-in log / activity log | 2 years / 7 years |
| Mirrored inventory movements / ledger mirror / sync attempts | 180 days / 1 year / 90 days |
| Webhook deliveries | 30 days |
| Assistant chats | Per workspace setting |
| Backups | About 35 days, then deleted |
| Card data | Never stored |

Shopify customer and shop redaction requests are honored automatically.

## 11. Sub-processors

| Service | Purpose | Data involved |
| --- | --- | --- |
| Production hosting `[CONFIRM: owner-operated server; location; front-proxy/VPS provider]` | Runs Rupert and its database | All workspace data |
| DNS `[CONFIRM: provider]` | Name resolution | None |
| Let's Encrypt | TLS certificates | None |
| GitHub | Source code, CI | No merchant data |
| Google | Sign-in (Google accounts) | Name and email of users who choose it |
| OpenCode `[CONFIRM: underlying model provider and its data-retention terms]` | Optional AI assistant | The questions asked and the records looked up, after redaction; only if the merchant enables it |
| Stripe | Rupert subscription billing | Workspace owner billing details (not merchant customer cards) |
| Email delivery | None in production today `[CONFIRM: provider if added]` | — |

The merchant connects its own processor, terminal, e-commerce and reporting accounts (for example Authorize.net, NMI, Shopify, Square, C-Trax, SwipeSimple, NAB/IRIS). Those are the merchant's providers under the merchant's own agreements, not Rupert sub-processors. Error tracking (Sentry) is supported but not enabled.

## 12. Vulnerability disclosure

Report privately through GitHub's private vulnerability reporting on the repository, or to `[CONFIRM: security email]`. The policy, response targets and safe-harbor terms are in [`SECURITY.md`](../../SECURITY.md).

## 13. Owner confirmation checklist

Fill these in before sharing:

- [ ] Company name, address, security contact (§1, §9, §12)
- [ ] Insurance (§1)
- [ ] Hosting, DNS and AI sub-processor details and contracts (§11)
- [ ] Disk encryption on the production host (§6)
- [ ] Date of the last successful restore drill (§6)
- [ ] MFA enforced on owner and admin Google accounts (§5)
- [ ] Semi-integrated terminal status and P2PE listing (§3, §4)
- [ ] TPSP acknowledgement, breach-notice window, deletion timeline (§4, §9, §10)
