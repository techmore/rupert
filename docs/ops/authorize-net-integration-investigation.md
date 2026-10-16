# Authorize.net integration investigation

Reviewed **2026-10-15, America/New_York**, against Rupert commit `9b23fcec4d93e4bca614d76d10a0747d6bb699a7` and official vendor documentation. This is a research record, not a deployment receipt. The existing connector's operator guide is [Authorize.net reporting](authorize-net-reporting.md).

## Decision and verified access

Use authenticated native portal exports immediately, preserving their capture time and search coverage. The merchant restored browser access, and native settled and unsettled Expanded CSV downloads were obtained privately during this work. Their schema was inspected without publishing records. This establishes **portal export access**, not unattended API access or continuous synchronization.

The owner deferred gateway credential work until Friday or Saturday because the Transaction Key may also serve Shopify. Do not generate, replace, rotate or retrieve a replacement key to unblock reporting. Do not email or contact vendors on the owner's behalf. No contact, payment operation, account-setting change or live API probe was performed for this investigation.

| Route | Capability | Concrete dependency | Current evidence |
| --- | --- | --- | --- |
| Native Merchant Interface | Download current search/report results | A signed-in user with reporting permissions | Native Expanded CSV schema verified |
| Existing API Login ID + Transaction Key | Supported reporting APIs; credential also has payment capability | Existing securely held credentials, correct environment, verified Gateway ID and reporting entitlement | Connector exists; live access unverified; owner deferred setup |
| OAuth `read` | Vendor-enforced read-only API access | Registered partner application, owner/admin consent and encrypted refresh credentials | Vendor-supported; initial onboarding missing from Rupert |
| Webhooks | Event-driven notification to supplement reporting | Configured endpoint and existing Signature Key; gateway authorization to register | Future option; no configuration changed |
| Scheduled report delivery | Potential separate product/account feature | Explicitly verified merchant entitlement and feed contract | Not established for this merchant portal |

## Supported reporting contract

