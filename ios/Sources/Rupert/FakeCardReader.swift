// The whole file is debug-only: a release build has no fake reader to select.
#if DEBUG
import Foundation

/// A scripted card reader for tests and debug builds. It talks to nothing and charges nothing.
///
/// Each `read` plays the next step of the script; the last step repeats. In a debug build,
/// `IOS_FAKE_CARD_READER=approved` (or `declined`, `cancelled`, `failed`, `timeout`, `hang`)
/// in the scheme's environment makes the app use it (`CardReaders.make`).
final class FakeCardReader: CardReader, @unchecked Sendable {
    enum Step {
        /// Answers with this result after a delay. A cancel during the delay answers `cancelled`.
        case finish(CardReadResult, after: TimeInterval = 0)
        /// Approves the requested amount on a made-up card after a delay.
        case approve(after: TimeInterval = 0)
        /// Waits for a card that never comes, until cancelled.
        case hang
        /// Does not answer and ignores cancel, until the test calls `finishStuck`.
        case stuck
        /// The app was killed while the reader was open: this read never returns.
        case appKilled
    }

    static let environmentKey = "IOS_FAKE_CARD_READER"

    private let lock = NSLock()
    private var script: [Step]
    private var current: Step?
    private var pending: UnsafeContinuation<CardReadResult, Never>?
    private var readingWaiters: [(count: Int, continuation: UnsafeContinuation<Void, Never>)] = []
    private var recordedRequests: [CardReadRequest] = []
    private var cancels = 0
    private var availabilityValue: CardReaderAvailability

    init(script: [Step], availability: CardReaderAvailability = .available) {
        self.script = script
        availabilityValue = availability
    }

    /// The reader a debug build was asked for in its environment, if any.
    convenience init?(environment: [String: String]) {
        switch environment[Self.environmentKey] {
        case "approved": self.init(script: [.approve(after: 2)])
        case "declined": self.init(script: [.finish(CardReadResult(status: .declined), after: 2)])
        case "cancelled": self.init(script: [.finish(.cancelled, after: 2)])
        case "failed": self.init(script: [.finish(.failed, after: 2)])
        case "timeout": self.init(script: [.finish(.timedOut, after: 5)])
        case "hang": self.init(script: [.hang])
        default: return nil
        }
    }

    /// Every request the reader was opened with, in order.
    var requests: [CardReadRequest] { lock.withLock { recordedRequests } }
    var cancelCount: Int { lock.withLock { cancels } }

    func setAvailability(_ value: CardReaderAvailability) {
        lock.withLock { availabilityValue = value }
    }

    func availability() async -> CardReaderAvailability {
        lock.withLock { availabilityValue }
    }

    func read(_ request: CardReadRequest) async -> CardReadResult {
        await withUnsafeContinuation { continuation in
            lock.lock()
            recordedRequests.append(request)
            let step = script.count > 1 ? script.removeFirst() : (script.first ?? .finish(.failed))
            current = step
            pending = continuation
            let count = recordedRequests.count
            let ready = readingWaiters.filter { $0.count <= count }
            readingWaiters.removeAll { $0.count <= count }
            lock.unlock()
            ready.forEach { $0.continuation.resume() }

            switch step {
            case let .finish(result, delay): complete(result, after: delay, read: count)
            case let .approve(delay):
                let approval = CardReadResult(status: .approved, providerReference: "FAKE-\(count)", amountCents: request.amountCents,
                                              cardBrand: .visa, lastFour: "0000", entryMethod: .contactless, approvalCode: "FAKE00")
                complete(approval, after: delay, read: count)
            case .hang, .stuck, .appKilled: break
            }
        }
    }

    func cancel() async {
        let waiting: UnsafeContinuation<CardReadResult, Never>? = lock.withLock {
            cancels += 1
            switch current {
            case .finish, .approve, .hang:
                defer { pending = nil }
                return pending
            case .stuck, .appKilled, nil:
                return nil
            }
        }
        waiting?.resume(returning: .cancelled)
    }

    /// Makes a `stuck` read answer at last, as a reader that finished long after it was given up on.
    func finishStuck(with result: CardReadResult) {
        resume(with: result, read: nil)
    }

    /// Returns once the reader has been opened `count` times.
    func waitUntilReading(count: Int = 1) async {
        await withUnsafeContinuation { continuation in
            lock.lock()
            if recordedRequests.count >= count {
                lock.unlock()
                continuation.resume()
            } else {
                readingWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    private func complete(_ result: CardReadResult, after delay: TimeInterval, read: Int) {
        Task.detached { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            self?.resume(with: result, read: read)
        }
    }

    /// Answers the pending read, if it is still the read `read` (nil: whichever is pending).
    private func resume(with result: CardReadResult, read: Int?) {
        lock.lock()
        guard read == nil || read == recordedRequests.count, let waiting = pending else {
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()
        waiting.resume(returning: result)
    }
}
#endif
