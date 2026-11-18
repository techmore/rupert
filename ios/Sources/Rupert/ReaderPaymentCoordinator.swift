import Foundation

/// What the app tells the register page when it is done with an attempt (`rupert:reader-result`).
/// It carries no payment facts: the page then reads the confirmed outcome from the server.
enum ReaderPageState: String, Equatable, Sendable {
    /// The server accepted the report or the cancel.
    case reported
    /// The app could not get an answer to the server; the server's own lookup settles it.
    case unreported
    /// This phone cannot run the reader for this attempt.
    case unavailable
}

/// The fixed things the coordinator may write to a log. There is no free text and no payment
/// value, so a token, an amount or anything about a card cannot reach a log through it.
enum ReaderLogEvent: String, Sendable {
    case messageRejected, joined, busy, readerUnavailable, serverUnavailable, claimFailed, expired
    case readerOpened, readerFinished, readerTimedOut, readerAbandoned, cancelRequested, lateResult
    case reportSent, reportUnsent, reportRefused, cancelSent, cancelUnsent, retry, recovering, leftToServer
}

protocol ReaderLogSink: Sendable {
    func record(_ event: ReaderLogEvent, httpStatus: Int?)
}

/// Debug builds print the event name; release builds log nothing, like the rest of the app.
struct ReaderConsoleLog: ReaderLogSink {
    func record(_ event: ReaderLogEvent, httpStatus: Int?) {
#if DEBUG
        NSLog("reader: %@%@", event.rawValue, httpStatus.map { " (\($0))" } ?? "")
#endif
    }
}

struct ReaderPolicy: Sendable {
    /// The longest the reader stays open. The server allows three minutes from when the page
    /// opened the attempt; the app stops sooner, and always before the server's expiry.
    var readerTimeout: TimeInterval = 120
    /// Stop this long before the server's expiry.
    var expiryMargin: TimeInterval = 5
    /// How long a reader has to close after it is told to, before the app gives up on it.
    var closeGrace: TimeInterval = 10
    /// Waits between sends of the same request when the server could not be reached.
    var retryDelays: [TimeInterval] = [1, 2, 4, 8]
    /// An unfinished attempt older than this is left to the server, which has settled it by then.
    var staleAfter: TimeInterval = 15 * 60
}

