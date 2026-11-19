# Self-service sign-up and monthly subscriptions: operator guide

Written 2026-11-18. This guide is for the person who runs the Rupert installation and owns the Stripe account. It covers the switch `RUPERT_SELF_SERVICE`, which is **off by default**, and everything the operator must do by hand before turning it on.

It builds on what was already in place and is described in [the subscriptions plan](../plans/customer-subscriptions-and-trust.md): free Google-verified sign-up at `/start`, the Subscription page at `/billing`, Stripe Checkout and the signed webhook behind `RUPERT_BILLING_ENABLED`, and one isolated instance per new customer behind `RUPERT_PROVISION_WORKSPACES`.

This is Rupert's own subscription billing. It is separate from the card payments a shop takes from its customers at the register; none of that code is involved.

## What the switch changes

| | Switch off (default) | Switch on |
| --- | --- | --- |
| Sign-up at `/start` | Free account, no terms box | Must accept the terms of service and privacy policy; the accepted version and time are recorded |
| New self-service workspace | Exempt, free record | Billable, with a trial of `RUPERT_TRIAL_DAYS` days. No card is asked for at sign-up |
| Workspaces that existed before | Not checked | Exempt: not checked, never billed, never asked to subscribe |
| Workspaces created by an operator (`/tenants`, `/setup`, approved `/signup` requests) | Not checked | Exempt unless the operator makes them billable |
| A billable workspace whose trial or subscription lapsed | Not checked | Read-only: every page still opens and exports still work; requests that change something are refused |
| Webhook | Each delivery is applied (safe to repeat) | Each Stripe event id is applied once; `customer.subscription.created` is also handled |
| `/platform/billing`, `/internal/workspaces/:id/entitlement` | 404 | Available |
| First-run checklist on `/workspace` | Not shown | Shown |

### Who is exempt

Exemption is a data flag, `tenants.billing_exempt`, not a name. The column defaults to true, so:

- every workspace present when the migration ran is exempt;
- every workspace created afterwards is exempt, unless it came from self-service sign-up while the switch was on, or the operator made it billable on the operator billing page.

An exempt workspace passes every check whatever its subscription record says. Nothing in this feature reads a workspace's name.

### Subscription states

Worked out from local records by `WorkspaceEntitlement`, never by calling Stripe during a page load.

| State | Meaning | Access |
| --- | --- | --- |
| `exempt` | The flag is set | Full, always |
| `comped` | The operator gave a complimentary plan until a date | Full until that date |
| `trialing` | Inside the sign-up trial, or a Stripe trial | Full |
| `active` | Stripe confirms a paid subscription | Full |
| `past_due` | A payment failed | Full for `RUPERT_BILLING_GRACE_DAYS` days from the first failure, then read-only |
| `canceled` | The subscription ended | Read-only |
| `trial_expired` | The trial ended and nobody subscribed | Read-only |

Read-only never deletes, hides or archives anything. A lapsed owner can still open Subscription and pay, grant support access, sign in and out, and delete the account. Subscribing again returns the workspace to full use as soon as Stripe's webhook confirms it.

## Settings

Set these in the control plane's environment. Never commit real values, and never paste them into an issue, a screenshot or a chat.

| Variable | Required | Purpose |
| --- | --- | --- |
| `RUPERT_SELF_SERVICE` | to turn the feature on | `1` on, anything else off |
| `RUPERT_TRIAL_DAYS` | no | Trial length in days. Default `14` |
| `RUPERT_BILLING_GRACE_DAYS` | no | Days of full use after a failed payment. Default `7` |
| `RUPERT_STRIPE_AUTOMATIC_TAX` | no | `1` adds Stripe Tax to checkout. Default off |
| `RUPERT_BILLING_ENABLED` | yes, for checkout | `true` enables checkout and the webhook, together with every `CSP_STRIPE_*` value below |
| `CSP_STRIPE_SECRET_KEY` | yes | Stripe secret or restricted key (`sk_test_…` in test mode) |
| `CSP_STRIPE_ACCOUNT_ID` | yes | The Stripe account id (`acct_…`); checkout refuses to start if the key belongs to another account |
| `CSP_STRIPE_MONTHLY_PRICE_ID` | yes | The monthly price id (`price_…`) |
| `CSP_STRIPE_REFERRAL_COUPON_ID` | yes | The referral coupon id; required even if referrals are not offered yet |
| `CSP_STRIPE_WEBHOOK_SECRET` | yes | The endpoint's signing secret (`whsec_…`) |
| `CSP_STRIPE_PORTAL_CONFIGURATION_ID` | for the Manage billing button | The Customer Portal configuration id (`bpc_…`) |
| `RUPERT_PUBLIC_ORIGIN` | yes | HTTPS origin customers return to after Stripe, for example the control plane's own address |
| `RUPERT_APPROVED_REFERRAL_CODES` | no | See the subscriptions plan |

