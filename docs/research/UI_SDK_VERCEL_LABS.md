# UI SDK (Vercel Labs): note for later

Status: **idea, not adopted.** Added 2026-11-12.

- Repo: https://github.com/vercel-labs/ui (docs: https://ui-sdk.dev/docs), Apache-2.0, **beta** (first commits November 2026).
- What it is: a library of UI *behaviors* (keyboard navigation, focus and focus recovery, selection, typeahead, dismissal, popups, drag and drop) plus the ARIA each needs, in `@ui-sdk/core`, with adapters for React, Vue, Svelte, Solid and **Web Components** (`@ui-sdk/web`).
- Agent angle: ships a coding-agent skill (`npx skills add vercel-labs/ui --skill ui-sdk`) so agents assemble accessible components from these behaviors instead of hand-rolling them.

## Why it could matter for Rupert

- The back office (Rails in `web/`) has hand-built menus, comboboxes, dialogs and pickers. The Web Components adapter could give them consistent keyboard and screen-reader behavior without changing frameworks. See [ui-standards.md](../ui-standards.md) and [human-interface-guidelines.md](../human-interface-guidelines.md).

## Before adopting

- Wait for a non-beta release.
- Trial on one screen first (a combobox-heavy form, e.g. a product or customer picker), check bundle size, Turbo/Stimulus interplay and keyboard/VoiceOver behavior, then decide.
