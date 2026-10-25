# Environment reference

Two kinds of configuration exist. **Boot-time variables** live in `/etc/rupert.env` on SER8 (read by systemd before dropping privileges) or in the repo-root `.env` in development; they are needed before the database can be opened. **Managed settings** are stored encrypted in the `settings` table and edited from Settings → Environment (or imported as `.env` text); they override the process environment for the same key and are what you normally change day to day.

## Boot-time variables (`/etc/rupert.env`)

| Variable | Required | Purpose |
| --- | --- | --- |
| `RAILS_ENV` | yes | `production` |
| `HOST` | yes | Public origin, e.g. `https://herbalhealers.rupertpos.com`. Enables host authorization (the app refuses to boot without it) and builds OAuth callbacks |
| `ADDITIONAL_HOSTS` | no | Comma-separated extra hostnames allowed by host authorization |
| `RUPERT_LEGACY_HOSTS` | no | Comma-separated retired hostnames (production: `rupert.stoverparc.org,rupert.cybersecuritypilot.org,herbalhealers.cybersecuritypilot.org`). Requests to them are redirected to `HOST` with the same path (301 for GET/HEAD, 308 otherwise); `/up` health checks are still answered. They do not need to be in `ADDITIONAL_HOSTS` |
| `SECRET_KEY_BASE` | yes | Session/cookie signing. `bin/rails secret` |
| `RAILS_ENCRYPTION_PRIMARY_KEY`, `RAILS_ENCRYPTION_DETERMINISTIC_KEY`, `RAILS_ENCRYPTION_KEY_DERIVATION_SALT` | yes | Active Record encryption for every credential and document column. Generate once with `bin/rails db:encryption:init`; **never change without re-encrypting** |
| `RUPERT_SQLITE_DATABASE_PRODUCTION` | no | Path of the SQLite file (default `storage/production.sqlite3`) |
| `RUPERT_SQLITE_DATABASE_DEVELOPMENT`, `RUPERT_SQLITE_DATABASE_TEST` | no | Per-environment SQLite paths; defaults are under `storage/` |
| `DATABASE_URL` | must be unset | Any nonempty value is rejected, including a SQLite URL. Configure the database with the `RUPERT_SQLITE_DATABASE_*` path variables instead. |
| `RUPERT_DB_ADAPTER` | no | Omit it; legacy value `sqlite3` is accepted. Any other explicit adapter value is rejected. |
| `SQLITE_BUSY_TIMEOUT_MS` | no | Writer wait before `SQLITE_BUSY` (default 5000) |
| `RAILS_MAX_THREADS` / `RAILS_MIN_THREADS` | no | Puma threads and AR pool (default 5) |
| `WEB_CONCURRENCY` | no | Puma workers (unset: single process, right for SER8) |
| `PORT` | no | Puma port (3000) |
| `JOB_THREADS` | no | Solid Queue worker threads (default 1: SQLite has one writer) |
| `JOB_CONCURRENCY` | no | Solid Queue worker processes (default 1) |
| `RAILS_LOG_LEVEL` | no | `info` (default) or `debug` |
| `RAILS_LOG_TO_STDOUT` | no | `1` to log to journald/stdout |
| `RAILS_SERVE_STATIC_FILES` | no | `1` when no proxy serves `public/` |
| `SHOPIFY_API_KEY`, `SHOPIFY_API_SECRET` | yes | The Partner app credentials: OAuth and webhook HMAC |
| `SCOPES` | no | OAuth scopes (default matches `shopify.app.toml`) |
| `SHOP_CUSTOM_DOMAIN`, `SHOPIFY_APP_PRIVATE_SHOP` | no | Shopify app template options; unused on SER8 |
| `SENTRY_DSN` | no | Enables error tracking; `SENTRY_ENVIRONMENT` (default `production`), `SENTRY_TRACES_SAMPLE_RATE` (default 0) |
| `RUPERT_UPDATE_CHECK` | no | `off` disables the in-app "update available" banner |
| `RUPERT_AUTODEPLOY_STATE` | no | Where System → Updates reads the updater's `status.json` (default `/var/lib/rupert-autodeploy`); must match the updater's |
| `RUPERT_AUTODEPLOY_INBOX` | no | Where System → Updates leaves install requests and the manual-mode flag (default `web/storage/autodeploy`); must match the updater's and `rupert-autodeploy.path` |
| `RUPERT_BUILD_SHA`, `RUPERT_BUILT_AT` | Docker only | Build identity for git-free deployments |
| `RUPERT_INITIALIZE_DATABASE` | Compose first start only | Set to `1` only to explicitly initialize a genuinely new empty SQLite database; remove it after successful initialization. Otherwise Compose requires a nonempty existing SQLite file. |
| `REDIS_URL` | compose only | Action Cable in the optional Docker Compose layout |
| `SECRET_KEY_BASE_DUMMY` | build only | Set by the Dockerfile during asset precompile; never at runtime |

