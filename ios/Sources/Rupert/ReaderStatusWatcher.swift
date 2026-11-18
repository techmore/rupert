import Foundation

/// What the app may say about a payment, from the server's status answer and nothing else. A
/// reader's own "approved" never makes `paid`: until the server confirms, the word is `checking`.
enum ReaderConfirmation: Equatable, Sendable {
    case checking
    case paid
    case declined(message: String?)
    /// Held for a manager. The app stops asking; it can stay this way for a long time.
    case held(message: String?)

    init(_ answer: ReaderAttemptStatus) {
        if answer.status == .paid {
            self = .paid
        } else if answer.needsReview {
            self = .held(message: answer.message)
        } else if answer.status == .declined {
            self = .declined(message: answer.message)
        } else {
            self = .checking
        }
    }

    /// Words for a small native alert. Nothing is shown while checking.
    var notice: (title: String, message: String)? {
        switch self {
        case .checking:
            return nil
        case .paid:
            return ("Card payment confirmed", "Rupert confirmed this card payment as paid.")
        case let .declined(message):
            return ("Card payment not taken", message ?? "This card payment was declined.")
        case let .held(message):
            return ("Card payment needs a manager", message ?? "Do not charge again. A manager must check this payment.")
        }
    }
}

/// Reads the server-confirmed outcome of attempts this install started
/// (`POST /native/reader_attempts/status`), at the pace the contract sets:
///
/// - only for a token whose start succeeded;
/// - every 2 seconds for the first 30 seconds after the report, then every 10 seconds;
/// - stop on paid or declined and forget the token; stop on 403 or 404 and forget the token,
///   never asking again; stop when the attempt is held for a manager; stop ten minutes after
///   start; stop while the app is in the background;
/// - on 422, a server error or no network, ask again at the slower pace;
/// - never two requests at once for one token.
///
/// It keeps nothing from an answer. The register page remains the main display.
actor ReaderStatusWatcher {
    static let fastPace: TimeInterval = 2
    static let slowPace: TimeInterval = 10
    static let fastWindow: TimeInterval = 30
    static let limit: TimeInterval = 10 * 60

    typealias Answer = Result<ReaderAttemptStatus, ReaderAPIFailure>

    private let client: ReaderAttemptClient
    private let store: any ReaderAttemptStore
    private let deviceID: String
    private let log: any ReaderLogSink
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    /// Called when what may be said about a token changes. The flag is true for a token the app
    /// found still held when it was launched.
    private let onChange: @Sendable (_ token: String, _ confirmation: ReaderConfirmation, _ afterRelaunch: Bool) -> Void

    private var paused = false
    private var loops: [String: Int] = [:]
    private var lastLoop = 0
    private var inFlight: Set<String> = []
    private var afterRelaunch: Set<String> = []
    private var said: [String: ReaderConfirmation] = [:]

    init(client: ReaderAttemptClient, store: any ReaderAttemptStore, deviceID: String, log: any ReaderLogSink = ReaderConsoleLog(),
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
         onChange: @escaping @Sendable (String, ReaderConfirmation, Bool) -> Void = { _, _, _ in }) {
        self.client = client
        self.store = store
        self.deviceID = deviceID
        self.log = log
        self.now = now
        self.sleep = sleep
        self.onChange = onChange
    }

    /// Start reading `token`'s status. `knowing` is an answer the caller has just read, which
    /// counts as this round's request so the server is not asked twice.
    func watch(token: String, knowing first: Answer? = nil, afterRelaunch relaunched: Bool = false) {
        guard isHeld(token) else { return }
        if relaunched { afterRelaunch.insert(token) }
        begin(token, first: first)
    }

    /// The app went to the background: no more requests until it returns.
    func pause() {
        paused = true
    }

    /// The app is back, or was just launched: one read for every token still held (except those
    /// the caller has just read), then the usual pace.
    func resume(except handled: Set<String> = [], afterRelaunch relaunched: Bool = false) {
        paused = false
        for record in store.all() where !handled.contains(record.token) && isHeld(record.token) {
            if relaunched { afterRelaunch.insert(record.token) }
            begin(record.token, first: nil)
        }
    }

    /// Whether a loop is alive for `token` (for tests).
    func isWatching(_ token: String) -> Bool {
        loops[token] != nil
    }

    private func isHeld(_ token: String) -> Bool {
        guard let record = store.record(for: token) else { return false }
        return record.watching && record.startedAt != nil
    }

    /// Makes sure a loop is alive for `token` and that it asks now rather than after a wait.
    private func begin(_ token: String, first: Answer?) {
        guard !paused else { return }
        // A request is already out: its answer is the prompt read, and its loop carries on.
        // This is also what keeps two requests for one token from ever being in flight.
        if inFlight.contains(token) { return }
        lastLoop += 1
        let id = lastLoop
        loops[token] = id // a loop that was waiting sees it has been replaced and ends
        Task { await self.loop(token, id, first) }
    }

    private func loop(_ token: String, _ id: Int, _ first: Answer?) async {
        var known = first
        while true {
            let answer: Answer
            if let given = known {
                answer = given
                known = nil
            } else {
                inFlight.insert(token)
                answer = await client.status(token: token, deviceID: deviceID)
                inFlight.remove(token)
                guard isCurrent(token, id) else { return }
            }

            let pace: TimeInterval
            switch answer {
            case let .success(status):
                say(token, ReaderConfirmation(status))
                if status.isSettled {
                    forget(token, .statusSettled)
                    return
                }
                if status.needsReview {
                    stop(token, id, .statusHeld)
                    return
                }
                let reportedAt = store.record(for: token)?.reportedAt
                pace = reportedAt.map { now().timeIntervalSince($0) < Self.fastWindow } == true ? Self.fastPace : Self.slowPace
            case let .failure(failure) where failure == .status(403) || failure == .status(404):
                log.record(.statusRefused, httpStatus: failure.httpStatus)
                forget(token, .statusForgotten)
                return
            case let .failure(failure):
                log.record(.statusUnread, httpStatus: failure.httpStatus)
                pace = Self.slowPace
            }

            guard withinLimit(token) else {
                stop(token, id, .statusTimeLimit)
                return
            }
            await sleep(pace)
            guard isCurrent(token, id) else { return }
            guard withinLimit(token) else {
                stop(token, id, .statusTimeLimit)
                return
            }
        }
    }

    /// Still the live loop for the token, and the app is in the foreground. A loop that finds
    /// the app in the background ends; `resume` starts a new one.
    private func isCurrent(_ token: String, _ id: Int) -> Bool {
        guard loops[token] == id else { return false }
        if paused {
            loops[token] = nil
            return false
        }
        return true
    }

    private func withinLimit(_ token: String) -> Bool {
        guard let started = store.record(for: token)?.startedAt else { return false }
        return now().timeIntervalSince(started) < Self.limit
    }

    private func say(_ token: String, _ confirmation: ReaderConfirmation) {
        guard said[token] != confirmation else { return }
        said[token] = confirmation
        onChange(token, confirmation, afterRelaunch.contains(token))
    }

    /// Stop asking, but keep the token: the next return to the app reads it once more.
    private func stop(_ token: String, _ id: Int, _ event: ReaderLogEvent) {
        if loops[token] == id { loops[token] = nil }
        log.record(event, httpStatus: nil)
    }

    /// Stop asking for good and let go of the token.
    private func forget(_ token: String, _ event: ReaderLogEvent) {
        loops[token] = nil
        afterRelaunch.remove(token)
        said[token] = nil
        store.stopWatching(token)
        log.record(event, httpStatus: nil)
    }
}
