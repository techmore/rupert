# Time & pay: multi-workspace audit (2026-11-10)

A read of the time-keeping system on `main` at `0cb2020a` (PRs #640, #642, #644), asking one question of every
query, job, setting and client: **does this still hold when a second workspace uses it?** Followed by the fixes and
the per-workspace switches that came out of it. Companion documents: [ARCHITECTURE](../time-and-pay/ARCHITECTURE.md),
[DECISIONS](../time-and-pay/DECISIONS.md), [staff timesheets](../employee-timesheets.md).

## How workspaces are kept apart

Every time & pay model includes `TenantScoped` (`default_scope { where(tenant_id: Current.tenant_id) }`), so a
record id from another workspace is simply not found (404). `Current.tenant` comes from the signed-in account, the
bearer token's own row (staff API), the registered clock device's row (kiosk) or the host name for an anonymous
request. `User` and `Setting` are not scoped by default; every time & pay read of them names the workspace.
No cross-workspace read was found. The findings below are about the edges of that boundary, about what one
workspace's choices do to another, and about leaks between people inside one workspace.

## Findings

| # | Severity | Area | What was wrong | Fix |
| --- | --- | --- | --- | --- |
| 1 | High | Payroll | A timesheet imported each punch as **gross** hours (clock-in to clock-out). The Pay page, overtime checks and leave accrual all count **paid** hours (unpaid meals removed), so an exported pay period paid a 30-minute unpaid meal that the worker's own page did not show. | `ClockShift#paid_hours_between`; the import, the staleness checks and the export now agree. A draft imported before the fix asks for a re-import at submit. |
| 2 | High | Time zones | Day, week and pay-period boundaries, the midnight split of an imported shift, "today" and every displayed clock time used the instance zone (Eastern). A workspace elsewhere got hours on the wrong day and in the wrong period. No workspace or store could record a zone. | `tenants.time_zone` (blank = instance default, so the existing workspace is unchanged), chosen at Settings → Time rules. Every web request, staff API request, kiosk request and time & pay job runs on the workspace's clock (`Current.with_tenant`, `use_business_zone`). |
| 3 | High | Push | A phone's push token was unique per workspace only, and sign-out could not reach the server (the "forget" call needs no session now; it used to need the one that had just ended). A second person on the same phone kept receiving the first person's schedule and approval notifications. | A token registers to one account everywhere (`PushDevice.register!` stops every other row with that token); forgetting needs only the token digest; signing out of the iPhone app, offboarding and deactivation stop delivery; a deactivated account or inactive workspace is never pushed to. |
| 4 | Medium | PIN clock | An anonymous browser on a workspace's address could tell a real PIN from a wrong one (two different refusals), wrong tries were counted per session cookie (reset by discarding it), and each try ran one bcrypt comparison per worker. | Nobody vouching (no store device, no sign-in) is refused before the digits are read. A signed-in phone is only ever compared with its own person's PIN. Tries are counted per store device or network address. |
| 5 | Medium | Privacy | **Team schedule** showed every worker's daily hours to any account linked to a staff record (cashier, reader, inventory). | Reviewers see their stores' staff; everyone else sees their own row. |
| 6 | Medium | Privacy | The punch report (page and CSV) showed every worker's hourly rate and estimated pay to reviewers without payroll access (shift leads). | Rates need `payroll.read`, except your own. |
| 7 | Medium | Store scope | A manager limited to stores could approve a punch fix, a timesheet or time off for another store's staff by posting its id (only the inbox filtered). | `People::StoreScope.covers?` in `TimeClockService.review`, `TimesheetPolicy#approve?` and the time-off policy. |
| 8 | Medium | iPhone app | The workspace handoff trusted any `control` origin in its link (readiness finding 12). A notification's `url` could name another workspace's address. There was no way to leave a workspace, so a second person stayed on the first one's sign-in page with its control-plane session and cached pages still in the web views. | The handoff accepts only the app's own control plane; a notification opens only a path on the current instance; **Settings → Switch workspace** forgets the push token, clears the web views' data and returns to the control plane. Push registration now carries the web views' session cookie explicitly. |
| 9 | Medium | Jobs | The C-Trax labour, Square timecard and directory schedulers stopped at the first workspace that raised, skipping the rest. Leave accrual computed "today" once, in the instance zone, for every workspace. `Current.set(tenant:)` kept the previous workspace's per-request caches. | Per-workspace rescue; `today` per workspace; `Current.with_tenant` resets caches and sets the zone. |
| 10 | Low | PIN clock | `/clock/workers` raised a 500 for an anonymous request (nil user). The web clock-in trusted a `source` form field. The staff API recorded its punches as `web`. | Empty list; the server decides the source (`web`, `ios`, `api`). |
| 11 | Low | Expo client | Every EAS profile prefilled the Herbal Healers address; sign-out left the previous name and workspace on screen. | No prefill; cleared; the sign-in error says to check the workspace address. |
| 12 | Low | Accounts | One email signs in to one workspace. A second workspace issuing a setup link for that email was told to "link the existing account", which it cannot see. | The refusal says what to do (use a different email) without saying where the account lives. |
| 13 | Low | Audit | Time-rules changes logged only the names of the fields posted. | The log line carries each changed value, old → new, and nothing is logged when nothing changed. |

Checked and sound: bearer tokens (workspace taken from the token row, sign-in refused on another workspace's
host), clock-device cookies (looked up inside the current workspace only), setup links, PIN uniqueness and
per-worker lockout (per workspace), pay rules, time rules, pay periods and locks, tip ledger, leave balances,
notification preferences (all stored per workspace or per user, with defaults for a workspace that has saved
nothing), writer locks (the workspace row plus the worker row, so two workspaces never wait on each other),
CSV and PDF exports (same scoped queries as the pages), notification dedupe keys, and the recurring jobs
(every active workspace, one at a time).

## Known limits (not fixed here)

- **One zone per workspace.** A workspace with stores in two time zones uses the workspace zone for both. `BusinessClock`
  already reads `Location#timezone` when a store has one; the column and the per-store choice do not exist yet.
- **Recurring job times are Eastern** (`config/recurring.yml`): the 04:10 leave accrual and the task reminders run at
  that Eastern time for every workspace. Break reminders and missed clock-outs compare instants and are unaffected.
- **The schedule builder draws times in the manager's browser zone** (`schedule_builder_controller.js`). A manager
  travelling outside the workspace's zone should check the times on the posted schedule.
- **The `.ics` schedule feed needs a signed-in session**, so calendar apps cannot subscribe to it. Opening it needs an
  expiring, revocable token first.
- **A trade or pick-up at another store is a warning, not a refusal** (manager approval is on by default).
- **Optional links typed into admin forms are not checked against the workspace** (a punch's or clock device's store, a
  shift's position, a department's manager). A foreign id is saved but reads back as nothing, so no data crosses;
  the cost is a blank where a name should be.
- **The staff API kill switch** (`RUPERT_EMPLOYEE_APP_ENABLED`) is still an instance-wide environment variable; the new
  per-workspace switch narrows it, it cannot turn the API on for one workspace alone.

## Per-workspace switches

**Settings → Time rules** (`/settings/time_rules`, permission `settings.write`; every store selected). Each is on by
default, which is what Rupert did before the switch existed.

| Switch | Off means |
| --- | --- |
| Clock in from the web and the installed web app | Clock in/out and breaks from a signed-in browser are refused; the clock card says to use the store clock. |
| Clock in from the phone apps | The same from the iPhone app, and `POST/PATCH /api/v1/employee/clock…` answer 403 `feature_disabled`. |
| PIN clock on the register | The Clock button leaves the POS strip; PIN punches from it are refused. |
| Clock kiosk | `/clock` says it is turned off; kiosk PIN punches are refused. |
| Breaks and meals | No new break can be started anywhere (an open break can still be ended). |
| Scheduling | Schedule builder, templates, availability, posted shifts, open shifts: pages and API refused, menus hidden. |
| Shift trades | Give-aways, swaps and pick-ups refused (web and API); the manager's trades page hidden. |
| Time-off requests | Staff cannot ask from their page or the API. Managers still record and decide leave. |
| Tips for staff | Tip figures and the cash-tip form leave the Pay page; `/api/v1/employee/pay` omits tips; declaring tips is refused. |
| Pay estimates for staff | The Pay page and API, the estimate on Today and on My reports, and payslips there. |
| Punch fixes by staff | Staff cannot request a correction (page, API or the kiosk's forgotten clock-out fix); a manager starts it. |
| Staff submit their own timesheets | Only someone with `timesheets.write` submits a sheet for review. |
| Missed clock-out reminders | No nudge to the worker or managers about an open punch. |
| Break reminders | Under Breaks, per store (already existed). |

Punch logging, same page:

| Setting | Default | What it does |
| --- | --- | --- |
| Keep the device and register name on each punch | On | Off stops storing them on new punches. |
| Detailed punch audit trail | Off | Writes `time_clock.*` lines to the activity log: clock in/out, breaks, fixes asked and decided, refused PINs; with source, store, device and who. |
| Record the network address of each punch | Off | Adds the address to those lines. Needs the trail. |
| Keep the punch audit trail | 7 years | 3, 4 or 7. Older lines are removed nightly. Punches, corrections and timesheets are never removed. |

A switch that is off is refused in the controller or service (`TimeRules.require_feature!` →
`TimeRules::FeatureDisabled`), not only hidden. Every change is an activity-log line (`time_rules.updated`) with who,
when and each value old → new.

## Tests

- `web/test/integration/time_multi_tenant_isolation_test.rb`: two workspaces with the same staff name, employee number
  and PIN. Pages, staff API, PIN clock and kiosk, exports, jobs, clock zone, settings, push and setup links.
- `web/test/integration/time_features_settings_test.rb`: defaults, permission, audit, each switch on the web, the API
  and the PIN clock, the logging options, retention, and a brand-new worker in a brand-new workspace from the setup
  link to the payroll export.
- `ios/Tests/RupertTests/AppReviewReadinessTests.swift`: notification links, cookie scoping, leaving a workspace.
