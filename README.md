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

Requirements: Ruby 3.2.x (rbenv), Bundler, Node (for the Shopify CLI).

```bash
bundle install          # from web/
cp .env.example .env    # fill in credentials at repo root
bin/rails db:create db:migrate   # from web/
bin/rails db:import_legacy       # one-time: pull data from legacy/prisma/dev.sqlite
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

- **Dashboard** — counts, drift, recent runs, revenue by source
- **Inventory** — products/variants with Shopify vs Square quantities
- **Reconcile** — SKU-level drift plan + per-SKU priority policy
- **Ledger** — transaction mirror from both platforms
- **Alerts** — low-stock flags (resolve/ignore)
- **Sync** — run syncs, view run history and logs
- **Settings** — `.env` import/export (JSON API included) and SQLite
  backup/restore:
  - `GET /settings/env.json` · masked env keys
  - `POST /settings/env_import` · body `{ "text": "KEY=VALUE\n…" }`
  - `GET /settings/env_export` · full `.env` text
  - `GET /settings/backup` · consistent SQLite snapshot (VACUUM INTO)
  - `POST /settings/restore` · multipart `file` upload

All pages sit behind Shopify OAuth (the app installs into your store).

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
