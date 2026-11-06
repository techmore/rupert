# Time, scheduling and pay: decisions and policy defaults

Each entry: what was decided, why, and where it is configured. Owner decisions already on record
(2026-10-25, `docs/employee-timesheets.md` "Pay rules") are kept and marked **owner**. Everything else
is a default a senior engineer would pick for a small multi-store retailer in Eastern Time; the owner
can change any of them at **Team → Settings → Time rules** (per store) without a deploy. Legal
defaults are drawn from public federal (FLSA) and state summaries as of 2026 and are not legal advice.

## Sources of truth

| Thing | Source of truth | Why |
| --- | --- | --- |
| Who works here, names, pay rates, PINs | Rupert `People::Employee` | Square is a former payment provider; its Team API still lists people but has no passcode read endpoint. Square team member ids are kept in `EmployeeSourceIdentity` (`source: 'square'`) by the existing directory sync and used only to match history. |
| Clock PIN | Rupert, set by the worker on first PIN clock-in (digest only) | Square's Team API does not expose passcodes. A worker with a Square passcode is told "Choose your Rupert PIN" once; managers can reset it. |
| Punches | Rupert `ClockShift` + `ClockBreak` | Square timecards and C-Trax labor remain read-only history (never summed with Rupert punches). |
| Planned shifts | Rupert `People::ScheduledShift` | Nothing else plans shifts. |
| Card tips | Dejavoo FEED events and Authorize.net settled transactions, attributed into `TipAllocation` | The terminal is the capture point; the gateway settlement is the money. Both are kept; settlement wins on amount. |
| Pay | Payroll provider (none yet) fed by `PayrollExport` | Rupert never moves money. |

## Square and the POS

Square is **not** the POS for card payments any more: Dejavoo SPIn terminals (Valmar merchant account,
Authorize.net gateway for online/hosted) handle cards; `docs/ops/payment-integrations.md` lists Square as
a former provider. Rupert's own cashier (`/ctrax_pos`) is the register. Square sync direction is one way,
Square → Rupert, read only, for catalog, orders, loyalty and timecard history. No employee data is written
to Square.

## Pay rules (owner, 2026-10-25; unchanged)

- Tips are shared evenly among everyone clocked in when the tip was left, administrators excluded.
  If only administrators were clocked in the tip is **unassigned**, shown, never dropped.
- Commission 1% of before-tax after-discount sales during punched-in hours; no commission for admins.
- Weekly overtime off by default (threshold 40 h, 1.5× when turned on).
- No punch rounding.
- Pay period weekly Thursday–Wednesday until chosen at Settings → Pay rules.

## Time rules defaults (`TimeRules`, per store)

| Rule | Default | Why |
| --- | --- | --- |
| Rule preset | Federal (FLSA) | The stores' state is not recorded in the repo; the owner picks the state preset (CT, MA, NY, NJ, CA, OR, CO available) and the defaults below update. |
| Meal break | Reminder after 6 h, 30 min, unpaid | Common retail practice and the MA/NY/CT rule; federal law requires none. A meal break under 20 min is treated as paid rest. |
| Rest break | Every 4 h, 10 min, paid | FLSA: short breaks are paid time. |
| Break reminders | On | Push/in-app nudge at the threshold; never auto-clocks anyone out. |
| Daily overtime | Off | Only CA/AK/NV/CO have it; the CA/CO presets turn it on. |
| Minors | Under 18; 8 h/day, 40 h/week, 7 AM–7 PM window | FLSA limits for under-16s, applied to all minors as a conservative default. The builder warns; it never blocks a manager. Date of birth is encrypted at rest already. |
| Predictive scheduling | 14 days notice (warning), 10 h minimum rest between shifts | NY/OR/CA-city style fair-workweek rules are the direction of travel; a warning costs nothing where it does not apply. |
| Punch rounding | None (owner) | Hours are the recorded seconds. |
| Buddy-punch prevention | PIN + registered store device (or a signed-in session). No photo, no GPS. | Privacy-respecting and works at a counter: a manager registers the register browser/tablet once (`ClockDevice`), after which a PIN punch from it is trusted. A PIN from an unknown browser is refused with "Use the store register or sign in". Photo capture is listed as a later option, off. |
| PIN | 4 digits, 5 tries then 10 min lockout | Fast at the counter; lockout stops guessing. |
| Trades | Need manager approval; 2 h minimum notice; blocked when they would create overtime, double-booking, a minor rule breach or an unqualified position | Guardrails run when a taker accepts and again at approval (`checks_json`). |
| Time off | 7 days notice requested (warning); blackout dates flagged, not blocked | Managers decide; the system informs. |
| Sick accrual | Off (0 per hour) | Most state laws use 1 h per 30 h worked; the state presets set that. |
| Vacation | 80 h/year grant; sick 40 h/year; carry-over cap 40 h | Matches the existing `LeaveBalance` defaults. The grant lands on **January 1** (the first `LeaveAccrualJob` run of the year), not the hire anniversary, so every balance resets on the same day as the leave year. On that run last year's unused vacation and sick hours carry over up to the cap; the excess is written to the ledger as a `carryover_cap` line so nothing disappears silently. Sick hours earned on hours worked are credited daily from paid clock hours since the last run (`employees.sick_accrued_through`). Every change is a `People::LeaveAccrual` line visible on the staff member's page. |
| Tips | Pool, admins excluded, per store, cash tips declared by the worker at clock-out | Owner rule plus a declared-cash step so the record is complete for tax reporting. |

