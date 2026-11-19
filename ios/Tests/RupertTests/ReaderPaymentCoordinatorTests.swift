import XCTest
@testable import Rupert

/// One phone card reader payment, end to end, against a stub of Rupert's server and the fake
/// reader. No network, no real reader, no payment.
final class ReaderPaymentCoordinatorTests: XCTestCase {
    private let token = TestPhone.token

    // MARK: The usual path

    func testHappyPathChargesWhatTheServerSaysAndReportsIt() async {
        let phone = TestPhone()
        let reader = FakeCardReader(script: [.finish(SampleCard.approved)])

        let state = await phone.coordinator(reader: reader).start(token: token)

        XCTAssertEqual(state, .reported)
        XCTAssertEqual(phone.server.paths, [StubTransport.start, StubTransport.result])
        let start = phone.server.calls[0]
        XCTAssertEqual(start.method, "POST")
        XCTAssertEqual(start.headers["Content-Type"], "application/json")
        XCTAssertEqual(start.body as NSDictionary, ["token": token, "device_id": TestPhone.deviceID])

        XCTAssertEqual(reader.requests.count, 1)
        XCTAssertEqual(reader.requests[0].reference, "RR0123456789abcdef01234567")
        XCTAssertEqual(reader.requests[0].amountCents, 1166)
        XCTAssertEqual(reader.requests[0].currency, "USD")
        XCTAssertEqual(reader.requests[0].providerParameters, ["profile": "p1"])

        let report = phone.server.calls[1].body
        XCTAssertEqual(Set(report.keys), ["token", "device_id", "result"])
        XCTAssertEqual(report["result"] as? NSDictionary, [
            "status": "approved", "provider_reference": "TXN-77aa88bb", "amount_cents": 1166, "card_brand": "Mastercard",
            "last_four": "4242", "entry_method": "contactless", "auth_code": "Z9Y8X7",
        ])
        XCTAssertEqual(phone.phase(), .reported)
    }

    func testEveryReaderOutcomeIsReportedInTheServersWords() async {
        let expected: [(CardReadResult, String)] = [
            (SampleCard.approved, "approved"),
            (CardReadResult(status: .declined, cardBrand: .visa, lastFour: "0002"), "declined"),
            (.cancelled, "cancelled"),
            (.failed, "failed"),
            (.timedOut, "failed"),
            // An approval that does not say how much is not something the server can accept as one.
            (CardReadResult(status: .approved), "failed"),
        ]
        for (result, word) in expected {
            let phone = TestPhone()
            let reader = FakeCardReader(script: [.finish(result)])
            let state = await phone.coordinator(reader: reader).start(token: token)
            XCTAssertEqual(state, .reported, word)
            let sent = phone.server.calls(to: StubTransport.result).first?.body["result"] as? [String: Any]
            XCTAssertEqual(sent?["status"] as? String, word)
            XCTAssertEqual(reader.requests.count, 1)
        }
    }

    func testTheAmountComesFromTheServerNotThePage() async {
        // The page cannot even say an amount: a message that carries one is not a message.
        XCTAssertNil(ReaderMessage(body: ["type": "start", "token": token, "amount_cents": 1]))
        XCTAssertNil(ReaderMessage(body: ["type": "start", "token": token, "amount": "0.01"]))

        let phone = TestPhone(server: StubTransport(amountCents: 98765))
        let reader = FakeCardReader(script: [.approve()])
        _ = await phone.coordinator(reader: reader).start(token: token)

        XCTAssertEqual(reader.requests.map(\.amountCents), [98765])
        let sent = phone.server.calls(to: StubTransport.result).first?.body["result"] as? [String: Any]
        XCTAssertEqual(sent?["amount_cents"] as? Int, 98765)
    }

    // MARK: Double tap

    func testASecondStartForTheSameTokenJoinsTheOneInFlight() async {
        let phone = TestPhone()
        let reader = FakeCardReader(script: [.approve(after: 0.1)])
        let coordinator = phone.coordinator(reader: reader)

        async let first = coordinator.start(token: token)
        await reader.waitUntilReading()
        async let second = coordinator.start(token: token)
        async let third = coordinator.start(token: token)
        let states = await [first, second, third]

        XCTAssertEqual(states, [.reported, .reported, .reported])
        XCTAssertEqual(reader.requests.count, 1, "one sale")
        XCTAssertEqual(phone.server.paths, [StubTransport.start, StubTransport.result])
        XCTAssertTrue(phone.log.lines.contains("joined"))
    }

