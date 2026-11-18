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
        let method: String
        let headers: [String: String]
        let body: [String: Any]
        let raw: String
    }

    static let start = "/native/reader_attempts/start"
    static let result = "/native/reader_attempts/result"
    static let cancel = "/native/reader_attempts/cancel"

    private let lock = NSLock()
    private var answers: [String: [Answer]] = [:]
    private var recorded: [Call] = []

    /// A server with the feature on: start answers with `amountCents`, report and cancel are accepted.
    init(amountCents: Int = 1166, expiresIn: TimeInterval = 180) {
        answers[Self.start] = [.json(200, Self.startAnswer(amountCents: amountCents, expiresIn: expiresIn))]
        answers[Self.result] = [.json(200, ["status": "unknown", "reported": true])]
        answers[Self.cancel] = [.json(200, ["status": "unknown", "reported": true])]
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
        let answer: Answer = lock.withLock {
            recorded.append(Call(path: path, method: request.httpMethod ?? "", headers: request.allHTTPHeaderFields ?? [:], body: body,
                                 raw: String(data: data, encoding: .utf8) ?? ""))
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
    static let deviceID = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"

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

    func coordinator(reader: any CardReader, isPad: Bool = false) -> ReaderPaymentCoordinator {
        ReaderPaymentCoordinator(
            client: ReaderAttemptClient(baseURL: { URL(string: "https://rupert.test")! }, transport: server),
            reader: reader, store: store, deviceID: Self.deviceID, isPad: isPad, policy: policy, log: log)
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
