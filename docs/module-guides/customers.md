# Customers (CRM)

Last checked against `main` at `ec5ae024` on `2026-10-25`.

## Purpose and owner

One place to find a customer from any sales source, see their orders and
spend, and keep local relationship notes: tags, status, assignment,
interactions and follow-ups. Product decisions: store owner. Changes are
reviewed through the normal PR flow.

`ModuleRegistry` key `customers` ("Customers"), section **Sell**, group
**Customers**. Operator guide:
[Customer CRM and employee directories](../ops/customer-crm-and-directories.md).

## Data model

- `Core::Customer` (table `customers`, `TenantScoped`): one row per **native
  source profile**. `source` is one of `shopify square ctrax swipesimple pos
  manual`; `external_id` is the source's id. Name, email and phone come from
  the source for imported rows and are editable only for `manual` rows.
- Local CRM fields on the same row survive directory refreshes:
  `preferred_name`, `crm_status` (`lead customer vip inactive`), `tags`,
  `owner_id`, `notes`.
- `CustomerInteraction` (`TenantScoped`): `kind` in `note call email meeting`,
  `body`, `author`. A logged email is a record of past contact; Rupert does not
  send it.
- `CustomerFollowUp` (`TenantScoped`): `title`, `due_on`, `owner`, `author`,
  `completed_at`.
- Orders (`Core::Order.customer_id`) are linked for lifetime spend, which is
  kept per currency.

A shared name, email or phone across sources is **not** treated as the same
person. A profile count is not a count of unique people.

## Permissions and tenant boundary

- Read: `customers.read` (`CustomerPolicy#index?`/`show?`). Staff without it
  get a "no access" page instead of a redirect.
- Add, edit, interactions, follow-ups and CSV export: `customers.write`.
- **Sync now** for directories: `customers.write` **and** `sync.write`.
- Default roles with `customers.read`: admin, manager, cashier, reader.
  `customers.write`: admin, manager (`User::ROLE_PERMISSIONS`).
- Every query runs through the `TenantScoped` default scope. Nested
  interaction/follow-up routes look the customer up with
  `tenant_id: Current.tenant_id`, so another tenant's id returns 404.

## Routes and API

- `GET /customers` (list, search, filters, sort), `GET /customers/:id`,
  `GET /customers/new`, `POST /customers`, `GET /customers/:id/edit`,
  `PATCH /customers/:id`.
- `GET /customers/export` (CSV), `POST /customers/sync_directory`.
- `POST /customers/:id/interactions`, `POST /customers/:id/follow_ups`,
  `PATCH /customers/:id/follow_ups/:id` (`event=complete|reopen`).
- No `/api/v1` endpoint. MCP tools `customer_lookup` and `customer_insights`
  need the `customers:read` scope and the owner's `customers.read`; they never
  return email, phone or address. See [MCP](../mcp.md) and
  [API standards](../api-standards.md).

## Workflow and status transitions

- `crm_status` is a free choice among `lead`, `customer`, `vip`, `inactive`;
  there is no enforced order.
- Follow-up: open → completed (`complete`) → open (`reopen`), done under a row
  lock. Any other event returns 422.

## UI patterns

- `/customers`: **List** template. `page_header` with a `More` menu, a
  `toolbar-band` with search, tag, source, profile verification, assignment,
  name and sort filters, then the table.
- `/customers/:id`: **Detail** template; eyebrow `Customer · <source>`, related
  sections as `section-card`.
- New and edit: **Form** template (`Add customer`, `Edit customer`).
- Known departure: the filter toolbar's `Apply` uses `btn-primary`, so the
  page can show a primary button outside the header. Not yet reviewed against
  the [HIG](../human-interface-guidelines.md).

## Integration and sync

- Reads only. `DirectorySyncJob` runs every 30 minutes
  (`config/recurring.yml`) and on **Sync now**, for each provider whose
  directory is available: C-Trax, Shopify, Square, SwipeSimple.
- A read publishes only after a complete, validated set of pages; an
  incomplete read keeps the earlier data.
- Shopify privacy webhooks (`customers_data_request`, `customers_redact`) are
  handled by their own jobs.
- Nothing in this module writes to Shopify, Square or another outside system.

## Audit history

- Interactions and follow-ups keep `author` and timestamps.
- Activity log entries: `customer_created`, `customer_updated` (names of the
  changed fields only, never their values), `customer_interaction_recorded`
  (the kind, not the text), `customer_follow_up_scheduled`,
  `customer_follow_up_completed` / `customer_follow_up_reopened`, and
  `data_exported` for the CSV (profile count and filter names). Entries label
  the profile as `Customer #<id>`; names, emails, phone numbers and notes are
  not copied into the log. Syncs from Shopify or Square do not log per
  profile.

## Failure and recovery

- Validation errors redirect back with the error sentence in a flash.
- CSV export refuses more than 25,000 profiles and asks for narrower filters;
  cells starting with `= + @ -` are prefixed so spreadsheets do not run them.
- A failed or partial directory read keeps the previous profiles. The source
  coverage panel shows last success and failures.
- Recovery is the whole-instance database backup; there is no module-level
  undo.

## Required tests

- `web/test/integration/customer_management_test.rb`
- `web/test/integration/customer_commerce_test.rb`
- `web/test/integration/customer_pagination_test.rb`
- MCP tools: `web/test/services/mcp/customers_tools_test.rb` and
  `web/test/integration/mcp_server_test.rb`.

## Open gaps

- CRM acceptance (#414) is closed. Audit logging of CRM edits and exports is
  not implemented (see above).
- Campaign attribution to customers is part of
  [#415](https://github.com/techmore/rupert/issues/415) and not built.
