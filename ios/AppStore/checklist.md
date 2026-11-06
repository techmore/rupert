# Resubmitting 1.1.0 (time, scheduling and pay) to the App Store

One page: everything App Review needs, who does it, and where it lives. **Done** = in this repo or in
the build; **Owner** = a click in App Store Connect or a secret only the owner has. The last line is
the one click nobody but the owner makes.

## Build and ship

| # | Item | Status | Where |
|---|---|---|---|
| 1 | Version 1.1.0, new build number | Done: `CFBundleShortVersionString` 1.1.0; build number is the UTC time at build | `Info.plist`, `ship.sh` |
| 2 | Time tab first, five tabs, Clock in quick action | Done | `Sources/Rupert/Tabs.swift`, `Info.plist` |
| 3 | Push notifications in the app (soft ask, APNs token to `/native/push_devices`, tap opens the page) | Done | `Sources/Rupert/PushRegistration.swift` |
| 4 | Push Notifications capability on the App ID + `aps-environment` entitlement in the signed build | **Owner**: tick Push Notifications on the `com.rupertpos.Rupert` App ID (Certificates, Identifiers & Profiles) and regenerate the distribution profile; `ship.sh`/Xcode then signs with `RupertApp/RupertApp.entitlements` (production in archives) | Apple Developer |
| 5 | APNs key on the server | **Owner**: create a Key (Apple Push Notifications service) in App Store Connect → Users and Access → Keys, download the `.p8` once, set `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8`, `APNS_TOPIC=com.rupertpos.Rupert`, `APNS_ENVIRONMENT=production` in `/etc/rupert.env` on SER8 and restart `rupert-web` and `rupert-jobs`. Until then the app still works: notifications show in the bell only | `docs/ops/environment-reference.md` |
| 6 | Web Push keys (installed web app, optional) | **Owner**: `bin/rails runner 'k = WebPush.generate_key; puts k.public_key, k.private_key'`, set `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT=mailto:sdolbec@rupertpos.com` | same |
| 7 | Unit tests (Swift) and the Simulator flow | Done: `xcodebuild test -scheme Rupert …` (package) and `RupertApp/UITests` (sign in, Time pages, soft ask, settings) | `Tests/`, `RupertApp/UITests/` |
| 8 | Build on a Mac for TestFlight | Done: `cd ios/RupertApp && xcodegen generate`, open `RupertApp.xcodeproj`, Product → Archive (or keep using `ship.sh` on Linux) | `RupertApp/project.yml` |
| 9 | Export compliance | Done: `ITSAppUsesNonExemptEncryption = NO` (HTTPS only), no question per build | `Info.plist` |

## Listing and privacy

