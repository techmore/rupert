# Time, scheduling and pay: report

_Draft; updated as each workstream lands. See ARCHITECTURE.md, DECISIONS.md, DESIGN.md, DEPLOYS.md._

## What was found

- Rails owns everything; the Rust core was retired on 2026-10-19. The iPhone app is a Hotwire Native shell, so every
  staff screen is a web page that the app renders, plus native push and a Time tab.
- A working but desktop-shaped HR system already existed: clock punches, corrections, timesheets with review,
  planned shifts (static table), time off with balances, pay rules (owner decisions of 2026-10-25), pay runs and
  payslips, read-only Square and C-Trax history. No PIN clock, no breaks, no publish/trades/open shifts, no tip
  ledger, no period lock, no push.
- Card tips were captured (Dejavoo FEED `tip_cents`, Authorize.net `tip_amount`, checkout `tip_cents`) but never
  attributed to a person; the FEED's `performedBy` clerk id was dropped; pay estimates ignored Rupert POS tips.
- Square is no longer the card POS (Dejavoo SPIn terminals on Valmar, Authorize.net for online); Square's Team API
  exposes team member ids but not passcodes, so PINs are Rupert-owned and set once on first clock-in.
- Production: autodeployer was blocked on a dirty `schema.rb` (fixed, see DEPLOYS.md); scheduled encrypted
  backups have been failing since at least Nov 1 for lack of a backup key (owner action).

## What was built

Measured on the merged tree with Playwright at 390 px (phone):

| Flow | Result |
| --- | --- |
| Clock in at the register with a PIN (trusted device, no sign-in) | 4 taps, **under 1 s** from first digit to "Clocked in · 8:42 AM ✓" |
| Request two days off from the staff app | 4 taps, 1.3 s, "Request sent. Your manager will answer here." |
| Approve a week of clean timesheets on a phone | 3 taps (Select all clean → Approve N → Confirm), 2.9 s |

### Staff (web pages, rendered in the iPhone app and the installed web app)

- **Clock** (`/employee`, the POS strip and the `/clock` kiosk): PIN pad with auto-submit, Clock out / Break / Meal / End break,
  first-use PIN setup, wrong-PIN and lockout messages, forgotten clock-out fix in two taps (planned end / 8 h / custom → a pending
  correction, new shift starts), offline queue on trusted devices with idempotent replay, break reminders, missed clock-out nudges.
- **Fix a punch** with reason, proposed times and breaks; original kept; reviewer decision notifies the worker.
- **Schedule**: posted shifts, Team view, open shifts with Pick up, Give away / Swap with guardrails (double-booking, overtime,
  position, minors, time off, notice, rest, availability, store), trade status page, availability editor, .ics feed.
- **Time off**: type chips, hours defaulted from posted shifts, balances with accrual, blackout and notice callouts, cancel.
- **Pay**: period stepper, hours net of unpaid breaks, estimated gross, card tips (shared with N / yours, Estimated vs Final),
  cash tips declared in two taps, bonuses, next payday, payslips; English and Spanish; dark mode.
- **Settings**: language, clock PIN, signed-in devices, notification preferences (iOS stream).

### Managers and owners

- **Timesheets, exceptions first** with inline fixes, bulk approve, full audit trail, store scope.
- **Approvals inbox**: punch fixes, time off, trades, timesheets; Approve/Deny with note; never your own.
- **Schedule builder**: drag-and-drop weekly grid, resize, click-to-add, conflict chips, labour cost vs the same weekday's average
  sales, open shifts, templates, copy last week, Post week with notifications and short-notice warning, blackout dates.
- **Tips**: terminal vs settled vs unassigned, by employee/day/store, assign unassigned tips, reconciliation vs Authorize.net batches
  and Dejavoo batch close, CSV.
- **Pay periods**: lock, provider-agnostic payroll CSV with SHA-256, reopen with reason, adjustments; locks enforced on punches,
  breaks, corrections, timesheet entries and time-off approvals.
- **Time rules** per store (preset by state, breaks, daily OT, minors, notice, rounding, PIN policy, trades, accrual, tips, payday),
  **Clock devices** (trusted registers/tablets), store scope on accounts and staff, leave accrual job, offboarding on terminate.

### Payments → tips path

