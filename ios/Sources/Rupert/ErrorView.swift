import HotwireNative
import Network
import SwiftUI
import UIKit

/// What a tab shows when a Rupert page cannot load, in place of Hotwire's "Error loading page".
/// It says what happened in shop words, offers Try Again, and reloads by itself when the phone
/// comes back online.
struct RupertErrorView: ErrorPresentableView {
    let error: HotwireNativeError
    let handler: ErrorPresenter.Handler?

    @StateObject private var network = NetworkWatch()

    var body: some View {
        let text = ErrorText(error)
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: text.symbol)
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(text.title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(text.message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let handler {
                        Button(action: handler) {
                            Text("Try Again").frame(minWidth: 160)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.top, 8)
                    }
                    if case .load = error, let details = ErrorDetails.latest {
                        Button("Copy Details for Support") {
                            UIPasteboard.general.string = details
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                        .font(.footnote)
                    }
                }
                .padding(32)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear { UIAccessibility.post(notification: .screenChanged, argument: nil) }
        .onChange(of: network.online) { _, online in
            if online, text.isConnection { handler?() }
        }
    }
}

/// The words for each kind of failure.
struct ErrorText: Equatable {
    var symbol: String
    var title: String
    var message: String
    /// The phone or the server could not be reached; worth retrying when the network returns.
    var isConnection = false

    init(symbol: String, title: String, message: String, isConnection: Bool = false) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.isConnection = isConnection
    }

    init(_ error: HotwireNativeError) {
        switch error {
        case .web(let web) where web.isOffline:
            self.init(symbol: "wifi.slash", title: "You're offline",
                      message: "Rupert will load this page as soon as your iPhone is back online.", isConnection: true)
        case .web(let web) where web.isTimeout:
            self.init(symbol: "hourglass", title: "Rupert is taking too long",
                      message: "The connection may be slow. Try again in a moment.", isConnection: true)
        case .web(let web) where Self.unreachable.contains(web.urlError?.code ?? .unknown):
            self.init(symbol: "wifi.exclamationmark", title: "Can't reach Rupert",
                      message: "Check the shop's Wi-Fi or your cellular connection, then try again.", isConnection: true)
        case .web:
            self.init(symbol: "exclamationmark.triangle", title: "This page did not load",
                      message: error.localizedDescription, isConnection: true)
        case .http where error.statusCode == 401 || error.statusCode == 403:
            self.init(symbol: "lock", title: "You don't have access to this page",
                      message: "Ask an owner or manager to give you access, or go back.")
        case .http where error.statusCode == 404:
            self.init(symbol: "questionmark.folder", title: "This page isn't here",
                      message: "It may have been moved or deleted. Go back, or try again.")
        case .http where (error.statusCode ?? 0) >= 500:
            self.init(symbol: "exclamationmark.triangle", title: "Rupert had a problem",
                      message: "Try again in a moment. If it keeps happening, use Report a problem in App settings.")
        case .http:
            self.init(symbol: "exclamationmark.triangle", title: "This page did not load",
                      message: error.localizedDescription)
        case .load:
            self.init(symbol: "exclamationmark.triangle", title: "This page did not finish loading",
                      message: "Try again. If it keeps happening, copy the details and send them to support.")
        }
    }

    private static let unreachable: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
        .internationalRoamingOff, .dataNotAllowed, .callIsActive,
    ]
}

/// The diagnostics of the last page whose JavaScript did not start (SceneController), for
/// "Copy Details for Support".
@MainActor
enum ErrorDetails {
    static var latest: String?
}

/// Whether the phone has a network path, for reloading an error page when it comes back.
final class NetworkWatch: ObservableObject {
    @Published private(set) var online = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { if self?.online != online { self?.online = online } }
        }
        monitor.start(queue: DispatchQueue(label: "rupert.network"))
    }

    deinit { monitor.cancel() }
}
