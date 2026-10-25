# Shared work items

Design for the owner's decision on [#407](https://github.com/techmore/rupert/issues/407) (2026-10-25):
**one shared table** holds tracked work — tasks and projects, assistant and feature requests, order
follow-up work, marketing campaign and event work, and training assignments — with per-type fields,
status steps, actions and views, and one shared way to assign, date, track status, keep history and
check workspace and role access. Each module keeps its own screens; it stops keeping its own copy of
the workflow table.

Status: **phases 1, 2b, 3 and 4 are built**: the core and tasks (phase 1), training assignments
(phase 2b, [#409](https://github.com/techmore/rupert/issues/409)), the marketing kinds and their
results table (phase 3, [#415](https://github.com/techmore/rupert/issues/415)) and the shared calendar
(phase 4, [#417](https://github.com/techmore/rupert/issues/417)). The remaining phases are listed at the end
and are not built.

## 1. The table

The shared table is the existing `tasks` table. It is not renamed (see section 8). In code it is
`Work::Item` (every kind) and `Projects::Task` (only rows of kind `task`).

| Column | Shared meaning |
| --- | --- |
| `tenant_id` | Workspace. Every query is filtered by `TenantScoped`. |
| `kind` | Which kind of work this row is: `task`, `training_assignment`, `marketing_event` or `campaign_task`. Must be registered (section 2). |
| `title`, `description` | What it is. `Work::Item#body` is the same column as `description`. |
| `status` | The kind's current status. Changes only through the kind's transitions. |
| `priority` | `low`, `medium`, `high`, `urgent`. |
| `assignee_id` | The person doing it (a `User` in the same workspace). |
| `requester_id` | The person who asked for it. New in phase 1, empty for existing tasks. |
| `start_on`, `due_on` | Planned dates (store time zone). |
| `started_at`, `completed_at` | When it first entered a "started" status, and when it last entered a "done" status. |
| `parent_id` | An enclosing item of any kind (a request that became a task, a campaign's checklist items). Must be in the same workspace. |
| `source_type`, `source_id` | The record this work is about (an assistant request, an order, a marketing campaign, a training module). |
| `position` | Hand-placed board order. |
| `details` | JSON object of the kind's own fields, checked against the kind's field list. |
| `created_at`, `updated_at` | Row timestamps. |

Task-only columns that predate the shared table stay as columns: `project_id`, `labels`,
`blocked_reason`, `recurrence`, `next_spawned_at`, `estimate_minutes`. Other kinds leave them
empty. New kinds put their own fields in `details`, not in new columns; a field becomes a column
only when it must be indexed or joined, and that needs its own migration.

Task children keep their own tables and foreign keys (`task_checklist_items`, `task_comments`,
`task_time_entries`, `task_attachments`, `task_dependencies`, `agent_feedbacks.task_id`). Because
the ids did not change, none of them moved.

## 2. Kind registry

`Work::Registry` (`web/app/modules/work/registry.rb`) lists the kinds. A row whose kind is not
registered cannot be saved. Each kind (`Work::Kind`) declares:

- **statuses**, the **initial** one, which count as **started** and which as **done**;
- **transitions**: `event => { from: [statuses], to: status, who: }`, where `who` is `:writer`
  (anyone the kind's policy lets update the item), `:assignee` (the assignee, or a manager) or
  `:manager` (only someone with the kind's write permission), or `:assignee_only` (only the assignee; nobody
  acts for them);
- **fields**: the `details` keys, each with a type (`string`, `text`, `integer`, `boolean`, `date`
  as `YYYY-MM-DD`, `url` as `https://…`), an optional `max` length and `required` flag. Unknown keys
  are refused;
- **permissions**: `read`, `write` and optional `self_service` permission keys;
- **policy**: a policy class, or the default `Work::ItemPolicy`;
- **model**: optionally a class that owns the kind's workflow. When set, the kind is written only
  through that class, so its own rules always apply;
- **activity prefix** for Activity log entries, and a **path** to the item's page;
- **calendar**: `:due` (on its `due_on`), `:span` (`start_on` through `due_on`) or none;
- optional **prepare** (run before validation, e.g. an event deriving `start_on`/`due_on` from its
  local start and end) and **check** (cross-field rules) callables;
- optional **event_details** (facts saved on every history row, in `work_item_events.details`) and
  **activity** (writes the Activity log entry for a transition instead of `<prefix>_transitioned`).

`Work::Kind#visible_to(user, relation)` narrows a relation to the items of the kind the person may
see, through the kind's own policy scope.

Registered:

| Kind | Model | Statuses | Transitions | Permissions | Fields |
| --- | --- | --- | --- | --- | --- |
| `task` | `Projects::Task` | `todo`, `in_progress`, `blocked`, `done` | read from the task's AASM machine: `start`, `unstart`, `finish`, `block`, `reopen` | `projects.read`, `projects.write`, staff `tasks.self` | none (task fields are columns) |
| `marketing_event` | — (`Work::Item`) | `planned`, `confirmed`, `held`, `cancelled` | `confirm` (writer), `hold` (writer), `cancel` (manager), `reopen` (manager, from held or cancelled) | `marketing.read`, `marketing.write`, Marketing on (`Marketing::WorkItemPolicy`); no staff access | `starts_at`, `ends_at` (local, required), `time_zone` (required), `venue`, `channel`, `location_id`, `offer_id`, `url`; `start_on`/`due_on` hold the local dates |
| `campaign_task` | — (`Work::Item`) | `todo`, `in_progress`, `done`, `cancelled` | `start`, `finish` (assignee or manager), `cancel`, `reopen` (manager) | as `marketing_event` | none; `source` = the campaign and/or `parent` = the event |
| `training_assignment` | — (`Work::Item`; read as `TrainingAssignment`) | `assigned`, `in_progress`, `completed`, `cancelled` | `start`, `complete` (assignee only), `cancel` (manager) | `hr.read`, `hr.write`; everyone else only their own (`Training::AssignmentPolicy`) | `completed_revision`, `completed_by_id`, `legacy_id`; `source` = the `TrainingModule`, `requester` = who assigned it |

The marketing kinds are defined in `web/app/modules/marketing/work_kinds.rb`, the training kind in
`web/app/modules/training/work_kind.rb`.

The task kind reads its transitions from `Projects::Task`'s state machine, so the two cannot
disagree. The task's own guards still apply (start and finish wait on unfinished dependencies;
finishing a repeating task creates the next one; board moves take a row lock).

## 3. Status changes

- `Projects::Task` changes status through its AASM events, as before.
- `Work::Item#transition!(event, user:, note:)` is the shared entry point. Under a row lock it
  refuses (`Work::Item::TransitionRefused`, nothing saved) when the kind has no such event, the
  event does not start from the current status, the kind's policy refuses the person, or the
  transition's `who` excludes them. For a kind with a model (tasks) it hands the event to that
  model, so a task started through `Work::Item` still waits on its dependencies. It writes one
  history row and an Activity log entry `<prefix>_transitioned`.
- Saving a changed `status` on a `Work::Item` without a transition is refused.

## 4. History

`work_item_events` is append-only, shared by every kind:

| Column | Meaning |
| --- | --- |
| `tenant_id`, `work_item_id`, `item_kind` | Which item, of which kind, in which workspace |
| `action` | `created`, `updated`, `assigned`, `rescheduled`, `transitioned`, `deleted` |
| `transition` | The event that fired (`start`, `finish`, …), when there was one |
| `from_status`, `to_status` | Status before and after |
| `actor_id`, `actor_name` | Who did it; `system` for jobs |
| `field_changes` | JSON `{ field: [before, after] }`; long text is cut at 300 characters |
| `note` | The blocked reason, or a transition note |
| `details` | JSON facts the kind keeps about the moment (training: `module_revision`; copied rows: `legacy_event_id`) |
| `created_at` | When |

Rows are written by `Work::Tracked` in the same transaction as the change, whichever path made it
(web, MCP, team chat approval, assistant request triage, the reminder job, recurrence). A saved row
is read-only and cannot be destroyed or deleted through the model. There is no foreign key to the
item, so a deleted item's history stays. Board order (`position`), reminder bookkeeping and the
timestamps implied by a status change are not recorded.

The Activity log (`ActivityLogger`) stays the workspace-wide audit trail. Task screens still write
`task_created`, `task_updated`, `task_deleted`, `task_transitioned` and `task_moved` as before; the
item history adds the field-level before/after detail per item. Phase 1 does not show the item
history on any screen yet.

## 5. Permissions and workspace boundary

- Every row and history row is `TenantScoped`; people, parents and sources must be in the same
  workspace.
- Each kind names its policy. `task` uses `Projects::TaskPolicy` unchanged (staff see and work only
  tasks assigned to them), and its scope now also filters `kind = 'task'`.
- `marketing_event` and `campaign_task` use `Marketing::WorkItemPolicy`: `Work::ItemPolicy`, and only
  while the workspace has Marketing turned on; staff accounts never see them.
- `Work::ItemPolicy` is the default for later kinds: `read` to see, `write` to create, change,
  reassign, transition and delete, and staff (employee) accounts with `self_service` see and work
  only items assigned to them. `Work::ItemPolicy::Scope.new(user, scope, kind:)` filters the
  workspace, the kind and, for staff, the assignee. `Work::ItemPolicy.for(user, item)` picks the
  kind's own policy.

## 6. How each module maps in

| Module | Becomes | Stays separate |
| --- | --- | --- |
| Tasks ([#413](https://github.com/techmore/rupert/issues/413)) | kind `task` — **done in phase 1** | checklist, comments, time, files, dependencies (child tables) |
| Projects | phase 1: unchanged container (`project_id`). Folding projects in as kind `project` with tasks as children is an open decision for a later phase | — |
| Assistant and feature requests ([#406](https://github.com/techmore/rupert/issues/406), PR #519) | kind `request`: `source` = the `AgentFeedback` row, `requester_id`, statuses `new` → `accepted` / `merged` / `declined`; accepting creates a child `task` (`parent_id`) | `AgentFeedback` keeps the inbound message, its chat link and GitHub sync; chat records stay their own conversation records ([#408](https://github.com/techmore/rupert/issues/408)) |
| Training ([#409](https://github.com/techmore/rupert/issues/409), PR #521) | **done in phase 2b**: kind `training_assignment`: `source` = the `TrainingModule`, statuses `assigned` → `in_progress` → `completed`, or `cancelled` (the old `TrainingAssignment::TRANSITIONS` table moved into the registry as is), `details` = `completed_revision`, `completed_by_id`, `legacy_id` | `training_modules` and `training_attachments` are content, not work, and stay |
| Marketing campaigns and events ([#415](https://github.com/techmore/rupert/issues/415)) | **done in phase 3**: kind `campaign_task` (work for a campaign, `source` = `Marketing::Campaign`, `parent` = the event) and kind `marketing_event` (`details`: `starts_at`, `ends_at`, `time_zone`, `venue` or `channel`, `location_id`, `offer_id`, `url`; `source` = the campaign) | `Marketing::Campaign` and `Offer` stay. Observed redemptions and results are facts, not work: `marketing_results` (`Marketing::Result`), one row per event, code, order source, store location and currency |
| Orders | kind `order_follow_up` for work about an order (special orders, fulfilment problems), `source` = `Core::Order` | `Core::Order` and its lines, payments and fulfilments stay the sales record. Orders do not move into the work table |
| Calendar ([#417](https://github.com/techmore/rupert/issues/417)) | **done in phase 4**: `/calendar` (`Work::Calendar`) reads `Work::Item` across kinds (task, training and campaign task `due_on`, event `start_on`–`due_on`), through each kind's policy scope, in one query per range, with time zone, place, status and a link from the kind's `path` | — |

## 7. Moving a module in (each later phase)

Every phase is its own pull request and follows the same steps, so no data is lost:

1. Register the kind (statuses, transitions, fields, permissions, policy, path).
2. Add a migration that copies each old row into `tasks` with its kind, keeps the old row, and
   records the new item id on the old row (`work_item_id`). Old history rows are copied into
   `work_item_events` with their original actor and time. The migration checks counts before it
   finishes and stops if they differ.
3. Point the module's model at the shared row (an adapter class with a `default_scope` on its kind,
   as `Projects::Task` does), keep its URLs, and redirect any old id-based URL to the new id.
4. Keep the old table read-only for at least one release; drop it only in a later, separate
   pull request once the copy is verified in production.
5. Keep API and MCP tools answering the same fields ([API standards](../api-standards.md)); the
   contract tests must stay green.

## 8. Phase 1: what changed, migration and rollback

**Why the table keeps its name.** Auto-deploy runs `db:migrate` before it restarts the app and does
not revert migrations when it rolls code back
([deployment notes](../../deploy/ser8/README.md)). Renaming `tasks` would break the running
release during the deploy and the rolled-back release afterwards. Every phase 1 change is
additive, so the previous release keeps working on the migrated database.

**Migration** `20261025190000_make_tasks_shared_work_items`:

- adds `kind` (not null, default `task`; SQLite stores the default, so every existing row reads
  `task` at once with no rewrite), `requester_id`, `started_at`, `parent_id`, `source_type`,
  `source_id` and `details`, with indexes on workspace + kind + status, workspace + parent, and the
  source;
- creates `work_item_events`;
- copies and rewrites nothing: task ids, URLs and every foreign key that points at tasks are
  unchanged. Existing tasks start with an empty item history; their earlier Activity log entries
  remain.

**Rollback.** `bin/rails db:migrate:down VERSION=20261025190000`, outside any open transaction,
with a backup first. It is refused while rows of another kind exist. It drops `work_item_events`
(the item history written since the migration is lost; the Activity log keeps its entries) and
removes the added columns. SQLite rebuilds `tasks` to remove columns, so the migration turns
foreign-key checks off for the rebuild; tasks and everything pointing at them are kept, which
`test/services/shared_work_items_migration_test.rb` checks on a copy with rows.

**Code.** `web/app/modules/work/` (`item.rb`, `item_event.rb`, `kind.rb`, `registry.rb`,
`tracked.rb`), `web/app/policies/work/item_policy.rb`. `Projects::Task` includes `Work::Tracked`
and reads only `kind = 'task'`. No route, screen, API response or MCP tool changed.

**Tests.** `test/models/work/item_test.rb` (registry, fields, transitions allowed and refused,
append-only history, workspace isolation, permissions, tasks through `Work::Item`),
`test/services/shared_work_items_migration_test.rb` (up, down and up on a copy with rows, refusals),
plus history checks in `tasks_flow_test.rb` and `mcp_server_test.rb`. The existing task, project,
staff, MCP, team chat and API docs contract tests pass unchanged.

## 9. Phases 3 and 4: marketing and the calendar

Phase 3 had no old table to copy (there were no event records before), so steps 2 to 4 of section 7
do not apply: the kinds were registered and new rows are written straight into `tasks`.

**Raw-query audit before registering the kinds.** A search of `web/app`, `web/lib` and `web/config`
for `unscoped`/`unscope` on task classes, `FROM tasks`/`JOIN tasks`, `tasks.` in SQL fragments,
`find_by_sql`/`select_all`/`execute` and every user of `Projects::Task` (task screens, project
progress and timeline, goals, dashboard widget, Next thing bar, reminder job, request triage, team
chat actions and links, MCP `list_tasks`, `list_projects`, `create_task`, `update_task`,
`period_review`, CSV export) found no read of the table that skips the `kind = 'task'` default scope.
The only cross-kind reads are `Work::Item` itself (parent check, calendar). The `tasks.` SQL
fragments are ordering and search clauses on `Projects::Task` relations, which keep the default
scope. `test/models/work/marketing_kinds_test.rb` and `test/integration/work_calendar_test.rb`
check that marketing items change no task count, listing, project progress, task page or MCP task
tool.

**Migration** `20261026100000_create_marketing_results`: creates `marketing_results` only (additive,
no rewrite of `tasks`). Rollback: `bin/rails db:migrate:down VERSION=20261026100000` drops the
results; marketing event and campaign task rows in `tasks` then block the phase 1 rollback until they
are removed.

**Code.** `web/app/modules/marketing/work_kinds.rb`, `result.rb`,
`web/app/policies/marketing/work_item_policy.rb`, `web/app/services/marketing/redemption_count.rb`,
`web/app/services/work/calendar.rb`, `Marketing::EventsController`, `EventWorkItemsController`,
`EventResultsController`, `CalendarController`, `WorkItemsHelper`.

## 10. Phase 2b: training assignments

Training had an old table, so this is the first phase that follows every step of section 7.

**Kind.** `Training::WorkKind` (`web/app/modules/training/work_kind.rb`): the old transitions unchanged
(`start` and `complete` by the assignee only, `cancel` by `hr.write`), `calendar: :due`, the module revision on
every history row (`event_details`), and the Activity log names training used before (`training_started`,
`training_completed`, `training_assignment_cancelled`, about the module). `TrainingAssignment` is now a
subclass of `Work::Item` with a `default_scope` on its kind (no `type` column, so no single-table
inheritance); its `unscoped` keeps the kind filter, so the setup checklist's cross-workspace reads cannot see
other kinds. `TrainingAssignmentEvent` reads `work_item_events` of the kind and translates the shared actions
(`created` → assigned, `transitioned` by start/complete/cancel → started/completed/cancelled).
`Training::AssignmentPolicy`: `hr.read` sees every assignment, `hr.write` assigns and cancels, everyone else
(staff included) sees and works only their own; assignments are never destroyed.

**Migration** `20261026150900_move_training_assignments_to_work_items` (additive):

- adds `work_item_events.details` and `training_assignments.work_item_id` (indexed);
- copies each old assignment into `tasks` (`kind = 'training_assignment'`, title = the module title, source =
  the module, assignee, requester = assigned by, due date, status, started and completed times — the cancel time
  for cancelled rows — and `details` = `legacy_id`, `completed_revision`, `completed_by_id`, original
  timestamps), records the new id on the old row, and copies each old history row into `work_item_events`
  (`assigned` → `created`; `started`/`completed`/`cancelled` → `transitioned` with `start`/`complete`/`cancel`)
  with its actor, name, note, time, `module_revision` and `legacy_event_id`;
- then checks that every old assignment has exactly one linked copy and every old event one copied event, and
  stops, saving nothing, if not;
- leaves `training_assignments` and `training_assignment_events` exactly as they were. They are read-only for
  this release (`TrainingAssignment::Legacy` only reads the id mapping); drop them in a later pull request once
  the copy is verified in production.

The copy is idempotent. `bin/rails training:copy_legacy_assignments` runs it again: after a code rollback, the
previous release keeps working on the old tables (it never reads the copies), and once the new code is back this
task copies what it wrote meanwhile — new assignments, new history rows, and newer status on rows already
copied — and checks the counts again.

**URLs.** Module pages keep their ids. Assignment ids changed (they are now `tasks` ids):
`/employee/training/:id` and its file links with an old id redirect (301) to the new id for the assignee only;
an old-id `POST` (start, complete, cancel) redirects without acting. An id that is both a new id and an old one
opens the new one.

**Rollback.** Code rollback needs nothing (see above). `bin/rails db:migrate:down VERSION=20261026150900`,
outside a transaction and after a backup, removes the copies, their history and the two added columns; it is
refused while training items exist that were made after the migration (they exist only in `tasks`).

**Raw-query audit, repeated for this kind.** The search of section 9 (`unscoped`/`unscope`, `FROM tasks`,
`JOIN tasks`, `tasks.` fragments, `find_by_sql`/`select_all`/`execute`, every `Projects::Task` user) found no
new read of the table that skips a kind filter. `GettingStartedChecklist` read `TrainingAssignment.unscoped`,
which is now kind-safe. `test/integration/training_work_items_test.rb` checks that training rows change no
task count, list, project progress, task page, task export or MCP task tool, plus the calendar by permission,
old links and workspace isolation; `test/services/training_work_items_migration_test.rb` runs up, re-run,
mismatch, down and up on a copy with rows.

**Code.** `web/app/modules/training/work_kind.rb`, `web/app/policies/training/assignment_policy.rb`,
`web/app/models/training_assignment.rb`, `training_assignment/legacy.rb`, `training_assignment_event.rb`,
`web/lib/tasks/training.rake`; `Work::Kind` (`event_details`, `activity`, `:assignee_only`), `Work::Tracked`
(transition notes, event details), `Work::Item` (a person who has since left no longer blocks saving an item
they were already on).

## 11. Later phases (not built)

1. **Requests** (#406, PR #519): kind `request`; triage writes the request item and its child task.
2. ~~Training~~: built (section 10). Drop `training_assignments` and `training_assignment_events` after a
   release has verified the copy.
3. ~~Marketing~~ and 4. ~~Calendar~~: built (section 9).
5. **Projects**: decide whether projects become kind `project`.
6. Show the item history on each item's page (marketing events show theirs; tasks do not yet).
7. When every module reads through `Work::Item` and deploys can tolerate it, consider renaming the
   table to `work_items` in a release that ships the rename on its own.

## Risks

- Code that reads the `tasks` table with `unscoped` or raw SQL sees every kind. The searches before
  phases 3 and 2b were clean (sections 9 and 10); repeat it before each new kind, and never call `unscoped` on
  `Projects::Task` (it drops the kind filter as well as the workspace). `TrainingAssignment.unscoped` keeps its
  kind.
- `details` is JSON in a text column: it cannot be indexed or summed. Fields that need that become
  columns in their own migration.
- History grows by one row per change; there is no retention rule yet.
