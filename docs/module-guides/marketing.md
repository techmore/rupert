# Marketing and influencers

Last checked against `main` at `96a8a660` on `2026-10-25`.

## Purpose and owner

Plan and review store promotion: community (group) campaigns with reviewed
replies that use existing discount codes, and an influencer CMS for prospects,
collaborations, product gifts, temporary codes and documents. Product
decisions: store owner. Writing and reviewing are separate permissions.

`ModuleRegistry` keys `marketing` ("Marketing"), `marketing_events`
("Events") and `influencers` ("Influencers"), section **Marketing**. Events
also appear on the shared **Work → Calendar** (`calendar`). Operator guides:
[Community thread and reply review](../ops/community-marketing.md),
[Influencer CMS](../ops/influencer-cms.md) and
[Shopify influencer discounts](../ops/shopify-influencer-discounts.md).

## Data model

All under `web/app/modules/marketing/`, all `TenantScoped` through
`Marketing::Record`:

- `Campaign` (name, topics, HTTPS storefront URL), `Community` (a group, its
  rules and rule confirmation), `Thread` (a saved discussion URL and triage
  status), `Reply` (one per thread) and `ReviewEvent` (reply review history).
- `Offer`: a discount code with full terms, start/end, destination URL and
  verification. It belongs to exactly one community **or** one influencer
  engagement. Codes are unique per workspace and merchant host.
- `Influencer`, `Engagement` (a collaboration), `Interaction` (encrypted
  conversation notes), `ProductGift` and `ProductGiftItem`, `Document` and
  `DocumentRevision`, `ShopifyDiscount` (a code created in Shopify by Rupert).
- `CmsEvent`: encrypted, read-only change history for influencer, engagement,
  gift, document, offer and Shopify discount records.