Dejavoo FEED now keeps `performedBy`/terminal/invoice; `Tips::Attribution` writes the ledger (checkout cashier → clerk id →
clocked-in staff at that store/time; owner's pool rule, admins excluded, whole cents); `Tips::Reconciliation` settles hourly against
Authorize.net settled transactions and Dejavoo batch close, mirrors refunds/voids/adjustments as negative rows and carries money that
settles after a lock into the next open period.

## Production status (SER8, herbalhealers.rupertpos.com)

Three PRs merged to `main` and installed by the autodeployer, each preceded by a verified SQLite backup and
followed by a live smoke test; details and receipts in [DEPLOYS.md](DEPLOYS.md).

| PR | Build | What | Result |
| --- | --- | --- | --- |
| #640 | `b7fdbf63` | Foundation (3 additive migrations) | Healthy |
| #642 | `eb246e60` | Clock, scheduling, tips, manager pages (1 additive migration) | Healthy; live clock in → break → clock out verified with a temporary worker, then cleaned up |
| #644 | see DEPLOYS.md | Push notifications, iPhone 1.1.0, App Store package | see DEPLOYS.md |

Operational findings the owner should act on:

1. **Encrypted backups have been failing** since at least Nov 1 (no active backup key). Create the key at
   **Settings → Backups** and keep the recovery kit. Until then only the deployer's pre-deploy copies and the
   manual copies in `/var/backups/rupert-manual` exist.
2. **Push needs keys**: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8`, `APNS_TOPIC`, `APNS_ENVIRONMENT` (and optionally
   `VAPID_*`) in `/etc/rupert.env`; the bell works without them.
3. **SER8 root volume is 99% full** (15 GB free).
4. Pick the stores' **state preset** at Settings → Time rules (defaults are federal) and register each register browser
   or counter tablet at **Team → Clock devices** so PIN punches work without a sign-in.

## Payroll provider recommendation

**Recommendation: Gusto (Simple plan) as the provider, fed by Rupert's payroll export.** Second choice OnPay.
Do not use Square Payroll.

Why:

- **Fits the stack.** Rupert produces one CSV per pay period (hours by type, card tips, cash tips, commission,
  bonuses, per employee). Gusto accepts hours and tip amounts per employee per pay run (manual entry or its
  hours import) and reports tips on W-2s and the FICA tip credit where it applies; its API (Gusto Embedded /
  partner API) is the cleanest path to a direct push later without changing the export.
- **Multi-state and tips without surprises.** Tax filing in every state at the base price (OnPay too; Square
  Payroll charges per additional state), tip reporting, new-hire reporting, PTO policies that match Rupert's
  accrual settings, employee self-service pay stubs (so Rupert's pay page stays an estimate and never has to be
  a payslip of record).
- **Price.** Published 2026 pricing is roughly $49/month base + $6 per person for both Gusto Simple and OnPay;
  for a shop of 5–15 hourly staff that is $80–140/month. Square Payroll's advertised base is lower but assumes
  Square POS timecards, which this business no longer runs for payments; its value is the Square timecard sync
  Rupert replaces.
- **Why not the others.** Square Payroll: tied to Square timecards/POS. Homebase: a scheduling product with
  payroll attached, overlapping everything just built. ADP Run / Paychex: fine but priced and sold for larger
  teams; quotes, not list prices. QuickBooks Payroll: only if the books move to QuickBooks Online.

Onboarding steps (owner): sign up, add employees from the Rupert staff list (employee number, email, pay rate),
set the pay schedule to match **Settings → Pay rules**, run the first period from Rupert's **Pay periods →
Download CSV** side by side with a manual check, then switch on direct deposit.

Sources: [Homebase: best payroll providers 2026](https://wf.joinhomebase.com/blog/online-payroll-services),
[Airwallex: best payroll software](https://www.airwallex.com/en-us/blog/best-payroll-software),
[G2: Gusto vs Square Payroll](https://www.g2.com/compare/gusto-vs-square-payroll),
[People Managing People: Gusto vs OnPay 2026](https://peoplemanagingpeople.com/tools/gusto-vs-onpay/),
[TechRepublic: Square Payroll vs OnPay](https://www.techrepublic.com/pt/article/square-vs-onpay/).

## What's left

- **Owner clicks**: App Store Connect submission (checklist item 22), Push Notifications capability and APNs key,
  backup key, time-rules preset, clock-device registration, payroll provider sign-up.
- **Live tip attribution has no real data yet**: the Dejavoo FEED and Authorize.net reporting connectors are configured
  per the payments docs but the terminal programme is still in sandbox (`docs/integrations/dejavoo-spin.md`); the first
  live batches will exercise `Tips::Reconciliation` for real. Watch **Team → Tips** for unassigned rows that first week.
- **Clerk ids on the terminal**: for the `performedBy` evidence path, staff must key the same number on the terminal as
  `employees.employee_number`; otherwise attribution falls back to the checkout cashier or clocked-in staff (still correct
  under the pool rule).
- **Photo capture at the clock** is designed but off (privacy); GPS is deliberately not used.
- **Expo staff app** (`mobile/`) keeps working against the extended API but gets no new screens; the iPhone app is the one
  being shipped.
- Pre-existing flaky test `TeamChatRestartTest#SIGKILL…` fails under full-suite load and passes alone; unrelated to this work.
- Nice-to-haves noted during review: a plain `‹ period ›` stepper on the Pay page (today it is a date field + Apply, which
  works but is one tap more), and a "Next thing to do" item for pending approvals (NextThings only reads MCP tools today).