/// Runs one phone card reader payment from the page's token to the report, against the contract
/// in docs/card-reader.md.
///
/// The rules it keeps:
/// - The page gives a token and nothing else. The amount comes from the server.
/// - One attempt at a time. The same token again joins the attempt in flight.
/// - The reader is opened at most once for a token, ever. The token is saved as `reading` before
///   the reader opens, so after a kill the app reports that it does not know what happened and
///   never opens the reader again.
/// - A report or a cancel the server did not acknowledge is sent again (the server keeps the
///   first and ignores repeats). The sale itself is never run again.
/// - A reader that does not answer is closed at the time limit and reported as failed. If it
///   answers later, that answer is reported too.
actor ReaderPaymentCoordinator {
    private let client: ReaderAttemptClient
    private let reader: any CardReader
    private let store: any ReaderAttemptStore
    private let deviceID: String
    private let isPad: Bool
    private let policy: ReaderPolicy
    private let log: any ReaderLogSink
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void

    private var flightToken: String?
    private var flightTask: Task<ReaderPageState, Never>?
    private var cancelRequested = false

    private enum ReadEvent { case finished(CardReadResult), deadline, cancel, graceOver }
    private var reading = false
    private var generation = 0
    private var events: [ReadEvent] = []
    private var waiter: CheckedContinuation<ReadEvent, Never>?
    /// Reads the app gave up on; their answer, if it ever comes, is still reported.
    private var abandoned: Set<Int> = []
    /// Results the server has not acknowledged, in memory only, so a later try can send them whole.
    private var unsent: [String: CardReadResult] = [:]

    init(client: ReaderAttemptClient, reader: any CardReader, store: any ReaderAttemptStore, deviceID: String, isPad: Bool,
         policy: ReaderPolicy = ReaderPolicy(), log: any ReaderLogSink = ReaderConsoleLog(),
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }) {
        self.client = client
        self.reader = reader
        self.store = store
        self.deviceID = deviceID
        self.isPad = isPad
        self.policy = policy
        self.log = log
        self.now = now
        self.sleep = sleep
    }

    /// Whether this phone can take a card payment, for hiding or disabling the tender.
    func availability() async -> CardReaderAvailability {
        isPad ? .unavailable(.iPad) : await reader.availability()
    }

    /// The page asked to take the payment for `token`. Returns when the app is done with it.
    func start(token: String) async -> ReaderPageState {
        if let flightToken, let flightTask {
            if flightToken == token {
                note(.joined)
                return await flightTask.value
            }
            note(.busy)
            return await refuse(token)
        }
        return await fly(token, known: store.record(for: token) != nil)
    }

    /// The page asked to stop. Returns nil when a start for the token is in flight: that start
    /// answers the page. Otherwise the cancel goes to the server and the token is remembered, so
    /// the reader is never opened for it.
    func cancel(token: String) async -> ReaderPageState? {
        if flightToken == token, let flightTask {
            note(.cancelRequested)
            cancelRequested = true
            deliver(.cancel, generation)
            _ = await flightTask.value
            return nil
        }
        if store.record(for: token) != nil {
            return flightToken == nil ? await fly(token, known: true) : .unreported
        }
        save(token, .claiming)
        return await cancelOnServer(token, readerRan: false)
    }

    /// At launch and when the app comes back: settle every attempt that was left unfinished, by
    /// telling the server what the app knows. The reader is not involved.
    func recover() async -> [(token: String, state: ReaderPageState)] {
        var settled: [(token: String, state: ReaderPageState)] = []
        for record in store.all() where !record.phase.isFinished {
            guard flightToken == nil else { break }
            settled.append((record.token, await fly(record.token, known: true)))
        }
        return settled
    }

    // MARK: One attempt

    private func fly(_ token: String, known: Bool) async -> ReaderPageState {
        cancelRequested = false
        let task = Task { () -> ReaderPageState in
            let state = known ? await self.resolve(token) : await self.run(token)
            self.flightToken = nil
            self.flightTask = nil
            return state
        }
        flightToken = token
        flightTask = task
        return await task.value
    }

    /// A first start for a token this install has not seen.
    private func run(_ token: String) async -> ReaderPageState {
        guard await availability() == .available else {
            note(.readerUnavailable)
            _ = await client.cancel(token: token, deviceID: deviceID)
            return .unavailable
        }

        save(token, .claiming)
        let start: ReaderAttemptStart
        switch await retrying({ await self.client.start(token: token, deviceID: self.deviceID) }) {
        case let .success(answer):
            start = answer
        case .failure(.malformed):
            // The server answered, but not with something to charge. Let go of the attempt.
            note(.claimFailed)
            _ = await cancelOnServer(token, readerRan: false)
            return .unavailable
        case let .failure(failure):
            // The reader was never opened, so the token may be started again.
            store.remove(token)
            if failure == .status(404) || failure == .status(403) {
                note(.serverUnavailable, failure.httpStatus)
                return .unavailable
            }
            note(.claimFailed, failure.httpStatus)
            return .unreported
        }

        if cancelRequested { return await cancelOnServer(token, readerRan: false) }
        let remaining = start.expiresAt.timeIntervalSince(now()) - policy.expiryMargin
        guard remaining > 0 else {
            note(.expired)
            return await cancelOnServer(token, readerRan: false)
        }

        // Saved before the reader opens: after this line the reader never opens again for this token.
        save(token, .reading)
        note(.readerOpened)
        let request = CardReadRequest(reference: start.reference, amountCents: start.amountCents, tipCents: start.tipCents,
                                      currency: start.currency, expiresAt: start.expiresAt, providerParameters: start.reader)
        let result = await read(request, token: token, limit: min(remaining, policy.readerTimeout))
        if cancelRequested, result.status == .cancelled { return await cancelOnServer(token, readerRan: true) }
        return await report(token, result)
    }

    /// A token this install has seen before (a relaunch, a return to the app, a repeated start).
    /// The reader is never opened here.
    private func resolve(_ token: String) async -> ReaderPageState {
        guard let record = store.record(for: token) else { return .unreported }
        switch record.phase {
        case .reported: return .reported
        case .closed: return .unreported
        case .claiming, .reading, .reporting: break
        }
        note(.recovering)
        if now().timeIntervalSince(record.firstSeen) > policy.staleAfter {
            return close(token)
        }
        switch record.phase {
        case .claiming:
            return await cancelOnServer(token, readerRan: false)
        case .reading:
            // The app stopped while the reader was open. Whether a card was charged is not known,
            // and "failed" says exactly that: the server looks the payment up and decides.
            return await report(token, .failed)
        case .reporting:
            if let whole = unsent[token] { return await report(token, whole) }
            guard let status = record.outcome.flatMap(CardReadResult.Status.init(rawValue:)), status != .approved else {
                // An approval cannot be reported without its amount, which is not kept across a
                // kill. The server finds an approved payment with its own lookup.
                return close(token)
            }
            return await report(token, CardReadResult(status: status))
        case .reported, .closed:
            return .unreported
        }
    }

    /// Another attempt is in flight. This phone cannot run the reader for `token`.
    private func refuse(_ token: String) async -> ReaderPageState {
        guard store.record(for: token) == nil else { return .unreported }
        _ = await client.cancel(token: token, deviceID: deviceID)
        return .unavailable
    }

    // MARK: The reader

    private func read(_ request: CardReadRequest, token: String, limit: TimeInterval) async -> CardReadResult {
        generation += 1
        let current = generation
        events = []
        reading = true
        defer { reading = false }

        let reader = self.reader
        Task.detached {
            let result = await reader.read(request)
            await self.readerFinished(result, generation: current, token: token)
        }
        let timer = after(limit, .deadline, current)
        var grace: Task<Void, Never>?
        while true {
            switch await nextEvent() {
            case let .finished(result):
                timer.cancel()
                grace?.cancel()
                note(.readerFinished)
                return result
            case .deadline, .cancel:
                guard grace == nil else { continue }
                if !cancelRequested { note(.readerTimedOut) }
                timer.cancel()
                // Not awaited: a reader that cannot close must not hold the payment up.
                Task.detached { await reader.cancel() }
                grace = after(policy.closeGrace, .graceOver, current)
            case .graceOver:
                abandoned.insert(current)
                note(.readerAbandoned)
                return .timedOut
            }
        }
    }

    private func readerFinished(_ result: CardReadResult, generation finished: Int, token: String) async {
        guard abandoned.remove(finished) != nil else {
            deliver(.finished(result), finished)
            return
        }
        // The reader answered after the app gave up on it. The server still gets to know.
        note(.lateResult)
        _ = await report(token, result)
    }

    private func after(_ delay: TimeInterval, _ event: ReadEvent, _ target: Int) -> Task<Void, Never> {
        Task {
            await self.sleep(delay)
            guard !Task.isCancelled else { return }
            self.deliver(event, target)
        }
    }

    private func deliver(_ event: ReadEvent, _ target: Int) {
        guard reading, target == generation else { return }
        if let waiting = waiter {
            waiter = nil
            waiting.resume(returning: event)
        } else {
            events.append(event)
        }
    }

    private func nextEvent() async -> ReadEvent {
        if !events.isEmpty { return events.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    // MARK: Telling the server

    private func report(_ token: String, _ result: CardReadResult) async -> ReaderPageState {
        save(token, .reporting, outcome: result.status.rawValue)
        unsent[token] = result
        switch await retrying({ await self.client.report(token: token, deviceID: self.deviceID, result: result) }) {
        case .success:
            unsent[token] = nil
            save(token, .reported)
            note(.reportSent)
            return .reported
        case let .failure(failure) where failure.isRetryable:
            // Kept as `reporting`: the next return to the app sends it again.
            note(.reportUnsent, failure.httpStatus)
            return .unreported
        case let .failure(failure):
            note(.reportRefused, failure.httpStatus)
            return close(token)
        }
    }

    private func cancelOnServer(_ token: String, readerRan: Bool) async -> ReaderPageState {
        if readerRan {
            save(token, .reporting, outcome: CardReadResult.Status.cancelled.rawValue)
        } else {
            save(token, .claiming)
        }
        switch await retrying({ await self.client.cancel(token: token, deviceID: self.deviceID) }) {
        case .success:
            save(token, .reported)
            note(.cancelSent)
            return .reported
        case let .failure(failure) where failure.isRetryable:
            note(.cancelUnsent, failure.httpStatus)
            return .unreported
        case let .failure(failure):
            note(.cancelUnsent, failure.httpStatus)
            return close(token)
        }
    }

    /// Done without an acknowledgement. The server's lookup settles the attempt.
    private func close(_ token: String) -> ReaderPageState {
        unsent[token] = nil
        save(token, .closed)
        note(.leftToServer)
        return .unreported
    }

    /// Sends again, after each wait, while the failure is one a repeat can cure. Only ever used
    /// for start, report and cancel, which the server treats the same however often they arrive.
    private func retrying<Answer>(_ send: () async -> Result<Answer, ReaderAPIFailure>) async -> Result<Answer, ReaderAPIFailure> {
        var answer = await send()
        for delay in policy.retryDelays {
            guard case let .failure(failure) = answer, failure.isRetryable else { break }
            note(.retry, failure.httpStatus)
            await sleep(delay)
            answer = await send()
        }
        return answer
    }

    private func save(_ token: String, _ phase: ReaderAttemptRecord.Phase, outcome: String? = nil) {
        let firstSeen = store.record(for: token)?.firstSeen ?? now()
        store.save(ReaderAttemptRecord(token: token, phase: phase, outcome: outcome, firstSeen: firstSeen))
    }

    private func note(_ event: ReaderLogEvent, _ httpStatus: Int? = nil) {
        log.record(event, httpStatus: httpStatus)
    }
}