Events and campaign work live in the shared work-item table
([design](../architecture/shared-work-items.md), #407 phase 3), read through
`Work::Item` (kinds defined in `Marketing::WorkKinds`):

- **Marketing event** (kind `marketing_event`): name, local start and end
  (`starts_at`/`ends_at`, wall time) in its own `time_zone`, a venue and/or a
  channel (`in_store`, `market`, `online`, `social`, `email`, `community`,
  `influencer`, `other`), optional store location (`location_id`, a
  `Location` external id), discount code (`offer_id`), link, campaign
  (`source`) and owner (`assignee_id`). `start_on`/`due_on` hold the event's
  local dates for the calendar. Ends must follow the start, within 92 days.
- **Campaign task** (kind `campaign_task`): work for an event (`parent`) and
  its campaign (`source`), with owner and due date.
- `Result` (`marketing_results`): observed redemptions and results of an
  event, one row per event, code, order source, store location and currency.
  `basis` is `stored_orders` (counted by Rupert) or `manual` (entered by
  hand); one event never mixes the two for one code. Counted rows keep the
  order ids they counted.

## Permissions and tenant boundary

- The whole module is behind the per-workspace feature flag
  `FeatureFlag :marketing` (setting `marketing_enabled`). When it is off,
  marketing pages return 404 except the `/marketing` landing page.
- Turning it on or off: an account manager with `settings.write`
  (`POST /marketing/toggle`).
- `marketing.read` to view, `marketing.write` to edit, `marketing.review` to
  approve, `marketing.contacts` for encrypted contact details, conversations
  and restricted documents, `marketing.discounts` to draft and create Shopify
  codes. Administrators get all five by default.
- Events and campaign tasks use `Marketing::WorkItemPolicy`: `marketing.read`
  to see, `marketing.write` to add, edit, change status, add work and record
  results, only while Marketing is on. Cancelling and reopening an event, and
  cancelling or reopening a campaign task, need `marketing.write` (the
  kind's manager step); starting and finishing a campaign task is open to its
  owner. Staff (employee) accounts have no access.
- `Marketing::CmsWriter.authorize!` re-checks the user is active, the tenant
  is active, the flag is on and the user belongs to the tenant before each
  CMS write. Parent records must belong to the same tenant (`same_tenant`).

## Routes and API

- `GET /marketing` (workspace), `POST /marketing/toggle`.
- `/marketing/events` (list, add, open, edit; `transition`), nested
  `work` (add a campaign task; `transition`) and `results` (`count` from
  stored orders, add by hand, remove).
- `/calendar`: the shared calendar (Work section).
- `/marketing/campaigns`, `communities` (`check_rules`), `offers` (`verify`),
  `threads` (`check_context`), `replies` (`transition`).
- `/marketing/influencers` (with `engagements`, `interactions`),
  `engagements` (`copy`, nested `shopify_discounts` with `activate` and
  `refresh`, `offers`, `product_gifts`, `documents`), `product_gifts`
  (`item`, `transition`), `documents` (`review`).
- No `/api/v1` endpoint. MCP tools `marketing_summary` and
  `marketing_records` need `marketing:read` and the owner's
  `marketing.read`. See [MCP](../mcp.md) and
  [API standards](../api-standards.md).

## Workflow and status transitions

- Reply (`Marketing::ReplyWorkflow`): `draft` → `pending_review` →
  `approved` → `published`; a reviewer can reject or request changes; a
  published reply can be `removed`. Approval checks fresh rules, context and
  offer verification; publishing is done by a person outside Rupert and then
  recorded.
- Influencer stage: `prospect shortlisted contacted interested active
  completed declined do_not_contact`. Changing a stage sends nothing.
- Engagement: `draft active completed cancelled`.
- Marketing event (`Work::Item#transition!`): `planned` → `confirmed` →
  `held`; `planned`/`confirmed` → `cancelled`; `held`/`cancelled` →
  `planned` (reopen). Campaign task: `todo` → `in_progress` → `done`, or
  `cancelled`; reopen returns to `todo`. Each change writes a
  `work_item_events` row and an Activity log entry
  (`marketing_event_transitioned`, `campaign_task_transitioned`).
- Product gift: `proposed approved ready_to_ship shipped delivered
  cancelled returned`.
- Shopify discount (`Marketing::ShopifyDiscountWorkflow`): `draft` →
  `creating` → `created`, or `failed`, `uncertain`, `blocked`.
- Edits use `lock_version`; a stale form is rejected with "This record
  changed. Reload before continuing."

## UI patterns

- `/marketing`: **Overview**-style workspace with a `More` menu, campaign and
  group lists, the review queue and a paginated thread list (30 per page).
- `/marketing/influencers`: **List** template; records open as **Detail**
  pages, edits as **Form** pages.
- `/marketing/events`: **List** (upcoming or past, status, campaign); an event
  is a **Detail** page (facts, status steps, Work for this event, Redemptions
  and results, History); add/edit is a **Form**.
- Not yet reviewed against the
  [HIG](../human-interface-guidelines.md).

## Integration and sync

- Community and existing-code workflows make no outside calls. Topic search
  opens a Bing query in a new tab; Rupert fetches no supplied URLs.
- Product gifts search the mirrored Shopify catalog; they do not reserve
  stock or create orders.
- **The one outside write:** `ShopifyDiscountWorkflow.activate` creates a
  discount code in Shopify. It needs `marketing.write`,
  `marketing.discounts` and `marketing.review`, an explicit confirmation of
  store, code and terms, an active engagement and an unexpired offer. Per
  `AGENTS.md`, the owner must sign off before any such Shopify write.
- No Square writes. No click counting.
- **Redemptions are read from stored orders only** (`Marketing::RedemptionCount`):
  orders already synced into Rupert's `orders` table whose `discount_codes`
  include the code (case-insensitive), inside the window (the event's local
  start and end unless changed), not cancelled or refunded, at the event's
  store location when it has one, and not already counted by another event.
  Rows are split by order source and currency; revenue is the order total
  before tax and tips. It never calls Shopify or Square and never changes an
  order.

## Audit history

- `CmsEvent` rows (encrypted payload, cannot be updated or deleted) record CMS
  saves, verifications, gift transitions and Shopify creation attempts with
  the actor.
- `ReviewEvent` rows keep reply revisions, decisions and publication evidence;
  the reply page lists the latest 50.
- Turning the module on or off writes `marketing.toggle` to the Activity log.
- Events and campaign tasks write append-only `work_item_events` rows (shown
  on the event page) and Activity log entries (`marketing_event_created`,
  `_updated`, `_transitioned`, `_results_counted`, `_result_saved`,
  `_result_removed`, `campaign_task_created`).

## Failure and recovery

- Validation, uniqueness and stale-record errors redirect to `/marketing`
  with a plain sentence.
- Shopify creation commits the `creating` state before the network call. It
  looks the code up first, so a retry does not create a second code. A
  network error leaves `uncertain`; **Check result** (`refresh`) reads
  Shopify again instead of re-creating. A record that already had an attempt
  cannot be activated again.
- Turning the flag off hides the module without deleting records.

## Required tests

- `web/test/integration/marketing_review_test.rb`
- `web/test/integration/influencer_cms_flow_test.rb`
- `web/test/integration/shopify_discount_flow_test.rb`
- `web/test/services/marketing_reply_workflow_test.rb`,
  `influencer_cms_test.rb`, `shopify_discount_workflow_test.rb`,
  `shopify_discount_api_test.rb`
- `web/test/services/mcp/marketing_tools_test.rb`
- `web/test/models/work/marketing_kinds_test.rb`,
  `web/test/services/marketing/redemption_count_test.rb`,
  `web/test/integration/marketing_events_flow_test.rb`,
  `web/test/integration/work_calendar_test.rb`

## Open gaps

- [#415](https://github.com/techmore/rupert/issues/415): events, campaign
  work and results are built; acceptance evidence (revision, environment,
  result) in the production workspace is not recorded. MCP tools do not list
  events or results yet.
- Shopify/Square writes behind explicit owner sign-off:
  [#416](https://github.com/techmore/rupert/issues/416). The Shopify discount
  write exists; its acceptance evidence is open.
- [#417](https://github.com/techmore/rupert/issues/417): the shared calendar
  is built (`/calendar`); acceptance evidence is not recorded.
