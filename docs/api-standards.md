# API standards and contracts

This page describes Rupert's programmable interfaces as they work on `main`
(checked at `ec5ae024`, 2026-10-25), and the rules for changing them. The
per-endpoint detail lives in the [read API guide](api-v1.md), the
[MCP guide](mcp.md) and the [Uploads inbox guide](ops/uploads-inbox.md). This
page is the shared contract that ties them together. If the code and this page
disagree, the code is right and this page needs fixing.

Rupert has three interfaces:

| Interface | Path | Who calls it | Credential |
| --- | --- | --- | --- |
| Integration API | `/api/v1/catalog`, `inventory`, `roadmap`, `metrics`, `uploads` | Scripts and other systems | API access token (`rupert_…`) with scopes |
| MCP server | `POST /mcp` | AI assistants (Claude, ChatGPT, custom agents) | The same API access token |
| Staff app API | `/api/v1/employee/*` | Rupert's own employee mobile app | Staff app session token (separate) |

Shopify webhooks under `/api/webhooks/*` are inbound calls from Shopify, verified
by the Shopify app engine. They are not a public contract and are not covered here.

## 1. Naming and resources

- Paths are lower case nouns: `/api/v1/catalog`, `/api/v1/uploads/:id`.
  Multi-word paths use underscores (`employee/square_timecards`).
- JSON field names are `snake_case`. MCP tool names are `snake_case` verbs or
  nouns (`list_tasks`, `sales_summary`).
- IDs are Rupert's own record IDs. Source IDs (Shopify, Square) keep their
  source and are never merged across sources: an identical SKU in Shopify and
  Square is two rows.
- Times are ISO 8601. MCP dates are `YYYY-MM-DD` in the store's time zone, and
  ranges are inclusive. MCP money is integer cents; `null` means unknown, never
  zero. The read API returns `price` exactly as mirrored from the source.

## 2. Authentication

**Integration API and MCP.** Send `Authorization: Bearer rupert_…`. Tokens are
created under **System → API access** by someone with `settings.write`. Rupert
stores only a SHA-256 digest and a short hint; the secret is shown once.
`ApiAccessToken.authenticate` accepts a token only if all of these hold:

- it matches the `rupert_` + 43 character format and a stored digest;
- it is not revoked and not expired;
- its owner is active and is not an employee (staff self-service) account;
- its tenant is active and the owner belongs to that tenant.

Browser cookies, the host name, query parameters and request bodies never
choose the tenant: the token does. Each request runs with `Current.user` and
`Current.tenant` set from the token and cleared afterwards.

**Staff app API.** `POST /api/v1/employee/session` with email and password
returns a session token (`rupert_employee_…`) that lasts 30 days
(`EmployeeAppSession`). Every staff app request, including sign-in, first checks
that the staff app is turned on for the installation
(`RUPERT_EMPLOYEE_APP_ENABLED`, off in production unless set); when it is off
the answer is `503 employee_app_disabled`. The switch is install-wide, not per
workspace or per user.
`DELETE /api/v1/employee/session` revokes the current device.

## 3. Scopes and permissions

A token carries one or more scopes. A scope works only while the token's owner
**currently** holds the matching permission; removing the permission disables
the scope on the next request. A token cannot be created with a scope its owner
lacks. This table is `ApiAccessToken::SCOPES`:

| Scope | Owner permission | Used by |
| --- | --- | --- |
| `catalog:read` | `inventory.read` | `GET /api/v1/catalog` |
| `inventory:read` | `inventory.read` | `GET /api/v1/inventory`; MCP stock tools |
| `roadmap:read` | none (active owner) | `GET /api/v1/roadmap` |
| `reports:read` | `reports.read` | `GET /api/v1/metrics`, `/metrics/:name`; MCP report tools |
| `finance:read` | `finance.read` | MCP `history_summary`, `compliance_check` |
| `timesheets:read` | `timesheets.read` | MCP `time_keeping_report`, `staff_schedule` |
| `tasks:read` | `projects.read` | MCP `list_tasks`, `list_projects` |
| `tasks:write` | `projects.write` | MCP `create_task`, `update_task` |
| `alerts:read` | `alerts.read` | MCP `list_alerts` |
| `customers:read` | `customers.read` | MCP `customer_lookup`, `customer_insights` |
| `marketing:read` | `marketing.read` | MCP `marketing_summary`, `marketing_records` |
| `purchasing:read` | `purchasing.read` | MCP `purchase_orders` |
| `system:read` | `system.read` | MCP operations tools |
| `feedback:read` | `settings.read` | MCP `list_feedback`, `report_context` |
| `uploads:read` | `uploads.read` | `GET /api/v1/uploads`, `/uploads/:id`; MCP `list_uploads` |
| `uploads:write` | `uploads.write` | `POST /api/v1/uploads` |

