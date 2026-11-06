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

_(filled in per workstream)_

## Production status

_(see DEPLOYS.md)_

## Payroll provider recommendation

_(see below, final section)_

## What's left

_(filled in at the end)_
