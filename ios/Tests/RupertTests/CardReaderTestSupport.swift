import Foundation
import XCTest
@testable import Rupert

/// Stands in for Rupert's server. Answers are queued per path; the last one for a path repeats.
/// Nothing here opens a connection.
final class StubTransport: ReaderHTTPTransport, @unchecked Sendable {
    enum Answer {
        case json(Int, [String: Any])
        case text(Int, String)
        case offline
    }

    struct Call {
        let path: String
        let query: String?
        let method: String
        let headers: [String: String]
        let body: [String: Any]
        let raw: String
    }

    static let start = "/native/reader_attempts/start"
    static let result = "/native/reader_attempts/result"
    static let cancel = "/native/reader_attempts/cancel"
    static let status = "/native/reader_attempts/status"

    private let lock = NSLock()
    private var answers: [String: [Answer]] = [:]
    private var recorded: [Call] = []
    private var held: Set<String> = []
    private var waiting: [String: [UnsafeContinuation<Void, Never>]] = [:]
    private var inFlight: [String: Int] = [:]
    private var most: [String: Int] = [:]

    /// A server with the feature on: start answers with `amountCents`, report and cancel are accepted.
    init(amountCents: Int = 1166, expiresIn: TimeInterval = 180) {
        answers[Self.start] = [.json(200, Self.startAnswer(amountCents: amountCents, expiresIn: expiresIn))]
        answers[Self.result] = [.json(200, ["status": "unknown", "reported": true])]
        answers[Self.cancel] = [.json(200, ["status": "unknown", "reported": true])]
        answers[Self.status] = [.json(200, Self.statusAnswer("submitting", reported: false))]
    }

    static func statusAnswer(_ status: String, reported: Bool = true, needsReview: Bool = false, message: String? = nil,
                             amountCents: Int = 1166) -> [String: Any] {
        ["status": status, "reported": reported, "needs_review": needsReview, "message": message ?? NSNull(), "amount_cents": amountCents]
    }

    /// Calls to `path` do not get their answer until `release(path)`.
    func hold(_ path: String) {
        lock.withLock { _ = held.insert(path) }
    }

    func release(_ path: String) {
        let resumed: [UnsafeContinuation<Void, Never>] = lock.withLock {
            held.remove(path)
            defer { waiting[path] = nil }
            return waiting[path] ?? []
        }
        resumed.forEach { $0.resume() }
    }

    /// The most requests to `path` that were ever waiting for an answer at the same moment.
    func mostAtOnce(_ path: String) -> Int {
        lock.withLock { most[path] ?? 0 }
    }

