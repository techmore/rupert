# Time, scheduling and pay: design vocabulary

Follows `docs/ui-standards.md` (templates, verbs, pills). This file adds the words and states that are
specific to time and pay so that web, POS and the iPhone app say the same thing.

## Names (one word each, everywhere)

| Concept | Say | Never |
| --- | --- | --- |
| Punching in/out | **Clock in**, **Clock out** | Punch, Check in, Start shift |
| Rest break | **Break** | Rest, Pause |
| Meal break | **Meal** | Lunch, Dinner |
| A planned shift | **Shift** | Rota, Assignment |
| A shift nobody owns yet | **Open shift** | Unassigned shift, Vacant |
| Offering your shift away | **Give away** | Drop, Release |
| Swapping with a colleague | **Swap** | Trade (use "trade" only as the umbrella word for give/swap/pick up) |
| Claiming an open shift | **Pick up** | Claim, Take |
| Time off of any kind | **Time off** (types: Vacation, Sick, Personal, Unpaid) | PTO (only in the payroll export column), Leave (only in URLs) |
| Changing a punch | **Fix a punch** → creates a **Correction** | Edit time, Amend |
| The week's hours record | **Timesheet** | Timecard |
| Pay period | **Pay period** | Pay cycle, Payroll run |
| Tip money from cards | **Card tips** | Credit tips, Gratuity |
| Tip money declared in cash | **Cash tips** | |
| Sharing tips | **Tip pool** / **Shared** | Tip out |
| Before the payroll file | **Estimated** | Projected, Pending |
| After the period is locked | **Final** | Confirmed |

## Statuses and pills

| State | Pill | Word |
| --- | --- | --- |
| Clocked in | `pill-fern` | Clocked in |
| On break / meal | `pill-olive` | On break · 12 min / On meal |
| Clocked out | `pill-taupe` | Clocked out |
| Forgotten clock-out | `pill-rose` | Never clocked out |
| Waiting for a manager (correction, time off, trade, timesheet) | `pill-clay` | Waiting |
| Approved | `pill-fern` | Approved |
| Denied / returned | `pill-rose` | Denied (time off, trade) · Returned (timesheet) |
| Cancelled / expired | `pill-taupe` | Cancelled · Expired |
| Shift not yet posted | `pill-taupe` | Draft |
| Shift posted | none (default) | |
| Open shift | `pill-clay` | Open |
| Tip estimated | `pill-taupe` | Estimated |
| Tip settled | `pill-fern` | Final |
| Tip unassigned | `pill-rose` | Unassigned |
| Pay period open / locked / exported | `pill-taupe` / `pill-olive` / `pill-fern` | Open · Locked · Exported |

## Icons (navigation_icon keys)

`clock` clock in/out · `calendar` schedule · `sun` time off · `wallet` pay · `swap` trades · `inbox` approvals ·
`check` approve · `x` deny. The POS clock button is a clock glyph with the live state colour as a dot.

## Copy rules

- Confirmations are one big line with the time: **Clocked in · 9:02 AM ✓**, **Clocked out · 5:31 PM · 8.2 h**.
- Every request form ends in one button named for the outcome: **Request time off**, **Offer shift**,
  **Pick up shift**, **Send correction**. Never "Submit".
- Manager decisions are **Approve** / **Deny** (time off, trades, corrections) and **Approve** / **Return**
  (timesheets) to match the existing timesheet words.
- Money: `$1,234.56`; estimated money carries the word *estimated* in the label, not an asterisk.
- Times in the store's zone, `9:02 AM`; dates `Thu, Nov 6`. Durations `8.2 h`, `45 min`.
- Spanish strings mirror these exactly (`es.yml`).

## Templates used

| Screen | Template | Notes |
| --- | --- | --- |
| Employee home (`/employee`) | Overview | Clock card first, then today's shift, then three cards: Schedule, Time off, Pay. |
| POS clock | `.pos-sheet` dialog | PIN pad, 44 px keys, one confirmation line, closes itself. |
| My schedule | List (week stepper) | Day rows; trades as row actions. |
| Time off | Form over a List | Balances row, then request form, then requests. |
| Pay | Report | Period stepper, stat row (Hours, Estimated gross, Tips, Bonuses), breakdown rows. |
| Timesheets (manager) | List, exceptions first | Toolbar: period, store, `Needs attention` filter default. Bulk approve in the header. |
| Schedule builder | Full-window List | Grid of people × days, drag and drop, labour cost line. |
| Approvals inbox | List | One row per item, Approve/Deny inline. |
| Tips | Report | Period stepper; Settled vs estimated vs unassigned. |
| Payroll periods | List → Detail | Lock, Download CSV. |
| Time rules | Settings | One section-card per topic, store selector. |
