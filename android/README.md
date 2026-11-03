# Rupert for Android

A native Android app for Rupert, built on [Hotwire Native Android](https://native.hotwired.dev)
1.3.2. It is the Android twin of the iPhone app in `ios/` and follows the same path as the website:

1. It opens on the control plane, `pos.rupertpos.com` (`BuildConfig.CONTROL_PLANE_URL`). Signed out,
   every tab shows Rupert's sign-in page. Sign in with email and password, or with Google (a
   browser tab, see below).
2. Tenants the control plane serves directly stay there.
3. A customer with an isolated workspace gets "Open my workspace". The app posts the one-time
   handoff to that instance itself, keeps its session and moves every tab there. The instance is
   remembered across launches.
4. A business that runs its own Rupert picks it in **App settings → Rupert server**.

| Tab | Page |
|---|---|
| Home | `/login`, which sends a signed-in person to their start page |
| Team Chat | `/chat` |
| Ask Rupert | `/ask_rupert` |
| Notifications | `/notifications` |
| Search | `/search` |

Each tab keeps its own back stack. Forms (`…/new`, `…/edit`) open as full-screen modals with a
close button. Every Rupert site (`*.rupertpos.com`, the control plane and the current workspace)
stays in the app, including links Rupert marks `data-turbo="false"`; other sites open in a browser
tab (Custom Tabs), and `mailto:`, `tel:`, `sms:` and `geo:` links in their apps. Pages pull to
refresh, except chat, Ask Rupert and POS.

This is separate from `mobile/`, the Expo app that only covers staff timesheets (`/employee`).

## Why Hotwire Native

`mobile/` is a narrow React Native client for one API (staff time and leave). The full Rupert
experience is the website, and the iPhone app already wraps it with Hotwire Native. Doing the same on
Android means:

- **One set of navigation rules.** Both apps read the same path configuration (below).
- **Same server integration.** Rupert already recognises Hotwire Native (`hotwire_native_app?` in
  turbo-rails matches `Hotwire Native Android` in the user agent), hides the web chrome the tab bar
  replaces, hides billing and sign-up, and runs the Google and workspace handoffs for the app.
- **New pages need no app release.** Only the native parts below live here.

## How Rupert treats the app

The same as the iPhone app (see `ios/README.md`). Android specifics:

- **Google sign-in** runs in a browser tab (Custom Tabs), because Google refuses sign-in inside
  embedded web views. The app keeps a random verifier in memory and sends only its SHA-256 to
  `/auth/google` (PKCE). Rupert answers `rupert://auth/google?code=…`, which Android hands to
  `MainActivity`; the app trades the code at `POST /native/session` and copies the session cookie
  into the web views (`GoogleSignIn.kt`, `NativeHttp.kt`). A code without the verifier is useless,
  so another app claiming `rupert://` gains nothing.
- **Workspace handoff**: "Open my workspace" answers `rupert://workspace?origin=…&handoff=…`.
  Hotwire Android proposes every main-frame navigation as a visit, so `Routing.kt` sees the redirect,
  and `NativeHttp.exchangeHandoff` posts the handoff to `<origin>/instance/session` as the browser
  form would.
- **Navigation rules**: the app loads `/native/android/path-configuration.json` from the control
  plane (same rules as `/native/ios/…`), and bundles one copy for the first launch: Gradle copies
  `ios/Sources/Rupert/Resources/path-configuration.json` into the app's assets at build time, so the
  repository keeps a single file. `web/test/integration/native_app_test.rb` checks that it matches
  the server's rules.
- **Page bridges** (`WebViewSupport.kt`): `window.rupertScanner` and `window.rupertBanner` are web
  message listeners injected only into Rupert's own origins and main frames, never into payment or
  other third-party frames. `inventory_count_scanner_controller.js` uses `rupertScanner` when the
  iOS handler is absent.

## Native parts

