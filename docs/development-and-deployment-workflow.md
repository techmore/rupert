# Development and deployment workflow

This guide is the shared path from an issue to an accepted change. It describes
the repository and SER8 automation as audited on 2026-10-22. Repository settings
and the installed updater can change; verify current GitHub checks and operator
mode before relying on them.

## 1. Start with one work contract

Before implementation, link the work to an issue or create a focused issue. It
should state the user outcome, scope and exclusions, acceptance checks, data or
permission impact, dependencies, rollout and recovery plan, and whether live
operator acceptance is required. Give one person ownership of integration.
Check open issues, PRs and active work for overlap before opening another PR.

Keep each change on its own short-lived branch and worktree. Do not share a
mutable checkout or push to another contributor's branch. Split independent
behaviors into separately reviewable PRs and link related work. Checkpoint
locally as useful; push coherent updates because each new PR head consumes CI.

## 2. Branch and review policy

Use `main` as the integration branch and open a PR for changes. Branch names
normally use `fix/`, `feature/`, `docs/` or a contributor/tool prefix. Branches
are configured for deletion after merge.

The API-verified `main` protection snapshot on 2026-10-22 requires a PR, has
zero required approving reviews, and does not require a PR branch to be current
with `main` (`strict=false`). It requires `CI (sqlite3)`, `Product site
consistency`, `Dependency and static scan`, and `cla`. `Employee mobile` is
path-filtered and is not a required check. Treat current GitHub settings as the
source of truth; see [issue #206](https://github.com/techmore/rupert/issues/206)
for the exact-SHA release receipt and missing/skipped-check evidence that are
still open.

Fix a real merge conflict when it blocks integration. Do not rebase solely
because `main` advanced. A green PR head is necessary for merge, but does not
prove that the integrated commit is deployable or accepted by an operator.

## 3. CI and integration

Full CI runs on pull requests and on pushes to `main`; feature-branch pushes do
not launch a duplicate full CI run. Mobile checks remain path-filtered and,
like CI, run on pull requests and `main` pushes only. PR runs of CI, Security
and Employee mobile cancel when the PR gets a newer head; `main` runs never
cancel each other, so every integrated SHA gets its own result. The
security workflow runs for pull requests, `main` pushes and its scheduled
scans. Cancellation should supersede older runs for the same PR, not serialize
unrelated work. Keep required check names stable and do not let path filters
silently skip a required check.

After a merge, verify the checks for the exact integrated `main` SHA. Preserve
the links to required runs and any applicable mobile validation with the PR or
release record. A successful check on an earlier or duplicate event is not a
substitute for a failed required check on the current head. The deployment
updater gates on the newest exact-SHA `CI (sqlite3)`, `Product site
consistency`, and `Dependency and static scan` checks. Missing or pending
checks wait; a completed non-success check blocks. `cla` is a PR-only check and
does not run as an integrated-main gate. If mobile source, the SDK checker, or
its workflow changes, the updater also requires the exact-SHA `validate` result
from the Employee mobile workflow, read from the newest commit in the
deployed range that touched those paths (that workflow does not run on later,
unrelated commits). Deployer tests cover missing, pending, failed, rerun and
mobile-path results.

Measure CI cost with runner-minute billing data and comparable windows. Record
runner minutes, runs per unique PR SHA, duplicate event pairs, queue time,
cancellations, failures and median completion time. Workflow counts alone do
not establish savings.

## 4. Deployment modes and release boundaries

SER8 runs the Rails application in Incus. The `rupert-autodeploy` timer polls
`origin/main` every five minutes. When the in-app updater is in **Automatically**
mode, a green eligible `main` commit can install without a stable release tag.
In **Only when I click Install** mode, an operator request is required. The
installed mode and deployed SHA must be verified from the host/app status; do
not infer either from repository configuration.

The updater checks for a clean checkout and fast-forward, waits for the newest
`CI (sqlite3)`, `Product site consistency`, and `Dependency and static scan`
checks on the target SHA (and `validate` on the newest mobile commit when mobile paths changed), takes a pre-deploy SQLite backup, installs
dependencies, migrates and precompiles assets, restarts services, then checks
`/up`. On health-check failure it rolls back the code; it does not reverse
database migrations. It records a failed SHA to avoid retry loops. A manual
request can retry a failed SHA. See the [SER8 updater runbook](../deploy/ser8/README.md#auto-deploy-rupert-autodeploy)
for file state, commands and limitations.

A stable `v*` tag/release, an automatic `main` install, a successful `/up`, and
product/operator acceptance are separate events. A release must target the
intended exact commit and include its checks and reviewed notes. Do not claim a
feature is live from a merge or prerelease alone; verify `X-Rupert-Build` and
the rendered feature on the intended instance.

## 5. Deployment receipt and recovery

For each release or operationally accepted change, record privately:

- PR URL, integrated full SHA, relevant exact-SHA check URLs and release/tag;
- deploy mode and observed current/target SHA, with the time of verification;
- backup identifier, migration/build outcome, service restart and health result;
- rollback result or reason it was not needed, plus operator acceptance and
  limitations.

Never put credentials, customer records, private logs or recovery material in
public GitHub. Keep deployments, merchant/provider writes, payroll actions and
restore decisions within their existing owner/operator authorization boundary.

Prefer additive migrations and rehearse recovery on an isolated restored copy.
The updater can roll back application code after a health failure, but database
migrations remain. Restoring a backup after business writes can lose data and
requires the owner's written approval. Follow the
[backup and restore runbook](ops/backup-restore-runbook.md).

## 6. Parallel delivery rule

Several people and agents work on Rupert at the same time. This is the rule that
lets them merge independently without breaking `main` or the deployment.

1. **One change, one branch, one worktree, one PR.** Create the branch from the
   current `origin/main` in its own worktree
   (`git worktree add -b docs/my-change ../rupert-my-change origin/main`). Never
   share a checkout or push to someone else's branch. Do not delete other
   people's branches; GitHub deletes a branch after its PR merges.
2. **Do not sync just because `main` moved.** Branch protection has
   `strict=false`, so a PR does not have to be current with `main`. Update a
   branch only when GitHub reports a conflict or a required check fails because
   of something already on `main`. To update without a local rebase, use
   `gh api -X PUT repos/techmore/rupert/pulls/<number>/update-branch`
   (the `gh` CLI has no `pr update-branch` command). Resolve real conflicts on
   the branch.
3. **Merge only on green.** The required checks (`CI (sqlite3)`,
   `Product site consistency`, `Dependency and static scan`, `cla`) must pass on
   the PR head. Auto-merge (`gh pr merge <number> --merge --auto`) is allowed
   once the owner has approved the change; GitHub then merges only after the
   required checks pass. Missing, skipped, pending or cancelled checks are not
   passes.
4. **Every `main` commit keeps its own result.** CI, Security and Employee mobile
   cancel superseded runs only for pull requests; `main` runs are grouped by
   commit SHA and never cancel each other
   ([PR #495](https://github.com/techmore/rupert/pull/495)). A cancelled `main`
   run would count as non-success and block deployment of that SHA.
5. **The deployment checks the integrated result.** Head-only PR checks do not
   prove the merged combination works. The SER8 updater
   (`deploy/ser8/rupert-autodeploy.sh`) deploys only when the exact `main` SHA
   has green `CI (sqlite3)`, `Product site consistency` and
   `Dependency and static scan`, and, if the range includes a mobile change, a
   green `validate` on the newest mobile commit
   ([PR #507](https://github.com/techmore/rupert/pull/507)). A red integrated
   check is fixed by a new PR, not by rerunning until green.
6. **Tests must not depend on the day they run.** Parallel merges land at any
   hour and day, so a test that counts by weekday or "today" fails on some
   merges and not others. Pin the clock (`travel_to`) to a fixed date; the page
   query budget test runs on a fixed Sunday, its largest day
   ([PR #505](https://github.com/techmore/rupert/pull/505)).
7. **Check integration when two PRs touch the same thing.** If PRs change the
   same model, migration, route or shared helper, the second one to merge
   updates its branch (rule 2) and reruns checks before merging. There is no
   merge queue today; if head-only checks stop being enough, add one rather than
   turning on `strict`.

`deploy/ser8/tests/test_delivery_rules.py` (run in the Product site consistency
job) checks that the workflow files, the updater and the page budget test still
match rules 3–6. Change that test and this section together.

## 7. Acceptance and evidence

Track the change through distinct states: PR checks, merged SHA, integrated
checks, deploy eligibility, backup, migration/build, installed revision,
health, publication and operator acceptance. Close an implementation issue
when its code and repository-level acceptance criteria are complete. Keep
issues open when they still require production evidence, finance reconciliation,
merchant use, owner/operator review, or recovery acceptance. Record the exact
remaining evidence without exposing private business data.

Related gates: [deployment readiness #207](https://github.com/techmore/rupert/issues/207),
[release readiness #326](https://github.com/techmore/rupert/issues/326), and
[workflow/deployment gates #334](https://github.com/techmore/rupert/issues/334).