The [Transaction Reporting overview](https://developer.authorize.net/api/reference/features/transaction-reporting.html) explicitly supports settled batches, transaction summaries, unsettled payments, transaction details, batch statistics, customer-profile transactions and merchant configuration. Rupert currently uses five methods:

| Request | Rupert purpose |
| --- | --- |
| `getMerchantDetailsRequest` | Check configured Gateway ID and merchant currency |
| `getSettledBatchListRequest` | Discover settlement batches and statistics |
| `getTransactionListRequest` | Discover payments in each batch |
| `getUnsettledTransactionListRequest` | Discover currently unsettled payments |
| `getTransactionDetailsRequest` | Read current type, status, amounts and references for each discovered/previously pending ID |

The [API reference](https://developer.authorize.net/api/reference/index.html#transaction-reporting) defines POST JSON/XML reporting at `https://api.authorize.net/xml/v1/request.api`; sandbox is `https://apitest.authorize.net/xml/v1/request.api`. List pagination allows up to 1,000 transactions per page with 1-based page offsets. A full first page does not prove completeness. `authenticateTestRequest` checks authentication, not every reporting method or historical coverage.

The [official reporting guide](https://www.authorize.net/content/dam/anet-redesign/documents/ReportingGuide_SOAP.pdf) documents a maximum 31-day settled-batch query and default previous-24-hour window. A `Z` suffix selects UTC rather than merchant local time. A midnight end time has special inclusive-day behavior. Historical batch searches cannot start before January 1 two years before the current year. Explicit backfills therefore need bounded windows and careful boundary reconciliation.

The [Transaction Details API settings help](https://account.authorize.net/helpCP/Account/Settings/Security_Settings/transaction_details_api.htm) describes reporting as an enabled account feature. Portal visibility alone cannot prove entitlement. A later authorized probe should verify merchant identity, batch listing, settled and unsettled paging, and transaction details separately, recording skipped probes when the account has no suitable data.

## Credential distinctions and checkout continuity

The [vendor's credential guide](https://support.authorize.net/knowledgebase/article/000001271/en-us) distinguishes these credentials:

| Credential | Meaning for this integration |
| --- | --- |
| API Login ID + Transaction Key | Gateway API authentication; can be shared across integrations; not intrinsically read-only |
| Portal username/password | Interactive Merchant Interface authentication; not a substitute API credential |
| Gateway ID | Merchant identity check, not authentication |
| Public Client Key | Client-side Accept integration, not reporting authentication |
| Signature Key | Integrity validation for responses/webhooks, not a substitute reporting key |
| OAuth client ID/secret and merchant refresh token | Separate application delegation; not a portal password or gateway Transaction Key |

The existing Transaction Key is shown only when generated. Generating another expires the previous key immediately if selected, otherwise in 24 hours. An overlap does not preserve checkout indefinitely. Reusing an existing authorized copy does not itself rotate it, but Rupert must continue restricting methods because the underlying key can process payments. The merchant's exact Shopify credential dependency remains unverified.

## OAuth onboarding and refresh

The [official OAuth guide](https://developer.authorize.net/api/reference/features/oauth.html) requires application registration in the **Partner Interface**, including an exact redirect URL and scope, before merchant consent. Request only `read`, use a confidential backend, validate unpredictable `state`, and exchange the short-lived authorization code server-side. Registration produces an application client ID/secret; a merchant browser login does not produce these credentials.

Production refresh uses `https://access.authorize.net/oauth/v1/token`; sandbox uses `https://accesstest.authorize.net/oauth/v1/token`. Authorize.net API requests put the access token in `merchantAuthentication.accessToken`. The guide describes access and refresh token expiry and revocation, but its prose and examples disagree on timing. Treat returned expiry metadata and authentication failures as authoritative; never promise indefinite access.

The [New Experience Authorized Applications guide](https://support.authorize.net/knowledgebase/Knowledgearticle/?code=KA-07620) confirms only an Account Owner or Account Administrator can approve OAuth access, `read` grants reporting access, and `read,write` grants broad transaction/profile capabilities. Existing grants are visible under **Account → Account and API Settings → Security Settings → Authorized Applications**. Revocation prevents future refreshes; an already issued access token can remain usable until expiration. This support article says ten minutes, differing from the developer guide's one-hour prose. Inspect, do not revoke existing checkout applications.

Rupert already refreshes an existing grant, rejects a token response unless its granted scope is exactly `read`, keeps access tokens in memory and persists rotated refresh tokens encrypted under a setup-version check. It does **not** implement partner registration, the consent redirect/callback or initial authorization-code exchange. Partner entitlement and an application grant remain concrete dependencies, not work that can be bypassed with the signed-in merchant tab.

The current client caches one access token for the import and does not refresh/retry mid-import after an expiry error. Large backfills can outlast a token. Before scheduling long jobs, add a bounded refresh/retry for read requests and verify refresh-token rotation under concurrent jobs; preserve atomic import failure if renewal fails. Do not weaken the `read` scope check to accommodate broader grants.

## Native exports, schema and historical limits

The current [New Experience report instructions](https://support.authorize.net/knowledgebase/Knowledgearticle/?code=KA-05369) describe **Reports → Settlement Report**, a selected time period, and **Download Report**. Formats include Standard/tab-delimited, Expanded CSV, and CAVV variants including Excel. These instructions establish an interactive download path; they do not establish an unattended feed or a scheduled-delivery feature.

Both privately obtained downloads use the same **54-column Expanded CSV** header. Relevant observed headers are:

- `Transaction ID`, `Transaction Status`, `Transaction Type`, `Reference Transaction ID`.
- `Settlement Amount`, `Settlement Currency`, `Settlement Date/Time`.
- `Authorization Amount`, `Authorization Currency`, `Submit Date/Time`.
- `Total Amount`, `Currency`, `Invoice Number`, `Invoice Description`, `Order Number`, `Market Type`, `Product`.

Both files contain timestamp values ending in `EDT`. Preserve the supplied zone/offset when converting to UTC; never interpret these as UTC or assume a fixed winter/summer offset. Keep separate submission and settlement dates. Record the actual query filters, captured time, account mapping, file hash and row count privately. This header/zone observation does not prove a complete account-history export or a maximum download size.

The [New Experience transaction-search guide](https://support.authorize.net/knowledgebase/article/KA-05371/en-us) says transaction display time uses account settings, history retains the current year plus the preceding two years, and older records are archived annually. Search filters combine as AND criteria. Defaults include unsettled transactions and a seven-day date filter; reset and record filters before claiming coverage. The current guide's 180-day full-card-number search restriction differs from the older download PDF's 120-day wording; use date/ID-based reconciliation instead of card searches.

The [older Download Transaction File Guide](https://www.authorize.net/content/dam/anet-redesign/documents/downloadguide.pdf) documents Expanded CSV fields, separate authorization/settlement currencies and amounts, original transaction references, and masked account data. Treat it as schema background: the current native header is the importer contract. Expanded downloads also carry customer/contact fields and free text; discard those unless a narrowly approved reconciliation requirement exists. No real records, totals, identities, hashes of merchant exports or session data belong in public Git.

## Scheduling and browser constraints

A 30-minute timer is an execution schedule, not evidence of a new upstream fetch. Re-importing the same CSV must retain its original capture time. Distinguish last attempt, successful upstream fetch, local import time and latest source transaction time. A quiet merchant can have a fresh successful fetch with zero new payments; an unchanged old file cannot demonstrate that fetch.

While API credentials remain deferred, a signed-in browser can produce a fresh export on demand. It still depends on the portal session, verification prompts and a user-visible authenticated workflow. No durable, vendor-supported browser export scheduler or session lifetime was established. Do not extract hidden cookies/storage, replay undocumented portal endpoints, defeat MFA or report an expired session as a successful sync. A pending sign-in should be visible as an access-needed badge.

The [separate Plus reporting documentation](https://developer.plus.authorize.net/docs/vas/en-us/reporting/developer/all/rest/reporting.html) describes report subscriptions and `/reporting/v3/report-downloads`, with organization identity and a distinct reporting contract. Related [Business Center reporting documentation](https://developer.plus.authorize.net/docs/cybs/en-us/reporting/user/all/ebc/reporting-ug.html) describes scheduled subscriptions. Neither establishes that a `new.authorize.net/smb2` merchant has that entitlement or that its Transaction Key authenticates those APIs. Do not adopt this surface until account access, authentication, report definition, schedule and retention are verified. No SFTP, email delivery or 30-minute native report schedule was established here.

Once authorized reporting credentials are available, the existing polling import is the concrete supported route for 30-minute fresh-data checks. Keep seven-day settlement overlap plus current unsettled payments and previously observed pending IDs. Backfill longer outages explicitly. Serialize concurrent imports per account; fail visibly on authentication, paging, count or identity mismatch. Do not alter payment/batch settings to change data availability.

## Webhooks and Shopify reconciliation

[Authorize.net's webhook guide](https://developer.authorize.net/api/reference/features/webhooks.html) positions notifications alongside reporting: details/current status still require reporting calls. Webhook management uses API credentials and notification verification requires a configured Signature Key. Webhooks do not bypass the deferred credential decision, provide historical backfill or establish net bank funding. A later implementation should verify signatures, deduplicate events and retain polling reconciliation; this investigation configures none.

[Authorize.net's Shopify guide](https://www.authorize.net/support/shopify-platform-update.html) says the payment app connects using API Login ID and Transaction Key. Shopify Payment ID and gateway transaction ID are different identifiers; the new app can place the Shopify Payment ID in the gateway transaction description. Consequently, matching by amount/time, invoice number or gateway ID alone can misassociate split captures, retries and refunds. Preserve gateway IDs and refund references; verify a real read-only pair privately before building a parser for the Shopify reference. A future allowlisted payment-reference field could avoid retaining the whole customer-supplied description. Rupert's current reporting importer omits that description and does not establish Shopify order links.

Gateway sales, Shopify orders, C-Trax sales and SwipeSimple payments may describe overlapping business events. Keep source-specific reconciliation records; do not sum feeds into retail revenue, create duplicate orders or change inventory. Settlement amounts are not processing fees or net payouts. Portal exports do not include a verified tip column; the API's optional tip/surcharge fields depend on source support and must remain unknown when absent.

## Existing code and next acceptance checks

Reviewed repository paths: `web/app/services/authorize_net_reporting/{client,check,import}.rb`, `web/app/jobs/authorize_net_reporting_job.rb`, `web/app/models/{pos_connection,authorize_net_transaction,authorize_net_batch}.rb`, `web/app/controllers/pos_connections_controller.rb` and `web/config/recurring.yml`.

At the reviewed base, API import is independent of the payment-capable `AuthorizeNetClient`, uses an explicit read-method allowlist, checks merchant/environment/tenant identity, bounds paging and detail volume, revisits pending IDs and performs an atomic local write. Credentials are encrypted. The recurring API job is daily and gated by enabled approved connections; later rollout changes require a separate deployment receipt. No production/API verification is claimed by this documentation commit.

Before calling the integration continuously fresh:

1. Import a newly captured portal export now; reconcile row counts/status totals privately, then replay to confirm no duplicates. Prove that old file replay cannot advance upstream freshness.
2. Confirm a later authenticated pull or export independently, including a zero-change fetch if no new payments exist. Verify an expired session reports access needed and retains the last good data.
3. After the owner's deferred review, use either existing approved credentials or a registered `read` OAuth grant. Run all read-access probes and preserve private receipts without keys or response bodies in logs.
4. Observe two actual upstream polling runs roughly 30 minutes apart, verify queue/worker execution and fetch timestamps, and compare a changed transaction or a returned empty result with the native portal. Timer configuration alone does not pass.
5. Validate UTC/day boundaries, unsettled-to-settled transition, linked refund, partial capture, pagination and bounded backfill with synthetic tests plus narrowly scoped private read-only checks. Establish fees/payouts separately if needed.

Remaining unknowns are live API entitlement, existing key ownership/Shopify sharing, partner registration availability, OAuth grant issuance, maximum native export size, merchant-specific optional fields, unattended portal export feasibility and any separate scheduled-report entitlement. None requires contacting anyone or rotating a key during the current portal-only work.
