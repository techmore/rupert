# WebMCP: Rupert tools for in-browser AI assistants

Rupert's pages offer tools to an AI assistant that runs inside the person's own
browser, using [WebMCP](https://github.com/webmachinelearning/webmcp) (W3C Web
Machine Learning Community Group draft, `document.modelContext`). It also serves
[`/llms.txt`](https://llmstxt.org) and `/llms-full.txt`, plain-text maps of the
public site for assistants that read rather than call tools.

WebMCP is the third way into the **same tools**:

| Path | Who calls | Credential | Tools |
| --- | --- | --- | --- |
| [MCP server](mcp.md) `POST /mcp` | External assistants (Claude Code, Desktop, ChatGPT…) | Bearer token with scopes | `Mcp::Registry` per token scope |
| [Ask Rupert](ops/ask-rupert.md) / team chat | Rupert's own in-app assistant | The signed-in person (in-process) | `Mcp::Registry` read tools + Ask Rupert lookups |
| **WebMCP** (this page) | An assistant in the person's browser | The signed-in browser session + CSRF | An allow-listed subset of the above |

Nothing is defined twice. `WebMcp::Registry` (`web/app/services/web_mcp/registry.rb`)
lists tool *names*; each name's title, description and JSON schema come from the
shared `Mcp::Registry` class or Ask Rupert's lookup definition, so a fix there
reaches all three paths.

## Public site (signed out)

The landing page (`/`) embeds read-only facts from `WebMcp::PublicSite`
(`web/app/services/web_mcp/public_site.rb`), the same source as `/llms.txt`:

| Tool | Answers |
| --- | --- |
| `get_business_info` | What Rupert is, who it is for, the four jobs, how a day runs, connections, guide links |
| `get_pricing` | Free account, $499/month, referral discount, sign-up links |
| `get_contact` | sdolbec@rupertpos.com, support, privacy, sign-in and create-account pages |
| `request_demo_link` | Free-account link and a `mailto:` demo-request link. Nothing is sent or booked |

The answers are embedded in the page, so calling a tool makes no request.
`/llms.txt` and `/llms-full.txt` return `text/markdown`, are cacheable for an
hour, and return 404 on a private single-store node (`RUPERT_NODE_MODE=workspace`).
When a price or address changes, change it in `PublicSite` and on the landing
page; `test/services/web_mcp/public_site_test.rb` checks they still agree.

## Signed-in app

Every page that has the app shell carries a small config
(`<script type="application/json" id="rupert-webmcp">`). `lib/webmcp.js` reads it
**only when the browser has `document.modelContext`** (or the older
`navigator.modelContext`). Without one it does nothing: no request, no tool.
With one, it fetches `GET /webmcp/tools` and registers each tool listed there with
`registerTool(tool, { signal })`. A call goes to `POST /webmcp/tools/:name`.

| Tool | Kind | Needs |
| --- | --- | --- |
| `business_pulse`, `sales_summary`, `daily_close`, `order_queues` | read | `reports.read` |
| `inventory_search` | read | `inventory.read` |
| `list_alerts` | read | `alerts.read` |
| `time_keeping_report` | read | `timesheets.read` (own hours only unless the person reviews timesheets) |
| `list_tasks` | read | `projects.read` |
| `data_guide` | read | any staff account |
| `where_is`, `how_do_i` | read (Ask Rupert lookups) | any staff account; only pages the person can open |
| `create_task` | **write, confirmed** | `projects.write`; adds a task to Rupert's own Tasks board |

Tool descriptions, arguments and results are documented in [mcp.md](mcp.md#3-tools).
Results use the MCP shape (`content`, `structuredContent`, `isError`).

### Who gets what

- The list is built per request from the person's **current** permissions
  (`user.can?`), through `WebMcp::SessionToken`, the same scope-to-permission check
  the MCP server and Ask Rupert use. A tool the person cannot use is not listed
  and is refused (`404 unknown_tool`) if called anyway.
- Staff self-service (employee) accounts, deactivated accounts and inactive
  stores get no tools (`403`).
- The page config carries a key derived from the person and their permissions.
  After a sign-in, sign-out or permission change (Turbo navigation), the old tools
  are unregistered through their `AbortSignal` and the new list is registered.

### Writes need the person's confirmation

The draft spec has no page-side way to ask the user yet (it is an open question
upstream), so Rupert does it itself:

1. The assistant calls `create_task`.
2. The page first sends a `dry_run` to validate and preview it.
3. The browser's own `confirm()` dialog shows the preview: *"An AI assistant in
   this browser wants Rupert to: …"*. A native dialog is used on purpose: an
   agent that drives the page's DOM cannot press it the way it could press an
   in-page button.
4. Only if the person presses OK is the call sent again with `confirmed: true`.
   If they decline, the assistant is told "The person declined" and nothing is sent.

The server refuses a write without `confirmed: true` (`428 confirmation_required`).
That flag records intent; it cannot prove a human pressed OK, so the real limits
are the person's own permissions, the allow-list, and the task-write cap. Write
tools are annotated `consequentialHint: true`, so a WebMCP agent that enforces its
own confirmation step will ask too.

### Never offered

Payments or card actions (card data never touches Rupert; card terminal, gateway
and subscription billing flows stay out), refunds, customers, user and role
administration, settings, backups, keys and tokens, exports, uploads, feedback,
deploys, logs and system health. The registry test fails if an offered tool's
name or scope matches any of these.

### Same safeguards as any other request

- **Session and CSRF**: `WebMcpController` is an ordinary `AuthenticatedController`.
  The browser session signs it in; every `POST` needs the page's CSRF token
  (`X-CSRF-Token`), otherwise `422` with `error: "csrf"`. No token is issued and
  `/mcp`'s bearer tokens are not accepted here.
- **Authorization**: `WebMcpPolicy#use?` (Pundit) for the endpoint, then the
  per-tool permission check, then each tool's own checks (for example
  `Projects::TaskPolicy#create?` inside `create_task`).
- **Rate limits**: Rack::Attack `webmcp/ip`, 60 requests a minute per IP, plus
  the global ceiling. `create_task` is capped at 20 writes a minute per person
  (`Mcp::TaskWriteGuard`, keyed `webmcp-<user id>`).
- **Audit**: every call writes `webmcp_tool_call` to the Activity log and the ops
  log: tool, outcome, duration, whether it was confirmed or a dry run, a SHA-256 of the
  arguments and the browser's user-agent. Arguments and results are never stored.
  A created task also gets the normal `task_created` entry and the note "Added by
  an AI assistant through Rupert MCP (token “Browser assistant (WebMCP)”)".
- **Result scrubbing**: keys, tokens and email addresses are removed from results;
  results over 200 KB are refused with a hint to narrow the request.
- **Untrusted text**: every tool is annotated `untrustedContentHint: true`
  because item names, task notes and similar fields are typed by people and can
  try to steer an assistant.
- The tools are registered only in the top-level app shell, not in the team-chat
  side panel or the customer display, and only for the page's own origin (no
  `exposedTo`).

## Switching it off

Set `RUPERT_WEBMCP=off` in the environment and restart. The shell stops
emitting the config and `/webmcp/*` returns `403`. `/llms.txt` stays available.

## Adding a tool

1. Build or fix it in `Mcp::Registry` first (see [mcp.md](mcp.md)), so the MCP
   server, Ask Rupert and team chat get it too.
2. Add its name to `READ_TOOLS` (read-only) or, for a low-risk write to Rupert's
   own data, `CONFIRM_TOOLS` in `WebMcp::Registry`.
3. Run `bin/rails test test/services/web_mcp test/integration/web_mcp_test.rb`
   and `node --test web/test/javascript/webmcp_test.mjs`.

## Spec status

WebMCP is a Community Group draft, not a W3C Standard, and browser support is
experimental. Rupert follows the 2 November 2026 draft (`document.modelContext`,
`registerTool` with an `AbortSignal`, `ToolAnnotations`) and also accepts the
earlier `navigator.modelContext` shape whose `registerTool` returned an
`unregister()` handle. The declarative `<form toolname>` proposal is not used.
