# Training: Learn Rupert and Training progress

Last checked against `main` at `ec5ae024` on `2026-10-25`.

## Purpose and owner

Teach people to use Rupert inside Rupert: a welcome with learning paths, a first-week checklist,
lessons with knowledge checks, page tours, definitions and a read-only team progress view.

Owner: the store owner decides the training expectations; lesson text is maintained in code and
reviewed through normal PR review. `ModuleRegistry` keys: `learning` (**Learn Rupert**, Me
section) and `training` (**Training progress**, Team → Pay & reports). Operator detail:
[onboarding and learning](../ops/in-app-learning.md).

Today this is **self-paced learning about Rupert**. It is not a general learning management
system: there are no owner-made training modules, uploaded materials or videos, assignments or
due dates on `main` (see Open gaps).

## Data model

No training tables. Content is code:

- `LearningCatalog` (lessons, permissions, knowledge checks, mistakes, practice, `TERMS`),
  `LearningExamples` (worked examples), `PageTours`, `PageGuides`, `GettingStartedChecklist`.
- Progress is per user, stored by `LearningJourney` in the user's `dashboard_config` JSON
  (`learning_focus`, `learning_completed`, `learning_completed_at`, `learning_tours`,
  `learning_welcome_hidden`, `learning_welcomed_at`, `learning_checklist_done`,
  `learning_checklist_hidden`). Updates take a row lock on the user.

The completion record holds the lesson key and time. It does not record a content revision.

## Permissions and tenant boundary

- `/learning` is open to every signed-in, active workspace account (registry permission `nil`).
  Each lesson is permission-checked on read and on completion.
- Training progress (`/learning/team`) needs `users.read` or `hr.read` in the controller; the
  rail entry is gated on `hr.read`. It lists users of the current tenant only.
- Completing a lesson changes only the signed-in person's own progress. It grants no access and is
  not a certification.

## Routes and API

`GET /learning`, `GET /learning/:id`, `POST /learning/:id/complete`, `GET /learning.json?q=`
(help search), `GET|POST /welcome`, `PATCH /learning/preferences`, `GET /learning/team`.
No `/api/v1` endpoint and no MCP tool. Contract rules: [API standards](../api-standards.md).

## Workflow and status transitions

Per lesson: not started → complete. Completion needs every knowledge-check answer right in one
submission; a wrong answer re-renders the lesson (HTTP 422) with explanations. A path is complete
when all its lessons are. Tours: not taken → taken or skipped. There is no assigned or
in-progress state, and no reopen.

## UI patterns

Learn Rupert is an Overview-style landing with lesson Detail pages. Help is folded: the page-help
disclosure, the `?` panel, `define(term)` popovers and `explain_calculation` disclosures; tours
start only when a person asks. Training progress is a read-only List page. Desktop and phone
visual acceptance: Unknown.

## Integration and sync

None. Nothing is read from or written to an outside system.

## Audit history

Only the per-user completion timestamps in `dashboard_config`. Completions and tours do not write
Activity log entries. There is no history of who changed lesson content beyond Git.

## Failure and recovery

- A missing or not-permitted lesson returns 404. Unknown paths or tours are refused, and profile
  input cannot select another user or change permissions.
- Resetting the dashboard layout keeps learning state.
- Progress lives in the user row, so it is restored with the database backup. Restore of
  learning state specifically: not tested (Unknown).

## Required tests

`test/integration/learning_flow_test.rb`, `learning_onboarding_test.rb`,
`learning_definitions_test.rb`, `onboarding_connect_test.rb`,
`test/services/page_tours_test.rb`, and `test/javascript/tour_test.mjs`, `help_panel_test.mjs`,
`practice_test.mjs`.

## Open gaps

- [#409](https://github.com/techmore/rupert/issues/409): owner-made training modules, uploaded
  materials and video, assignment to a person or group with a due date, and access limited to
  assigned content are not on `main`.
- [#399](https://github.com/techmore/rupert/issues/399), [#410](https://github.com/techmore/rupert/issues/410)
  and [#411](https://github.com/techmore/rupert/issues/411) were closed on owner acceptance on
  2026-10-25. The source on `main` does not show assigned or in-progress states, an audit trail of
  completion actor and content revision, or video upload. How those acceptances map to `main` is
  Unknown and should be checked.
- [#412](https://github.com/techmore/rupert/issues/412): no link from completion to a training
  bonus. The Incentives model (`IncentiveModel`) has a training rate for staff marked as in
  training, set by hand; it does not read lesson completion, and nothing is saved to payroll.
- [#407](https://github.com/techmore/rupert/issues/407): whether training moves onto a shared
  project model.
