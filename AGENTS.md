# Shopify app development

This app is scaffolded from a Shopify app template. See the README for framework-specific details.

Use the [Shopify AI Toolkit](https://shopify.dev/docs/apps/build/ai-toolkit) for all Shopify API and platform work. If missing, install it in the agent host per that page (or `npx skills add Shopify/shopify-ai-toolkit --list` for skill-compatible hosts) — do not add tooling to this repo.

## Hard rules (do not violate)

- **Push-guard approval windows are DISABLED (owner directive, 2026-08-14).** `PlatformPushGuard.authorize!` no longer requires a multi-approval window — only the maintenance freeze still blocks a platform. Re-enable window gating only with explicit owner sign-off.
- **Square was unfrozen on 2026-08-14 (owner directive) so the maintenance loop can write to both platforms.** The 15-minute sync (`SyncEngine.run!`) now runs `InventoryMaintainer` after each mirror: linked SKUs get Square's count pushed to Shopify (delta-only), and size-family members get derived targets pushed to both platforms. Square may be re-frozen any time via `ops:push_guard:freeze[square,reason]`; check `ops:push_guard:status`.
- **No SKU changes right now.** Do not create, rename, reassign, or push any SKU changes to Shopify or Square. This includes applying the SKU remediation plan (`ops:sku_remediation_plan` is plan-only). You may plan and inspect, but never write SKUs.
- When in doubt about a data-mutating action on Shopify/Square, ask before applying.
