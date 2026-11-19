import CryptoKit
import Foundation

/// What the app remembers about a payment attempt across a kill: the token, how far it got and
/// when. No amount, no reference, nothing from a status answer and nothing about a card.
struct ReaderAttemptRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// Asked the server what to charge. The reader has not been opened.
        case claiming
        /// The reader was opened. From here on it is never opened again for this token.
        case reading
        /// The reader answered (`outcome`); the server has not acknowledged the report yet.
        case reporting
        /// The server acknowledged the report or the cancel, or already had one. Finished.
        case reported
        /// Finished without an acknowledgement; the server settles it with its own lookup.
        case closed

        var isFinished: Bool { self == .reported || self == .closed }
    }

    let token: String
    var phase: Phase
    /// The reader's outcome word while `reporting`: approved, declined, cancelled, failed or timedOut.
    var outcome: String?
    let firstSeen: Date
    /// When the server answered start. Status may be read only after this, and for ten minutes.
    var startedAt: Date?
    /// When the server acknowledged the report or the cancel.
    var reportedAt: Date?
    /// Whether the app still reads this token's status. Off once the server said paid or
    /// declined, or answered 403 or 404.
    var watching = false

    init(token: String, phase: Phase, outcome: String? = nil, firstSeen: Date, startedAt: Date? = nil, reportedAt: Date? = nil,
         watching: Bool = false) {
        self.token = token
        self.phase = phase
        self.outcome = outcome
        self.firstSeen = firstSeen
        self.startedAt = startedAt
        self.reportedAt = reportedAt
        self.watching = watching
    }

    /// Nothing more to send and nothing more to read: the token itself can be forgotten.
    var isDone: Bool { phase.isFinished && !watching }
}

protocol ReaderAttemptStore: AnyObject, Sendable {
    func record(for token: String) -> ReaderAttemptRecord?
    func all() -> [ReaderAttemptRecord]
    /// Saves the record. A record that is done is forgotten instead: only a digest of its token
    /// is kept, with the last word for the page, so the reader still never opens for it again.
    func save(_ record: ReaderAttemptRecord)
    func remove(_ token: String)
    /// What the page was last told about a token that has since been forgotten.
    func forgottenState(for token: String) -> ReaderPageState?
}

extension ReaderAttemptStore {
    /// Stop reading this token's status, for good.
    func stopWatching(_ token: String) {
        guard var record = record(for: token), record.watching else { return }
        record.watching = false
        save(record)
    }
}

/// The store the app uses: one small JSON value in UserDefaults.
final class UserDefaultsReaderAttemptStore: ReaderAttemptStore, @unchecked Sendable {
    static let key = "rupert.reader.attempts"
    /// How long anything is kept: a held token, or the digest of a forgotten one.
    static let keep: TimeInterval = 24 * 60 * 60
    static let limit = 50

    private struct Forgotten: Codable {
        let state: String
        let at: Date
    }

    private struct Contents: Codable {
        var records: [String: ReaderAttemptRecord] = [:]
        /// SHA-256 of a forgotten token: what the page was told, and when.
        var forgotten: [String: Forgotten] = [:]
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(for token: String) -> ReaderAttemptRecord? {
        lock.withLock { load().records[token] }
    }

    func all() -> [ReaderAttemptRecord] {
        lock.withLock { load().records.values.sorted { $0.firstSeen < $1.firstSeen } }
    }

    func save(_ record: ReaderAttemptRecord) {
        lock.withLock {
            var contents = load()
            if record.isDone {
                contents.records[record.token] = nil
                contents.forgotten[Self.digest(record.token)] = Forgotten(state: (record.phase == .reported ? ReaderPageState.reported : .unreported).rawValue,
                                                                          at: Date())
            } else {
                contents.records[record.token] = record
            }
            let cutoff = Date().addingTimeInterval(-Self.keep)
            contents.records = contents.records.filter { $0.value.firstSeen > cutoff }
            contents.forgotten = contents.forgotten.filter { $0.value.at > cutoff }
            if contents.forgotten.count > Self.limit {
                let oldest = contents.forgotten.sorted { $0.value.at < $1.value.at }.prefix(contents.forgotten.count - Self.limit)
                oldest.forEach { contents.forgotten[$0.key] = nil }
            }
            store(contents)
        }
    }

    func remove(_ token: String) {
        lock.withLock {
            var contents = load()
            contents.records[token] = nil
            store(contents)
        }
    }

    func forgottenState(for token: String) -> ReaderPageState? {
        lock.withLock { load().forgotten[Self.digest(token)].flatMap { ReaderPageState(rawValue: $0.state) } }
    }

    static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func load() -> Contents {
        guard let data = defaults.data(forKey: Self.key) else { return Contents() }
        return (try? JSONDecoder().decode(Contents.self, from: data)) ?? Contents()
    }

    private func store(_ contents: Contents) {
        if contents.records.isEmpty && contents.forgotten.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(contents) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
