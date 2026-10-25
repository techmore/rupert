# Branching

The `main` branch is the Ruby on Rails (ROR) app in `web/`, the production implementation and source of truth. Deployed to SER8.

## Working branches

- Cut short-lived branches and land changes through pull requests.
- Branch off `main`.
- Naming: `fix/…`, `feature/…`, `docs/…`, or a tool prefix such as `codex/…` / `claude/…`.
- Head branches are **auto-deleted on merge** (repository setting), which keeps the branch list short.

## Deployment and acceptance

Merging to `main` is how a change reaches production. SER8's updater polls
`main` every 5 minutes and installs the tip once that exact SHA has green
`CI (sqlite3)`, `Product site consistency` and `Dependency and static scan`
checks (and mobile `validate` when mobile paths changed). In **Automatically**
mode, the default, that happens on the next poll; in **Only when I click
Install** mode an operator requests it. Each attempt takes a backup, writes a
release receipt and rolls the code back if the health or smoke check fails.
There is no release branch: a stable `v*` tag marks a commit already on `main`
and does not deploy anything. A merge, deployment, stable release and operator
acceptance are separate states; check the receipt or `X-Rupert-Build` before
describing a change as live. See the [development and deployment workflow](development-and-deployment-workflow.md)
and [SER8 updater runbook](../deploy/ser8/README.md#auto-deploy-rupert-autodeploy).
