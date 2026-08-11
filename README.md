# Rupert

Centralized inventory operations: a Shopify + Square sync
engine with an Oatmeal-styled web dashboard, backed by a single SQLite
database. Runs as a Ruby on Rails 7.1 app (based on the
[Shopify Ruby app template](https://github.com/Shopify/shopify-app-template-ruby))
and deploys to a DigitalOcean droplet straight from GitHub.

```
Shopify ──┐                     ┌── Dashboard
          │                     ├── Inventory
Square ───┼── sync engine ──▶ Prisma-style SQLite DB ──▶ GUI
          │   (Rails jobs)     │      (Rails + Tailwind)
          └────────────────────┴── Settings (env, backup/restore)
```

## What's here

| Path | Purpose |
| --- | --- |
| `web/` | The Rails 7.1 app: sync engine services, Oatmeal GUI, JSON APIs |
| `legacy/` | The original Node/React implementation, kept as reference |
| `shopify.app.toml` | Shopify app config (scopes, webhooks) |
| `Dockerfile`, `docker-compose.yml` | Droplet deployment |
| `.github/workflows/deploy.yml` | Push-to-main → build image → SSH deploy |

## Local development

Requirements: Ruby 4.0.6 (rbenv), Bundler, PostgreSQL 16, Node (for the
Shopify CLI).

```bash
bundle install          # from web/
cp .env.example .env    # fill in credentials at repo root
# create the postgres role/db (or set POSTGRES_* env vars):
#   createuser -s rupert && createdb -O rupert rupert_development
bin/rails db:create db:migrate   # from web/
bin/rails db:import_legacy       # one-time: pull data from legacy/prisma/dev.sqlite
bin/rails db:sqlite_to_postgres  # one-time: migrate production.sqlite3 -> PG
bin/rails tailwindcss:build
bin/rails server        # http://localhost:3000
```

The `.env` at the repo root is loaded at boot (Dotenv) and holds the sync
engine credentials (`SHOPIFY_CLIENT_ID/SECRET`, `SQUARE_ACCESS_TOKEN`, …).
The Shopify OAuth pair (`SHOPIFY_API_KEY`/`SHOPIFY_API_SECRET`) comes from
`shopify app info --web-env` when developing through the Shopify CLI, or is
set on the droplet for production.

## Operations

```bash
bin/rails ops:sync                    # full Shopify + Square sync
bin/rails ops:sync_source[square]     # single source
bin/rails ops:reconcile               # print the reconciliation plan summary
bin/rails test                        # page + API smoke tests
```

Scheduled syncs run through Solid Queue (`bin/jobs`) — every 15 minutes in
production, configurable via `SYNC_MINUTES` / `config/solid_queue.yml`.

## GUI pages

- **Dashboard** — per-user customizable widgets (key stats, per-channel
  revenue, attention, stock alerts, sync/reconcile history)
- **Sales** — daily sales journal in spreadsheet style: an hourly × location
  pivot plus every sale of the day in arrival order
- **Customers** — unified CRM view (searchable, Ransack + Pagy)
- **Inventory** — products/variants with Shopify vs Square quantities
- **Reconcile** — SKU-level drift plan + per-SKU priority policy
- **Ledger** — transaction mirror from both platforms
- **Alerts** — low-stock flags (resolve/ignore)
- **Sync** — run syncs, view run history and logs
- **SwipeSimple** — import sales from a SwipeSimple CSV export (no public API) into the canonical sales stream
- **Connections** — plain-language guide to every service's keys: what's set, where to find each, and how to renew
- **Settings** — `.env` import/export (JSON API included) and DB backup/restore:
  - `GET /settings/env.json` · masked env keys
  - `POST /settings/env_import` · body `{ "text": "KEY=VALUE\n…" }`
  - `GET /settings/env_export` · full `.env` text
  - `GET /settings/backup` · consistent snapshot (PostgreSQL `pg_dump`)
  - `POST /settings/restore` · multipart `file` upload
- **Team / People (HR)** — full employee lifecycle:
  - **Employees** · HR records with department, position, and status lifecycle
  - **Departments** · org chart (manager, headcount)
  - **Positions** · job titles and pay grades
  - **Timesheets** · weekly hours with submit / approve / reject workflow
  - **Leave & PTO** · requests, approvals, and annual balances
  - **Payroll** · pay runs built from approved timesheets and pay rates

All pages sit behind Shopify OAuth (the app installs into your store).

## ERP architecture

Rupert is a modular monolith growing into a full ERP for small businesses.
Extensions live under `app/modules/<name>/` and register themselves in
`app/models/module_registry.rb` (nav + permission gate). The canonical domain
core lives in `app/modules/core/` (`Customer`, `Order`, `OrderLine`,
`Payment`) and is fed by the Shopify/Square sync engine through
`CanonicalOrderImporter` — a clean seam between the source mirrors
(`ShopifyProduct`, `LedgerEntry`, …) and the unified ERP model. A third,
manual source (`SwipesimpleImporter`) feeds CSV exports through the same seam.

- Roles: `super_admin`, `admin`, `manager`, `cashier`, `reader` with a
  permission matrix in `User::ROLE_PERMISSIONS` and Pundit policy objects
- Dashboards: per-user widget layout saved as JSON on `User#dashboard_config`
- Sales grid: `SalesController` builds an hourly × location pivot from
  `Core::Order` (`groupdate`-ready time series)
- HR: `app/modules/people/` (employees, departments, positions, timesheets,
  leave & PTO, payroll) with `PayrollCalculator` turning approved timesheets
  into payslips
- DB: PostgreSQL (`pg` gem). SQLite is kept only for the one-time legacy import.

## Deploying to a droplet

1. Create a droplet with Docker (e.g. Ubuntu + Docker image).
2. Add GitHub secrets to this repo:
   - `GHCR_TOKEN` — PAT with `packages:write`
   - `DROPLET_HOST`, `DROPLET_USER`, `DROPLET_SSH_KEY`
3. On the droplet, create `/opt/rupert/.env` (copy from `.env.example`):
   - `SHOPIFY_API_KEY` / `SHOPIFY_API_SECRET` / `HOST` (public HTTPS URL)
   - `SQUARE_ACCESS_TOKEN` (+ optional `SQUARE_LOCATION_ID`)
   - `SECRET_KEY_BASE` (`bin/rails secret`)
   - `RAILS_ENCRYPTION_PRIMARY_KEY` / `DETERMINISTIC_KEY` / `KEY_DERIVATION_SALT`
     (`bin/rails db:encryption:init`) — keep these stable, encrypted
     settings will be unreadable if they change
4. Push to `main` — the workflow builds the image to GHCR and SSHes into the
   droplet to `docker compose up -d`. The SQLite database lives in a Docker
   volume (`rupert-db`) and survives deploys; use the Settings page or a
   volume snapshot for backups.

## Data model

Mirrors the legacy Prisma schema (table/column names preserved for import
compatibility): `ShopifyProduct`, `ShopifyVariant`, `SquareItem`,
`SquareVariation`, `SkuLink`, `ReconcileRun`, `ReconcileItem`, `Location`,
`InventoryLevel`, `InventoryMovement`, `StockAlert`, `SyncRun`,
`InventoryPolicy`, `LedgerEntry`, plus Shopify session storage (`shops`,
`users`) and app `settings`.

## Known caveats

- **Client-credentials token**: the Shopify sync uses the store's
  client-credentials token (`SHOPIFY_CLIENT_ID`/`SECRET`). If the token is
  rejected (`[API] Invalid API key or access token`), re-install the app on
  the store or regenerate the secret in the Shopify admin — the sync will
  fail loudly in the Sync page until then.
- SQLite is fine for a single-instance ops tool; the production warning can
  be silenced, but if you outgrow it, switch `config/database.yml` to
  PostgreSQL and `db:import_legacy`-style migration.
