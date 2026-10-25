# Dashboard and cash flow

Last checked against `main` at `ec5ae024` on `2026-10-25`.

## Purpose and owner

The **Dashboard** is each person's home page: a set of widgets for sales,
stock, tasks and money they are allowed to see. **Cash flow** answers "where
is the money?" for a date range: what came into and left the bank, what was
sold, what was recorded as spent, and where cash stands. Both only read.
Product decisions: store owner; finance figures are reviewed by the owner and
bookkeeper.

`ModuleRegistry` keys `dashboard` ("Dashboard", section **Overview**) and
`cash_flow` ("Cash flow", section **Bookkeeping**, group **Overview**).
Operator guide: [Cash flow dashboard](../ops/cash-flow-dashboard.md).

## Data model

Neither page owns business records. They read:

- `DashboardSales`: paid/fulfilled canonical orders plus completed C-Trax and
  SwipeSimple sales, USD only, built per request. It never reads payment,
  deposit or ledger mirrors.
- `CashFlowReport`: `bank_statement_lines` (by `posted_on`, optionally one
  account), `DashboardSales`, `expenses`, `vendor_payments`, the retained
  statement balance from `BookkeepingOverview`, and the latest retained
  `CashForecastScenario`.
- The only stored state is each user's widget order and hidden widgets in
  `users.dashboard_config`.

## Permissions and tenant boundary

- Dashboard: `dashboard.read` (every default role except `employee`, whose
  navigation is limited to the staff pages). Each widget has its
  own permission list in `DashboardWidget::PERMISSIONS`, for example
  `cash_flow` needs `finance.read`, `revenue` needs `sales.read`,
  `commissions` needs `payroll.read`. A widget the user cannot see cannot be
  saved into their layout.
- Cash flow: `finance.read` for the page and its JSON.
- All source models are `TenantScoped`, so figures come from the current
  tenant only.

## Routes and API

- `GET /` and `GET /dashboard` (`home#index`); `POST /dashboard/customize`
  (body `{ widgets: [...], hidden: [...] }` or `{ reset: true }`).
- `GET /finance/cash_flow` (HTML, Turbo Stream refresh, and
  `.json?range=90d&account=...`). The JSON uses the signed-in session, not an
  API token, and is not part of the `/api/v1` contract.
- Related token APIs: `GET /api/v1/metrics` and `/api/v1/metrics/:name`
  (`reports:read`), and MCP `business_pulse`, `metric`, `sales_summary`. See
  [API standards](../api-standards.md) and [MCP](../mcp.md).

## Workflow and status transitions

None. Both pages read only. Cash flow ranges are `30d`, `90d`, `ytd`, `12m`
or custom from/to dates; bad dates fall back to the last 30 days.

## UI patterns

- Dashboard: **Overview** template; greeting header with the date as
  eyebrow, then the person's widgets in their saved order.
- Cash flow: **Report** template; `page_header`, period tabs, a
  `toolbar-band` with from/to and bank account, `Apply`, then figures, two
  charts with table twins and recent money events. Chart colours are theme
  tokens (`--chart-*`).
- Cash flow refreshes itself every 30 seconds while the tab is visible and
  shows "Live · refreshed Ns ago".

## Integration and sync

No outside calls. Figures are only as fresh as the source syncs and uploads
behind them (Shopify, Square, C-Trax, SwipeSimple, bank statement uploads).
Nothing here writes to any outside system.

## Audit history

None for page views or the 30-second live refresh. Saving or resetting the
dashboard layout writes `dashboard_layout_saved` (widget and hidden counts) or
`dashboard_layout_reset`. Downloading the cash flow JSON writes
`data_exported` with the date range (and "one bank account" when filtered; the
account label is not copied). Retaining a cash forecast writes
`cash_forecast_retained`.

## Failure and recovery

- Missing or uncertain data is shown as warnings, not hidden: for example
  non-USD or missing-amount sales are excluded with a warning, and C-Trax
  sales show "unavailable until the original encryption keys are restored"
  when they cannot be read.
- Cash balance with no retained statement closing balance is
  **Unavailable**, not zero. Runway is shown only when a verified balance
  exists and the average daily net is negative.
- Undecided bank lines count and appear as "Not yet reviewed".
- A bad cash flow range redirects with an alert (HTML) or returns 422 with
  `{ "error": ... }` (JSON).

## Required tests

- `web/test/integration/dashboard_customize_test.rb`
- `web/test/models/dashboard_widget_test.rb`
- `web/test/services/dashboard_presenter_test.rb`,
  `dashboard_sales_test.rb`
- `web/test/integration/cash_flow_page_test.rb`
- `web/test/services/cash_flow_report_test.rb`

## Open gaps

- Dashboard and cash flow acceptance against scoped bank accounts
  ([#427](https://github.com/techmore/rupert/issues/427)) is closed on owner
  acceptance; bank-to-ledger account binding
  ([#203](https://github.com/techmore/rupert/issues/203)) is closed.
- The sales-to-ledger posting policy
  ([#204](https://github.com/techmore/rupert/issues/204)) is open, so
  statements built from the ledger may be incomplete. Cash flow compares
  sales with deposits; it is not a reconciliation.
