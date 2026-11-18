import Foundation

/// What the app remembers about a payment attempt across a kill: the token and how far it got.
/// No amount, no reference, and nothing about a card.
struct ReaderAttemptRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// Asked the server what to charge. The reader has not been opened.
        case claiming
        /// The reader was opened. From here on it is never opened again for this token.
        case reading
        /// The reader answered (`outcome`); the server has not acknowledged the report yet.
        case reporting
        /// The server acknowledged the report or the cancel. Finished.
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
}

protocol ReaderAttemptStore: AnyObject, Sendable {
    func record(for token: String) -> ReaderAttemptRecord?
    func all() -> [ReaderAttemptRecord]
    func save(_ record: ReaderAttemptRecord)
    func remove(_ token: String)
}

/// The store the app uses: one small JSON value in UserDefaults.
final class UserDefaultsReaderAttemptStore: ReaderAttemptStore, @unchecked Sendable {
    static let key = "rupert.reader.attempts"
    /// Finished tokens are kept this long so a repeated start cannot open the reader again.
    static let keepFinished: TimeInterval = 24 * 60 * 60
    static let limit = 50

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(for token: String) -> ReaderAttemptRecord? {
        lock.withLock { load()[token] }
    }

    func all() -> [ReaderAttemptRecord] {
        lock.withLock { load().values.sorted { $0.firstSeen < $1.firstSeen } }
    }

    func save(_ record: ReaderAttemptRecord) {
        lock.withLock {
            var records = load()
            records[record.token] = record
            let cutoff = Date().addingTimeInterval(-Self.keepFinished)
            records = records.filter { !$0.value.phase.isFinished || $0.value.firstSeen > cutoff }
            if records.count > Self.limit {
                let oldestFinished = records.values.filter(\.phase.isFinished).sorted { $0.firstSeen < $1.firstSeen }
                oldestFinished.prefix(records.count - Self.limit).forEach { records[$0.token] = nil }
            }
            store(records)
        }
    }

    func remove(_ token: String) {
        lock.withLock {
            var records = load()
            records[token] = nil
            store(records)
        }
    }

    private func load() -> [String: ReaderAttemptRecord] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: ReaderAttemptRecord].self, from: data)) ?? [:]
    }

    private func store(_ records: [String: ReaderAttemptRecord]) {
        if records.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