    func testAnotherTokenWhileOneIsInFlightIsRefusedAndReleased() async {
        let phone = TestPhone()
        let reader = FakeCardReader(script: [.approve(after: 0.1)])
        let coordinator = phone.coordinator(reader: reader)

        async let first = coordinator.start(token: token)
        await reader.waitUntilReading()
        let other = await coordinator.start(token: TestPhone.otherToken)
        let state = await first

        XCTAssertEqual(other, .unavailable)
        XCTAssertEqual(state, .reported)
        XCTAssertEqual(reader.requests.count, 1)
        XCTAssertEqual(phone.server.calls(to: StubTransport.cancel).map { $0.body["token"] as? String }, [TestPhone.otherToken])
    }

    func testAStartForAFinishedTokenNeverOpensTheReaderAgain() async {
        let phone = TestPhone()
        let reader = FakeCardReader(script: [.approve()])
        let coordinator = phone.coordinator(reader: reader)
        _ = await coordinator.start(token: token)

        let again = await coordinator.start(token: token)

        XCTAssertEqual(again, .reported)
        XCTAssertEqual(reader.requests.count, 1)
        XCTAssertEqual(phone.server.paths, [StubTransport.start, StubTransport.result])
    }

    // MARK: Killed, then started again

    func testKilledWhileTheReaderWasOpenReportsFailedAndNeverReadsAgain() async {
        let phone = TestPhone()
        let before = FakeCardReader(script: [.appKilled])
        phone.policy.readerTimeout = 3600 // a killed app's timers do not fire
        let killed = phone.coordinator(reader: before)
        phone.policy.readerTimeout = 0.3
        Task { _ = await killed.start(token: self.token) }
        await before.waitUntilReading()
        XCTAssertEqual(phone.phase(), .reading, "saved before the reader opened")
        XCTAssertEqual(phone.server.paths, [StubTransport.start])

        // The app starts again: a new coordinator and a new reader over what was saved.
        let after = FakeCardReader(script: [.approve()])
        let relaunched = phone.coordinator(reader: after)
        let settled = await relaunched.recover()

        XCTAssertEqual(settled.map(\.token), [token])
        XCTAssertEqual(settled.map(\.state), [.reported])
        XCTAssertEqual(after.requests.count, 0, "recovery never runs the reader")
        // It asks what the server knows first. The server has heard nothing, so the app says what
        // it knows: the read did not finish.
        XCTAssertEqual(phone.server.paths, [StubTransport.start, StubTransport.status, StubTransport.result], "and never asks to start again")
        XCTAssertEqual(phone.server.calls[1].body as NSDictionary, ["token": token, "device_id": TestPhone.deviceID])
        XCTAssertEqual(phone.server.calls[2].body["result"] as? NSDictionary, ["status": "failed"])
        XCTAssertEqual(phone.phase(), .reported)

        // The page, reloaded, posts the same token again.
        let again = await relaunched.start(token: token)
        XCTAssertEqual(again, .reported)
        XCTAssertEqual(after.requests.count, 0)
        let nothingLeft = await relaunched.recover()
        XCTAssertTrue(nothingLeft.isEmpty)
    }

    func testKilledBeforeTheReaderOpenedCancelsOnTheServer() async {
        let phone = TestPhone()
        phone.store.save(ReaderAttemptRecord(token: token, phase: .claiming, outcome: nil, firstSeen: Date()))
        let reader = FakeCardReader(script: [.approve()])

        let settled = await phone.coordinator(reader: reader).recover()

        XCTAssertEqual(settled.map(\.state), [.reported])
        XCTAssertEqual(phone.server.paths, [StubTransport.cancel])
        XCTAssertEqual(reader.requests.count, 0)
    }

