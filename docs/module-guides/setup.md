# Organization setup and onboarding

Last checked against `main` at `ec5ae024` on `2026-10-25`.

## Purpose and owner

Gets a new workspace from nothing to useful: create the first workspace and
administrator, save source connection details, and give each person a short,
role-aware "first week" checklist and learning path. Product owner: the store
owner. Changes are reviewed through a PR.

There is no single `ModuleRegistry` entry called "Setup". The pieces are:

- First-run setup at `/setup` (no rail entry; only reachable before any
  workspace exists).
- Onboarding at `/onboarding` (no rail entry).
- The welcome and "Your first week" checklist on the home page and at
  `/welcome`, part of **Me → Learn Rupert** (`learning`).
- **System → Owner checklists** (`owner_checklists`): private owner records of
  domains and outside services. It records information; it does not configure
  anything.

## Data model

- `Tenant` and the first `User` (role `super_admin`), created together by
  `SetupController#create`. The default chart of accounts is seeded
  (`Finance::ChartOfAccounts.seed!`).
- Connection details are `Setting` rows per tenant, written through
  `EnvStore.set`; `Setting#value` is encrypted (`encrypts :value`).
- Learning and checklist progress live in the user's workspace preferences
  (`LearningJourney`: chosen path, completed lessons and times, tours, items
  marked done by hand). See [in-app learning](../ops/in-app-learning.md).
- `GettingStartedChecklist` is computed, not stored. Most items tick
  themselves from real state (a saved connection, a successful `SyncRun`, a
  second user, a finished lesson); the rest have **Mark done**.
- Self-service sign-up uses `WorkspaceSignup` (`pending`, `approved`,
  `rejected`) and `WorkspaceDeployment` (`requested`, `provisioning`, `ready`,
  `failed`); see [private workspaces](../ops/private-workspaces.md).
- `OwnerChecklist` records are written through `OwnerChecklistWriter` with
  optimistic locking (`lock_version`).

## Permissions and tenant boundary

- `/setup` returns to the login page once any `Tenant` exists and is `404` on an
  isolated workspace node (`WorkspaceNode.isolated?`).
- `/onboarding` shows the connection form only to people with
  `settings.write` on an active workspace; others see the learning path.
  Submitted keys must be in `EnvStore::MANAGED_KEYS`.
- Checklist items appear per permission (`settings.write`, `sync.read`,
  `sales.read`, timesheet or receipt reviewers, account managers,
  `dashboard.read`). Employee accounts get a staff list (clock in, open the
  register).
- Owner checklists require an owner/administrator role, not a delegated
  settings permission (`require_owner`).
- Settings, sync runs and users are filtered by `tenant_id`.

## Routes and API

- `GET/POST /setup`, `GET /onboarding`, `POST /onboarding/connect`.
- `GET/POST /welcome`, `GET /learning`, `GET /learning/team`.
- `/owner_checklists` (index, new, create, show, edit, update, print, service,
  feature review).
- No `/api/v1` endpoint or MCP tool. `get_workspace_info` reports workspace
  facts only. See [API standards](../api-standards.md).

## Workflow and status transitions

1. First run: one form creates the workspace and super admin, signs them in.
2. Onboarding: save Shopify details (required to show the dashboard; Square is
   optional). Saving never starts a sync, tests credentials or charges anything.
   Once `SHOPIFY_CLIENT_ID` and `SHOPIFY_CLIENT_SECRET` are set, `/onboarding`
   redirects to the dashboard.
3. Welcome: choose a learning path or skip; either is recorded.
4. First week checklist: items move from not done to done (automatically or by
   **Mark done**) until the list is finished or hidden.

There is no per-step owner, prerequisite or "last validated" field in source;
step status is done / not done.

## UI patterns

`/onboarding` is a Form template (`.page-narrow`, one primary action "Choose my
getting-started path"). The checklist is a card with a `progress` bar on the
home page. Owner checklists use List / Detail / Form templates.

## Integration and sync

Saving connection details writes only local encrypted settings. First-run setup
copies managed keys already present in the server environment into the first
tenant. Syncs are started separately from **System → Sync** and are read-only
mirrors. Nothing here writes to Shopify, Square or another outside system.

## Audit history

Unknown for first-run setup and onboarding saves: no `ActivityLogger` call was
found in `SetupController` or `OnboardingController`. Sign-in is recorded by the
session code. Owner checklists store `created_by` and `updated_by` (`OwnerChecklistWriter`).

## Failure and recovery

- Invalid first-run input re-renders the form with errors (`422`).
- An unknown key on `/onboarding/connect` is refused; any other error shows
  "Could not save connection details". Saving again replaces the value, so a
  retry does not create duplicates (`find_or_initialize_by` on key and tenant).
- A failed workspace deployment shows "Setup needs operator attention".
- Owner checklist edits that conflict show a stale-record message.

## Required tests

- `web/test/integration/onboarding_connect_test.rb`
- `web/test/integration/learning_onboarding_test.rb`,
  `learning_flow_test.rb`, `learning_definitions_test.rb`
- `web/test/integration/connections_flow_test.rb`,
  `connection_credentials_test.rb`
- `web/test/services/workspace_signup_provisioner_test.rb`

No test was found that posts to `/setup` directly.

## Open gaps

- Gates #396–#401 were closed on the owner's walkthrough acceptance on
  2026-10-25. #402 (keep the gate non-mutating for production and merchant
  data) is still open.
- The release-gate wording asks each step to show its owner, prerequisites,
  most recent validation and remaining work. Source shows done / not done
  only; whether that difference was accepted is Unknown.
