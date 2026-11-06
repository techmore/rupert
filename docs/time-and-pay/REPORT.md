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

_(filled in at the end)_
