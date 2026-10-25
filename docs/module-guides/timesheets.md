# Time clock and timesheets

Last checked against `main` at `ec5ae024` on `2026-10-25`.

## Purpose and owner

Staff record the hours they work (Time clock), put them on a weekly timesheet,
and submit it; a reviewer approves or returns it. Approved hours feed draft pay
runs ([payroll guide](payroll.md)). Read-only Square and C-Trax histories show
source hours next to Rupert's own. Product owner: store owner. Reviewer of
changes: Unknown (no named reviewer is recorded).

`ModuleRegistry` keys: `time_clock` (Me), and in Team → Time: `time_keeping`,
`timesheets`, `punch_history`, `square_timesheets`, `ctrax_timesheets`.

## Data model

- `ClockShift` (`clock_shifts`): one clock-in/clock-out interval per worker,
  with a client `request_token`. Overlapping shifts for one worker, or overlap
  with imported Square hours, are rejected.
- `ClockCorrection`: a requested change to a shift. Original and proposed times
  are read-only after creation; status `pending`, `approved` or `rejected`.
- `People::Timesheet` (`timesheets`): one employee and a period of at most
  31 days; periods for one employee cannot overlap.
- `People::TimesheetEntry`: hours per day with `work_type` (`regular`,
  `overtime`, `pto`, `holiday`) and an optional `clock_shift_id` when imported from the clock.
- `People::TimesheetEvent`: one row per workflow action (actor, action, details).
- `SquareTimecard` / `SquareTimecardDay` and `CtraxLaborShift`: imported source
  history, kept separate from Rupert timesheets.

All of these are `TenantScoped`.

## Permissions and tenant boundary

- `timesheets.self`: own time workspace (the `employee` role has it).
- `timesheets.read`: everyone's timesheets, Time keeping, Punch report, source
  history. `timesheets.write`: edit any timesheet. `timesheets.review`
  (`shift_leader` role) with `timesheets.read` allows approve/reject.
- `People::TimesheetPolicy`: a reviewer can never approve or reject a sheet for
  their own linked employee. Staff without `timesheets.write` can reopen only
  their own rejected sheet.
- `TimesheetWorkflow` refuses work unless the user is active and belongs to the
  current, active tenant. See also [navigation and access](../ops/navigation-access.md).

## Routes and API

- Web: `/time_clock` (clock in/out, corrections), `/people/timesheets`
  (with `submit`, `approve`, `reject`, `reopen`, `bulk_approve`, entries,
  `import_shifts`; CSV download), `/people/time_keeping`, `/people/punch_history`,
  `/people/square_timesheets`, `/people/ctrax_timesheets`.
- Staff app API: `/api/v1/employee/clock` and `/api/v1/employee/timesheets`
  (see [staff app guide](staff-app.md) and [API standards](../api-standards.md)).
- MCP tools: `time_keeping_report` and `staff_schedule` (`timesheets:read`).

## Workflow and status transitions

`People::Timesheet` uses AASM: `draft` → `submitted` (submit) → `approved` or
`rejected` (review) → `draft` (reopen). Only drafts can be edited. Submit needs
at least one entry, an active employee, and imported clock entries that still
match their shifts with no pending correction. Reopen is refused while a payslip
covers the period. A sheet with submission history cannot be deleted. All of
this runs inside `TimesheetWorkflow`, used by both the web and the staff app.

Clock corrections go `pending` → `approved` or `rejected`; approval changes the
shift, the request is kept.

## UI patterns

Timesheets is a List page with a Detail page per sheet (`More` menu) and Add/Edit
forms. Time keeping and Punch report are Report pages with a date range. Square
and C-Trax history are read-only List/Detail pages. Known departure: Square and
C-Trax history are source-named pages, which the
[interface guidelines](../ui-standards.md) mark as transitional.

## Integration and sync

Square timecards are read with `TIMECARDS_READ` only, optionally every 15 minutes
per opted-in tenant ([Square history](../ops/square-timecard-history.md)).
C-Trax labor history refreshes every 15 minutes when enabled
([C-Trax refresh](../ops/ctrax-timesheet-refresh.md)). Nothing is written back to
Square or C-Trax, and source history never enters payroll generation.

## Audit history

`TimesheetEvent` rows for every workflow action (entry changes store before and
after values), `ActivityLogger` entries named `timesheet_<action>`, reviewer and
review time on the sheet, and the retained original times on `ClockCorrection`.

## Failure and recovery

Errors return a one-sentence alert (web) or `422 invalid_request` (API). Clock-in
with the same `request_token` returns the existing shift, so retrying is safe; a
busy database asks the person to retry. Re-importing shifts refreshes entries
without duplicates. Writes take a tenant-wide lock so overlapping periods cannot
race on SQLite. Restore follows the
[backup and restore runbook](../ops/backup-restore-runbook.md).

## Required tests

`test/integration/time_clock_test.rb`, `time_clock_concurrency_test.rb`,
`timesheet_reviews_test.rb`, `employee_timesheets_test.rb`,
`demo_timesheets_test.rb`, `time_keeping_test.rb`, `punch_history_test.rb`,
`square_timecard_history_test.rb`, `ctrax_timesheet_schedule_test.rb`,
`employee_source_timesheets_test.rb`, the release-gate walkthrough
`test/acceptance/timesheet_lifecycle_walkthrough_test.rb` (#422), and the Square timecard service and job
tests under `test/services` and `test/jobs`.

## Open gaps

- [#422](https://github.com/techmore/rupert/issues/422): the synthetic lifecycle walk
  (clock, correction, submit, reject/reopen, approve, history, export, payroll lock) is
  `test/acceptance/timesheet_lifecycle_walkthrough_test.rb`; the issue closes on its
  recorded evidence.
- Timezone: clock shifts are split into days at local midnight (America/New_York) and
  paid on elapsed time, so a shift across the November daylight-saving change counts
  the repeated hour (22:00 EDT to 03:00 EST is 6 hours). Hours are stored to two
  decimals (`hours` is `decimal(6,2)`), so a punch interval is held to the nearest
  0.01 hour (36 seconds); there is no other rounding.