Some MCP tools add checks on top of the scope (administrator or platform
operator owner); [mcp.md](mcp.md) lists them per tool.

**Writes.** Only `tasks:write` and `uploads:write` let a token change anything,
and both change only Rupert's own records: tasks on Rupert's board, and files
received into the Uploads inbox. An upload token can send a file but never
approve an import. MCP `submit_feedback` stores feedback with any valid token.
No API, MCP tool or staff app endpoint writes to Shopify, Square, C-Trax or
another outside system.

The staff app API has no scopes. Each request acts as the signed-in staff
member's linked worker record: timesheets, clock shifts and Square timecards are
looked up through that worker, so another person's record answers `404`.

## 4. Tenant and permission enforcement

- Tenant-owned models include `TenantScoped`, whose default scope is
  `tenant_id = Current.tenant_id`. API controllers set `Current.tenant` only from
  the credential.
- Integration API controllers call `require_scope` before any read. The scope
  check includes the owner's current permission (`ApiAccessToken#allows?`).
- MCP `tools/list` returns only the tools the token may use. A call to a tool
  the token cannot use is answered as a tool error, not data.
- Staff app timesheet changes go through `TimesheetWorkflow`. The staff app can
  `submit`, `import_shifts`, and `reopen` a rejected timesheet; it never reviews
  or approves.

## 5. Response and error shapes

**Integration API** success: `{ "data": …, "meta": { "api_version": "v1", … } }`.
Errors: `{ "error": { "code": "…", "message": "…" } }`.

| Status | `code` | When |
| --- | --- | --- |
| 400 | `invalid_pagination`, `invalid_source`, `invalid_request`, `no_file`, `too_many_files` | Bad parameters |
| 401 | `unauthorized` | Missing, invalid, revoked or expired token; also sends `WWW-Authenticate: Bearer realm="Rupert API"` |
| 403 | `forbidden` | Token lacks the scope, or the owner lacks the permission |
| 404 | `not_found` | Record not in this tenant |
| 413 | `too_large` | Upload request over the size limit |
| 422 | — | Every file in an upload request was rejected (body still lists each file and its reason) |
| 429 | `rate_limited`, `limit_reached` | Rate limit (`Retry-After` header) or upload quota |

**Staff app API** uses a flatter, older shape: `{ "error": "code" }`, sometimes
with `"message"`. Codes: `unauthorized` (401), `invalid_credentials` (401),
`forbidden` (403), `not_found` (404), `invalid_request` and `unsupported_action`
(422), `rate_limited` (429), `employee_app_disabled` (503). The mobile app
depends on this shape, so it stays as it is within v1.

**MCP** follows JSON-RPC 2.0. Protocol problems return JSON-RPC errors
(`-32700`, `-32600`, `-32601`, `-32602`). Tool problems (denied scope, bad
arguments, missing record) return a normal result with `isError: true` and a
plain-language message. HTTP `413` for bodies over 256 KiB, `405` for
`GET /mcp`, `403` for a cross-site `Origin`.

All three interfaces send `Cache-Control: no-store`.

## 6. Pagination and filtering

**Integration API lists** (`catalog`, `inventory`, `uploads` index): `page`
(1–1000, default 1) and `per_page` (1–100, default 50). Out-of-range or
non-numeric values return `400 invalid_pagination`. `meta` carries `page`,
`per_page`, `has_more` and `next_page` (`null` on the last page or at page
1000). Lists are ordered by ID (uploads newest first). Pages are live reads, so
a sync between requests can shift rows.

Filters: catalog `source=shopify|square` (default `shopify`); inventory
`source` and `location_id`; uploads `status` and `sha256` (64 hex characters).
Unknown filter values on uploads are ignored; an unknown `source` is `400`.

**MCP tools** that list use `page` (1–1000) and `per_page` (1–50, default 25)
with the same `meta.has_more` / `meta.next_page`. Results over 200 KB are
refused with a hint to narrow the request.

**Staff app lists** are capped instead of paged: up to 104 timesheets and 100
clock shifts, newest first. Square timecards return 100 at a time with
`next_before` (pass it back as `before`).

## 7. Idempotency for writes

There is no general `Idempotency-Key` header. Each write handles retries in its
own way:

