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

Pay rate amounts, payslip hours, amounts and notes, and pay run totals and notes
are encrypted at rest (#421). Totals are added up in Ruby (`pluck`, then sum):
never `SUM()`, filter or sort these columns in SQL. Employee address and date of
birth are encrypted too. See [encryption-at-rest.md](../ops/encryption-at-rest.md).

## Permissions and tenant boundary

`payroll.read` to see pay runs and the Incentives model; `payroll.write` to
create, generate, add/remove payslips, finalize and pay (`People::PayRunPolicy`).
Only the admin role has payroll permissions by default. `PayrollCalculator`
refuses a pay run from another tenant.

## Routes and API

Web: `/people/pay_runs` (index, show, new, create, and `generate_payslips`,
`add_payslip`, `remove_payslip`, `finalize`, `pay`; `/people/pay_runs/:id.csv` downloads the
payslips, `PayRunCsv`), `/people/incentives`,
Settings → Pay rules (`/settings#pay-rules`). No `/api/v1` endpoint or MCP tool
reads or writes payroll.

## Workflow and status transitions

`People::PayRun` uses AASM: `draft` → `finalized` → `paid`. Payslips can be
regenerated only on a draft. Generation uses approved, non-demo timesheet
entries inside the period. Hourly pay is every hour × rate; overtime follows
`PayRules`: **off by default** (all hours, including entries marked
`overtime`, at straight time). When an owner turns it on, worked hours
(`regular` and `overtime` entries, not PTO or holiday) over the threshold in
each seven-day work week earn the multiplier; only days inside the pay run
count toward a week that straddles its start or end. Salaried pay is a
prorated slice of the annual salary and ignores overtime. The rate is the latest
one in effect during the pay run's period (not today's), and an employee with
approved hours but no rate for the period gets no payslip and is named in an
alert on the pay run page, never dropped silently. Every payslip
without deductions gets a flat **15% placeholder estimate** (`TAX_ESTIMATE`),
labelled "Deductions (estimate)" on the pay run page. It is not tax or
withholding; real deductions await qualified payroll review (#424, #425).
Finalize needs a draft with at least one payslip and stores the totals; finalizing
again is refused. Paying needs a finalized run and records today's date. Pay runs
cannot overlap: a second run for any of the same dates (a double-click, a retry, a
new run for a week already paid) is refused, so approved hours are paid once.
Manual payslips are entered in dollars. A timesheet covered by a payslip
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
duplicate pay, and an overlapping second pay run is refused. There is no "unpay" or "unfinalize" action; recovery after a
wrong finalize is Unknown beyond a database restore
([backup and restore runbook](../ops/backup-restore-runbook.md)).

## Required tests

`test/integration/people_flow_test.rb` (pay run flow), `incentives_page_test.rb`,
`test/models/pay_rules_test.rb`, `pay_rules_settings_test.rb`,
`test/services/employee_pay_week_test.rb`, `incentive_model_test.rb`,
`timesheet_compensation_test.rb`, `commission_preview_test.rb`,
`live_commissions_test.rb`, `test/services/payroll_calculator_test.rb`
(overtime off by default, threshold/multiplier/week start from `PayRules`,
straddled weeks, salaried, placeholder deductions) and
`employee_work_summary_test.rb`. The release-gate walkthrough
`test/acceptance/payroll_walkthrough_test.rb` (#424) runs a hand-computed pay run
from clock punches through correction, finalize, CSV export and paid
(`WALKTHROUGH_LOG=1` prints the steps). `test/services/sensitive_field_encryption_test.rb`
covers ciphertext on disk, the Ruby totals and the backfill.

## Open gaps

- [#423](https://github.com/techmore/rupert/issues/423): owner-approved rules
  for tips, bonuses, commission, rounding and deductions. `PayRules` overtime
  settings now feed `PayrollCalculator`, the staff pay estimate and the staff
  work summary; whether the threshold method matches the owner's legal
  overtime rule still needs payroll review.
- [#424](https://github.com/techmore/rupert/issues/424): reconcile synthetic
  examples through draft, finalize, correction/reversal and export. Draft
  correction and CSV export are walked in `test/acceptance/payroll_walkthrough_test.rb`;
  there is still no reversal after a run is finalized or paid.
- [#425](https://github.com/techmore/rupert/issues/425): calculator output is
  not payroll-ready (flat 15% placeholder deduction, no tips or training bonuses in
  payslips, commission display-only).
- Training-bonus link: [#412](https://github.com/techmore/rupert/issues/412).