| Feature | Where | Notes |
|---|---|---|
| Server picker with checks | `ServerActivity.kt`, `InstanceAddress.kt` | Address form, then a request for the navigation rules proves it is Rupert |
| Google sign-in (PKCE) | `GoogleSignIn.kt`, `Pkce.kt` | Custom Tab, `rupert://auth/google` callback |
| App lock | `AppLock.kt` | Fingerprint, face or screen lock (BiometricPrompt); cover over every screen; no recent-apps snapshot |
| Tabs | `Tabs.kt`, `activity_main.xml` | Same five tabs as iOS; a tab left behind by a sign-in or sign-out starts over when opened |
| Barcode scanning | `BarcodeScanner.kt` | Google code scanner (ML Kit in Play services): no camera permission, images never leave the phone |
| Banner colours | `BannerColors.kt`, `RupertWebFragment.kt` | Top bar and status bar icons follow each page's `--color-banner` and appearance changes |
| Workspace handoff | `NativeHttp.kt`, `RupertLinks.kt` | |
| Deep links | `AndroidManifest.xml` | `rupert://auth/google`; App Links for `pos.rupertpos.com` (below) |
| Launcher shortcuts | `res/xml/shortcuts.xml` | Team Chat, Ask Rupert, Notifications, Search (like iOS quick actions) |
| App settings | `SettingsActivity.kt` | Lock, workspace, server, support, report a problem, privacy, delete account, version |
| Error screen | `RupertWebFragment.kt` | Says why a page did not start, with copyable diagnostics |

**Dark mode.** Native screens follow the phone's light or dark setting (`values-night`). Pages
follow the appearance chosen in Rupert's account menu, and the top bar takes each page's banner
colour; Chromium's forced darkening is off so pages are never double-darkened.

**Accessibility.** Every icon-only control has a label (tabs, App settings, close, lock); headings
are marked for TalkBack; touch targets are at least 48 dp; text uses scalable `sp` sizes; while the
app is locked, the pages under the cover are hidden from screen readers.

## Security

- **HTTPS only.** `res/xml/network_security_config.xml` turns cleartext off and trusts only the
  system's certificate authorities (no user-installed CAs). Plain http is allowed only for
  `localhost`, `127.0.0.1`, the emulator's `10.0.2.2`, and `*.local`, `*.lan`, `*.internal`,
  `*.home.arpa`. `InstanceAddress.kt` applies the same list to typed addresses, and
  `NetworkSecurityConfigTest` keeps the two in step. A LAN server reached by bare IP address needs
  https (or a local name); add its IP to the config only in a private build.
- **No runtime permissions.** The app asks for `INTERNET`; its libraries add the install-time
  `USE_BIOMETRIC` (app lock) and `ACCESS_NETWORK_STATE` (Play services). No camera, microphone,
  location, contacts or storage permissions: the barcode scanner runs in Play services, and photo
  attachments go through the camera app or the file picker.
- **No secrets in the repository.** No keys, keystores or service accounts; `.gitignore` refuses
  `*.jks`, `*.keystore`, `keystore.properties` and Play service-account JSON. Release signing reads
  environment variables (below).
- **No backups.** `allowBackup="false"` and `data_extraction_rules.xml`: the session cookie and
  settings never leave the phone.
- **Web views:** file and content access off, geolocation off, debugging only in debug builds, no
  WebView metrics to Google.
- Card data never touches the app or Rupert: hosted payment fields only, as on the web.

## Build

Needs JDK 17 or later and the Android SDK (platform 36). From `android/`:

```bash
./gradlew testDebugUnitTest lintDebug   # unit and Robolectric tests, lint
./gradlew assembleDebug                 # app/build/outputs/apk/debug/app-debug.apk
./gradlew bundleRelease                 # app/build/outputs/bundle/release/app-release.aab (unsigned)
./gradlew connectedDebugAndroidTest     # smoke test on a running emulator or phone
```