    func testKilledBeforeTheReportArrivedSendsTheOutcomeWordOnly() async {
        for word in ["declined", "cancelled", "failed", "timedOut"] {
            let phone = TestPhone()
            phone.store.save(ReaderAttemptRecord(token: token, phase: .reporting, outcome: word, firstSeen: Date(), startedAt: Date(), watching: true))
            let reader = FakeCardReader(script: [.approve()])

            let settled = await phone.coordinator(reader: reader).recover()

            XCTAssertEqual(settled.map(\.state), [.reported], word)
            XCTAssertEqual(phone.server.paths, [StubTransport.status, StubTransport.result])
            XCTAssertEqual(phone.server.calls[1].body["result"] as? NSDictionary, ["status": word == "timedOut" ? "failed" : word])
            XCTAssertEqual(reader.requests.count, 0)
        }
    }

    func testAnApprovalLostToAKillIsLeftToTheServersLookup() async {
        // The amount is not kept on disk, and an approval cannot be reported without it.
        let phone = TestPhone()
        phone.store.save(ReaderAttemptRecord(token: token, phase: .reporting, outcome: "approved", firstSeen: Date(), startedAt: Date(), watching: true))
        let reader = FakeCardReader(script: [.approve()])

        let settled = await phone.coordinator(reader: reader).recover()

        XCTAssertEqual(settled.map(\.state), [.unreported])
        XCTAssertEqual(phone.server.paths, [StubTransport.status], "it asks what the server knows, and sends nothing")
        XCTAssertEqual(reader.requests.count, 0)
        XCTAssertEqual(phone.phase(), .closed)
    }

    func testAnOldUnfinishedAttemptIsLeftToTheServer() async {
        let phone = TestPhone()
        phone.store.save(ReaderAttemptRecord(token: token, phase: .reading, outcome: nil, firstSeen: Date().addingTimeInterval(-3600),
                                             startedAt: Date().addingTimeInterval(-3590), watching: true))
        let reader = FakeCardReader(script: [.approve()])

        let settled = await phone.coordinator(reader: reader).recover()

        XCTAssertEqual(settled.map(\.state), [.unreported])
        XCTAssertEqual(phone.server.paths, [])
        XCTAssertEqual(reader.requests.count, 0)
    }

    func testRecoveryWithNothingSavedDoesNothing() async {
        let phone = TestPhone()
        let settled = await phone.coordinator(reader: FakeCardReader(script: [.approve()])).recover()
        XCTAssertTrue(settled.isEmpty)
        XCTAssertEqual(phone.server.paths, [])
    }

    // MARK: Network loss

    func testAReportThatDidNotGetThroughIsSentAgainButTheSaleIsNot() async {
        let phone = TestPhone()
        phone.server.script(StubTransport.result, [.offline, .json(503, [:]), .json(200, ["status": "unknown", "reported": true])])
        let reader = FakeCardReader(script: [.finish(SampleCard.approved)])

        let state = await phone.coordinator(reader: reader).start(token: token)

        XCTAssertEqual(state, .reported)
        XCTAssertEqual(reader.requests.count, 1, "the sale ran once")
        XCTAssertEqual(phone.server.calls(to: StubTransport.start).count, 1)
        let reports = phone.server.calls(to: StubTransport.result)
        XCTAssertEqual(reports.count, 3)
        XCTAssertEqual(Set(reports.map(\.raw)).count, 1, "the same report each time")
        XCTAssertEqual(phone.log.lines.filter { $0.hasPrefix("retry") }.count, 2)
    }

    func testAReportThatNeverGetsThroughIsKeptAndSentWholeOnReturn() async {
        let phone = TestPhone()
        phone.server.script(StubTransport.result, [.offline])
        let reader = FakeCardReader(script: [.finish(SampleCard.approved)])
        let coordinator = phone.coordinator(reader: reader)

        let state = await coordinator.start(token: token)
        XCTAssertEqual(state, .unreported)
        XCTAssertEqual(phone.phase(), .reporting)
        XCTAssertEqual(phone.server.calls(to: StubTransport.result).count, 3, "first send and two retries")

        // The page tries again while still offline: no second sale.
        let again = await coordinator.start(token: token)
        XCTAssertEqual(again, .unreported)
        XCTAssertEqual(reader.requests.count, 1)
        XCTAssertEqual(phone.server.calls(to: StubTransport.start).count, 1)

        // Back online, the app returns to the foreground.
        phone.server.script(StubTransport.result, [.json(200, ["status": "paid", "reported": true])])
        let settled = await coordinator.recover()
        XCTAssertEqual(settled.map(\.state), [.reported])
        XCTAssertEqual(reader.requests.count, 1)
        let last = phone.server.calls(to: StubTransport.result).last?.body["result"] as? [String: Any]
        XCTAssertEqual(last?["status"] as? String, "approved")
        XCTAssertEqual(last?["amount_cents"] as? Int, 1166)
        XCTAssertEqual(phone.phase(), .reported)
    }

