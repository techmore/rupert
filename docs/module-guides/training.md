# Training: Learn Rupert and Training progress

Last checked against `main` at `b15205e7` plus the training assignments change on `2026-10-25`.

## Purpose and owner

Two parts:

1. **Learn Rupert**: teach people to use Rupert inside Rupert: a welcome with learning paths, a
   first-week checklist, lessons with knowledge checks, page tours, definitions and a read-only team
   progress view.
2. **Training** (owner-made modules, #399 #410 #411): a manager writes a module (text, files, a
   video link), assigns it to people with a due date, and sees who has started and finished; staff
   see their own assignments in their workspace, start them and mark them complete. Every step is
   kept in an append-only history.

Owner: the store owner decides the training expectations; lesson text is maintained in code and
reviewed through normal PR review; owner-made modules are written in the app. `ModuleRegistry`
keys: `learning` (**Learn Rupert**, Me section), `training_modules` (**Training**, Team → Pay &
reports) and `training` (**Training progress**, Team → Pay & reports, Learn Rupert lessons only).
Staff reach their assignments from **Training** in the staff workspace navigation (`/employee/training`). Operator detail:
[onboarding and learning](../ops/in-app-learning.md).

## Data model

### Training (owner-made modules)

Migration `20261025140000_create_training_assignments`:

- `training_modules`: `title`, `body` (plain text, up to 50,000 characters), `video_url` (https
  only), `revision`, `created_by_id`, `updated_by_id`. `revision` goes up whenever the title, text,
  video link or files change (`TrainingModule#bump_revision!` for files).
- `training_attachments`: PDF, PNG, JPG, GIF, TXT or CSV, up to 10 MB each and 10 per module; the
  type is checked against the name and the file's first bytes. Video files are refused: a module
  links to its video. Bytes follow the `Upload` convention: base64 in `content_base64`, encrypted
  with Active Record encryption, SHA-256 checked on every read, so the normal database backups
  carry them ([backups](../ops/backups.md)). Removing a file only sets `removed_at`/`removed_by_id`;
  the row cannot be destroyed.
