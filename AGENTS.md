# Shopify app development

This app is scaffolded from a Shopify app template. See the README for framework-specific details.

Use the [Shopify AI Toolkit](https://shopify.dev/docs/apps/build/ai-toolkit) for all Shopify API and platform work. If missing, install it in the agent host per that page (or `npx skills add Shopify/shopify-ai-toolkit --list` for skill-compatible hosts) — do not add tooling to this repo.

## Hard rules (do not violate)

- **The push guard is REMOVED (owner directive, 2026-08-18).** `PlatformPushGuard.authorize!` is a no-op: no outbound write is blocked by approval windows or the maintenance freeze. Freeze/approve/status remain only as read-only operator info. The replacement safeguard is the rule below.
- **ALWAYS ASK before any data-mutating action on Shopify or Square** — creating/updating products, pushing inventory, or writing SKUs. Do not apply without explicit owner sign-off first. Syncs (read-only mirrors into the local DB) are fine to run without asking.
- **Square can still be frozen any time for maintenance via `ops:push_guard:freeze[square,reason]`** — this now records state for awareness but no longer blocks writes; check `ops:push_guard:status`.
- **SKU changes require explicit owner sign-off before writing** to Shopify or Square. You may plan and inspect freely, but never write SKUs without asking.