    func testAReportTheServerRefusesIsNotSentAgain() async {
        let phone = TestPhone()
        phone.server.script(StubTransport.result, [.json(422, ["error": "The reported amount does not match this checkout."])])
        let reader = FakeCardReader(script: [.finish(SampleCard.approved)])
        let coordinator = phone.coordinator(reader: reader)

        let state = await coordinator.start(token: token)

        XCTAssertEqual(state, .unreported)
        XCTAssertEqual(phone.server.calls(to: StubTransport.result).count, 1)
        XCTAssertEqual(phone.phase(), .closed)
        let settled = await coordinator.recover()
        XCTAssertTrue(settled.isEmpty)
        // The server may still call the attempt open; the reader stays shut for this token.
        _ = await coordinator.start(token: token)
        XCTAssertEqual(reader.requests.count, 1)
    }

    func testNoNetworkAtStartOpensNoReaderAndTheTokenCanBeTriedAgain() async {
        let phone = TestPhone()
        phone.server.script(StubTransport.start, [.offline])
        let reader = FakeCardReader(script: [.approve()])
        let coordinator = phone.coordinator(reader: reader)

        let state = await coordinator.start(token: token)
        XCTAssertEqual(state, .unreported)
        XCTAssertEqual(reader.requests.count, 0)
        XCTAssertNil(phone.phase(), "the reader never opened, so nothing is held against the token")

        phone.server.script(StubTransport.start, [.json(200, StubTransport.startAnswer())])
        let retried = await coordinator.start(token: token)
        XCTAssertEqual(retried, .reported)
        XCTAssertEqual(reader.requests.count, 1)
    }

    // MARK: A reader that hangs

    func testAReaderWaitingForACardIsClosedAtTheTimeLimit() async {
        let phone = TestPhone()
        let reader = FakeCardReader(script: [.hang])

        let state = await phone.coordinator(reader: reader).start(token: token)

        XCTAssertEqual(state, .reported)
        XCTAssertEqual(reader.cancelCount, 1)
        XCTAssertEqual(phone.server.paths, [StubTransport.start, StubTransport.result])
        XCTAssertEqual(phone.server.calls[1].body["result"] as? NSDictionary, ["status": "cancelled"], "the reader said it closed without a card")
        XCTAssertTrue(phone.log.lines.contains("readerTimedOut"))
    }

    func testAReaderThatNeverAnswersIsGivenUpOnAndReportedFailedAndItsLateAnswerIsStillReported() async {
        let phone = TestPhone()
        let reader = FakeCardReader(script: [.stuck])

        let state = await phone.coordinator(reader: reader).start(token: token)

        XCTAssertEqual(state, .reported)
        XCTAssertEqual(reader.cancelCount, 1)
        XCTAssertEqual(phone.server.calls(to: StubTransport.result).map { $0.body["result"] as? NSDictionary }, [["status": "failed"]])

        // Long after, the reader answers: it had charged the card.
        reader.finishStuck(with: SampleCard.approved)
        await eventually("the late result is reported") { phone.server.calls(to: StubTransport.result).count == 2 }
        let late = phone.server.calls(to: StubTransport.result).last?.body["result"] as? [String: Any]
        XCTAssertEqual(late?["status"] as? String, "approved")
        XCTAssertEqual(reader.requests.count, 1)
        XCTAssertTrue(phone.log.lines.contains("lateResult"))
    }

    func testTheReaderIsNeverOpenPastTheServersExpiry() async {
        // Ten minutes allowed by the app's own limit, but the server's expiry is a moment away.
        // (The expiry is sent in whole seconds, so this is between one and two seconds from now.)
        let phone = TestPhone(server: StubTransport(expiresIn: 2))
        phone.policy.readerTimeout = 600
        let reader = FakeCardReader(script: [.hang])
        let began = Date()

        let state = await phone.coordinator(reader: reader).start(token: token)

        XCTAssertEqual(state, .reported)
        XCTAssertLessThan(Date().timeIntervalSince(began), 10)
        XCTAssertEqual(reader.cancelCount, 1)
    }

