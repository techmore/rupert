# Human Interface Guideline: v0.2.1 release scope

This is the Human Interface Guideline (HIG) for the modules in the v0.2.1
release gate ([#326](https://github.com/techmore/rupert/issues/326),
[#429](https://github.com/techmore/rupert/issues/429)). It does not repeat the
rules. The rules are the [interface guidelines](ui-standards.md), and the live
catalogue is **System → Style guide** (`/system/style_guide`). This page:

1. maps each topic the release gate asks for to the section that defines it;
2. lists the release-scope surfaces and which rules apply to each;
3. says how to validate a module on desktop and phone, and what to record.

If this page and `ui-standards.md` disagree, `ui-standards.md` wins and this page
gets fixed.

## 1. Topic map

| Release-gate topic | Where it is defined | The rule in one line |
| --- | --- | --- |
| Navigation | [§2 Structure](ui-standards.md#2-structure), [§3 Navigation registry](ui-standards.md#3-navigation-registry) | One shell. The rail comes from `ModuleRegistry` only; tabs are only for views of the same record or report. |
| Layout | [§2](ui-standards.md#2-structure) width tiers, [§4 Page templates](ui-standards.md#4-page-templates) | Every page is one of six templates (Overview, List, Detail, Form, Report, Settings) at one of three widths. |
| Typography | [§6 Colour, type, spacing](ui-standards.md#6-colour-type-spacing) | Display serif for titles and figures, system sans for the rest, fixed size steps, no pixel sizes. |
| Colour | [§6](ui-standards.md#6-colour-type-spacing) | Token classes only, never hex. Every pair meets WCAG AA (`web/bin/check-palette-contrast`). |
| Spacing | [§6](ui-standards.md#6-colour-type-spacing) | `space-y-6` between page sections, `space-y-4` inside a card, `gap-3` in toolbars. |
| Shared components | [§5 Components](ui-standards.md#5-components-css-classes) | Use a listed class. A new component goes into §5, the stylesheet and the style guide first. |
| Interaction patterns | [§1 Principles](ui-standards.md#1-principles), [§7 Verbiage](ui-standards.md#7-verbiage), [§11](ui-standards.md#11-how-to-approach-a-new-screen) | One primary action per page; the rest under `More`. One verb per intent (`Add`, `Edit`, `Save`, `Open`…). |
| Accessibility | [§9 Accessibility and devices](ui-standards.md#9-accessibility-and-devices) | Keyboard reachable, visible focus, labelled landmarks, one `h1`, state never shown by colour alone. |
| Responsive behaviour | [§2](ui-standards.md#2-structure) "Display size", [§9](ui-standards.md#9-accessibility-and-devices) | Desktop first. Phones must work at 375px with no horizontal scroll and no hidden data; the rail becomes a drawer. |
| Loading, empty, error, success | [§8 States](ui-standards.md#8-states) | Busy button label, a one-sentence flash for the result, `.empty-state` with the next action, field errors under the field. |

## 2. Release-scope surfaces

Each module has a guide in [module-guides/](module-guides/README.md) whose
"UI patterns" section records its templates and any known departures.

| Surface | Rules that apply | Module guide |
| --- | --- | --- |
| Management web app (all modules below) | All of `ui-standards.md` | — |
| Initial setup | Settings and Form templates | [setup](module-guides/setup.md) |
| Team chat, Ask Rupert | Shell utilities (§2); chat panels follow §5 and §8 | [assistant](module-guides/assistant.md) |
| Projects, Tasks, calendar | List, Detail, Form | [projects and tasks](module-guides/projects-and-tasks.md) |
| Learn Rupert, Training progress | List, Detail, Report | [training](module-guides/training.md) |
| Customers (CRM) | List, Detail, Form | [customers](module-guides/customers.md) |
| Marketing, Influencers | Overview, List, Detail, Form | [marketing](module-guides/marketing.md) |
| Uploads | List, Detail | [uploads](module-guides/uploads.md) |
| Backups | Settings | [backups](module-guides/backups.md) |
| Time clock, Timesheets, Time keeping | Form, List, Report | [timesheets](module-guides/timesheets.md) |
| Payroll, Incentives | List, Detail, Report | [payroll](module-guides/payroll.md) |
| Dashboard, Cash flow | Overview, Report | [finance dashboard](module-guides/finance-dashboard.md) |
| POS | The full-screen exception in [§5 POS](ui-standards.md#pos) | Not in the release scope |
| Staff web app (`/employee`) | Same tokens and verbs; its own small layout for staff accounts | [staff app](module-guides/staff-app.md) |
| Staff mobile app (`mobile/`) | Verbiage (§7) and states (§8) apply. It does not share the web tokens: colours are hard-coded in `mobile/App.tsx`, and it has no dark appearance. | [staff app](module-guides/staff-app.md) |
| Native desktop menus (macOS, elementary OS) | Not built; tracked in [#428](https://github.com/techmore/rupert/issues/428) | None yet |

## 3. Validating a module

A module meets this HIG when every main page passes the
[page checklist (§10)](ui-standards.md#10-page-checklist) and one representative
workflow has been walked on desktop and phone. For each module record:

- **Revision**: the full `main` SHA and the instance (local, sandbox or SER8).
- **Desktop**: 1440px wide, Herbal and Dark appearances. Walk the workflow named
  below from the rail, including one empty state and one error state.
- **Phone**: 375px wide. The same workflow, opened from the drawer. Check there
  is no horizontal scroll, every control can be reached, and no figure is cut off.
- **Keyboard**: the workflow without a mouse (`Tab`, `Enter`, `Esc`, `/` search).
- **Roles**: once as an owner/admin and once as the least-privileged staff role
  that can use the module. Pages a role cannot use are absent from its rail.
- **Result**: pass, or each departure with the page, the rule it breaks and an
  issue link.

Representative workflows:

| Module | Workflow |
| --- | --- |
| Setup | Open the setup steps, finish one step, reload, confirm the step stays done |
| Assistant | Ask one question in Ask Rupert; post in a Team chat room |
| Projects and tasks | Add a task with a due date, assign it, move it to done |
| Training | Open a lesson, finish it, see it on Training progress |
| Customers | Search a customer, add a tag and a follow-up |
| Marketing | Open a campaign and an offer |
| Uploads | Upload a CSV, open its review page |
| Backups | Open the backup status and the latest snapshot |
| Timesheets | Clock in and out, submit a timesheet, review it as a manager |
| Payroll | Open a draft pay run and a payslip |
| Finance dashboard | Open Dashboard and Cash flow for last month |
| Staff mobile app | Sign in, clock in, clock out, open a timesheet |

Automated checks that already pin parts of this HIG:
`web/test/integration/compact_navigation_test.rb`, `module_nav_test.rb`,
`page_header_pages_test.rb`, `navigation_access_boundaries_test.rb`,
`web/test/models/module_registry_groups_test.rb`, and
`web/bin/check-palette-contrast` in CI. They check structure, labels, access and
contrast. They do not check layout at phone width; that still needs the walk
above.

## 4. Status

No module has a recorded desktop and phone walk against this guide yet. Record
results on [#432](https://github.com/techmore/rupert/issues/432) (cross-module
consistency) with the fields in §3.