The sign-up flow also needs Google sign-in configured, as it does today, because Google verifies the owner's email. The app sends no email of its own.

With `RUPERT_SELF_SERVICE=1` but billing not configured, sign-up, trials and read-only mode all work, and the Subscription page says checkout is being set up. Do not leave it that way in production: a trial would end with no way to pay.

## Stripe dashboard steps (the owner does these)

Do everything in **test mode** first, then repeat in live mode. Test and live have separate keys, prices, webhook endpoints and portal configurations.

1. **Product and price.** Create a product for the Rupert subscription. Add one recurring price: monthly, USD 499.00. Copy the price id into `CSP_STRIPE_MONTHLY_PRICE_ID`. The code checks that this price is active, in USD, 49900 cents and monthly, and refuses checkout otherwise; changing the amount means changing `RupertBilling.verify_configuration!` and the public price text in the same pull request.
2. **Referral coupon.** Create a coupon: 50% off, repeating, 12 months, limited to the product above. Copy its id into `CSP_STRIPE_REFERRAL_COUPON_ID`.
3. **Webhook endpoint.** Add an endpoint at `https://<control plane host>/webhooks/stripe`, API version `2025-06-30.basil`, listening for exactly these events:
   - `checkout.session.completed`
   - `customer.subscription.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
   - `invoice.paid`
   - `invoice.payment_failed`

   Copy the signing secret into `CSP_STRIPE_WEBHOOK_SECRET`.
4. **Customer Portal.** Create a portal configuration for Rupert: allow updating the payment method and viewing invoices; allow cancellation **at the end of the billing period** (the cancellation page says so); do not allow switching plans. Copy the configuration id into `CSP_STRIPE_PORTAL_CONFIGURATION_ID`. The portal is refused during a referral plan's 12-month commitment.
5. **Failed payments.** Under Billing → Revenue recovery, choose the retry schedule and what happens when retries run out. Recommended: retry for about two weeks, then cancel the subscription. Keep `RUPERT_BILLING_GRACE_DAYS` no longer than that window, so a workspace is not read-only while Stripe has already stopped trying, or the reverse.
6. **Tax.** Decide whether the subscription is taxable where you sell. If you use Stripe Tax: add your registrations, set the product's tax category, then set `RUPERT_STRIPE_AUTOMATIC_TAX=1`. Without it, checkout charges the price with no tax line.
7. **Business details.** Check the public business name, statement descriptor, support address and the links to your terms, privacy and refund pages under Settings → Business → Public details.
8. **Account id.** Copy the account id into `CSP_STRIPE_ACCOUNT_ID`.

## Before turning it on

1. The terms, privacy and refund pages (`/terms`, `/privacy`, `/refunds`) still carry a "Draft for review" notice and owner placeholders. They must be approved, by counsel where needed, before anyone is asked to accept them. See the decisions below.
2. Off-host backups must be working and a restore must have been rehearsed. The migration is additive, but deploys have no migration rollback.
3. Decide where new customers live. As built, a self-service sign-up queues an isolated instance on the owner's server; that is only fulfilled when `RUPERT_PROVISION_WORKSPACES=true` and the host worker is installed ([subscriptions plan, Phase 2](../plans/customer-subscriptions-and-trust.md)). Until then a new customer has an account, a trial clock that is running and a workspace that says "being prepared". Do not open sign-up to the public in that state.
4. Run the test-mode pass below against the real test-mode Stripe account.

## Turning it on

1. Set the `CSP_STRIPE_*` values, `RUPERT_PUBLIC_ORIGIN` and `RUPERT_BILLING_ENABLED=true` (test-mode keys first).
2. Set `RUPERT_SELF_SERVICE=1` and restart the web and job services.
3. Open `/platform/billing` as a platform administrator. Every existing workspace must show **Exempt**. If one does not, mark it exempt there before going further.
4. Sign up a test business and walk the checklist under "Testing in Stripe test mode".

To turn it off again, unset `RUPERT_SELF_SERVICE` and restart. Trials, subscription records and the exempt flag stay as they are; nothing is checked while it is off.

Workspace nodes: a new isolated instance is told about the switch when it is created (the host worker writes `RUPERT_SELF_SERVICE=1` into its environment only if the control plane has the switch on at that moment). An instance created earlier needs that line added to its `/etc/rupert.env` and a restart. A node asks the control plane what its subscription allows at most every five minutes. If the control plane cannot be reached it uses the last answer for up to a week, and with no answer at all it allows full access: an outage never locks a customer out.

## The operator billing page

`/platform/billing` (platform administrators only; also in the Instance overview menu) lists every workspace with its plan, Stripe status, state and access. Four changes are possible, all local, none of which touches Stripe:

- **Mark exempt.** The workspace is never checked again. Use it for a friend, a pilot, or to undo a mistake at once.
- **Make billable.** Asks for the workspace address to be typed. The workspace gets a whole new trial from that moment, so it can never become read-only by surprise. It never applies to the operator's own home workspace.
- **Comp a plan.** Full use until a chosen date (up to five years), with an optional note. When it ends the workspace is judged by its trial and subscription again.
- **End complimentary plan.**

Each change is written to the activity log. To cancel or refund a real subscription, use the Stripe dashboard; the webhook brings the result back.

## Testing in Stripe test mode

### Automated, no Stripe account needed

Stripe and Google are doubled; nothing leaves the machine.

```sh
cd web
bin/rails db:prepare
bin/rails tailwindcss:build
WALKTHROUGH_LOG=1 bin/rails test test/acceptance/self_service_signup_walkthrough_test.rb
bin/rails test test/integration/self_service_gate_test.rb test/integration/self_service_webhook_test.rb \
  test/services/workspace_entitlement_test.rb test/models/billing_webhook_event_test.rb