### Optional features and integrations

| Variable | Default | Purpose |
| --- | --- | --- |
| `RUPERT_BUZZ_ENABLED` | off | `1` turns on the optional Buzz module ([web/engines/buzz/README.md](../../web/engines/buzz/README.md)) |
| `RUPERT_EMPLOYEE_APP_ENABLED` | `0` in production, `1` elsewhere | `1` allows employee-app (staff mobile) sign-in; see [staff-app.md](../module-guides/staff-app.md) |
| `RUPERT_GOOGLE_OAUTH_HOST` | `HOST` in production; any host elsewhere | The one host whose Google callback is registered. Every Google sign-in and sign-up is sent there, so other hostnames and the iPhone app need no callback of their own. A bare hostname or a URL |
| `RUPERT_SWIPESIMPLE_INBOX` | unset (off) | Absolute directory that `SwipesimpleInboxJob` imports reports from; only for an explicit trusted producer, not for webpage sync. See [swipesimple-reporting.md](swipesimple-reporting.md) |
| `RUPERT_BACKUP_STATUS_DIR` | `web/storage/backups` | Where System → Backups reads the status JSON written by the backup scripts; must match their `STATUS_DIR` / `STATUS_PATH`. See [backups.md](backups.md) |
| `RUPERT_INSTANCE_LABEL` | `Not configured` | Deployment label on the platform instance page (80 characters, no control characters). See [private-workspaces.md](private-workspaces.md) |

### Logging and the System page

Full detail in [logging.md](logging.md).