| Write | Retry behaviour |
| --- | --- |
| `POST /api/v1/uploads` | A file whose SHA-256 matches a retained upload is stored as `duplicate` of the earlier one and answers `200` (not `201`); nothing is imported twice |
| MCP `submit_feedback` | With `source_ref`, the same message is filed only once |
| MCP `create_task` | **Not idempotent**: a repeated call adds another task |
| MCP `update_task` | Field changes set values, so a repeat gives the same result; a `note` is appended again on every call |
| `POST /api/v1/employee/clock` | Send a `request_token`; a retry with the same token, or while a shift is already open, returns the existing shift |
| Staff timesheet changes | Go through `TimesheetWorkflow`; stale or invalid transitions answer `422` |

## 8. Rate limits

From `config/initializers/rack_attack.rb`. Over a limit answers `429` with
`Retry-After` and `{ "error": { "code": "rate_limited", … } }`.

| Bucket | Limit |
| --- | --- |
| `/api/v1/*` with a token | 300 per minute per token |
| `/api/v1/*` without a token | 60 per minute per IP |
| `POST /api/v1/uploads` | 30 per minute per token |
| `POST /mcp` with a token | 120 per minute per token |
| `POST /mcp` without a token | 30 per minute per IP |
| `POST /api/v1/employee/session` | 10 per minute per IP, plus the shared login throttle |
| Everything | 600 per minute per IP |

## 9. Versioning, stability and deprecation

The version is in the path (`/api/v1`) and in `meta.api_version` on integration
API responses. MCP negotiates its protocol version (`2025-06-18`, `2025-03-26`,
`2024-11-05`); Rupert's tool set is not separately versioned.

**What v1 promises today.** Within `/api/v1` and the MCP tool set, these do not
change without the deprecation rule below: existing paths and tool names,
existing response fields and their meaning, error codes, scope names and the
scope-to-permission mapping, pagination parameters and limits.

**Allowed without notice:** adding endpoints, tools, optional parameters,
response fields, error codes for new failure cases, and new scopes. Clients
must ignore fields they do not know.

**Rule for changes (deprecation).** A breaking change to the list above needs:

1. a GitHub issue that names the change, who is affected and the replacement;
2. the replacement shipped first, with both working side by side;
3. a note in the relevant guide (`api-v1.md`, `mcp.md`) marking the old form
   deprecated, with the date it may be removed;
4. at least 90 days, matching the default token lifetime, before removal, or a
   new path version (`/api/v2`) if the old form cannot stay.

Security fixes may tighten access immediately (for example, refusing a scope an
owner no longer holds). No deprecation has been needed yet.

The staff app API is used only by Rupert's own mobile app, which ships from this
repository. It may change together with the app, but a change must keep the
currently installed app version working until the update is out.

## 10. Safe examples

Use a placeholder host and an environment variable; never paste a real token.

```sh
export RUPERT_API_TOKEN=rupert_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
curl -H "Authorization: Bearer $RUPERT_API_TOKEN" \
  'https://rupert.example.com/api/v1/inventory?source=square&per_page=50'
curl -H "Authorization: Bearer $RUPERT_API_TOKEN" \
  'https://rupert.example.com/api/v1/metrics/gross_sales?period=last_month&compare=previous'
curl -H "Authorization: Bearer $RUPERT_API_TOKEN" -F file=@statement.csv \
  'https://rupert.example.com/api/v1/uploads'
```

## 11. Tests that pin the contracts

| Contract | Tests |
| --- | --- |
| Token auth, scopes, tenant isolation, catalog/inventory/roadmap shapes | `web/test/integration/api_integration_test.rb` |
| Metrics endpoints | `web/test/integration/api_metrics_test.rb` |
| Uploads endpoints | `web/test/integration/uploads_api_test.rb` |
| MCP protocol, tools, scopes, errors | `web/test/integration/mcp_server_test.rb`, `mcp_operations_test.rb`, `mcp_history_summary_test.rb` |
| Staff app API | `web/test/integration/employee_timesheets_test.rb` and related employee tests |
| Docs match code (scopes, tools, routes) | `web/test/integration/api_docs_contract_test.rb` |

The last test fails when a scope, MCP tool or `/api/v1` route is added without
being documented here or in [mcp.md](mcp.md).

## 12. Known gaps

- No OpenAPI description, webhooks, per-client rate-limit settings or general
  idempotency key.
- The staff app error shape differs from the integration API shape.
- `create_task` is not idempotent, and `update_task` appends its `note` on every call.
- Contract tests per in-scope module beyond the files above are still to be
  written ([#430](https://github.com/techmore/rupert/issues/430)).
