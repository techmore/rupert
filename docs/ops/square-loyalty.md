# Square Loyalty mirror

Rupert keeps a read-only local copy of the store's Square Loyalty program: the program (earning rules, point expiry, wording), its reward tiers, promotions, every member account (balance, lifetime points, expiring points) and the full points ledger (earned, promotion bonus, reward claimed/redeemed/cancelled, adjusted, expired, with order IDs). Nothing is ever written to Square: no point adjustments, no rewards, no promotion changes.

## Endpoints and permission

Only these Square calls are made (Square API reference 2026-09-16), all needing the `LOYALTY_READ` OAuth permission:

- `POST /oauth2/token/status` — checks the saved token's scopes before any loyalty read.
- `GET /v2/loyalty/programs/main` — the program and reward tiers (404 means the seller has no program).
- `GET /v2/loyalty/programs/{id}/promotions` — promotions (30 per page).
- `POST /v2/loyalty/accounts/search` with no query — every member (200 per page).
- `POST /v2/loyalty/events/search` — the ledger, newest first (30 per page), filtered by `created_at` after the first run.

If the token reports scopes without `LOYALTY_READ`, or Square answers 403/`INSUFFICIENT_SCOPES`, the sync stops before reading and says so. To fix it, the owner re-authorizes the Rupert app in the Square Developer Dashboard with `LOYALTY_READ` added (or uses a personal access token from that app), saves the new token under Square in Connections, then syncs again. Personal access tokens may report no scope list; the loyalty endpoints then decide.

## Running it

- Preview without storing anything (reads program, promotions, members and the newest ledger page):
  `TENANT_ID=... ACTOR_ID=... bundle exec rails square:loyalty`
- Store the local copy: add `APPLY=1`.
- Hourly refresh is off until someone allowed to sync customers opts the workspace in:
  `TENANT_ID=... ACTOR_ID=... ENABLED=1 bundle exec rails square:loyalty_schedule` (`ENABLED=0` turns it off).
- **Sell → Loyalty → More → Sync now** queues one read for the signed-in person (needs `customers.write` and `sync.write`).

The actor must be active in the workspace with `customers.write` and `sync.write`. Runs are recorded as `square / loyalty` sync attempts and appear on the Square connection's health.

## Safe to re-run

- Program, tiers, promotions and members are read completely, then published in one transaction. Any error, repeated ID, repeated cursor, changed token or a different Square merchant than the stored copy publishes nothing and keeps the previous data.
- Members missing from a complete read are kept and marked "No longer a member"; tiers no longer in the program are hidden, not deleted.
- Ledger events are stored by Square event ID, page by page, so a re-read never duplicates. Each run reads from the last complete read less one day of overlap. If a run runs out of time (a long first history), the unread older part is recorded and continued on the next run; the page shows "Still reading" until it finishes.

## Where it shows

- **Sell → Loyalty** (`/loyalty`): members, points outstanding, last-30-day earning and redemptions, the program (earning, expiry, rewards, promotions, Square as the source pill) and the member list with search, filters (can claim a reward, not matched to a customer, no longer members) and sortable columns.
- **Customer page → Loyalty**: points, lifetime points, rewards available and the next reward, expiring points and the latest ten ledger entries with links to matching Square orders.

A member is linked to a Rupert customer only through the Square customer ID on the loyalty account (the Square customer directory sync creates those customers). Phone numbers are stored encrypted and shown as the last four digits only; names and phones are never used to guess identity.