    func testAnAttemptThatAlreadyExpiredOpensNoReader() async {
        let phone = TestPhone(server: StubTransport(expiresIn: -1))
        let reader = FakeCardReader(script: [.approve()])

        let state = await phone.coordinator(reader: reader).start(token: token)

        XCTAssertEqual(state, .reported)
        XCTAssertEqual(reader.requests.count, 0)
        XCTAssertEqual(phone.server.paths, [StubTransport.start, StubTransport.cancel])
    }

    // MARK: Cancel

    func testCancelBeforeStartTellsTheServerAndTheReaderNeverOpens() async {
        let phone = TestPhone()
        let reader = FakeCardReader(script: [.approve()])
        let coordinator = phone.coordinator(reader: reader)

        let cancelled = await coordinator.cancel(token: token)
        let started = await coordinator.start(token: token)

        XCTAssertEqual(cancelled, .reported)
        XCTAssertEqual(started, .reported)
        XCTAssertEqual(phone.server.paths, [StubTransport.cancel])
        XCTAssertEqual(phone.server.calls[0].body as NSDictionary, ["token": token, "device_id": TestPhone.deviceID])
        XCTAssertEqual(reader.requests.count, 0)
    }

    func testCancelWhileTheReaderIsOpenClosesItAndCallsCancel() async {
        let phone = TestPhone()
        phone.policy.readerTimeout = 30
        let reader = FakeCardReader(script: [.hang])
        let coordinator = phone.coordinator(reader: reader)

        async let started = coordinator.start(token: token)
        await reader.waitUntilReading()
        let cancelled = await coordinator.cancel(token: token)
        let state = await started

        XCTAssertNil(cancelled, "the start in flight answers the page")
        XCTAssertEqual(state, .reported)
        XCTAssertEqual(reader.cancelCount, 1)
        XCTAssertEqual(phone.server.paths, [StubTransport.start, StubTransport.cancel])
    }

    func testCancelAfterTheCardWasReadReportsTheResultInstead() async {
        let phone = TestPhone()
        phone.policy.readerTimeout = 30
        phone.policy.closeGrace = 5
        let reader = FakeCardReader(script: [.stuck])
        let coordinator = phone.coordinator(reader: reader)

        async let started = coordinator.start(token: token)
        await reader.waitUntilReading()
        async let cancelled = coordinator.cancel(token: token)
        await eventually("the reader was told to close") { reader.cancelCount == 1 }
        // Too late to stop: the reader had the card and answers with the approval.
        reader.finishStuck(with: SampleCard.approved)
        let (state, answer) = await (started, cancelled)

        XCTAssertEqual(state, .reported)
        XCTAssertNil(answer)
        XCTAssertEqual(phone.server.paths, [StubTransport.start, StubTransport.result], "a result, not a cancel")
        let sent = phone.server.calls[1].body["result"] as? [String: Any]
        XCTAssertEqual(sent?["status"] as? String, "approved")
    }

    func testALateResultAfterCancelIsStillReported() async {
        let phone = TestPhone()
        phone.policy.readerTimeout = 30
        let reader = FakeCardReader(script: [.stuck])
        let coordinator = phone.coordinator(reader: reader)

        async let started = coordinator.start(token: token)
        await reader.waitUntilReading()
        _ = await coordinator.cancel(token: token)
        let state = await started

        // The reader would not close, so the app cannot say "cancelled": it says it does not know.
        XCTAssertEqual(state, .reported)
        XCTAssertEqual(phone.server.paths, [StubTransport.start, StubTransport.result])
        XCTAssertEqual(phone.server.calls[1].body["result"] as? NSDictionary, ["status": "failed"])

        reader.finishStuck(with: SampleCard.approved)
        await eventually("the late result is reported") { phone.server.calls(to: StubTransport.result).count == 2 }
        let late = phone.server.calls(to: StubTransport.result).last?.body["result"] as? [String: Any]
        XCTAssertEqual(late?["status"] as? String, "approved")
        XCTAssertEqual(reader.requests.count, 1)
    }

