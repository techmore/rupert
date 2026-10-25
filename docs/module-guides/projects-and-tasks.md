# Projects and tasks

Last checked against `main` at `96a8a660` on `2026-10-25`.

## Purpose and owner

Plan and track work: projects with owners, members and dates, and tasks assigned to people with
due dates, status, checklists and discussion. Staff see only the tasks assigned to them
(**My tasks**).

Owner: the store owner decides how work is planned and assigned. Changes are reviewed through
normal PR review. `ModuleRegistry` keys: `projects` and `tasks` (Work section; `goals` and
`kpis` sit beside them but are not covered here). Operator detail:
[Projects and Tasks](../ops/projects-and-tasks.md).

## Data model

Under `web/app/modules/projects/`: `Projects::Project`, `ProjectMember`, `ProjectTemplate`
(tasks, checklists and date offsets as one JSON document), `Task`, `TaskChecklistItem`,
`TaskComment`, `TaskTimeEntry`, `TaskAttachment` (stored in the database, served only as
downloads) and `TaskDependency`. `Project` and `Task` include `TenantScoped`. `projects.goal_id`
must point at a goal in the same workspace.

Tasks live in the shared work-item table ([#407](https://github.com/techmore/rupert/issues/407),
[design](../architecture/shared-work-items.md)): the `tasks` table carries a `kind` (`task` for
every task), and `Projects::Task` reads only that kind. `Work::Item` reads every kind, and
`work_item_events` keeps an append-only history of each task's creation, field changes, status
changes and deletion, with who did it. Marketing events and campaign tasks share the table
(kinds `marketing_event`, `campaign_task`, see [Marketing](marketing.md)); they never appear in task
lists, counts, project progress or task tools. Requests, training and order follow-up move in during
later phases.

## Permissions and tenant boundary

- `projects.read` views; `projects.write` plans (create, delete, reassign, dates, dependencies,
  templates, project export). Policies: `Projects::ProjectPolicy`, `Projects::TaskPolicy`.
- Staff accounts (`tasks.self`) work only on tasks assigned to them: edit title and notes,
  comment, tick the checklist, log time, attach files, block or finish. Their endpoints are on
  the boundary list in `ApplicationController#enforce_employee_boundary`.
- Team membership only decides who is notified, not who may see a task.
- Records are filtered to the current tenant by `TenantScoped`.

## Routes and API

- Web: `/calendar` (**Work → Calendar**, `ModuleRegistry` key `calendar`), `/projects/projects`,
  `/projects/tasks` (views: board, list, calendar),
  `/projects/tasks/:id`, plus nested checklist, comment, time entry, attachment, dependency and
  template routes.
- MCP tools ([MCP guide](../mcp.md)): `list_tasks` and `list_projects` (`tasks:read`, owner needs
  `projects.read`); `create_task` and `update_task` (`tasks:write`, owner needs
  `projects.write`; `update_task` also checks the owner may edit that task). Team chat can
  propose the two write tools; a person must approve them.
- No `/api/v1` endpoint. Contract rules: [API standards](../api-standards.md).

## Workflow and status transitions

AASM state machines with direct assignment turned off:

- **Project**: `planned` → `active` ⇄ `on_hold` → `completed`; any of those → `archived`;
  `reopen` returns `completed` or `archived` to `active`. Completing with open tasks asks whether
  to finish them or leave them open.
- **Task**: `todo`, `in_progress`, `blocked`, `done` (`Projects::Task::BOARD_STATUSES`).
  `start` and `finish` are refused while the task waits on unfinished dependencies. Blocking
  records a reason. Finishing a repeating task creates the next copy once. Board moves go
  through `Task#move_to!`, which takes a row lock.

## UI patterns

Tasks is a List-template page with `.tabs` for board, list and calendar; a task is a Detail page
with facts and related sections. Projects has a board and a timeline per project. Desktop and
phone visual acceptance: Unknown.

**Calendar** ([#417](https://github.com/techmore/rupert/issues/417)): **Work → Calendar**
(`/calendar`, `CalendarController`, `Work::Calendar`) shows task deadlines, campaign task deadlines
and marketing events together, as a **Month** grid or an **Agenda** table (`.tabs`), with a month
stepper and a Show filter (everything, task deadlines, marketing). Each kind is filtered by its own
policy scope (tasks: `projects.read`; marketing: `marketing.read` with Marketing on), so a person sees
only what they could open; everything is in the current workspace. All kinds load in one query per
month. Task dates are in store time; event times are shown in each event's own time zone with its
abbreviation, with venue, store location or channel, status and a link to the task or event page.
The page is in the rail for anyone with `projects.read`, or `marketing.read` while Marketing is on.
Staff accounts keep **My tasks** and do not get the calendar. The Tasks page keeps its own calendar
tab of tasks by due date (`TasksController#load_calendar`).

## Integration and sync

None. Tasks and projects live only in Rupert. Nothing is sent to Shopify, Square or another
outside system. Notifications are in-app only (no email or push).

## Audit history

The task controller writes Activity log entries (`task_created`, `task_updated`,
`task_deleted`, `task_transitioned`, `task_moved`), and the task page shows the latest 25.
Tasks created by an assistant are marked as such; a task approved from team chat links back to
the chat message and records who asked. CSV exports are logged. Every save of a task, from any
path (web, MCP, team chat, request triage, jobs), also writes a `work_item_events` row with the
field before/after values; those rows cannot be edited or deleted and outlive the task.

## Failure and recovery

- Invalid moves (blocked by dependencies, wrong state) are refused with a message and the task
  stays where it was.
- `TaskReminderJob` (07:30 America/New_York) adds due-today and weekly overdue reminders with a
  dedupe key, so reruns send nothing twice.
- Migration `20261023120000` clears `tasks.project_id` values that point at no project in the
  same workspace; back up first ([operator notes](../ops/projects-and-tasks.md)).

## Required tests

`test/integration/tasks_flow_test.rb`, `project_management_test.rb`,
`employee_tasks_access_test.rb`, `projects_guide_test.rb`, `task_ai_activity_test.rb`,
`mcp_server_test.rb`, `test/policies/projects_task_policy_test.rb`,
`test/javascript/task_board_test.mjs`, `test/models/work/item_test.rb`,
`test/models/work/marketing_kinds_test.rb`, `test/integration/work_calendar_test.rb`,
`test/services/shared_work_items_migration_test.rb`, and the team chat approval tests
(`test/services/team_chat/actions_test.rb`).

## Open gaps

- [#407](https://github.com/techmore/rupert/issues/407): decided (one shared table); phase 1 moved
  tasks in. Later phases are listed in the [design](../architecture/shared-work-items.md). The item
  history is not shown on the task page yet.
- [#417](https://github.com/techmore/rupert/issues/417): the shared calendar is built; acceptance
  evidence in the production workspace is not recorded. No week view and no calendar feed (iCal).
- [#406](https://github.com/techmore/rupert/issues/406): assistant requests triaged into tracked
  tasks without duplicates.
- Email or push delivery, @mentions and per-person notification preferences are not built.
- Acceptance in the intended production workspace: not recorded.