## Card tip attribution (`Tips::Attribution`)

Order of evidence for who earned a card tip, strongest first:

1. **Checkout cashier**: the FEED event or Authorize.net transaction carries Rupert's checkout reference
   (`external_reference_id` / `invoice_number` = `PosCheckout#reference`), whose `user_id` is the signed-in
   cashier → their worker.
2. **Terminal clerk id**: FEED `performedBy` matched to `employees.employee_number` (the same number
   staff type on the terminal). Stored on the event as `performed_by`.
3. **Time and register match**: the terminal (`tpn` → `PosTerminal` → register/store) and the transaction
   time → the workers clocked in at that store at that moment.

Under the owner's **pool** rule all three only decide *which store's* pool the tip joins; the split is
among everyone clocked in at that store at that moment (admins excluded), in whole cents with the
remainder going to the earliest clock-in. Under **direct** the cashier (1 or 2) keeps it and 3 is the
fallback. When nobody eligible was clocked in the allocation is **unassigned** and listed for the manager.

Settlement: `Tips::Reconciliation` matches allocations to Authorize.net settled transactions (by
transaction id / invoice) and to Dejavoo batch close totals, marks them `settled`, and creates mirrored
negative rows for refunds, voids and tip adjustments (`TipAdjust` on SPIn, `tip_amount` changes on
settlement). A batch that settles after its pay period is locked lands in the next open period with
status `carried`, so an exported payroll file never changes under the provider.

## Payroll export

Provider-agnostic CSV per employee per period with regular, overtime (weekly and daily), PTO, sick,
holiday hours, card tips, cash tips, commission, bonuses, and the pay rate on record. Period lock
(`PayPeriod`) refuses new or changed hours/tips inside a locked period; approved corrections after the
lock become next-period adjustments. The file's SHA-256 is recorded on the period.

## Roles and store scope

`employee` (own records), `shift_leader` (review timesheets, approve trades/corrections for their stores,
no pay), `manager` (schedule, time off, timesheets, tips reconciliation; no payroll), `admin` (payroll,
rules, devices), `super_admin` (platform). Managers and shift leads can be limited to stores
(`users.location_ids`); empty means all stores. Employees only ever see their own pay.

## Time zones, DST, overnight

Every store has a `Location#timezone`; punches are stored in UTC and shown in the store's zone
(`BusinessClock`). Overnight shifts keep one punch pair and split at midnight only when hours are
imported into a timesheet (existing behaviour). DST: durations are computed from instants, so a shift
across the fall-back night counts the real hour.

## Retention, PII, offboarding

Punches, allocations and corrections are kept for 4 years (FLSA 3 years, plus a year); nothing is
auto-deleted by this work. Terminating a worker revokes app sessions and setup links, clears the PIN,
unassigns future shifts (they become open shifts) and cancels live trades (`Offboarding`). Address and
date of birth stay encrypted at rest (existing).

## Accessibility and language

All new screens: 44 px targets, Dynamic Type friendly (rem sizes), VoiceOver labels on icon buttons,
contrast checked with `bin/check-palette-contrast`, dark mode via tokens. Spanish strings for the
employee-facing clock, time-off and pay screens live in `config/locales/es.yml`; a worker's `locale`
is set from their profile.