    func testCancelWhileAskingTheServerOpensNoReader() async {
        let phone = TestPhone()
        phone.server.script(StubTransport.start, [.offline, .json(200, StubTransport.startAnswer())])
        phone.policy.retryDelays = [0.3]
        let reader = FakeCardReader(script: [.approve()])
        let coordinator = phone.coordinator(reader: reader)

        async let started = coordinator.start(token: token)
        await eventually("the first start was sent") { phone.server.calls(to: StubTransport.start).count == 1 }
        let cancelled = await coordinator.cancel(token: token)
        let state = await started

        XCTAssertNil(cancelled)
        XCTAssertEqual(state, .reported)
        XCTAssertEqual(reader.requests.count, 0)
        XCTAssertEqual(phone.server.paths.last, StubTransport.cancel)
    }

    // MARK: Unavailable

    func testTheFeatureOffOnTheServerIsUnavailableAndOpensNoReader() async {
        for status in [404, 403] {
            let phone = TestPhone()
            phone.server.script(StubTransport.start, [.json(status, ["error": "No such payment."])])
            let reader = FakeCardReader(script: [.approve()])

            let state = await phone.coordinator(reader: reader).start(token: token)

            XCTAssertEqual(state, .unavailable, "\(status)")
            XCTAssertEqual(reader.requests.count, 0)
            XCTAssertEqual(phone.server.paths, [StubTransport.start], "asked once, not again")
            XCTAssertNil(phone.phase())
        }
    }

    func testARefusedStartOpensNoReader() async {
        let phone = TestPhone()
        phone.server.script(StubTransport.start, [.json(422, ["error": "This payment request expired."])])
        let reader = FakeCardReader(script: [.approve()])

        let state = await phone.coordinator(reader: reader).start(token: token)

        XCTAssertEqual(state, .unreported)
        XCTAssertEqual(reader.requests.count, 0)
    }

    func testASignInPageInPlaceOfAnAnswerOpensNoReader() async {
        let answers: [StubTransport.Answer] = [.text(200, "<html>Sign in</html>"), .json(302, [:]),
                                               .json(200, ["reference": "RR1", "amount_cents": 0, "currency": "USD", "expires_at": "2099-01-01T00:00:00Z"]),
                                               .json(200, ["reference": "RR1", "amount_cents": true, "currency": "USD", "expires_at": "2099-01-01T00:00:00Z"]),
                                               .json(200, ["reference": "RR1", "amount_cents": 11.5, "currency": "USD", "expires_at": "2099-01-01T00:00:00Z"]),
                                               .json(200, ["reference": "RR1", "amount_cents": "1166", "currency": "USD", "expires_at": "2099-01-01T00:00:00Z"]),
                                               .json(200, ["reference": "RR1", "amount_cents": 1166, "currency": "USD"]),
                                               .json(200, ["amount_cents": 1166, "currency": "USD", "expires_at": "2099-01-01T00:00:00Z"])]
        for (index, answer) in answers.enumerated() {
            let phone = TestPhone()
            phone.server.script(StubTransport.start, [answer])
            let reader = FakeCardReader(script: [.approve()])
            let state = await phone.coordinator(reader: reader).start(token: token)
            XCTAssertNotEqual(state, .reported, "answer \(index)")
            XCTAssertEqual(reader.requests.count, 0, "answer \(index)")
        }
    }

    func testAPhoneThatCannotReadCardsSaysUnavailableAndReleasesTheAttempt() async {
        let reasons: [CardReaderUnavailableReason] = [.unsupportedDevice, .region, .featureOff, .notConfigured]
        for reason in reasons {
            let phone = TestPhone()
            let reader = FakeCardReader(script: [.approve()], availability: .unavailable(reason))
            let coordinator = phone.coordinator(reader: reader)

            let state = await coordinator.start(token: token)

            XCTAssertEqual(state, .unavailable, reason.rawValue)
            XCTAssertEqual(phone.server.paths, [StubTransport.cancel], "never asked what to charge")
            XCTAssertEqual(reader.requests.count, 0)
            let availability = await coordinator.availability()
            XCTAssertEqual(availability, .unavailable(reason))
        }
    }