| Variable | Default | Purpose |
| --- | --- | --- |
| `RUPERT_LOG_FORMAT` | `json` in production, `rails` elsewhere | `json`, `text` or `rails` (Rails' own log, no request events) |
| `RUPERT_SLOW_REQUEST_MS` | `2000` | Slow-request warning threshold |
| `RUPERT_LOG_QUIET_JOB_MS` | `1000` | Successful jobs faster than this are counted, not logged |
| `RUPERT_LOG_SUMMARY_SECONDS` | `300` | Window of the `noise_summary` line |
| `RUPERT_OPS_EVENTS` | on | `0` stops writing System page events |
| `RUPERT_OPS_EVENT_DAYS` | `14` | How long System page events are kept |

### Team chat models

Full detail in [team-chat.md](team-chat.md).

| Variable | Purpose |
| --- | --- |
| `RUPERT_CHAT_PROVIDER` | `opencode_go`, `local_gateway`, `ollama`, `openai` or `opencode_cli`; unset = auto |
| `RUPERT_CHAT_MODEL` | Model id (OpenCode Go default `deepseek-v4.1-flash`) |
| `RUPERT_CHAT_API_BASE` | Base URL for `openai`, or an override for the others |
| `RUPERT_CHAT_API_KEY` | Key for `opencode_go` / `openai` |
| `RUPERT_CHAT_FALLBACK` | `engine[:model]` list to try in order when the first model is refused or unreachable, or `none` |
| `RUPERT_LOCAL_LLM_URL` | The rupert-llm gateway (`…/v1`); setting it turns on the local `@agents` |
| `RUPERT_LOCAL_TOOLS` | `all` gives local bots every tool on every question (stable prompt the model server can cache) instead of only the tools for the question's topics |
| `RUPERT_VERIFY` | `1` (every local bot) or a comma list of bot handles: check and fix each local answer against its tool data |

### Subscriptions, owner identities and private workspaces

See [the subscriptions plan](../plans/customer-subscriptions-and-trust.md) and [private-workspaces.md](private-workspaces.md). `.env.example` lists them with safe defaults.

| Variable | Where | Purpose |
| --- | --- | --- |
| `RUPERT_BILLING_ENABLED` | control plane | `true` turns on Rupert subscriptions (also needs every `CSP_STRIPE_*` key); keep `false` until test-mode acceptance |
| `RUPERT_PUBLIC_ORIGIN` | control plane | Public origin for billing return URLs and feedback links (default `https://rupertpos.com`) |
| `RUPERT_APPROVED_REFERRAL_CODES` | control plane | Comma-separated owner-approved referral codes; when set, only these are eligible |
| `RUPERT_OWNER_GOOGLE_EMAILS` | control plane | Comma-separated owner Google mailboxes for `platform:link_owner_identities` |
| `RUPERT_PROVISION_WORKSPACES` | control plane | `true` lets the control plane hand workspaces to the host provisioner |
| `RUPERT_WORKSPACE_BASE_DOMAIN` | control plane, host | Parent domain of customer workspace hostnames (default `workspaces.rupertpos.com`) |
| `RUPERT_PROVISIONER_TOKEN` | control plane, host | Shared private token between the control plane and the host provisioner (32+ characters) |
| `RUPERT_CONTROL_PLANE_ORIGIN` | host, workspace | Canonical HTTPS origin of the control plane |
| `RUPERT_NODE_MODE` | workspace | `workspace` makes this instance an isolated single-store node |
| `RUPERT_WORKSPACE_ID`, `RUPERT_TENANT_ID`, `RUPERT_INSTANCE_HOSTNAME`, `RUPERT_INSTANCE_SECRET` | workspace | Identity of an isolated workspace node; generated by the host worker, never shared |

## SER8 host scripts (not read by the app)

These are read by scripts in `deploy/ser8`, from their own environment or systemd unit, not from `/etc/rupert.env`.

| Variable | Script | Default | Purpose |
| --- | --- | --- | --- |
| `RUPERT_AUTODEPLOY_APP` | `rupert-autodeploy.sh` | `/opt/rupert` | Checkout to deploy |
| `RUPERT_AUTODEPLOY_BACKUPS` | `rupert-autodeploy.sh` | `/var/backups/rupert-autodeploy` | Pre-deploy SQLite backups |
| `RUPERT_AUTODEPLOY_LOCK` | `rupert-autodeploy.sh` | `/run/rupert-autodeploy.lock` | Single-run lock |
| `RUPERT_AUTODEPLOY_ENV_FILE` | `rupert-autodeploy.sh` | `/etc/rupert.env` | Environment loaded for bundle, migrate and precompile |
| `RUPERT_AUTODEPLOY_PATH` | `rupert-autodeploy.sh` | `/opt/rbenv/versions/4.0.9/bin:…` | `PATH` for the deploy (selects Ruby) |
| `RUPERT_AUTODEPLOY_SMOKE_PATH` | `rupert-autodeploy.sh` | `/login` | Page used for the post-deploy layout and asset smoke check |
| `RUPERT_CUSTOMER_IMAGE` | `customer_provisioner.py` | required | Reviewed clean image fingerprint (64 hex) |
| `RUPERT_CUSTOMER_REVISION` | `customer_provisioner.py` | required | Exact Git revision of that image (40 hex) |
| `RUPERT_CUSTOMER_MAX_INSTANCES` | `customer_provisioner.py` | `8` | Pilot quota, 1–50 |
| `RUPERT_CUSTOMER_ROUTE_COMMAND` | `customer_provisioner.py` | `/usr/local/libexec/rupert-customer-route` | Absolute path of the route helper |
| `RUPERT_PROVISIONER_MAX_IDLE_SECONDS` | `customer_provisioner.py` | `60` | Longest poll delay while idle |
| `RUPERT_CUSTOMER_BIND_ADDRESS` | `customer_route.py` | unset (all addresses) | IPv4 LAN address the Caddy customer routes bind to |
| `RUPERT_LLM_CONTAINER` | `team-chat/setup-local-model.sh` | `rupert-llm` | Incus container for the local model |
| `RUPERT_LLM_IMAGE` | `team-chat/setup-local-model.sh` | `images:ubuntu/24.04` | Its base image |
| `RUPERT_LLM_MEMORY` | `team-chat/setup-local-model.sh` | `12GiB` | Its memory limit |
| `RUPERT_LLM_CPUS` | `team-chat/setup-local-model.sh` | `6` | Its CPU limit |

## Mobile build (EAS)

| Variable | Purpose |
| --- | --- |
| `RUPERT_IOS_BUNDLE_ID` | iOS bundle identifier for the employee app (`mobile/app.config.ts`) |
| `RUPERT_ANDROID_PACKAGE` | Android package name for the employee app |

`EXPO_PUBLIC_RUPERT_URL` sets the app's default server; see [mobile/README.md](../../mobile/README.md).

`deploy/ser8/tests/test_environment_reference.py` fails when non-test code names a `RUPERT_*` variable that this page does not list.

## Managed settings (Settings → Environment, encrypted in the database)

| Key | Purpose |
| --- | --- |
| `SHOPIFY_CLIENT_ID`, `SHOPIFY_CLIENT_SECRET` | Client-credentials token for the sync engine (custom app in the store's admin) |
| `SHOPIFY_SHOP_DOMAIN` | `your-store.myshopify.com`; falls back to the workspace record, never to a built-in default |
| `SHOPIFY_LOCATION_ID` | gid of the primary selling location (optional) |
| `SQUARE_APPLICATION_ID`, `SQUARE_ACCESS_TOKEN`, `SQUARE_ENVIRONMENT` (`production`/`sandbox`), `SQUARE_LOCATION_ID` | Square read access; a saved token turns the Square sync on |
| `SQUARE_SANDBOX_APPLICATION_ID`, `SQUARE_SANDBOX_ACCESS_TOKEN` | Sandbox pair for testing |
| `SYNC_MINUTES` (informational; schedule is `config/recurring.yml`), `SYNC_HISTORY_DAYS` (first-sync lookback, default 30) | Sync window |
| `AUTHORIZE_NET_LOGIN_ID`, `AUTHORIZE_NET_TRANSACTION_KEY`, `AUTHORIZE_NET_CLIENT_KEY`, `AUTHORIZE_NET_SANDBOX` | Card payments for warehouse sales |
| `GOOGLE_PAY_*`, `APPLE_PAY_*` | Wallet buttons on the warehouse checkout |
| `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` | Google sign-in |
| `GOOGLE_DRIVE_CLIENT_ID`, `GOOGLE_DRIVE_CLIENT_SECRET`, `GOOGLE_DRIVE_REFRESH_TOKEN`, `GOOGLE_DRIVE_FOLDER_ID`, `GOOGLE_DRIVE_RETENTION` | Instance backups to Drive (platform administrator only) |
| `FEEDBACK_READY_SENDERS` | Who may mark reports filed through MCP `submit_feedback` "ready for development": comma, space or newline separated 64-hex Nostr public keys or `npub…` values (Settings → Environment). Empty means nobody; reports are then always for review. See `docs/ops/feedback-reports.md` |
| `FULFILLMENT_ALERT_HOURS` | Unfulfilled-order alert threshold |
| `PUSH_GUARD_*`, `PUSH_FREEZE_*` | Informational freeze/approval state (no longer enforced) |

The `BUZZ_*` and `OPCODE_BUZZ_PRIVATE_KEY` keys were removed with Buzz. Only the optional Buzz module reads `BUZZ_RELAY_URL`, `BUZZ_CHANNEL` and `BUZZ_PRIVATE_KEY` (encrypted workspace settings, set on its Setup page), and only while `RUPERT_BUZZ_ENABLED=1` is set on the server; it is off by default everywhere. See [web/engines/buzz/README.md](../../web/engines/buzz/README.md). Team chat's model settings (`RUPERT_CHAT_*`) are boot-time variables; see [team-chat.md](team-chat.md).

Masked values are visible at `GET /settings/env.json`; a full export needs the password again and is logged. Imports and exports are audit-logged and rate-limited.