- `training_assignments`: `training_module_id`, `assignee_id` (a `User`), `assigned_by_id`,
  `due_on`, `status`, `started_at`, `completed_at`, `completed_by_id`, `completed_revision`,
  `cancelled_at`, `lock_version`. One open assignment per person per module. Cannot be destroyed.
  A completed assignment is the record a future training bonus binds to (#412); nothing reads it
  for pay today.
- `training_assignment_events`: append-only history: `actor_id`, `actor_name`, `action`
  (`assigned`, `started`, `completed`, `cancelled`), `from_status`, `to_status`,
  `module_revision`, `note`, `created_at`. Saved rows are read-only and cannot be destroyed or
  deleted through the model. Rows are written only by `TrainingAssignment.assign!` and
  `TrainingAssignment#transition!`, in the same transaction as the change.

Shared Project table (#407 #409): not built. The assignment columns match a task's (`assignee_id`,
`due_on`, `status`, `started_at`/`completed_at`) and the history rows are generic (actor, action,
from/to status, time), so a module can become a "training" project type with these transitions
and these rows its history.

### Learn Rupert

No tables. Content is code:

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
- Training modules: `hr.read` sees modules, files, assignments, progress and history; `hr.write`
  adds and edits modules, adds and removes files, assigns and cancels. Employee-role accounts
  cannot open `/training` (`restrict_employee_workspace`).
- `/employee/training` (`EmployeeTrainingController`) starts every lookup from assignments whose
  `assignee_id` is the signed-in account in the current tenant: another person's assignment, its
  files, or a cancelled assignment is 404. Only the assignee can start or complete; a manager
  cannot complete on someone's behalf.
- All four tables are `TenantScoped`; assignees must be active users of the module's tenant.

## Routes and API

`GET /learning`, `GET /learning/:id`, `POST /learning/:id/complete`, `GET /learning.json?q=`
(help search), `GET|POST /welcome`, `PATCH /learning/preferences`, `GET /learning/team`.
Training: `GET /training`, `GET|POST /training/new`, `GET /training/:id`,
`GET|PATCH /training/:id/edit`, `POST /training/:id/attachments`,
`GET|DELETE /training/:id/attachments/:file_id`, `POST /training/:id/assignments` (`assignee_ids[]`,
`role`, `department_id`, `due_on`), `POST /training/assignments/:id/cancel`; staff:
`GET /employee/training`, `GET /employee/training/:id`, `POST /employee/training/:id/start`,
`POST /employee/training/:id/complete`, `GET /employee/training/:id/files/:file_id`.
No `/api/v1` endpoint and no MCP tool. Contract rules: [API standards](../api-standards.md).

## Workflow and status transitions

Per lesson: not started → complete. Completion needs every knowledge-check answer right in one
submission; a wrong answer re-renders the lesson (HTTP 422) with explanations. A path is complete
when all its lessons are. Tours: not taken → taken or skipped.

Training assignment (`TrainingAssignment::TRANSITIONS`):

```
assigned ──start (assignee)──▶ in_progress ──complete (assignee)──▶ completed
   └──────────────cancel (hr.write)───────┴──▶ cancelled
```

Any other move is refused (`TransitionRefused`, shown as an alert) and writes nothing: completing
before starting, acting on someone else's assignment, restarting a completed one, or changing
`status` directly. Completion stores who, when and the module revision. There is no reopen; assign
again for a refresher (the old completion stays). Assigning to a role or department picks the
active accounts with that role, or the active staff in that department with a linked account;
people who already have the module open are skipped.

**How a manager assigns:** Team → Training → **Add training module** (title, text, optional video
link) → on the module page add files → under **Assign** choose people, a role or a department and an
optional due date → **Assign**. **How staff complete:** staff workspace → **Training** → open the
module → **Start** → read the text, download files, **Open video** → **Mark complete**. The
manager sees the status, completion time and revision in the module's Assignments table and every
step under History.

Setup (#399): the first-week checklist (`GettingStartedChecklist`) shows **Configure, assign and
complete a training module** to `hr.write` accounts; it ticks itself once any assignment in the
workspace is completed. Anyone with assignments also gets **Complete your assigned training**,
ticked when none are open.

## UI patterns

Training is a List page (stat row: assigned, in progress, completed, overdue) with a Detail page
per module (facts, text, Files, Assignments with the assign form, History) and a Form for add and
edit. The video is a link that opens on its own site in a new tab (`rel="noopener noreferrer"`);
nothing is embedded, so the content security policy is unchanged. Staff pages use the staff
workspace layout. Learn Rupert shows a notice when the person has open training.
Learn Rupert is an Overview-style landing with lesson Detail pages. Help is folded: the page-help
disclosure, the `?` panel, `define(term)` popovers and `explain_calculation` disclosures; tours
start only when a person asks. Training progress is a read-only List page. Desktop and phone
visual acceptance: Unknown.

## Integration and sync

None. Nothing is read from or written to an outside system.

## Audit history

Training: `training_assignment_events` (append-only, above) is the trail of record, shown on the
module page to `hr.read` and on the assignment page to the trainee. Activity log entries:
`training_module_created`, `training_module_updated`, `training_file_added`,
`training_file_removed`, `training_assigned`, `training_started`, `training_completed`,
`training_assignment_cancelled`.

Learn Rupert: only the per-user completion timestamps in `dashboard_config`. Lesson completions and
tours do not write Activity log entries. There is no history of who changed lesson content beyond Git.

## Failure and recovery

- A missing or not-permitted lesson returns 404. Unknown paths or tours are refused, and profile
  input cannot select another user or change permissions.
- Resetting the dashboard layout keeps learning state.
- Training modules, files, assignments and history are database rows, so they are restored with
  the database backup; file bytes need the encryption keys in `/etc/rupert.env` as well. A file
  whose checksum does not match is refused on download rather than served. Restore of training
  content specifically: not tested (Unknown).
- Progress lives in the user row, so it is restored with the database backup. Restore of
  learning state specifically: not tested (Unknown).

## Required tests

`test/integration/learning_flow_test.rb`, `learning_onboarding_test.rb`,
`learning_definitions_test.rb`, `onboarding_connect_test.rb`,
`test/services/page_tours_test.rb`, `test/models/training_assignment_test.rb`,
`test/integration/training_assignments_flow_test.rb` (assign, transitions, append-only history,
staff-only-own, read-only managers, tenant isolation, file types and size, setup step), and `test/javascript/tour_test.mjs`, `help_panel_test.mjs`,
`practice_test.mjs`.

## Open gaps

- [#409](https://github.com/techmore/rupert/issues/409) / [#407](https://github.com/techmore/rupert/issues/407):
  training is not yet on the shared Project table; the tables above are shaped to fold into it.
- [#399](https://github.com/techmore/rupert/issues/399), [#410](https://github.com/techmore/rupert/issues/410)
  and [#411](https://github.com/techmore/rupert/issues/411) were reopened on 2026-10-25; the
  assignment, state, history and upload pieces are now in source. Acceptance needs a run on the
  live workspace with synthetic users and content, including a backup restore of a training file.
- Video is by link only; Rupert does not host or play video, and cannot tell whether it was watched.
- Learn Rupert lessons are not yet assignable as training modules, and there are no recurring
  (annual) assignments or reminders before a due date.
- [#412](https://github.com/techmore/rupert/issues/412): no link from completion to a training
  bonus. A completed `training_assignments` row is what it would bind to. The Incentives model
  (`IncentiveModel`) has a training rate for staff marked as in training, set by hand; it does not
  read completions, and nothing is saved to payroll.
