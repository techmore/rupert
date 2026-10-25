# Assistant: Team chat and Ask Rupert

Last checked against `main` at `ec5ae024` on `2026-10-25`.

## Purpose and owner

Two assistant surfaces that answer questions from Rupert's own data:

- **Team chat** (`/chat`): shared rooms where people talk and can mention `@rupert` (and, when
  configured, local test models such as `@qwen`, `@lfm`, `@bonsai`, `@gemma`).
- **Ask Rupert**: a private help panel opened from the top bar. It explains where things are and
  how to do them, and can read data the person may see.

Owner: the store owner decides who may use each surface and which model answers. Changes are
reviewed through normal PR review. `ModuleRegistry` keys: `team_chat` (Team → People) and
`ask_rupert_usage` (System → Settings). Ask Rupert itself is a top-bar utility, not a rail entry.

## Data model

- Team chat: `TeamChat::Room`, `Membership`, `Message`, `Attachment`, `Reaction`, `Run`
  (`chat_runs`, the reply outbox), `Approval` and `ApprovalEvent` (`chat_approvals`, proposed
  changes and their receipts). Messages and attachments are rows in Rupert's own database.
- Ask Rupert: conversations and messages per person, plus `ask_rupert_usages` (counters only:
  person, time, provider, model, tokens, lookups; kept 35 days).
- `TeamChat::Approval` is `TenantScoped`; a decided approval cannot be edited. Other tables:
  Unknown whether every one includes `TenantScoped`; rooms are looked up through
  `Room#visible_to?`.

## Permissions and tenant boundary

- Team chat: `TeamChat.allowed?` requires an active, non-employee user with `settings.write`
  in the current tenant, so it is administrators only today. Each room is also checked with
  `visible_to?`.
- Ask Rupert: `chat.use` (administrators by default; can be granted on the Permissions screen).
  Employee accounts are refused. The usage page needs `settings.read` to view and
  `settings.write` to change.
- Lookups run in-process **as the person who asked**, with that person's current permissions.
  Ask Rupert uses `AskRupert::ScopedToken`, an in-memory token built from the person's
  permissions that never carries a write scope.
- Everyone in a room reads `@rupert`'s reply. Before rooms are opened to staff, the tools must be
  limited to what every member may see ([team chat guide](../ops/team-chat.md)).

## Routes and API

- Team chat: `/chat`, `/chat/:room`, `/chat/:room/messages` (JSON polling), rooms, DMs, dock,
  presence and the model battery under `/chat/models`.
- Ask Rupert: `/ask_rupert`, `/ask_rupert/conversations[/:id]`, `…/messages`, `…/report`,
  `/ask_rupert/usage`.
- No `/api/v1` endpoint. The assistants call the same tool classes as the [MCP server](../mcp.md)
  in-process. Contract rules: [API standards](../api-standards.md).

## Workflow and status transitions

- A team chat reply creates a `chat_runs` row with its pending message. A worker claims it with a
  short lease; the deadline is two minutes for `@rupert` and five for local models. The asker can
  press Stop.
- Write tools only **propose**. `create_task`, `update_task` and `submit_feedback` are the only
  tools that can be approved in chat (`TeamChat::Actions::LOCAL_TOOLS`). An approval moves
  `proposed` → `done`, `failed` or `dismissed`. It runs as the person who pressed **Approve**,
  and only if that person holds the needed permission.
- Ask Rupert never changes anything except a report the person sends with **Send report**.

## UI patterns

Team chat is a full chat page plus a dock beside other pages; it polls every 1–3 seconds (no
WebSockets). Ask Rupert is a side panel, full width on a phone. The usage page is a Settings
template page. Both follow the shell rules in the [interface guidelines](../ui-standards.md).
Desktop and phone visual acceptance: Unknown.

## Integration and sync

- Model provider is chosen by instance environment, not a web setting:
  `RUPERT_CHAT_PROVIDER` (`opencode_go`, `ollama`, `openai`, `opencode_cli`, or auto) for team
  chat; Ask Rupert has per-workspace modes (cloud, local first, local only) using the `opencode`
  CLI and an optional Ollama model.
- Team chat uses RubyLLM (`ruby_llm` 2.1) with native tool calling, falling back to the
  `opencode` CLI in auto mode.
- What leaves the server: the question, recent conversation and tool results go to the chosen
  model. With a cloud provider that is an outside service; in Ask Rupert's local-only mode nothing
  leaves the server. Ask Rupert passes text through `AskRupert::Redactor` (keys, bearer tokens,
  card-like numbers; emails and phones in tool results). Team chat removes contact details from
  tool results.
- No writes to Shopify, Square or any outside commerce system.

## Audit history

- Approved chat changes write an Activity log entry (`team_chat_action`) with the approval id,
  tool and provenance (requester, room, model). Approval events record who decided and when.
- Ask Rupert tool calls are logged as `ask_rupert_tool` (tool, outcome, duration, conversation id;
  never the question or results).
- A task created from chat gets "Requested by … via team chat" and a link back to the message.

## Failure and recovery

- `TeamChat::RecoverRunsJob` runs every minute and re-dispatches queued or abandoned runs; a run
  gets three claims before it fails. A changed model or endpoint fails recovery instead of
  continuing on another route.
- Proposal creation and its receipt share a transaction, so a crash does not duplicate approval
  cards. A failed receipt is never re-run.
- Ask Rupert marks a reply stuck for 3 minutes as failed; over-limit requests get HTTP 429 with
  `Retry-After`. If no model is reachable, people see a "can't reach the assistant" message.

## Required tests

`test/integration/team_chat_test.rb`, `team_chat_questions_test.rb`,
`team_chat_request_revision_test.rb`, `ask_rupert_flow_test.rb`, `chat_side_panel_test.rb`,
`test/services/team_chat/*_test.rb` (including `actions_test.rb`, `approval_test.rb`,
`permission_delivery_test.rb`, `restart_test.rb`), `test/services/ask_rupert/*_test.rb`,
`test/jobs/chat_worker_isolation_test.rb`, and `test/javascript/team_chat_test.mjs`,
`ask_rupert_test.mjs`.

## Open gaps

- [#403](https://github.com/techmore/rupert/issues/403): an owner-approved provider passing
  synthetic chat, tool-call, timeout and fallback checks.
- [#404](https://github.com/techmore/rupert/issues/404): evidence that answers stay inside the
  asker's tenant and permissions.
- [#406](https://github.com/techmore/rupert/issues/406): triage of assistant requests into tracked
  tasks, monitored through status changes, without duplicates.
- [#408](https://github.com/techmore/rupert/issues/408): chat stays its own record, with
  authorized links to projects.
- Opening team chat to non-administrators is not done.