    static func startAnswer(amountCents: Int = 1166, expiresIn: TimeInterval = 180) -> [String: Any] {
        ["reference": "RR0123456789abcdef01234567", "amount_cents": amountCents, "tip_cents": 0, "currency": "USD",
         "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(expiresIn)), "reader": ["profile": "p1"]]
    }

    func script(_ path: String, _ list: [Answer]) {
        lock.withLock { answers[path] = list }
    }

    var calls: [Call] { lock.withLock { recorded } }
    func calls(to path: String) -> [Call] { calls.filter { $0.path == path } }
    var paths: [String] { calls.map(\.path) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let data = request.httpBody ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        // Recorded when it is sent, so a held request counts as out.
        lock.withLock {
            inFlight[path, default: 0] += 1
            most[path] = max(most[path] ?? 0, inFlight[path] ?? 0)
            recorded.append(Call(path: path, query: request.url?.query, method: request.httpMethod ?? "", headers: request.allHTTPHeaderFields ?? [:],
                                 body: body, raw: String(data: data, encoding: .utf8) ?? ""))
        }
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let wait: Bool = lock.withLock {
                guard held.contains(path) else { return false }
                waiting[path, default: []].append(continuation)
                return true
            }
            if !wait { continuation.resume() }
        }
        let answer: Answer = lock.withLock {
            inFlight[path, default: 1] -= 1
            var queue = answers[path] ?? [.json(404, [:])]
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            answers[path] = queue
            return next
        }
        switch answer {
        case .offline:
            throw URLError(.notConnectedToInternet)
        case let .json(status, object):
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case let .text(status, text):
            return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

final class RecordingLog: ReaderLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    /// Each line as the console log would print it.
    var lines: [String] { lock.withLock { recorded } }

    func record(_ event: ReaderLogEvent, httpStatus: Int?) {
        lock.withLock { recorded.append(event.rawValue + (httpStatus.map { " (\($0))" } ?? "")) }
    }
}

/// One phone: a server stub, a store on its own UserDefaults suite, a log, and coordinators made
/// over them. Making a second coordinator over the same phone is the app starting again.
final class TestPhone {
    static let token = String(repeating: "ab", count: 32)
    static let otherToken = String(repeating: "cd", count: 32)
    static let deviceID = "0f1e2d3c-4b5a-4978-8796-a5b4c3d2e1f0"

    let server: StubTransport
    let log = RecordingLog()
    let suite = "rupert.reader.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: UserDefaultsReaderAttemptStore
    var policy = ReaderPolicy(readerTimeout: 0.3, expiryMargin: 0, closeGrace: 0.15, retryDelays: [0.01, 0.01], staleAfter: 900)

    init(server: StubTransport = StubTransport()) {
        self.server = server
        defaults = UserDefaults(suiteName: suite)!
        store = UserDefaultsReaderAttemptStore(defaults: defaults)
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }

    let clock = TestClock()
    let said = SaidLog()

    var client: ReaderAttemptClient {
        ReaderAttemptClient(baseURL: { URL(string: "https://rupert.test")! }, transport: server)
    }

    func coordinator(reader: any CardReader, isPad: Bool = false, watcher: ReaderStatusWatcher? = nil) -> ReaderPaymentCoordinator {
        guard let watcher else {
            return ReaderPaymentCoordinator(client: client, reader: reader, store: store, deviceID: Self.deviceID, isPad: isPad, policy: policy, log: log)
        }
        // With a watcher, the coordinator reads the same test clock, so "after reporting" lines up.
        let clock = self.clock
        return ReaderPaymentCoordinator(client: client, reader: reader, store: store, deviceID: Self.deviceID, isPad: isPad, policy: policy, log: log,
                                        watcher: watcher, now: { clock.now })
    }

    /// A status watcher on the test clock: it waits only when the test moves time.
    func watcher() -> ReaderStatusWatcher {
        let clock = self.clock
        let said = self.said
        return ReaderStatusWatcher(client: client, store: store, deviceID: Self.deviceID, log: log, now: { clock.now },
                                   sleep: { await clock.sleep($0) }, onChange: { said.record($0, $1, $2) })
    }

    /// A token as the app holds it after start succeeded and the report was acknowledged.
    func hold(_ token: String = TestPhone.token, phase: ReaderAttemptRecord.Phase = .reported, startedAgo: TimeInterval = 5,
              reportedAgo: TimeInterval? = 0) {
        store.save(ReaderAttemptRecord(token: token, phase: phase, firstSeen: Date(), startedAt: clock.now.addingTimeInterval(-startedAgo),
                                       reportedAt: reportedAgo.map { clock.now.addingTimeInterval(-$0) }, watching: true))
    }

    func phase(_ token: String = TestPhone.token) -> ReaderAttemptRecord.Phase? {
        store.record(for: token)?.phase
    }

    /// Everything the app has written to disk for the reader, as text.
    var savedText: String {
        defaults.data(forKey: UserDefaultsReaderAttemptStore.key).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

extension XCTestCase {
    /// Waits, without blocking the thread, until `condition` holds.
    func eventually(_ what: String, within seconds: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
                    _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end {
                XCTFail("Timed out waiting for: \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// A card as a real reader might describe it, to check that none of it strays.
enum SampleCard {
    static let approved = CardReadResult(status: .approved, providerReference: "TXN-77aa88bb", amountCents: 1166, cardBrand: .mastercard,
                                         lastFour: "4242", entryMethod: .contactless, approvalCode: "Z9Y8X7")
    /// Text that must never appear in a log or on disk.
    static let secrets = ["TXN-77aa88bb", "1166", "Mastercard", "4242", "Z9Y8X7", "contactless"]
}

/// Text shaped like card data, for checking that the app drops it. Put together when the tests
/// run, so that nothing shaped like a card number is written in this repository (bin/release-audit).
enum CardLike {
    static let number = "4" + String(repeating: "1", count: 15)
    static let other = "55" + String(repeating: "0", count: 4) + String(repeating: "5", count: 9) + "9"
    static let grouped = stride(from: 0, to: 16, by: 4).map { String(Array(number)[$0..<$0 + 4]) }.joined(separator: "-")
    static let track1 = "%B" + other + "^X"
    static let track2 = ";" + number + "=" + "2512"
}

/// Time that moves only when a test moves it. A sleeper wakes when the clock passes its time.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    private var sleepers: [(wake: Date, continuation: UnsafeContinuation<Void, Never>)] = []
    private var asked: [TimeInterval] = []
    private var counters: [(count: Int, continuation: UnsafeContinuation<Void, Never>)] = []

    var now: Date { lock.withLock { current } }
    /// Every wait that was asked for, in order.
    var sleeps: [TimeInterval] { lock.withLock { asked } }

    func sleep(_ seconds: TimeInterval) async {
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let ready: [UnsafeContinuation<Void, Never>] = lock.withLock {
                asked.append(seconds)
                sleepers.append((current.addingTimeInterval(seconds), continuation))
                let due = counters.filter { $0.count <= asked.count }.map(\.continuation)
                counters.removeAll { $0.count <= asked.count }
                return due
            }
            ready.forEach { $0.resume() }
        }
    }

    /// Returns once `count` waits have been asked for in all.
    func waitForSleeps(_ count: Int) async {
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let already: Bool = lock.withLock {
                if asked.count >= count { return true }
                counters.append((count, continuation))
                return false
            }
            if already { continuation.resume() }
        }
    }

    func advance(by seconds: TimeInterval) {
        let due: [UnsafeContinuation<Void, Never>] = lock.withLock {
            current = current.addingTimeInterval(seconds)
            let woken = sleepers.filter { $0.wake <= current }.map(\.continuation)
            sleepers.removeAll { $0.wake <= current }
            return woken
        }
        due.forEach { $0.resume() }
    }
}

/// What the watcher said may be shown, in order.
final class SaidLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(token: String, confirmation: ReaderConfirmation, afterRelaunch: Bool)] = []

    var all: [ReaderConfirmation] { lock.withLock { entries.map(\.confirmation) } }
    var afterRelaunch: [Bool] { lock.withLock { entries.map(\.afterRelaunch) } }

    func record(_ token: String, _ confirmation: ReaderConfirmation, _ afterRelaunch: Bool) {
        lock.withLock { entries.append((token, confirmation, afterRelaunch)) }
    }
}