```

The walkthrough prints each step: sign-up, terms, trial, Checkout Session, webhook, first payment, portal, failed payment, grace, read-only, recovery, cancellation, resubscription.

### By hand, with the Stripe CLI and a test-mode account

You need the [Stripe CLI](https://docs.stripe.com/stripe-cli) logged in to the test-mode account. These commands create test-mode objects only.

```sh
stripe products create --name "Rupert subscription (test)"
stripe prices create --product <prod_id> --currency usd --unit-amount 49900 -d "recurring[interval]=month"
stripe coupons create --percent-off 50 --duration repeating --duration-in-months 12
stripe listen --forward-to localhost:3000/webhooks/stripe   # prints the whsec_ signing secret
```

In a second terminal, with the ids those commands printed:

```sh
cd web
export RUPERT_SELF_SERVICE=1 RUPERT_BILLING_ENABLED=true
export CSP_STRIPE_SECRET_KEY=sk_test_... CSP_STRIPE_ACCOUNT_ID=acct_...
export CSP_STRIPE_MONTHLY_PRICE_ID=price_... CSP_STRIPE_REFERRAL_COUPON_ID=...
export CSP_STRIPE_WEBHOOK_SECRET=whsec_... CSP_STRIPE_PORTAL_CONFIGURATION_ID=bpc_...
export RUPERT_PUBLIC_ORIGIN=https://localhost:3000
bin/rails db:prepare
bin/rails runner '
  tenant = Tenant.create!(name: "Test Bakery", subdomain: "test-bakery", billing_exempt: false)
  User.create!(tenant: tenant, email: "owner@test-bakery.example", name: "Owner", role: "admin", password: "local-test-password")
  CustomerSubscription.create!(tenant: tenant, trial_ends_at: 14.days.from_now)
'
bin/dev
```

Sign in at `http://localhost:3000/login` as `owner@test-bakery.example`, then:

