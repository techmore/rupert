# Phone card reader payments: the app side

Prepared 2026-11-18. This is the iPhone app's half of a card payment the phone starts, built and
tested against a **fake** card reader. There is no payment provider SDK, no Tap to Pay entitlement
and no real payment in this repository, and a shipped build cannot take a card (see
[Inert until a reader exists](#inert-until-a-reader-exists)).

The server half and the full contract are in pull request
[#666](https://github.com/techmore/rupert/pull/666) (`docs/integrations/device-reader-payments.md`
on that branch). This page says what the app does with it.

## The pieces

| Part | File | What it is |
| --- | --- | --- |
| `CardReader` | `Sources/Rupert/CardReader.swift` | The protocol a reader implements: `availability()`, `read(_:)`, `cancel()`. Also `CardReadRequest`, `CardReadResult` and `UnavailableCardReader`. |
| `FakeCardReader` | `Sources/Rupert/FakeCardReader.swift` | A scripted reader for tests and debug builds. The whole file is inside `#if DEBUG`. |
| `ReaderAttemptClient` | `Sources/Rupert/ReaderAttemptClient.swift` | The three server calls: start, result, cancel. The transport is injected; tests use a stub. |
| `ReaderAttemptStore` | `Sources/Rupert/ReaderAttemptStore.swift` | What survives a kill: the token and how far it got. |
| `ReaderPaymentCoordinator` | `Sources/Rupert/ReaderPaymentCoordinator.swift` | Runs one attempt from token to report. |
| `ReaderBridge` | `Sources/Rupert/ReaderBridge.swift` | The `rupertReader` message handler, installed beside the scanner in `WebViewSupport`. |

## What happens

1. The register page posts `{ type: "start", token }` to `rupertReader`. The token is the only
   thing the page may say. A message with any other key (an amount, a reference, a checkout id) is
   dropped. So is a message from a frame, or from a page that is not on the Rupert the app is
   pointed at. The scanner and banner handlers have no such check; this one is new, for this
   handler only.
2. The app posts the token and its install identifier to `POST /native/reader_attempts/start`
   with the session cookie. The answer says what to charge: reference, amount, currency, expiry.
3. The app saves the token as `reading`, then opens the reader for exactly that amount.
4. The app posts what the reader said to `POST /native/reader_attempts/result`.
5. The app dispatches `rupert:reader-result` on `window` with `{ token, state }`. `state` is
   `reported`, `unreported` or `unavailable`. The event carries no payment facts.
6. The page reads the confirmed outcome from the server
   (`GET /native/pos_checkouts/:id/reader_attempt`). The app does not: that route needs a checkout
   id, which the app is never given. What the app learns from the server is the attempt's status
   in the answer to its own report.

`{ type: "cancel", token }` closes the reader and calls `POST /native/reader_attempts/cancel`. If
the reader had already read the card, the app reports the result instead.

## The rules the coordinator keeps

- **One attempt at a time.** A second start for the same token joins the one in flight. A start
  for another token while one is in flight is answered `unavailable`, and that attempt is cancelled
  on the server so the checkout is not left waiting.
- **The reader opens at most once for a token.** The token is saved before the reader opens and
  kept for a day. A repeated start, a relaunch or a return to the app never opens it again.
- **Killed or sent to the background.** When the app next becomes active it settles what was left,
  with server calls only:

  | Saved as | Meaning | What the app does |
  | --- | --- | --- |
  | `claiming` | The reader never opened. | Calls cancel. |
  | `reading` | The app stopped while the reader was open. | Reports `failed`: the app does not know, and the server looks the payment up. |
  | `reporting`, not approved | The reader answered; the report did not arrive. | Reports the outcome word alone. |
  | `reporting`, approved | As above, for an approval. | Nothing. An approval needs its amount, which is not kept on disk. The server's sweep finds it. |
  | older than 15 minutes | The server settled it long ago. | Nothing. |

- **Network loss.** A report or cancel the server did not acknowledge is sent again after 1, 2, 4
  and 8 seconds, and again when the app next becomes active. The server keeps the first report and
  ignores repeats. The sale is never run again.
- **A reader that hangs.** The reader is told to close after two minutes, or five seconds before
  the server's expiry if that is sooner. If it does not close within ten seconds the app reports
  `failed` and moves on. If the reader answers later, that answer is reported too.
- **Unavailable.** An iPad, a phone whose reader says it cannot run, or a build with no reader:
  the app calls cancel and answers `unavailable`, without asking what to charge. A 404 or 403 from
  start (feature off, unknown token, another device) is also `unavailable`, and no reader opens.

## Card data

A reader returns a `CardReadResult` and nothing else: the outcome and six optional facts (provider
reference, amount, brand, last four, entry method, approval code). These are the fields the server
accepts. A value that is not in the server's accepted form, or that contains twelve or more digits
in a row, is dropped when the result is made.

- **On disk:** the token, a phase word, an outcome word and a time. No amount, no reference,
  nothing about a card. The install identifier is a random UUID kept in the app's preferences.
- **In logs:** the coordinator can only log a fixed set of event names and an HTTP status. Debug
  builds print them; release builds log nothing.
- **In memory:** a result the server has not acknowledged is held until it is sent or the app ends.

## Inert until a reader exists

- `CardReaders.make()` returns `UnavailableCardReader` unless a reader is built in. No build of
  this repository has one, so every start is answered `unavailable`.
- The fake is compiled only when `DEBUG` is set, and chosen only when the scheme's environment has
  `RUPERT_FAKE_CARD_READER` (`approved`, `declined`, `cancelled`, `failed`, `timeout` or `hang`).
  `CardReaderBuildTests` reads the sources and fails if `FakeCardReader` is named outside
  `#if DEBUG`, if anything imports a card reader framework, or if the entitlement appears.
- The server routes answer 404 while the feature is off, and production has no provider at all.
- With nothing saved, the return-to-app check reads one preference and stops.

## How a real reader plugs in

The reader backed by a payment provider's SDK lives in a **private** companion repository. This
public repository never holds the SDK, its headers, its documentation or any merchant identifier.

The private repository holds:

1. A type named `ProvidedCardReader` that implements `CardReader` over the provider's SDK and maps
   its answer to `CardReadResult`. It attaches `CardReadRequest.reference` to the sale and turns
   tips and fees off in the reader.
2. A build overlay for `RupertApp/project.yml` (xcodegen `include`) that adds those sources and
   the SDK to the app target, sets the `RUPERT_CARD_READER_PROVIDER` compilation condition, and
   points at its own entitlements file.

`CardReaders.make()` returns `ProvidedCardReader()` when that condition is set. Release builds
that take cards are made from the private repository, with this one checked out beside it.

## What must happen first

1. An Apple Developer **organization** account for the app.
2. Apple's Tap to Pay on iPhone entitlement granted to that account. It is not in
   `RupertApp/RupertApp.entitlements` and must not be added before it is granted: signing fails.
3. The provider's SDK and sandbox credentials.
4. The server side merged and a real provider behind it (pull request #666, "What remains").
5. The register page's button, which opens the attempt, posts the token and polls status.

## Deliberately not here

- A real reader, the provider's SDK, the entitlement, any Info.plist key for it.
- Any screen. The system reader sheet is the provider's; the register page shows the waiting state.
- A way for the page to ask whether the phone can take cards before it opens an attempt. The
  contract has no such message. `ReaderPaymentCoordinator.availability()` is ready for one.
- Reading the confirmed outcome in the app (see step 6).
- Refunds on the phone.

## Tests

`Tests/RupertTests`: `ReaderPaymentCoordinatorTests`, `ReaderBridgeTests`, `CardReadResultTests`
and `CardReaderBuildTests`. They use the fake reader and a stub transport, so nothing touches the
network. Run them with the rest of the package's tests (README, "Tests").