CI (`.github/workflows/android.yml`) runs the tests and lint and keeps the debug APK and unsigned
bundle as artifacts. It never signs or uploads.

### Run against a local Rupert

```bash
cd web && bin/rails server -b 127.0.0.1 -p 3000      # in one terminal
cd android && ./gradlew installDebug -Prupert.controlPlane=http://10.0.2.2:3000
```

Or install the normal build and choose `http://10.0.2.2:3000` in App settings → Rupert server
(`10.0.2.2` is the computer, seen from the emulator).

### Setup used for the first build (macOS, Apple silicon)

- JDK 21 (`brew install openjdk@21`); the Android SDK in `~/Library/Android/sdk` with platform 36,
  build-tools 36.1.0, platform-tools and the emulator.
- `brew install --cask android-commandlinetools`, then
  `sdkmanager --sdk_root=$HOME/Library/Android/sdk "system-images;android-36;google_apis;arm64-v8a"`.
- The Homebrew `avdmanager` looks for system images next to itself, not in `--sdk_root`; either
  install `cmdline-tools;latest` into the SDK and use that `avdmanager`, or create the AVD by hand
  (`~/.android/avd/rupert.ini` and `rupert.avd/config.ini` pointing `image.sysdir.1` at the image).
- Robolectric needs `--add-opens java.base/jdk.internal.access` on JDK 21 for Android 16; the
  build passes it to unit tests.

## Configuration

| Setting | Where | Value |
|---|---|---|
| Application ID | `app/build.gradle.kts` | `com.rupertpos.rupert` (cannot change after the first Play upload) |
| Control plane | `-Prupert.controlPlane` | `https://pos.rupertpos.com` |
| Version | `app/build.gradle.kts` | `1.0.0`; the version code comes from `RUPERT_VERSION_CODE` (CI run number) |
| Minimum / target Android | `app/build.gradle.kts` | 9 (API 28) / 16 (API 36) |

## Play Store

`PlayStore/` holds what the listing needs: `checklist.md` (the Play Console steps the owner does,
in order), `listing.md` (title, descriptions, graphics), `data-safety.md` (the Data safety form and
content rating answers), `review-notes.md` (App access instructions for Play review) and
`screenshots/`. Nothing has been uploaded to Google.

### Release signing

Play App Signing keeps the key that signs what people install; you sign uploads with your own
**upload key**, created once and kept outside this repository (a password manager or private
backup):

```bash
keytool -genkeypair -v -keystore ~/private/rupert-upload.jks -alias upload \
  -keyalg RSA -keysize 4096 -validity 10000
```

Then build a signed bundle:

```bash
export RUPERT_UPLOAD_KEYSTORE=~/private/rupert-upload.jks RUPERT_UPLOAD_KEY_ALIAS=upload
read -rs RUPERT_UPLOAD_KEYSTORE_PASSWORD && export RUPERT_UPLOAD_KEYSTORE_PASSWORD
read -rs RUPERT_UPLOAD_KEY_PASSWORD && export RUPERT_UPLOAD_KEY_PASSWORD
RUPERT_VERSION_CODE=2 ./gradlew bundleRelease
```

Each upload needs a higher `RUPERT_VERSION_CODE`.

### App Links

Rupert links (`pos.rupertpos.com/chat`, `/notifications`, `/tasks`, `/inventory_counts`, `/orders`,
`/timesheets`, `/schedule`, `/ask_rupert`, `/search`, `/workspace`) open in the app once Android
verifies the site. Sign-in paths are left out on purpose. After the first upload, copy the
**App signing key certificate SHA-256** (Play Console → Test and release → App integrity) into the
server's environment and deploy:

```bash
RUPERT_ANDROID_CERT_SHA256=AA:BB:…   # comma-separate several (e.g. also the upload key)
```

Rupert then serves it at `/.well-known/assetlinks.json` (`AndroidAssetLinksController`). Check on a
phone with `adb shell pm get-app-links com.rupertpos.rupert`.
