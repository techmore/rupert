# Marketing site and sign-in UX pass (2026-11-02)

A UI/UX review of the signed-out pages on rupertpos.com: the landing page (`docs/index.html`, generated into
`web/app/views/landing/index.html.erb` by `bin/build-product-site`), sign-in (`/login`) and the free sign-up form
(`/start`). Reviewed locally at 1440 and 375 px wide, in light and dark. Before/after images are in
[site-ux-pass-2026-11-02](site-ux-pass-2026-11-02/).

This pass builds on two open pull requests and does not repeat their work:

- techmore/rupert#616 (website partner readiness) adds Open Graph and Twitter metadata, the terms, refunds, security
  and integrations pages, the footer company line and policy links, the pricing terms line and the card-data FAQ.
- techmore/rupert#619 (WebMCP and llms.txt) adds `/llms.txt` and read-only tools for AI assistants.

Each merges cleanly with this branch. #616 and #619 conflict with each other in the generated landing view and
`web/config/routes.rb`; after merging both, re-run `python3 bin/build-product-site` and merge the routes by hand.

## Method

- Full-page screenshots with the installed Google Chrome, driven by Playwright.
- axe-core 4.10.3, WCAG 2.0/2.1/2.2 A and AA rules plus best practices, on `/`, `/login`, `/start` and `/signup`, at
  both widths and in both themes: 0 violations before and after.
- A separate check for targets under 24 × 24 px (WCAG 2.2, 2.5.8).
- Page weight and Largest Contentful Paint from Chrome's performance entries. Lighthouse is not installed on the review
  machine and was not downloaded.

## Fixed in this pass

| # | Finding | Change |
| --- | --- | --- |
| 1 | The first screen said what Rupert does but not who it is for. | Hero eyebrow: "Point of sale and back office for shops". |
| 2 | No way to reach a person or ask for a demo anywhere on the landing page. | Closing section adds "Ask for a demo" (an email to sdolbec@rupertpos.com, subject "Rupert demo request", the same link #619 gives AI assistants) and shows the address. A last FAQ answers "Can I see Rupert before I sign up?". |
| 3 | The only filled button in pricing was "Use a referral code", which most visitors cannot use. The free plan is the main call to action everywhere else. | The free plan carries the emphasis and the filled button ("No card needed" badge). The referral plan keeps its badge with a quiet button. Plan headings line up side by side. |
| 4 | On phones, "Sign in" and "Start free" wrapped onto two lines each. With #616's `nowrap` rule, Start free would run past the gutter at 360 px and off-screen at 320 px. | Tighter header spacing below 560 px; everything fits on one line down to 320 px. Pricing hides only below 351 px. |
| 5 | The footer rule ran into the side gutters, wider than every other line on the page. | The rule spans the content column. |
| 6 | The search description was 280 characters, mostly referral fine print; results cut it off near 155. | 148 characters: what Rupert is, for whom, and "Free to start". |
| 7 | The favicon and the header mark used two URLs for the same 12 KB logo. | One URL (`?v=1`), so they can share a cached copy. |
| 8 | `/start` came back empty after a rejected submit (for example a taken or reserved address), so people retyped both fields. | The form keeps what was typed. |
| 9 | The workspace address rules (2–63 lowercase letters, numbers or hyphens) appeared only in the error banner after a failed submit. | A hint under the field, tied to it with `aria-describedby`, a placeholder example and `title` text for the browser's pattern message. |
| 10 | A malformed post to `/start` (`registration` sent as a string) raised a 500. | `params.expect` returns 400. |
| 11 | `/start` had no privacy or support links and no meta description. | Both added, matching sign-in. |
| 12 | On rupertpos.com, sign-in had no link back to the home page; the top bar hides the brand there. | "Rupert home" leads the links under the card, on the main site only. Sign-in also gets a meta description. |

Tests cover 2, 8, 9, 10 and 12.

## Left for the owner or other work

| # | Finding | Why it is left | Suggested next step |
| --- | --- | --- | --- |
| A | Pricing does not say what the $499 plan adds over the free account. The code gates nothing on paid status. | A business decision, not a wording fix. | Decide what paid includes (support, limits, number of stores, onboarding), then list it on each plan card. |
| B | The landing stylesheet's cache-busting stamp (`landing.css?v=`) is on a line #616 also changes (v=3 to v=4). This branch changes the stylesheet but leaves the stamp alone to avoid a conflict. | Avoids a merge conflict. | Whichever of #616 and this PR merges second bumps it (to `?v=5`) in `docs/index.html`, then regenerates. |
| C | `/marketing` files (landing CSS, logo, screenshots) are served with no `Cache-Control` header; only fingerprinted `/assets` files get long caching. | Server behaviour; out of scope for a page pass. | Send `public, max-age=31536000, immutable` for `/marketing` files requested with a `?v=` stamp. |
| D | Phones download the 1600 px screenshots. The page is light (about 220 KB for the first phone screen, 417 KB fully scrolled; LCP well under 2.5 s locally), but a 1000 px set would save about 40% on 1× and 2× screens. | Modest gain for 10 more images in the repo. | Add a 1000 px WebP set with `srcset` and `sizes` if mobile traffic grows. |
| E | `robots.txt` is empty and there is no sitemap. Only the root of rupertpos.com is indexable; every other path redirects to `pos.rupertpos.com`. | Depends on where the policy pages settle (#616). | Once the canonical host for policy pages is settled, add a sitemap listing them and a `Sitemap:` line. |
| F | `input type=submit` buttons render at weight 500 next to weight-600 link buttons (for example "Continue with Google" beside "Already a customer? Sign in" on `/start`). | App-wide button style, shared with the signed-in app. | Fix in the app UX pass so every form changes together. |
| G | Footer links are 22 px tall. | Passes WCAG 2.5.8 through its spacing exception (20 px gaps). | Optional: 4 px vertical padding makes them 26 px tall. |
| H | Lighthouse was not run. | Not installed; downloads were avoided on a shared disk. | Run it against production after deploy. |

## Checked and fine

- Contrast meets AA for all text in both themes (axe). The landing colors are copied from the app palette, which CI
  checks with `bin/check-palette-contrast`; `landing.css` itself is not checked in CI.
- Headings are in order, every image has alt text or is marked decorative, the skip link works, focus outlines are
  visible, and the FAQ uses native `details`/`summary`.
- No horizontal scrolling at 320, 360, 375 or 1440 px.
- Typography follows a consistent scale (display serif for headings, system sans for text). Section spacing is 96 px on
  desktop and 64 px on phones. No changes were needed.
- The hero image is the LCP element and loads eagerly with `fetchpriority="high"`. Images below the fold are lazy.