1. Open `/billing`. It shows the trial. Choose Monthly, tick the box, continue to Stripe, and pay with the test card `4242 4242 4242 4242`. Stripe sends you back to an `https://localhost` address that will not load locally; that is expected, and nothing depends on it. Reload `http://localhost:3000/billing`: once `stripe listen` shows the events delivered with status 200, the state is Trial (carried into Stripe) or Active.
2. Replay an event: `stripe events resend <evt_id>`. The delivery returns 200 and nothing changes.
3. Fail a payment: in the Stripe dashboard, replace the customer's card with `4000 0000 0000 0341` and advance a [test clock](https://docs.stripe.com/billing/testing/test-clocks) past the renewal, or run `stripe trigger invoice.payment_failed` for an unrelated event to see it ignored. `/billing` shows the failed payment and the date full use ends.
4. Cancel from Manage billing. The page says when the subscription ends. Cancel immediately in the dashboard to see read-only mode: pages open, exports download, saving anything is refused with an explanation.
5. Subscribe again from `/billing`. The same Stripe customer is reused.
6. As a platform administrator, open `/platform/billing` and try Mark exempt, Make billable and Comp a plan.

The real sign-up at `/start` needs Google sign-in configured for the host you test on, because Google verifies the email before anything is created. A workspace created that way waits for its isolated instance, so use the runner command above to test read-only mode on one machine.

## Decisions for the owner

Each has a recommended default and what the code does today.

| Decision | Recommended | What the code assumes now |
| --- | --- | --- |
| Monthly price and currency | Keep USD 499 per month until there is evidence to change it | USD 499.00 monthly, checked against Stripe before every checkout; shown on the landing page and Subscription page. Set 2026-10-20 |
| Free trial length | 14 days | `RUPERT_TRIAL_DAYS`, default 14. The unused part of the trial carries into Stripe when the customer subscribes early |
| Card at sign-up | Not required | Not required. The card is taken at Stripe Checkout when the owner chooses to subscribe |
| What a lapsed account can do, and for how long | Read and export, indefinitely, until the owner deletes the account or you set a retention period in the terms | Read-only with no time limit. Nothing is ever deleted automatically |
| Grace after a failed payment | 7 days, inside Stripe's retry window | `RUPERT_BILLING_GRACE_DAYS`, default 7 |
| Sales tax on the subscription | Use Stripe Tax once registered where required; ask your accountant where that is | Off. `RUPERT_STRIPE_AUTOMATIC_TAX=1` turns it on |
| Refund and cancellation policy | Cancel any time, effective at the end of the paid period, no partial-month refunds, refunds for billing errors | `/refunds` is a draft with owner placeholders. Not approved |
| Terms of service and privacy policy | Have counsel review before launch | `/terms` and `/privacy` are drafts with a visible draft notice. Sign-up records acceptance of terms version `2026-10-20` (`RupertBilling::TERMS_VERSION`); raise it whenever the text changes |
| Support contact | One monitored address | `RUPERT_SUPPORT_EMAIL` |
| Where new customers are hosted | One isolated instance per customer on your server, as already chosen | Sign-up queues an isolated instance. Provisioning stays off until the host worker is installed and accepted |
| Free accounts created before the switch | Leave exempt; make individual ones billable only after telling them | Exempt |
| Referral plan (50% for 12 months with a commitment) | Keep, or hide until the monthly plan is proven | Offered on the Subscription page as before |

## What is not built

- **No email.** The app has no mailer. Trial-ending, payment-failed and cancellation notices are Stripe's own emails (enable them under Settings → Billing → Customer emails) plus the notices inside Rupert.
- **Sign-up is Google only.** There is no password sign-up, so there is no separate email verification step.
- **Read-only covers the web app and the bearer-token API (`/api/v1`, non-employee).** The staff phone app's API, inbound provider webhooks, scheduled syncs and background jobs are not stopped for a lapsed workspace.
- **Existing isolated instances** do not learn about the switch by themselves (see "Workspace nodes" above).
- **No automatic deletion or retention clock** for lapsed workspaces.
- **No proration, plan changes, seats, annual billing or usage pricing.** One monthly plan, plus the existing referral plan.
- **No revenue reporting.** The operator page shows states, not money; use Stripe for that.
- **The legal pages are drafts.**
