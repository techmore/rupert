# Rupert for iPhone

A native iPhone and iPad app for Rupert, built on [Hotwire Native](https://native.hotwired.dev)
1.3.1. It follows the same path as the website:

1. It opens on the control plane, `pos.rupertpos.com` (`RupertControlPlaneURL`). Signed out, every
   tab shows Rupert's sign-in page. Sign in with email and password, or with Google (the system
   sign-in sheet), or sign up (`/start`, `/signup`, also through the Google sheet).
2. Tenants the control plane serves directly (Herbal Healers today) stay there.
3. A customer with an isolated workspace gets "Open my workspace". The app posts the one-time
   handoff to that instance itself, keeps its session and moves every tab there. The instance is
   remembered across launches.

| Tab | Page |
|---|---|
| Home | `/login`, which sends a signed-in person to their start page |
| Team Chat | `/chat` |
| Ask Rupert | `/ask_rupert` |
| Notifications | `/notifications` |
| Search | `/search` |

Each tab keeps its own back stack. Forms (`…/new`, `…/edit`) open as sheets. Every
`*.rupertpos.com` page stays in the app (including links Rupert marks `data-turbo="false"`);
other sites open in an in-app Safari view. Pages pull to refresh, except chat, Ask Rupert and
POS. The navigation rules come from Rupert at `/native/ios/path-configuration.json`, so they
change with a deploy. The app bundles a copy for its first launch.

This is separate from `mobile/`, the Expo staff timesheet app.

## How Rupert treats the app

- Rupert recognises the app by `Hotwire Native` in the user agent (`hotwire_native_app?`). It adds
  `native-app` to `<body>` and hides the top-bar buttons the tab bar replaces, the status bar and
  the chat dock (`web/app/assets/tailwind/application.css`). The menu, brand and account stay.
- **Email and password** sign-in works in the page as usual. The session cookie lasts 14 days.
- **Google sign-in** cannot run in an embedded web view, so the app opens it in the system
  sign-in sheet (ASWebAuthenticationSession). Rupert hands back a two-minute, single-use
  encrypted code that only works with a secret the app kept (PKCE). The app trades it at
  `POST /native/session` for a normal session cookie. See `web/app/services/native_sign_in.rb`
  and `Sources/Rupert/GoogleSignIn.swift`. Sign-up forms carry their fields to the sheet as an
  encrypted `intent`. Covered by `web/test/integration/native_app_test.rb`.
- **Workspace handoff**: in the app, "Open my workspace" answers `rupert://workspace?origin=…&handoff=…`.
  `Sources/Rupert/WorkspaceHandoff.swift` posts the handoff to `<origin>/instance/session` as the
  browser form would and copies the instance's session cookie into the web views
  (`web/test/integration/native_workspace_handoff_test.rb`).

## Configuration

| Setting | Where | Value |
|---|---|---|
| Bundle ID | `xtool.yml` | `com.rupertpos.Rupert` |
| Control plane | `Info.plist` `RupertControlPlaneURL` | `https://pos.rupertpos.com` |
| Version | `Info.plist` `CFBundleShortVersionString` | `1.0.0` (the build number is stamped at build time) |
| Minimum iOS | `Package.swift` | 17 |

## Build on Linux (no Mac)

Uses [omarchy-apple-dev](https://github.com/joshuaswarren/omarchy-apple-dev) in full mode (the iOS
SDK from an Xcode 27 `.xip`; WebKit is not in its no-Xcode mode). On elementary OS M-Series the
**Apple Dev** app runs all of these with buttons: add the `ios/` folder as a project.

```bash
cd ios
xtool dev build                  # debug build: xtool/Rupert.app
~/omarchy-apple-dev/device-run.sh   # install and launch on the iPhone on USB
```

TestFlight, with an App Store Connect API key (App Manager) and the app record created once in
App Store Connect for `com.rupertpos.Rupert`:

```bash
ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=<uuid> \
  ~/omarchy-apple-dev/ship.sh --upload
```

`ship.sh` compiles the icon, signs with the team's distribution certificate, validates the `.ipa`
offline and uploads it. It never submits for review.

## Build on a Mac

Open `ios/Package.swift` in Xcode 26 or later, or use any Hotwire Native app template and add
these sources. Nothing here is Linux-specific.

## App Store

`AppStore/` holds what the App Store listing needs: `checklist.md` (what review needs beyond
TestFlight, the App Privacy and age rating answers, the 4.2 case), `listing.md` (name, subtitle,
description, keywords, URLs), `review-notes.md` (notes and demo login for App Review) and
`screenshots/` (iPhone 6.9" and iPad 13"). The review login lives in a fictional demo shop made by
`REVIEW_PASSWORD=… bin/rails rupert:app_review_demo`.

Native parts beyond the web pages: camera barcode scanning on inventory counts
(`BarcodeScanner.swift`, VisionKit), an optional Face ID lock (`AppLock.swift`), the App settings
sheet behind the person button on each tab's first page (`AppSettings.swift`, SwiftUI) and Home
Screen quick actions (`Info.plist`, `SceneController.swift`).

Inside the app Rupert offers no sign-up and no subscription purchase (App Store guideline 3.1.1):
`hotwire_native_app?` hides them in `sessions/new` and the account menu, and `BillingController`
refuses them. Account deletion is in the account menu (`/account/delete`).
