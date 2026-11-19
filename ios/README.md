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
| Time | `/employee`: the clock, today's shift, schedule, time off and pay |
| Home | `/login`, which sends a signed-in person to their start page |
| Team Chat | `/chat` |
| Ask Rupert | `/ask_rupert` |
| Notifications | `/notifications` |

Search stays in every page's top bar (five tabs is iOS's limit before a "More" tab).

**More than one workspace, or more than one person, on a phone.** The person button → **Switch workspace**
signs out, tells Rupert to stop sending this phone's notifications, clears the web views' Rupert cookies and
cached pages, and returns to the control plane's sign-in page. A push token belongs to one account at a time:
registering it for another account (in any workspace) stops the previous registration on the server. A
notification only ever opens a path on the workspace the app is pointed at.

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
| Version | `Info.plist` `CFBundleShortVersionString` | `1.1.0` (the build number is stamped at build time by `ship.sh`; an Xcode archive uses `CURRENT_PROJECT_VERSION` in `RupertApp/project.yml`, which must go up for every upload) |
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

## Tests

`Tests/RupertTests` covers the session watcher, the bottom inset, Rupert's own sites, the Time tab,
notification deep links and the Info.plist privacy keys. On a Mac:
`xcodebuild test -scheme Rupert -destination 'platform=iOS Simulator,name=iPhone 18 Pro'`.
App Review readiness and partner notes: `docs/ios/app-review-readiness.md`.

## Build and run on a Mac (Simulator, TestFlight)

`RupertApp/project.yml` describes an Xcode project that compiles the same `Sources/Rupert` into a
runnable app (the package alone is a library). Generate it with [xcodegen](https://github.com/yonaskolb/XcodeGen);
the `.xcodeproj` is not committed.

```bash
brew install xcodegen
cd ios/RupertApp && xcodegen generate
xcodebuild build -scheme RupertApp -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO
xcrun simctl install booted <DerivedData>/Build/Products/Debug-iphonesimulator/Rupert.app
SIMCTL_CHILD_RUPERT_DEV_ORIGIN=http://127.0.0.1:3000 xcrun simctl launch booted com.rupertpos.Rupert
```

`RUPERT_DEV_ORIGIN` (debug builds only, `Instance.swift`) points the whole app at a local Rupert;
the "RupertApp (local)" scheme sets it to `http://127.0.0.1:3005`. `RupertApp/UITests` signs in as
the demo worker and walks the Time tab, saving a screenshot of each step:

```bash
TEST_RUNNER_RUPERT_UI_EMAIL=sam.okafor@juniper-pine.example TEST_RUNNER_RUPERT_UI_PASSWORD=… \
TEST_RUNNER_RUPERT_UI_SHOTS=/abs/dir xcodebuild test -scheme RupertApp -only-testing:RupertAppUITests \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO
```

For TestFlight from a Mac: open `RupertApp.xcodeproj`, pick the team, Product → Archive. The
entitlements file turns on push (`aps-environment`); the App ID needs the Push Notifications
capability (checklist item 4). `ship.sh` on Linux remains the other path.

## Push notifications

`PushRegistration.swift`: after the first signed-in page the app explains what the notifications
are for ("Stay in the loop"), then asks iOS; the APNs token goes to `POST /native/push_devices`
with the session cookie and is forgotten on sign-out. A tapped notification opens its `url` in the
Time tab. The server side (`PushNotifier`, APNs token auth) needs `APNS_*` keys in `/etc/rupert.env`;
without them the bell alone carries every message.

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
