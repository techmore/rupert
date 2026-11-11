# Resubmitting 1.1.0 (time, scheduling and pay) to the App Store

One page: everything App Review needs, who does it, and where it lives. **Done** = in this repo, in
the build or set in App Store Connect; **Owner** = a click or a secret only the owner has. Status on
2026-11-11: submitted and waiting for review; the APNs key (item 5) is the one open item.

## Build and ship

| # | Item | Status | Where |
|---|---|---|---|
| 1 | Version 1.1.0, new build number | Done: `CFBundleShortVersionString` 1.1.0; build **202611111754** archived with Xcode 27.2 and uploaded 2026-11-11 (`CURRENT_PROJECT_VERSION`; `ship.sh` stamps the UTC time itself) | `Info.plist`, `RupertApp/project.yml`, `ship.sh` |
| 2 | Time tab first, five tabs, Clock in quick action | Done | `Sources/Rupert/Tabs.swift`, `Info.plist` |
| 3 | Push notifications in the app (soft ask, APNs token to `/native/push_devices`, tap opens the page) | Done | `Sources/Rupert/PushRegistration.swift` |
| 4 | Push Notifications capability on the App ID + `aps-environment` entitlement in the signed build | Done 2026-11-11: Push Notifications enabled on the `com.rupertpos.Rupert` App ID (App Store Connect API); build 202611111754 is signed with `aps-environment` = `production`. The older `omarchy-apple-dev` distribution profile became invalid with the change; `ship.sh` on Linux needs a fresh profile before its next upload | Apple Developer |
| 5 | APNs key on the server | **Owner** (the only push step left; needs an Apple ID sign-in with 2FA, the API cannot create this key): developer.apple.com → Certificates, IDs & Profiles → Keys → **+**, tick Apple Push Notifications service (APNs), download the `.p8` once, set `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8`, `APNS_TOPIC=com.rupertpos.Rupert`, `APNS_ENVIRONMENT=production` in `/etc/rupert.env` on SER8 and restart `rupert-web` and `rupert-jobs`. Until then the app still works: notifications show in the bell only (`PushNotifier.apns_configured?` is false, checked 2026-11-11) | `docs/ops/environment-reference.md` |
| 6 | Web Push keys (installed web app, optional) | Done 2026-11-11: VAPID keys generated on SER8 and set in `/etc/rupert.env` with `VAPID_SUBJECT=mailto:sdolbec@rupertpos.com`; services restarted, `/up` 200, `PushNotifier.web_push_configured?` true | same |
| 7 | Unit tests (Swift) and the Simulator flow | Done: `xcodebuild test -scheme Rupert …` (package, 19 tests) and `RupertApp/UITests` (sign in, Time pages, soft ask, settings); both passed 2026-11-11 on the iOS 27.2 Simulator, the UI test as the demo worker against the live demo workspace | `Tests/`, `RupertApp/UITests/` |
| 8 | Build on a Mac for TestFlight | Done: `cd ios/RupertApp && xcodegen generate`, open `RupertApp.xcodeproj`, Product → Archive (or keep using `ship.sh` on Linux) | `RupertApp/project.yml` |
| 9 | Export compliance | Done: `ITSAppUsesNonExemptEncryption = NO` (HTTPS only), no question per build | `Info.plist` |

## Listing and privacy

| # | Item | Status | Where |
|---|---|---|---|
| 10 | What's new, description, keywords | Done 2026-11-11: What's new, promotional text, description and keywords set on version 1.1.0 | `listing.md` |
| 11 | Screenshots: iPhone 6.9" 1320×2868, iPad 13" 2064×2752 | Done: regenerated 2026-11-06 on the merged clock, schedule, time-off and pay pages (`screenshots/make-screenshots.sh`, signs in as the worker for the Time pages); uploaded to version 1.1.0 on 2026-11-11 (9 iPhone, 5 iPad) | `screenshots/` |
| 12 | App Privacy answers | Unchanged from the published 1.0 label; answers below (push adds nothing: an APNs token is not collected data under Apple's labels). No API exists for this page: the owner should glance at it once | App Store Connect → App Privacy |
| 13 | Privacy manifest | Done: UserDefaults CA92.1 only; push and notifications need no required-reason API | `PrivacyInfo.xcprivacy` |
| 14 | Usage strings | Done: camera, photos, microphone, Face ID unchanged; notifications need none (the system prompt has its own text; the app explains first) | `Info.plist` |
| 15 | Age rating | Done 2026-11-11: "Alcohol, Tobacco, or Drug Use or References: Infrequent" set on the 1.1.0 app info (was None; App Store Connect now shows 12+ on its current scale) | App Information |
| 16 | Review notes and demo logins | Done 2026-11-11: `rupert:app_review_demo` run on SER8 (new workspace `app-review-demo` only), both logins checked against production, notes and logins stored in App Review Information (passwords live only there) | `review-notes.md` |
| 17 | Account deletion in the app (5.1.1(v)) | Done, and now works for staff accounts too; deletes push tokens and the clock PIN | `AccountDeletionsController`, `AccountDeletion` |
| 18 | No purchases, no sign-up in the app (3.1.1) | Done, unchanged | `sessions/new`, `BillingController` |
| 19 | Sign in with Apple (4.8) | Not required: the app only signs in accounts a business already created (Rupert's own email/password system; Google is an alternative sign-in for existing accounts, not account creation). Apple's 4.8 exception for apps that "exclusively use your company's own account setup and sign-in systems" and for enterprise accounts applies. If review disagrees, reply in Resolution Center with this and, only then, add Sign in with Apple (see `docs/time-and-pay/DECISIONS.md`, "App Store") | `sessions/new` |
| 20 | Minimum functionality (4.2) | Done: native features below | `Sources/Rupert` |
| 21 | Support mailbox | Default `sdolbec@rupertpos.com`; `RUPERT_SUPPORT_EMAIL` to change | `/etc/rupert.env` |
| 22 | **Submit for Review** | Done 2026-11-11: 1.1.0 (build 202611111754) submitted, **Waiting for Review**, manual release (nothing goes public until the owner presses Release) | App Store Connect |

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

## Multi-workspace changes (2026-11-10)

These Swift changes are in build **202611111754** (uploaded and submitted 2026-11-11). An Xcode archive needs
`CURRENT_PROJECT_VERSION` in `RupertApp/project.yml` raised for every upload; `ship.sh` stamps its own.

| Item | Status | Where |
|---|---|---|
| Settings → **Switch workspace**: signs out, forgets the push token, clears the web views' Rupert data, returns to the control plane | Done; walk it once on a device with two accounts | `Sources/Rupert/AppSettings.swift`, `SceneController.swift` |
| Push registration sends the web views' session cookie itself; the token is forgotten without a session and when moving to another workspace | Done; confirm one real notification after the APNs key (item 5) is set | `Sources/Rupert/PushRegistration.swift` |
| A notification opens only a path on the current workspace; the workspace handoff accepts only this app's control plane | Done, unit tested | `PushRegistration.swift`, `WorkspaceHandoff.swift`, `Tests/RupertTests` |
| Server: a time feature a workspace turned off shows a plain "turned off" message in the app instead of the page | Done | `docs/audits/2026-11-10-time-multi-tenant-audit.md` |

## After the other time & pay streams merge

- Regenerate `screenshots/` (item 11) and the `docs/time-and-pay/screenshots/ios-*.png` set
  (`RupertApp/UITests` with `TEST_RUNNER_RUPERT_UI_SHOTS`).
- Re-read `review-notes.md` steps against the live demo workspace once (PIN clock on the POS page,
  time off, schedule, pay).
