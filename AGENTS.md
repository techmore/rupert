# Shopify app development

This app is scaffolded from a Shopify app template. See the README for framework-specific details.

Use the [Shopify AI Toolkit](https://shopify.dev/docs/apps/build/ai-toolkit) for all Shopify API and platform work. If missing, install it in the agent host per that page (or `npx skills add Shopify/shopify-ai-toolkit --list` for skill-compatible hosts) — do not add tooling to this repo.

## Hard rules (do not violate)

- **No SKU changes right now.** Do not create, rename, reassign, or push any SKU changes to Shopify or Square. This includes applying the SKU remediation plan (`ops:sku_remediation_plan` is plan-only). You may plan and inspect, but never write SKUs.
- When in doubt about a data-mutating action on Shopify/Square, ask before applying.
