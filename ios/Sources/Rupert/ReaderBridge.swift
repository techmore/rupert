import UIKit
import WebKit

/// What the register page may ask of the app: `{ type: "start", token }` or `{ type: "cancel", token }`.
/// Exactly those two keys. A message with anything else in it (an amount, a reference, a checkout
/// id) is not a message this app acts on: what to charge comes from the server alone.
enum ReaderMessage: Equatable {
    case start(token: String)
    case cancel(token: String)

    init?(body: Any) {
        guard let fields = body as? [String: Any], Set(fields.keys) == ["type", "token"],
              let type = fields["type"] as? String, let token = fields["token"] as? String,
              token.range(of: "\\A[0-9a-f]{64}\\z", options: .regularExpression) != nil else { return nil }
        switch type {
        case "start": self = .start(token: token)
        case "cancel": self = .cancel(token: token)
        default: return nil
        }
    }

    var token: String {
        switch self {
        case let .start(token), let .cancel(token): return token
        }
    }
}

/// Phone card reader payments for Rupert's register page (docs/card-reader.md).
///
/// The page posts an attempt token to the `rupertReader` message handler. The app asks Rupert's
/// server what to charge, runs the card reader, reports what the reader said, and answers the page
/// with a `rupert:reader-result` event that carries the token and one word: `reported`,
/// `unreported` or `unavailable`. The page then reads the confirmed outcome from the server.
///
/// No build of this repository has a real reader, so a shipped app answers `unavailable`.
final class ReaderBridge: NSObject, WKScriptMessageHandler {
    static let shared = ReaderBridge()
    static let handlerName = "rupertReader"
    static let eventName = "rupert:reader-result"

    private lazy var coordinator = ReaderPaymentCoordinator(
        client: ReaderAttemptClient(baseURL: { Instance.current }, transport: WebSessionTransport(),
                                    userAgent: "Rupert iOS/\(Instance.appVersion)"),
        reader: CardReaders.make(),
        store: UserDefaultsReaderAttemptStore(),
        deviceID: InstallIdentifier.current(),
        isPad: UIDevice.current.userInterfaceIdiom == .pad)
    private let log = ReaderConsoleLog()
    private weak var page: WKWebView?
    private var observing = false

    static func install(in controller: WKUserContentController) {
        controller.add(shared, name: handlerName)
        shared.observeReturns()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard let webView = message.webView,
              Self.accepts(isMainFrame: message.frameInfo.isMainFrame, scheme: origin.protocol, host: origin.host, port: origin.port,
                           instance: Instance.current),
              let command = ReaderMessage(body: message.body) else {
            log.record(.messageRejected, httpStatus: nil)
            return
        }
        page = webView
        let coordinator = self.coordinator
        Task { @MainActor in
            let state: ReaderPageState?
            switch command {
            case let .start(token): state = await coordinator.start(token: token)
            case let .cancel(token): state = await coordinator.cancel(token: token)
            }
            if let state { Self.post(state, token: command.token, to: webView) }
        }
    }

    /// Only the top page of the Rupert the app is pointed at may ask for a payment: not a frame
    /// inside it, and not a page on any other site, another Rupert workspace included. The app's
    /// calls go to that same instance with its session.
    static func accepts(isMainFrame: Bool, scheme: String, host: String, port: Int, instance: URL) -> Bool {
        guard isMainFrame, let expectedScheme = instance.scheme?.lowercased(), let expectedHost = instance.host?.lowercased(),
              !host.isEmpty else { return false }
        return scheme.lowercased() == expectedScheme && host.lowercased() == expectedHost
            && effectivePort(port == 0 ? nil : port, scheme: expectedScheme) == effectivePort(instance.port, scheme: expectedScheme)
    }

    private static func effectivePort(_ port: Int?, scheme: String) -> Int {
        port ?? (scheme == "https" ? 443 : 80)
    }

    /// The script that tells the page. The detail is JSON made by the serializer, never pasted text.
    static func eventScript(token: String, state: ReaderPageState) -> String {
        let detail = (try? JSONSerialization.data(withJSONObject: ["token": token, "state": state.rawValue], options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "window.dispatchEvent(new CustomEvent(\"\(eventName)\", { detail: \(detail) }))"
    }

    /// Tells the page, if the web view still shows the instance the payment belongs to.
    @MainActor
    private static func post(_ state: ReaderPageState, token: String, to webView: WKWebView?) {
        guard let webView, let url = webView.url, let scheme = url.scheme, let host = url.host,
              accepts(isMainFrame: true, scheme: scheme, host: host, port: url.port ?? 0, instance: Instance.current) else { return }
        webView.evaluateJavaScript(eventScript(token: token, state: state))
    }

    /// When the app comes back (and at its first activation after a launch), settle any attempt
    /// that was left unfinished. With nothing saved this does nothing at all.
    private func observeReturns() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.recover()
        }
        recover()
    }

    private func recover() {
        guard !UserDefaultsReaderAttemptStore().all().allSatisfy(\.phase.isFinished) else { return }
        let coordinator = self.coordinator
        Task { @MainActor [weak self] in
            for settled in await coordinator.recover() {
                Self.post(settled.state, token: settled.token, to: self?.page)
            }
        }
    }
}