| # | Item | Status | Where |
|---|---|---|---|
| 10 | What's new, description, keywords | Done (text) · Owner pastes | `listing.md` |
| 11 | Screenshots: iPhone 6.9" 1320×2868, iPad 13" 2064×2752 | Done for this build; **regenerate after the clock, schedule, tips and manager pages merge** (`screenshots/make-screenshots.sh`, now signs in as the worker for the Time pages) | `screenshots/` |
| 12 | App Privacy answers | Owner clicks; answers below (unchanged by push: an APNs token is not collected data under Apple's labels) | App Store Connect → App Privacy |
| 13 | Privacy manifest | Done: UserDefaults CA92.1 only; push and notifications need no required-reason API | `PrivacyInfo.xcprivacy` |
| 14 | Usage strings | Done: camera, photos, microphone, Face ID unchanged; notifications need none (the system prompt has its own text; the app explains first) | `Info.plist` |
| 15 | Age rating | Owner clicks: unchanged, 13+ | App Information |
| 16 | Review notes and demo logins | Done · Owner runs `rupert:app_review_demo` on SER8 and types the two passwords | `review-notes.md` |
| 17 | Account deletion in the app (5.1.1(v)) | Done, and now works for staff accounts too; deletes push tokens and the clock PIN | `AccountDeletionsController`, `AccountDeletion` |
| 18 | No purchases, no sign-up in the app (3.1.1) | Done, unchanged | `sessions/new`, `BillingController` |
| 19 | Sign in with Apple (4.8) | Not required: the app only signs in accounts a business already created (Rupert's own email/password system; Google is an alternative sign-in for existing accounts, not account creation). Apple's 4.8 exception for apps that "exclusively use your company's own account setup and sign-in systems" and for enterprise accounts applies. If review disagrees, reply in Resolution Center with this and, only then, add Sign in with Apple (see `docs/time-and-pay/DECISIONS.md`, "App Store") | `sessions/new` |
| 20 | Minimum functionality (4.2) | Done: native features below | `Sources/Rupert` |
| 21 | Support mailbox | Default `sdolbec@rupertpos.com`; `RUPERT_SUPPORT_EMAIL` to change | `/etc/rupert.env` |
| 22 | **Submit for Review** | **Owner only** | App Store Connect |

## App Privacy answers

Apple counts what Rupert's server collects through the app, not only the app's own code.

**Do you or your third-party partners collect data from this app?** Yes.

| Data type | Collected | Linked to the user | Used for tracking | Purpose |
|---|---|---|---|---|
| Contact Info → Name | Yes | Yes | No | App Functionality |
| Contact Info → Email Address | Yes | Yes | No | App Functionality |
| User Content → Photos or Videos | Yes (attachments) | Yes | No | App Functionality |
| User Content → Customer Support | Yes (Report a problem) | Yes | No | App Functionality |
| User Content → Other User Content (chat, Ask Rupert, business records, hours and time-off requests) | Yes | Yes | No | App Functionality |
| Identifiers → User ID | Yes | Yes | No | App Functionality |
| Diagnostics → Other Diagnostic Data (page details sent with Report a problem) | Yes | Yes | No | App Functionality |

Everything else: **not collected**: no precise or coarse location (the clock uses a PIN and a
registered store device, never GPS), no contacts, health, financial info of the user, browsing or
search history, purchases, sensitive info, audio data, advertising data, crash data, performance
data. Tracking: **No**. Payments happen on the website, through Stripe, not in the app. The APNs
device token is a delivery address held by Apple's push service and Rupert's server; Apple's
privacy label guidance does not treat it as a collected data type.

## Age rating answers

Merchants' catalogs in the app can list vapes and hemp/THC products, so **Alcohol, Tobacco, or Drug
Use or References: Infrequent** (13+). Every other content question: **None**. Unrestricted web
access: **No**. User-generated content shared publicly: **No** (Team chat is private to a business's
own staff). Messaging and chat: **Yes**. Result: **13+**.

## Guideline 4.2: why this is more than a website

1. **Push notifications** for schedule posted or changed, requests decided, shift offers, forgotten
   clock-outs and break reminders (UNUserNotificationCenter, APNs), with a tap opening the page.
2. **Camera barcode scanning** for inventory counts (VisionKit `DataScannerViewController`).
3. **Face ID / Touch ID / passcode lock** (LocalAuthentication), with a cover in the app switcher.
4. **Native App settings screen** (SwiftUI): lock, workspace, help, privacy, account deletion, version.
5. **Home Screen quick actions**: Clock in, Team chat, Ask Rupert, Notifications.
6. **Native tab bar** with its own back stack per tab, native sheets for forms, pull to refresh.
7. **System Google sign-in sheet** (ASWebAuthenticationSession) with a PKCE code handoff.
8. **Native top bar** that follows the page's colours in all five appearances.

## After the other time & pay streams merge

- Regenerate `screenshots/` (item 11) and the `docs/time-and-pay/screenshots/ios-*.png` set
  (`RupertApp/UITests` with `TEST_RUNNER_RUPERT_UI_SHOTS`).
- Re-read `review-notes.md` steps against the live demo workspace once (PIN clock on the POS page,
  time off, schedule, pay).
