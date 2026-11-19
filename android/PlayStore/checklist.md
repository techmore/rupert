# Google Play: what the owner does

Everything here happens in the owner's Google accounts; nothing has been created or uploaded. **Done**
= in this repo or the build; **Owner** = a click in Play Console or a secret only the owner has.

| # | Item | Status | Where |
|---|---|---|---|
| 1 | Google Play developer account (one-time US$25). Choose **Organization** (needs a D-U-N-S number) so the app skips the personal-account rule of a 12-tester, 14-day closed test before production. | Owner | play.google.com/console/signup |
| 2 | Identity and developer verification, contact email `sdolbec@rupertpos.com`, website `https://rupertpos.com` | Owner | Play Console → Account details |
| 3 | Create app: name `Rupert: Shop Back Office`, default language English (US), App, Free | Owner | Play Console → Create app |
| 4 | Upload key (`keytool`, kept outside the repo) and a signed bundle | Owner, steps in `../README.md` → Release signing | `./gradlew bundleRelease` |
| 5 | Play App Signing: accept Google-managed app signing key on the first upload | Owner | Test and release → App integrity |
| 6 | Internal testing release with the bundle; add the owner's own Google account as tester | Owner | Test and release → Internal testing |
| 7 | App Links: put the App signing key SHA-256 in `RUPERT_ANDROID_CERT_SHA256` on the server and deploy | Owner | `../README.md` → App Links |
| 8 | Store listing: texts, icon, feature graphic, phone screenshots | Done (files) · Owner pastes and uploads | `listing.md`, `icon-512.png`, `feature-graphic.png`, `screenshots/` |
| 9 | Privacy policy URL `https://pos.rupertpos.com/privacy` | Done (page) | App content → Privacy policy |
| 10 | App access: sign-in needed, review login | Notes done · Owner runs the demo task and types the password | `review-notes.md` |
| 11 | Ads: **No ads** | Owner clicks | App content → Ads |
| 12 | Content rating questionnaire (IARC) | Owner clicks, answers in `data-safety.md` | App content → Content rating |
| 13 | Target audience: **18 and over** only; not designed for children | Owner clicks | App content → Target audience |
| 14 | Data safety form | Owner clicks, answers in `data-safety.md` | App content → Data safety |
| 15 | Account deletion URL `https://pos.rupertpos.com/account/delete` (web, after signing in) and in-app path | Done | App content → Data safety → Data deletion |
| 16 | Financial features: **My app doesn't provide any financial features** (no payments in the app) | Owner clicks | App content → Financial features |
| 17 | Government app, health, news, COVID: No | Owner clicks | App content |
| 18 | Category **Business**; contact email `sdolbec@rupertpos.com` | Owner clicks | Store settings |
| 19 | Countries: United States (or all) | Owner clicks | Production → Countries |
| 20 | Production release: promote the tested build, **managed publishing on** so nothing goes live until you press Publish | Owner only | Publishing overview |

## Before each upload

- `./gradlew testDebugUnitTest lintDebug` and the CI job are green.
- Install the release build on a phone (`bundletool` or an internal testing link) and sign in with
  email and with Google, open a workspace if you have one, scan a barcode on an inventory count,
  turn the lock on and off.
- Raise `RUPERT_VERSION_CODE`.

## Policies to keep in mind

- **Payments:** the app sells nothing; billing and sign-up are hidden inside the app
  (`hotwire_native_app?`), as on iOS. Keep it that way, or Play Billing rules apply.
- **Webview apps:** Play accepts apps built around a website when they add app functionality. This
  one adds the native scanner, lock, tabs, settings, shortcuts and server picker; the review notes
  list them.
- **Ask Rupert / @rupert** send the person's question and business data to a cloud AI provider that
  processes it for Rupert. A provider acting for you is not "sharing" on the Data safety form, but the
  privacy policy must say it (it does today). Decide before submitting whether that holds for the
  provider you use.
