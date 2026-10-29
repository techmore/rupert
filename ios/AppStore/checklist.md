# From TestFlight to the App Store

What App Store review needs that TestFlight (internal testers) did not. **Done** = in this repo or in
the build; **Owner** = a click in App Store Connect or a secret only the owner has.

| # | Item | Status | Where |
|---|---|---|---|
| 1 | Name, subtitle, description, keywords, promotional text | Done (text) · Owner pastes | `listing.md` |
| 2 | Category Business / Productivity | Owner picks | `listing.md` |
| 3 | Support URL https://rupertpos.com/support | Done (page) | `web/app/views/public_pages/support.html.erb` |
| 4 | Marketing URL https://rupertpos.com | Already live | landing page |
| 5 | Privacy policy URL https://rupertpos.com/privacy | Done (page) | `web/app/views/public_pages/privacy.html.erb` |
| 6 | App Privacy answers ("nutrition label") | Owner clicks, answers below | App Store Connect → App Privacy |
| 7 | Screenshots: iPhone 6.9" 1320×2868, iPad 13" 2064×2752 | Done | `screenshots/` |
| 8 | Age rating questionnaire → 4+ | Owner clicks, answers below | App Information → Age Rating |
| 9 | Export compliance | Done: `ITSAppUsesNonExemptEncryption = NO` in Info.plist (HTTPS only), so no question per build | `Info.plist` |
| 10 | Price: Free · Availability: all countries (or United States only) | Owner clicks | Pricing and Availability |
| 11 | Review notes and demo login | Notes done · demo shop task done · Owner runs it and types the password | `review-notes.md`, `rupert:app_review_demo` |
| 12 | Account deletion in the app (5.1.1(v)) | Done: account menu → Delete my account; App settings → Delete account | `AccountDeletionsController` |
| 13 | No purchases in the app (3.1.1) | Done: billing hidden and refused in the app; sign-up hidden in the app | `_shell.html.erb`, `BillingController`, `sessions/new` |
| 14 | Sign in with Apple (4.8) | Not needed: the app has no sign-up; it signs in accounts a business already made | `sessions/new` |
| 15 | Minimum functionality, web wrapper risk (4.2) | Done: native features below | `ios/Sources/Rupert` |
| 16 | Privacy manifest: required-reason APIs | Done: UserDefaults CA92.1 added | `PrivacyInfo.xcprivacy` |
| 17 | Usage strings for camera, photos, microphone, Face ID | Done | `Info.plist` |
| 18 | Version 1.0.0, new build number | Done: build number is the UTC time at build | `ship.sh` |
| 19 | Support mailbox | Owner: make support@rupertpos.com reach you, or set `RUPERT_SUPPORT_EMAIL` | `/etc/rupert.env` |
| 20 | Submit for review | Owner only | App Store Connect |

## App Privacy answers

Apple counts what Rupert's server collects through the app, not only the app's own code.

**Do you or your third-party partners collect data from this app?** Yes.

| Data type | Collected | Linked to the user | Used for tracking | Purpose |
|---|---|---|---|---|
| Contact Info → Name | Yes | Yes | No | App Functionality |
| Contact Info → Email Address | Yes | Yes | No | App Functionality |
| User Content → Photos or Videos | Yes (attachments) | Yes | No | App Functionality |
| User Content → Customer Support | Yes (Report a problem) | Yes | No | App Functionality |
| User Content → Other User Content (chat, Ask Rupert, business records) | Yes | Yes | No | App Functionality |
| Identifiers → User ID | Yes | Yes | No | App Functionality |
| Diagnostics → Other Diagnostic Data (page details sent with Report a problem) | Yes | Yes | No | App Functionality |

Everything else: **not collected** (location, contacts, health, financial info of the user, browsing
history, search history, purchases, sensitive info, audio data, advertising data, crash data,
performance data). Tracking: **No**. Payments happen on the website, through Stripe, not in the app.

## Age rating answers

Every content question (violence, sexual content, profanity, horror, drugs, alcohol, gambling,
contests, medical): **None**. Unrestricted web access: **No** (the app only opens Rupert's own
sites; other links open in a Safari view). User-generated content: Team chat is private to a
business's own staff, not public: answer **No** for "user-generated content shared publicly".
Messaging and chat: **Yes** if asked (private team chat). Result: **4+**.

## Guideline 4.2: why this is more than a website

Web wrappers get rejected when they add nothing a browser does not. Rupert's app adds:

1. **Camera barcode scanning** for inventory counts (VisionKit `DataScannerViewController`), with a
   haptic on each read. Not possible in mobile Safari with the same reliability.
2. **Face ID / Touch ID / passcode lock** (LocalAuthentication), with a cover in the app switcher.
3. **Native App settings screen** (SwiftUI): lock, workspace, help, privacy, account deletion, version.
4. **Home Screen quick actions** to Team chat, Ask Rupert, Notifications and Search.
5. **Native tab bar** with its own back stack per tab, native modal sheets for forms, pull to refresh.
6. **System Google sign-in sheet** (ASWebAuthenticationSession) with a PKCE code handoff.
7. **Native top bar** that follows the page's colours in all five appearances.

If review still answers 4.2, the next step is **push notifications** for Rupert's notifications
(needs an APNs key from the owner and a server sender). Reply in Resolution Center with the list
above first.
