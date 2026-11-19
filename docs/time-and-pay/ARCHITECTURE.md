# Time, scheduling and pay: architecture

Written 2026-11-06 from a read of `main` at `f10b74f9`. Companion documents: [DECISIONS.md](DECISIONS.md)
(policy defaults and why), [DESIGN.md](DESIGN.md) (shared vocabulary, statuses, copy),
[DEPLOYS.md](DEPLOYS.md) (production log) and [REPORT.md](REPORT.md) (what was built).

## What runs where

| Layer | Owner | Notes |
| --- | --- | --- |
| Server, web UI, JSON API | Rails 8.1 in `web/` (SQLite, Solid Queue) | The only backend. The Rust core (`core/`) was removed on 2026-10-19 (`4cb15da4`); nothing time-related ever lived there. |
| iPhone app | `ios/` Swift, Hotwire Native 1.3.1 shell around the web pages | Native tab bar, sheets, Face ID lock, barcode scanner, Google sign-in handoff. Every time/pay screen is a web page rendered in the app; native code adds push registration and the Time tab. |
| Staff app (older) | `mobile/` Expo/React Native | Calls `/api/v1/employee/*` (kill-switched off in production since 2026-10-25). Kept building; the iPhone app is the one being submitted. |
| POS | `/ctrax_pos` full-screen web cashier (`layouts/pos`) | Card: Dejavoo SPIn cloud terminal (P-series), Authorize.net (Accept.js) and NMI for hosted/online, cash. Square is a former payment provider: catalog/inventory/orders/loyalty sync only. |

## Identity, auth and roles

- `User` signs in (email/password, Google). `People::Employee` is the HR record, linked by `employees.user_id`.
  `TimeClockService.worker_for(user)` resolves exactly one active worker or refuses.
- Roles are a string enum on `User`: `super_admin`, `admin`, `manager`, `shift_leader`, `cashier`,
  `inventory_employee`, `reporting`, `reader`, `employee`. Permissions are `module.action` strings resolved
  user override → tenant role override → built-in matrix (`User::ROLE_PERMISSIONS`). The brief's
  employee / shift lead / manager / owner / admin map to `employee`, `shift_leader`, `manager`, `admin`,
  `super_admin`. Location scoping is new in this work (`users.location_ids`, see DECISIONS).
- Employee-role accounts are hard-allowlisted per controller in `ApplicationController#restrict_employee_workspace`.
- The iPhone app shares the browser session cookie (14 days). The Expo app uses `EmployeeAppSession` bearer tokens.

## What existed before this work (and is kept)

| Area | Where | Kept as |
| --- | --- | --- |
| Clock punches | `ClockShift`, `TimeClockService`, `TimeClockController` (`/time_clock`) | The punch record. Extended with location, source, breaks, PIN. |
| Corrections | `ClockCorrection` (original and proposed times, reviewer, status) | The audit trail for edited punches. Extended with breaks. |
| Timesheets | `People::Timesheet`, `TimesheetWorkflow` (draft → submitted → approved/rejected), `TimesheetEvent` | Review unit for pay. Exceptions view and bulk approve added on top. |
| Schedules | `People::ScheduledShift` (planned shift, location, warnings) | Extended with publish, open shifts, templates, availability, trades. |
| Time off | `People::LeaveRequest`, `People::LeaveBalance`, `LeaveRequestWorkflow` | Extended with accrual policy, blackout dates, notifications. |
| Pay rules | `PayRules` (one Setting row; owner decisions of 2026-10-25) | Kept verbatim. Location time rules added beside it (`TimeRules`). |
| Pay estimate | `EmployeePayWeek`, `CommissionPreview` | Tip input replaced by `TipAllocation` ledger. |
| Payroll | `People::PayRun`, `People::Payslip`, `PayRunCsv`, `People::PayrollCalculator` | Period lock and provider-agnostic export added (`PayPeriod`, `PayrollExport`). |
| Notifications | `Notification` (in-app bell) | Push delivery added (`PushDevice`, `PushNotifier`). |
| Source history | Square timecards, C-Trax labor shifts (read-only) | Unchanged. |

## Payments and tips: the data path

```
P-series terminal ──SPIn Sale(TipAmount, InvoiceNumber=checkout ref)──▶ PosPaymentAttempt ──▶ PosCheckout(tip_cents, user_id) ──▶ Core::Order(tip_cents)
        │
        └──FEED webhook (every transaction + batch close)──▶ DejavooFeedEvent(tip_cents, batch_number, performed_by, terminal_id, invoice_number)
Authorize.net Reporting API (settled batches, transactions with tip) ──▶ AuthorizeNetTransaction / AuthorizeNetBatch
```

`Tips::Attribution` turns each card tip into `TipAllocation` rows (see DECISIONS for the order of evidence:
checkout cashier → FEED `performedBy` clerk id → clocked-in staff at that register/time). Settlement
(`Tips::Reconciliation`) marks allocations settled against Authorize.net batches / Dejavoo batch close, reverses
them on refund/void and records tip adjustments as deltas. Allocations carry the pay period they belong to; a
batch that settles after a period is locked lands in the next open period as a carried adjustment.

## Deployment

Merging to `main` deploys to SER8 (Incus container `rupert`, `/opt/rupert`): `rupert-autodeploy` polls every 5
minutes, requires the exact SHA's `CI (sqlite3)`, `Product site consistency` and `Dependency and static scan`
checks, takes a SQLite backup, migrates, precompiles, restarts `rupert-web`/`rupert-jobs`, checks `/up` and the
`X-Rupert-Build` header, and rolls the code back on failure (migrations stay, so every migration here is additive).
See `deploy/ser8/README.md`, `docs/ops/backups.md` and [DEPLOYS.md](DEPLOYS.md).
