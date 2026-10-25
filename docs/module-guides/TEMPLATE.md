# Module guide template

Copy this file to `docs/module-guides/<module>.md` and fill every section. Each
guide states how the module behaves **today**, from the source on `main`. Keep it
short and factual. Write `Unknown` when nobody has checked, and `None` when the
module has nothing for that section. Do not describe planned features as if they
exist; put them under "Open gaps" with their issue number.

Shared rules live elsewhere, so link to them and do not copy them:

- Interface: [interface guidelines](../ui-standards.md) and the
  [Human Interface Guideline for the release scope](../human-interface-guidelines.md).
- APIs: [API standards](../api-standards.md).
- Delivery: [development and deployment workflow](../development-and-deployment-workflow.md).

---

# <Module name>

Last checked against `main` at `<short SHA>` on `<YYYY-MM-DD>`.

## Purpose and owner

What the module is for, in one or two sentences. Who owns product decisions
(a role, for example "store owner") and who reviews changes. `ModuleRegistry`
keys and the rail section/group it lives in.

## Data model

The tables/models that are the source of truth, and which ones are mirrors or
derived. Name the model classes and main fields. Say which records are
tenant-scoped (`TenantScoped`).

## Permissions and tenant boundary

The permissions that gate reading and writing (`User::ROLE_PERMISSIONS`), the
Pundit policy, any extra checks (administrator, feature flag, employee
accounts), and how records stay inside one tenant.

## Routes and API

Main web routes. Any `/api/v1` endpoints or MCP tools that read or write the
module, with their token scopes. Link to [API standards](../api-standards.md)
instead of restating the contract.

## Workflow and status transitions

The statuses a record moves through, what moves it, and who may do it. Name the
state machine or service that enforces it.

## UI patterns

Which page template each main page uses (List, Detail, Form, Report, Settings,
Overview), the primary action, and any known departures from the interface
guidelines.

## Integration and sync

External systems the module reads from or writes to, the direction, and the
schedule. State plainly whether it writes to Shopify, Square or another outside
system (most modules do not).

## Audit history

What is recorded when records change: activity log entries, versions, actor and
time fields.

## Failure and recovery

What the person sees when something fails, what retries exist, how duplicates
are prevented, and how to recover (including restore notes).

## Required tests

The test files that cover the module today, and the checks a change must keep
passing.

## Open gaps

Release-gate items that are not done, with issue links. Known unknowns.
