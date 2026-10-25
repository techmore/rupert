# Payroll and incentives

Last checked against `main` at `ec5ae024` on `2026-10-25`.

## Purpose and owner

Build pay runs from approved timesheets, adjust payslips, finalize and mark them
paid. The Incentives model is a read-only "what if" for commission plans. Rupert
does not send money, file taxes or calculate real withholding. Product owner:
store owner; payroll rules need a payroll professional's review (open gate).

`ModuleRegistry` keys: `payroll` and `incentives` (Team → Pay & reports).

## Data model

- `People::PayRun` (`pay_runs`): name, period, status, totals, `paid_on`.
- `People::Payslip`: employee, pay rate, hours, `gross_cents`,
  `deductions_cents`, `net_cents` (all whole cents, never negative).
- `People::PayRate`: hourly or salaried rate per employee.
- `PayRules`: one `Setting` row per tenant (pay period weekly or every two
  weeks, week start day, overtime on/off, threshold, multiplier). Until chosen,
  Rupert uses weekly Thursday–Wednesday and shows the period as not chosen.

`PayRun`, `Payslip` and `Setting` rows are `TenantScoped`.

## Permissions and tenant boundary

`payroll.read` to see pay runs and the Incentives model; `payroll.write` to
create, generate, add/remove payslips, finalize and pay (`People::PayRunPolicy`).
Only the admin role has payroll permissions by default. `PayrollCalculator`
refuses a pay run from another tenant.

## Routes and API

Web: `/people/pay_runs` (index, show, new, create, and `generate_payslips`,
`add_payslip`, `remove_payslip`, `finalize`, `pay`), `/people/incentives`,
Settings → Pay rules (`/settings#pay-rules`). No `/api/v1` endpoint or MCP tool
reads or writes payroll.

## Workflow and status transitions

`People::PayRun` uses AASM: `draft` → `finalized` → `paid`. Payslips can be
regenerated only on a draft. Generation uses approved, non-demo timesheet
entries inside the period: hourly pay is regular hours × rate plus `overtime`
entries × 1.5; salaried pay is a prorated slice of the annual salary. Every
payslip without deductions gets a flat **15% estimate** (`TAX_ESTIMATE`).
Finalize needs at least one payslip and stores the totals. Paying needs a
finalized run and records today's date. A timesheet covered by a payslip
cannot be reopened.

## UI patterns

Payroll is a List page, a pay run is a Detail page with a `More` menu, and Add
pay run is a Form. The Incentives model is a Report page with a period picker.

## Integration and sync

None. Pay runs do not post to the ledger, a bank or a payroll provider.
Commission and card bonus figures (`TimesheetCompensation`, 1% of credited
sales and $10 per card redemption; `EmployeePayWeek`, 1% of on-shift sales and
an even tip split) are display-only and are not added to payslips.

## Audit history

`ActivityLogger` entries `pay_run_created`, `pay_run_finalized` (with the net
total) and `pay_run_paid`. Payslip-level change history: Unknown (no version
table was found).

## Failure and recovery

Actions that are not allowed in the current state redirect with a one-sentence
alert (for example "Finalize the pay run before paying."). Regeneration deletes
and rebuilds a draft's payslips inside a tenant lock, so repeating it does not
duplicate pay. There is no "unpay" or "unfinalize" action; recovery after a
wrong finalize is Unknown beyond a database restore
([backup and restore runbook](../ops/backup-restore-runbook.md)).

## Required tests

`test/integration/people_flow_test.rb` (pay run flow), `incentives_page_test.rb`,
`test/models/pay_rules_test.rb`, `pay_rules_settings_test.rb`,
`test/services/employee_pay_week_test.rb`, `incentive_model_test.rb`,
`timesheet_compensation_test.rb`, `commission_preview_test.rb`,
`live_commissions_test.rb`. No dedicated `PayrollCalculator` unit test was found.

## Open gaps

- [#423](https://github.com/techmore/rupert/issues/423): owner-approved rules
  for tips, bonuses, commission, overtime, rounding and deductions. `PayRules`
  overtime settings feed the staff pay estimate, but `PayrollCalculator` still
  uses a fixed 1.5 multiplier on `overtime` entries.
- [#424](https://github.com/techmore/rupert/issues/424): reconcile synthetic
  examples through draft, finalize, correction/reversal and export. No pay run
  export or reversal exists.
- [#425](https://github.com/techmore/rupert/issues/425): calculator output is
  not payroll-ready (flat 15% deduction, no tips or training bonuses in
  payslips, commission display-only).
- Training-bonus link: [#412](https://github.com/techmore/rupert/issues/412).
