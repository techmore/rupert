# Module guides

One guide per module in the v0.2.1 release gate
([#326](https://github.com/techmore/rupert/issues/326),
[#431](https://github.com/techmore/rupert/issues/431)). Each follows
[TEMPLATE.md](TEMPLATE.md) and describes the module as it is on `main`, with
unknowns marked `Unknown` and missing work listed under "Open gaps".

Shared rules the guides point to:
[interface guidelines](../ui-standards.md),
[Human Interface Guideline for the release scope](../human-interface-guidelines.md),
[API standards](../api-standards.md) and the
[development and deployment workflow](../development-and-deployment-workflow.md).

## Release-gated modules

The release scope comes from the gate items in #326. Each guide covers the
`ModuleRegistry` entries listed beside it.

| Guide | `ModuleRegistry` keys | Gate issues |
| --- | --- | --- |
| [Organization setup](setup.md) | `owner_checklists` (setup itself has no key) | #396–#402 |
| [Assistant: Team chat and Ask Rupert](assistant.md) | `team_chat`, `ask_rupert_usage` | #403–#406, #408 |
| [Projects and tasks](projects-and-tasks.md) | `projects`, `tasks` | #407, #413, #417 |
| [Training](training.md) | `learning`, `training` | #399, #409–#412 |
| [Customers (CRM)](customers.md) | `customers` | #414 |
| [Marketing and influencers](marketing.md) | `marketing`, `influencers` | #415–#417 |
| [Uploads inbox](uploads.md) | `uploads` | #418 |
| [Backups and restore](backups.md) | none (System health and Settings) | #400, #418–#421 |
| [Time clock and timesheets](timesheets.md) | `time_clock`, `timesheets`, `time_keeping`, `punch_history`, `square_timesheets`, `ctrax_timesheets` | #422 |
| [Payroll and incentives](payroll.md) | `payroll`, `incentives` | #423–#425 |
| [Dashboard and cash flow](finance-dashboard.md) | `dashboard`, `cash_flow` | #427 |
| [Staff app (mobile)](staff-app.md) | none (serves `time_clock`, `timesheets`) | #436 |

Not covered: the native macOS and elementary OS menus
([#428](https://github.com/techmore/rupert/issues/428)) are not built, so they
have no guide yet. Modules outside the release gate (stock, bookkeeping beyond
the dashboard and cash flow, reports, POS) have no guide yet.

## Keeping guides current

Update a module's guide in the same PR that changes its data model, permissions,
routes, statuses or integrations, and refresh its "Last checked" line. When a
gate issue closes, move the item out of "Open gaps" and link the evidence.
