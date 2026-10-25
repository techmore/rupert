# Staff app (mobile)

Last checked against `main` at `ec5ae024` on `2026-10-25`.

## Purpose and owner

Lets staff clock in and out, request clock corrections, and fill in and submit
their own timesheets from a phone. Two clients use the same server: the native
Expo/React Native app in `mobile/` and the installable web app at `/employee`.
Product owner: store owner. Signing and store distribution are owner decisions
and have not been done ([mobile README](../../mobile/README.md)).

It has no `ModuleRegistry` key of its own. It serves the staff side of
`time_clock` and `timesheets` (see [time clock and timesheets](timesheets.md));
employee accounts see only `ctrax_pos`, `time_clock`, `timesheets`, `receipts`
and `learning` in the web rail.

## Data model

- `EmployeeAppSession`: one row per signed-in device: user, employee,
  `device_name`, SHA-256 `token_digest`, `expires_at` (30 days after sign-in),
  `revoked_at`, and a fingerprint of the password hash. `TenantScoped`.
- The app reads and writes `ClockShift`, `ClockCorrection` and
  `People::Timesheet`/`TimesheetEntry` through the same services as the web.

## Permissions and tenant boundary

A token works only while: the app is enabled, it is not revoked or expired, the
user and tenant are active, the user has exactly one active linked employee in
that tenant, and the password has not changed since sign-in. Sign-in also
checks that a workspace subdomain, if present, matches the user's tenant. The
API always acts for the signed-in worker: it cannot review timesheets, and it
can reopen only a rejected sheet. These tokens are separate from operator API
tokens and have no catalog, report or admin scopes.

## Routes and API

`/api/v1/employee/session` (POST sign-in, GET, DELETE),
`/api/v1/employee/clock` (GET, POST, PATCH `:id`, POST `:id/corrections`),
`/api/v1/employee/timesheets` (CRUD, `actions/:event` for `submit`, `reopen`,
`import_shifts`, and `entries`), `/api/v1/employee/square_timecards` (read
only; the native app does not call it). Web: `/employee` and its pages,
`/employee/devices` (list and revoke own devices). Contract and error shape:
[API standards](../api-standards.md) and
[staff timesheets](../employee-timesheets.md).

## Workflow and status transitions

Session: issued → revoked (sign-out, device revoke, access change, or employee
consolidation) or expired after 30 days. Timesheet and clock states are the ones
in [time clock and timesheets](timesheets.md).

## UI patterns

The native app is one screen file (`mobile/App.tsx`): sign-in, timesheet list
and detail, clock, corrections. It is outside the management-app shell and the
[interface guidelines](../ui-standards.md). How far the `/employee` web pages
follow those guidelines: Unknown.

## Integration and sync

None outside Rupert. The native app talks only to the instance's HTTPS origin,
refuses redirects, stores the token in SecureStore and does not keep the
password. There is no offline queue; after a timeout it asks the person to
refresh before retrying.

## Audit history

Sign-ins are written to the access log (`AccessLogger`, success and failure).
Clock and timesheet changes are audited as in the timesheets guide. Device
revocation sets `revoked_at`; a separate log entry for it: Unknown.

## Failure and recovery

**Kill switch** ([#436](https://github.com/techmore/rupert/issues/436)):
`RUPERT_EMPLOYEE_APP_ENABLED` (off in production unless set to `1`). While off,
every employee API call, sign-in included, returns `503 employee_app_disabled`
and existing tokens fail closed. It is install-wide, not per workspace or per
user; per-device revocation covers single devices. The `/employee` web pages use
normal web sign-in and are not affected. Bad or revoked tokens get `401`, which
makes the app sign out. Sign-in is rate limited (`employee-login/ip`, plus
`LoginThrottle`).

## Required tests

`test/integration/employee_timesheets_test.rb` (API, kill switch, revocation),
`employee_workspace_test.rb`, `employee_preview_test.rb`,
`employee_role_boundaries_test.rb`, and in `mobile/`: `npm run check`
(`tests/validation.test.mjs`, `tests/dependency-security.test.mjs`). The
`Employee mobile` workflow runs on mobile path changes; the deployer requires
its `validate` result for those commits.

## Open gaps

- Native signing, store distribution and real-device acceptance have not been
  done (see the mobile README).
- [#326](https://github.com/techmore/rupert/issues/326) asks whether mobile is
  disabled or kept for release; production default is off.
- Raw `npm audit` still reports upstream advisories with source-hashed
  backports (mobile README).
