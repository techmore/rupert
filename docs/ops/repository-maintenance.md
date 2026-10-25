# Repository maintenance

The Rails application in `web/` is the active web service. `mobile/` is the
employee client; the original Node implementation was removed in October 2026. The generated
product site in `docs/` is checked against `web/config/product_roadmap.json`.

## Validation

From a clean development or CI checkout:

```sh
python3 bin/build-product-site --check
python3 bin/check-doc-links
node --test web/test/javascript/*_test.mjs
npm ci --prefix mobile
npm run check --prefix mobile
git diff --check
```

The mobile check includes SDK compatibility, TypeScript, employee boundaries,
and the recorded security backports. A registry audit alone still reports
the patched upstream versions; `audit:security` verifies the backports before
accepting those documented exceptions.

Run Rails checks from `web/` in an isolated checkout with a dedicated test
database. No production environment file is needed:

```sh
export RAILS_ENV=test
export SHOPIFY_API_KEY=test-api-key SHOPIFY_API_SECRET=test-secret-key
export HOST=app-host-name.io
bundle install
bundle exec rubocop -c rubocop.yml
bin/rails db:prepare
bin/rails tailwindcss:build
bin/rails assets:precompile
bin/rails test
```

CI repeats the Rails suite on SQLite (`CI (sqlite3)`). Browser tests are
discovered by filename rather than an explicit list. New browser tests use
`web/test/javascript/*_test.mjs`. Native export verification remains in the
Employee mobile workflow; signing and distributing a binary are separate.

## Git and deployment

Production now tracks `main`: start each change from current `origin/main` in
its own worktree and land it through a PR. Once merged and green on the exact
integrated SHA, the SER8 updater installs it (automatically by default, or on
request in click-only mode) and writes a release receipt. The rules are in the
[development and deployment workflow](../development-and-deployment-workflow.md)
and the [release process](release-process.md). Keep other active chats'
uncommitted changes in their own checkouts.

Earlier, the running release was a hand-promoted stack ahead of
`main` (on October 16, `0cd3be6` had 259 commits beyond `main`). That history
is why older deployment receipts mention `/var/lock/rupert-deploy.lock` and
promoting a reviewed revision by hand; it no longer describes how changes ship.

## Branding

The approved face remains 40px in headers and 96px on the login card.
`shared/rupert_face` selects responsive 80px/192px PNGs with the 512px
master as a fallback. The small files reduce normal header downloads from
273,008 bytes to 12,443 bytes without changing the display size.
Keep explicit dimensions, empty decorative alt text beside the brand name,
and accessible labels on the surrounding links.

Generated assets, local databases, `.env` files, logs, dependency directories,
and private source exports stay ignored. Keep tracked `.keep` placeholders
and operational history. `git fsck` may report unreachable objects retained
from prior work; that does not indicate corruption or justify pruning them.