    func testAnIPadSaysUnavailableWhateverTheReaderSays() async {
        let phone = TestPhone()
        let reader = FakeCardReader(script: [.approve()])
        let coordinator = phone.coordinator(reader: reader, isPad: true)

        let state = await coordinator.start(token: token)

        XCTAssertEqual(state, .unavailable)
        XCTAssertEqual(reader.requests.count, 0)
        XCTAssertEqual(phone.server.paths, [StubTransport.cancel])
        let availability = await coordinator.availability()
        XCTAssertEqual(availability, .unavailable(.iPad))
    }

    func testABuildWithoutAReaderSaysUnavailableEvenWhenTheServerIsOff() async {
        // A shipped build against production: no reader in the app, and the routes answer 404.
        let phone = TestPhone()
        phone.server.script(StubTransport.cancel, [.json(404, [:])])

        let state = await phone.coordinator(reader: UnavailableCardReader()).start(token: token)

        XCTAssertEqual(state, .unavailable)
        XCTAssertEqual(phone.server.paths, [StubTransport.cancel])
        XCTAssertNil(phone.phase(), "nothing saved")
    }

    // MARK: What is written down

    func testNothingAboutTheCardIsLoggedOrSaved() async {
        let phone = TestPhone()
        phone.server.script(StubTransport.result, [.offline, .json(200, ["status": "unknown", "reported": true])])
        let reader = FakeCardReader(script: [.finish(SampleCard.approved)])
        let coordinator = phone.coordinator(reader: reader)
        var saved: [String] = []

        async let started = coordinator.start(token: token)
        await reader.waitUntilReading()
        saved.append(phone.savedText)
        _ = await started
        saved.append(phone.savedText)
        _ = await coordinator.start(token: TestPhone.otherToken)
        _ = await coordinator.cancel(token: token)
        _ = await coordinator.recover()

        XCTAssertFalse(phone.log.lines.isEmpty)
        for line in phone.log.lines {
            XCTAssertNotNil(line.range(of: "^[A-Za-z]+( \\([0-9]{3}\\))?$", options: .regularExpression), "a fixed word and at most an HTTP status: \(line)")
            XCTAssertFalse(line.contains(token))
            for secret in SampleCard.secrets + ["RR0123456789abcdef01234567", TestPhone.deviceID] {
                XCTAssertFalse(line.contains(secret), line)
            }
            XCTAssertNil(line.range(of: "[0-9]{4,}", options: .regularExpression), "no run of digits: \(line)")
        }

        // On disk: the token, the phase, the outcome word, three times and one flag. For a token
        // that was let go, a digest of it and the word the page was told. Nothing else.
        for text in saved {
            let contents = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: [String: [String: Any]]]
            XCTAssertNotNil(contents)
            XCTAssertTrue(Set((contents ?? [:]).keys).isSubset(of: ["records", "forgotten"]))
            for (key, record) in contents?["records"] ?? [:] {
                XCTAssertEqual(key, record["token"] as? String)
                XCTAssertTrue(Set(record.keys).isSubset(of: ["token", "phase", "outcome", "firstSeen", "startedAt", "reportedAt", "watching"]), "\(record.keys)")
                XCTAssertTrue(["claiming", "reading", "reporting", "reported", "closed"].contains(record["phase"] as? String ?? ""))
                if let outcome = record["outcome"] { XCTAssertTrue(["approved", "declined", "cancelled", "failed", "timedOut"].contains(outcome as? String ?? "")) }
                for time in ["firstSeen", "startedAt", "reportedAt"] where record[time] != nil { XCTAssertTrue(record[time] is NSNumber) }
            }
            for (key, entry) in contents?["forgotten"] ?? [:] {
                XCTAssertNotNil(key.range(of: "\\A[0-9a-f]{64}\\z", options: .regularExpression))
                XCTAssertNotEqual(key, token)
                XCTAssertEqual(Set(entry.keys), ["state", "at"])
                XCTAssertTrue(["reported", "unreported"].contains(entry["state"] as? String ?? ""))
            }
            for secret in ["TXN-77aa88bb", "Mastercard", "Z9Y8X7", "contactless", "RR0123456789abcdef01234567"] {
                XCTAssertFalse(text.contains(secret))
            }
        }
    }
}
