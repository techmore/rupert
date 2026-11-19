import XCTest
@testable import Rupert

/// Reading the server-confirmed outcome: the status call, the pace, when it stops, and what may
/// be said. Time is a test clock: nothing here waits on the real one.
final class ReaderStatusWatcherTests: XCTestCase {
    private let token = TestPhone.token
    private let status = StubTransport.status

    /// Lets other tasks run until `condition` holds. No clock is involved.
    private func until(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
        let giveUp = Date().addingTimeInterval(10)
        while !(await condition()) {
            if Date() > giveUp {
                XCTFail("Never happened: \(what)", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }

    /// Lets everything that can run, run; then says how many status requests were made.
    private func requests(_ phone: TestPhone, afterSettling watcher: ReaderStatusWatcher) async -> Int {
        for _ in 0..<2000 { await Task.yield() }
        return phone.server.calls(to: status).count
    }

    private func answers(_ phone: TestPhone, _ list: [[String: Any]]) {
        phone.server.script(status, list.map { .json(200, $0) })
    }

    // MARK: The call

    func testTheStatusCallSendsTheTokenAndInstallIdentifierAndNothingElse() async {
        let phone = TestPhone()
        _ = await phone.client.status(token: token, deviceID: TestPhone.deviceID)

        let call = phone.server.calls[0]
        XCTAssertEqual(call.path, "/native/reader_attempts/status")
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.query, nil, "the token is never in a URL")
        XCTAssertEqual(call.body as NSDictionary, ["token": token, "device_id": TestPhone.deviceID])
        XCTAssertNotNil(UUID(uuidString: TestPhone.deviceID))
    }

    func testAStatusAnswerIsFiveFields() async {
        let phone = TestPhone()
        answers(phone, [StubTransport.statusAnswer("paid")])
        let paid = await phone.client.status(token: token, deviceID: TestPhone.deviceID)
        XCTAssertEqual(paid, .success(ReaderAttemptStatus(status: .paid, reported: true, needsReview: false, message: nil, amountCents: 1166)))

        answers(phone, [StubTransport.statusAnswer("unknown", needsReview: true, message: "A manager must check this payment.")])
        let held = await phone.client.status(token: token, deviceID: TestPhone.deviceID)
        XCTAssertEqual(held, .success(ReaderAttemptStatus(status: .unknown, reported: true, needsReview: true,
                                                          message: "A manager must check this payment.", amountCents: 1166)))

        for word in ["submitting", "unknown", "paid", "declined"] {
            answers(phone, [StubTransport.statusAnswer(word, reported: false)])
            let answer = try? await phone.client.status(token: token, deviceID: TestPhone.deviceID).get()
            XCTAssertEqual(answer?.status.rawValue, word)
            XCTAssertEqual(answer?.reported, false)
        }

        // Anything else in the answer is not read: the type has nowhere to put it.
        var extra = StubTransport.statusAnswer("declined", message: "Declined.")
        extra["card_brand"] = "Visa"
        extra["last_four"] = "0002"
        extra["reference"] = "RR1"
        extra["checkout"] = ["id": 7]
        answers(phone, [extra])
        let answer = try? await phone.client.status(token: token, deviceID: TestPhone.deviceID).get()
        XCTAssertEqual(answer, ReaderAttemptStatus(status: .declined, reported: true, needsReview: false, message: "Declined.", amountCents: 1166))
        XCTAssertEqual(Set(answer.map { Mirror(reflecting: $0).children.compactMap(\.label) } ?? []),
                       ["status", "reported", "needsReview", "message", "amountCents"])
    }

    func testAStatusAnswerInAnotherFormIsNotAnAnswer() async {
        var missingMessage = StubTransport.statusAnswer("paid")
        missingMessage["message"] = nil
        var wordForFlag = StubTransport.statusAnswer("paid")
        wordForFlag["reported"] = "true"
        var numberForFlag = StubTransport.statusAnswer("paid")
        numberForFlag["needs_review"] = 0
        var numberForMessage = StubTransport.statusAnswer("paid")
        numberForMessage["message"] = 5
        var textAmount = StubTransport.statusAnswer("paid")
        textAmount["amount_cents"] = "1166"
        let bad: [[String: Any]] = [StubTransport.statusAnswer("approved"), StubTransport.statusAnswer("PAID"), missingMessage, wordForFlag,
                                    numberForFlag, numberForMessage, textAmount, [:]]
        for (index, body) in bad.enumerated() {
            let phone = TestPhone()
            answers(phone, [body])
            let answer = await phone.client.status(token: token, deviceID: TestPhone.deviceID)
            XCTAssertEqual(answer, .failure(.malformed), "answer \(index)")
        }

        let failures: [(StubTransport.Answer, ReaderAPIFailure)] = [
            (.json(403, ["error": "This payment was started on another device."]), .status(403)), (.text(404, ""), .status(404)),
            (.json(422, ["error": "x"]), .status(422)), (.json(503, [:]), .status(503)), (.json(302, [:]), .status(302)),
            (.text(200, "<html>Sign in</html>"), .malformed), (.offline, .network),
        ]
        for (given, expected) in failures {
            let phone = TestPhone()
            phone.server.script(status, [given])
            let answer = await phone.client.status(token: token, deviceID: TestPhone.deviceID)
            XCTAssertEqual(answer, .failure(expected))
        }
    }

    // MARK: What may be said

    func testOnlyAPaidStatusSaysPaid() {
        func said(_ status: ReaderAttemptStatus.Status, review: Bool = false, message: String? = nil) -> ReaderConfirmation {
            ReaderConfirmation(ReaderAttemptStatus(status: status, reported: true, needsReview: review, message: message, amountCents: 1166))
        }
        XCTAssertEqual(said(.paid), .paid)
        XCTAssertEqual(said(.submitting), .checking)
        XCTAssertEqual(said(.unknown), .checking, "reported and awaiting the lookup is checking, never approved")
        XCTAssertEqual(said(.declined, message: "The card was declined on the phone."), .declined(message: "The card was declined on the phone."))
        XCTAssertEqual(said(.unknown, review: true, message: "Hold."), .held(message: "Hold."))
        XCTAssertEqual(said(.declined, review: true, message: "Hold."), .held(message: "Hold."), "a closed attempt marked for a manager")

        XCTAssertNil(ReaderConfirmation.checking.notice)
        XCTAssertEqual(ReaderConfirmation.paid.notice?.title, "Card payment confirmed")
        XCTAssertEqual(ReaderConfirmation.held(message: "Hold.").notice?.message, "Hold.")
        XCTAssertEqual(ReaderConfirmation.declined(message: "No.").notice?.message, "No.")
        XCTAssertNotNil(ReaderConfirmation.held(message: nil).notice?.message)
        for confirmation in [ReaderConfirmation.checking, .held(message: nil), .declined(message: nil)] {
            let words = "\(confirmation.notice?.title ?? "") \(confirmation.notice?.message ?? "")".lowercased()
            XCTAssertFalse(words.contains("approved"))
            XCTAssertFalse(words.contains("paid"))
        }
    }

    func testAnApprovalOnThePhoneIsCheckingUntilTheServerConfirmsIt() async {
        let phone = TestPhone()
        // Even a report answer that says "paid" shows nothing: only the status route does.
        phone.server.script(StubTransport.result, [.json(200, ["status": "paid", "reported": true])])
        answers(phone, [StubTransport.statusAnswer("unknown"), StubTransport.statusAnswer("unknown"), StubTransport.statusAnswer("paid")])
        let watcher = phone.watcher()
        let reader = FakeCardReader(script: [.finish(SampleCard.approved)])

        let state = await phone.coordinator(reader: reader, watcher: watcher).start(token: token)

        XCTAssertEqual(state, .reported)
        await phone.clock.waitForSleeps(1)
        XCTAssertEqual(phone.server.paths, [StubTransport.start, StubTransport.result, status], "status is read only after the report")
        XCTAssertEqual(phone.said.all, [.checking], "the reader said approved; the app says checking")
        XCTAssertEqual(phone.clock.sleeps, [2])

        phone.clock.advance(by: 2)
        await phone.clock.waitForSleeps(2)
        XCTAssertEqual(phone.said.all, [.checking])
        phone.clock.advance(by: 2)
        await until("the token is let go") { await !watcher.isWatching(self.token) }

        XCTAssertEqual(phone.said.all, [.checking, .paid])
        XCTAssertEqual(phone.said.afterRelaunch, [false, false])
        XCTAssertEqual(phone.server.calls(to: status).count, 3)
        XCTAssertNil(phone.store.record(for: token), "forgotten once paid")
        XCTAssertEqual(phone.store.forgottenState(for: token), .reported)
        XCTAssertEqual(reader.requests.count, 1)
    }

    // MARK: The pace

    func testTwoSecondsForThirtySecondsThenTenUntilTenMinutesAfterStart() async {
        let phone = TestPhone()
        answers(phone, [StubTransport.statusAnswer("unknown")])
        phone.hold(startedAgo: 5, reportedAgo: 0)
        let watcher = phone.watcher()
        let began = phone.clock.now

        await watcher.watch(token: token)
        var readAt: [TimeInterval] = []
        while true {
            let count = readAt.count + 1
            await until("request \(count) or the end") {
                phone.clock.sleeps.count >= count ? true : await !watcher.isWatching(self.token)
            }
            guard phone.clock.sleeps.count >= count else { break }
            readAt.append(phone.clock.now.timeIntervalSince(began))
            XCTAssertEqual(phone.server.calls(to: status).count, count, "one request before each wait")
            phone.clock.advance(by: phone.clock.sleeps[count - 1])
        }

        let fast = stride(from: 0.0, through: 28, by: 2).map { $0 }
        let slow = stride(from: 30.0, through: 590, by: 10).map { $0 }
        XCTAssertEqual(readAt, fast + slow)
        XCTAssertEqual(phone.clock.sleeps, Array(repeating: 2, count: 15) + Array(repeating: 10, count: 57))
        XCTAssertEqual(phone.server.calls(to: status).count, 72)
        XCTAssertLessThan(readAt.last ?? .infinity, ReaderStatusWatcher.limit - 5, "no request ten minutes after start")

        // Stopped, not forgotten: more time brings no more requests.
        phone.clock.advance(by: 3600)
        let after = await requests(phone, afterSettling: watcher)
        XCTAssertEqual(after, 72)
        XCTAssertNotNil(phone.store.record(for: token))
        XCTAssertEqual(phone.said.all, [.checking], "said once, not at every answer")
        XCTAssertEqual(phone.server.mostAtOnce(status), 1)
    }

    func testWithoutAReportOnRecordThePaceIsTheSlowOne() async {
        let phone = TestPhone()
        phone.hold(startedAgo: 5, reportedAgo: nil)
        let watcher = phone.watcher()

        await watcher.watch(token: token)
        await phone.clock.waitForSleeps(1)

        XCTAssertEqual(phone.clock.sleeps, [10])
    }

    func testATokenWhoseStartNeverSucceededIsNeverAskedAbout() async {
        let phone = TestPhone()
        phone.store.save(ReaderAttemptRecord(token: token, phase: .claiming, firstSeen: Date()))
        let watcher = phone.watcher()

        await watcher.watch(token: token)
        await watcher.watch(token: TestPhone.otherToken)
        await watcher.resume()

        let made = await requests(phone, afterSettling: watcher)
        XCTAssertEqual(made, 0)
    }

    // MARK: When it stops

    func testPaidAndDeclinedStopAndForgetTheToken() async {
        let cases: [([String: Any], ReaderConfirmation)] = [
            (StubTransport.statusAnswer("paid"), .paid),
            (StubTransport.statusAnswer("declined", message: "The card was declined on the phone."), .declined(message: "The card was declined on the phone.")),
        ]
        for (answer, expected) in cases {
            let phone = TestPhone()
            answers(phone, [StubTransport.statusAnswer("unknown"), answer])
            phone.hold()
            let watcher = phone.watcher()

            await watcher.watch(token: token)
            await phone.clock.waitForSleeps(1)
            phone.clock.advance(by: 2)
            await until("stopped") { await !watcher.isWatching(self.token) }

            XCTAssertEqual(phone.said.all, [.checking, expected])
            XCTAssertNil(phone.store.record(for: token))
            XCTAssertEqual(phone.clock.sleeps, [2])
            phone.clock.advance(by: 600)
            await watcher.resume()
            let made = await requests(phone, afterSettling: watcher)
            XCTAssertEqual(made, 2, "never asked about again")
        }
    }

    func testHeldForAManagerStopsAndShowsTheHoldMessage() async {
        let phone = TestPhone()
        answers(phone, [StubTransport.statusAnswer("unknown", needsReview: true, message: "Do not charge again; a manager must check it.")])
        phone.hold()
        let watcher = phone.watcher()

        await watcher.watch(token: token)
        await until("stopped") { await !watcher.isWatching(self.token) }

        XCTAssertEqual(phone.said.all, [.held(message: "Do not charge again; a manager must check it.")])
        XCTAssertEqual(phone.said.all.first?.notice?.title, "Card payment needs a manager")
        XCTAssertEqual(phone.said.all.first?.notice?.message, "Do not charge again; a manager must check it.")
        XCTAssertEqual(phone.clock.sleeps, [], "no wait and no second request")
        phone.clock.advance(by: 600)
        let made = await requests(phone, afterSettling: watcher)
        XCTAssertEqual(made, 1)
        XCTAssertNotNil(phone.store.record(for: token), "kept: a manager may release it, and the next return reads it once")
    }

    func testRefusedOrUnknownStopsForGoodAndForgetsTheToken() async {
        for code in [403, 404] {
            let phone = TestPhone()
            phone.server.script(status, [.text(code, "")])
            phone.hold()
            let watcher = phone.watcher()

            await watcher.watch(token: token)
            await until("stopped") { await !watcher.isWatching(self.token) }

            XCTAssertNil(phone.store.record(for: token), "\(code)")
            XCTAssertEqual(phone.said.all, [])
            XCTAssertEqual(phone.clock.sleeps, [], "never retried")
            phone.clock.advance(by: 60)
            await watcher.resume()
            await watcher.watch(token: token)
            let made = await requests(phone, afterSettling: watcher)
            XCTAssertEqual(made, 1, "\(code)")
            XCTAssertTrue(phone.log.lines.contains("statusRefused (\(code))"))
        }
    }

    func testAServerErrorNoNetworkOrARefusedFormIsTriedAgainAtTheSlowPace() async {
        let phone = TestPhone()
        phone.server.script(status, [.json(422, ["error": "x"]), .json(500, [:]), .json(503, [:]), .offline, .text(200, "<html>"),
                                     .json(200, StubTransport.statusAnswer("unknown")), .json(200, StubTransport.statusAnswer("paid"))])
        phone.hold(startedAgo: 1, reportedAgo: 0) // well inside the first thirty seconds
        let watcher = phone.watcher()

        await watcher.watch(token: token)
        for step in 1...6 {
            await phone.clock.waitForSleeps(step)
            XCTAssertEqual(phone.server.calls(to: status).count, step)
            phone.clock.advance(by: phone.clock.sleeps[step - 1])
        }
        await until("stopped") { await !watcher.isWatching(self.token) }

        XCTAssertEqual(phone.clock.sleeps, [10, 10, 10, 10, 10, 10], "five failures at the slow pace; then past thirty seconds anyway")
        XCTAssertEqual(phone.said.all, [.checking, .paid])
        XCTAssertNotNil(phone.store.forgottenState(for: token))
    }

    // MARK: One at a time, and not in the background

    func testThereIsNeverASecondRequestForATokenWhileOneIsOut() async {
        let phone = TestPhone()
        answers(phone, [StubTransport.statusAnswer("unknown")])
        phone.hold()
        phone.hold(TestPhone.otherToken)
        let watcher = phone.watcher()
        phone.server.hold(status)

        await watcher.watch(token: token)
        await until("the request is out") { phone.server.calls(to: self.status).count == 1 }
        for _ in 0..<5 {
            await watcher.watch(token: token)
            await watcher.resume(except: [TestPhone.otherToken])
            await watcher.pause()
            await watcher.resume(except: [TestPhone.otherToken])
        }
        let whileOut = await requests(phone, afterSettling: watcher)
        XCTAssertEqual(whileOut, 1, "everything else waits for the answer")

        // Another token is another matter.
        await watcher.watch(token: TestPhone.otherToken)
        await until("the other token's request is out") { phone.server.calls(to: self.status).count == 2 }
        XCTAssertEqual(Set(phone.server.calls(to: status).map { $0.body["token"] as? String }), [token, TestPhone.otherToken])

        phone.server.release(status)
        await phone.clock.waitForSleeps(2)
        XCTAssertEqual(phone.server.calls(to: status).count, 2)
        XCTAssertEqual(phone.clock.sleeps, [2, 2], "the one loop per token carried on")
    }

    func testNothingIsReadInTheBackgroundAndOneReadFollowsTheReturn() async {
        let phone = TestPhone()
        answers(phone, [StubTransport.statusAnswer("unknown")])
        phone.hold()
        let watcher = phone.watcher()

        await watcher.watch(token: token)
        await phone.clock.waitForSleeps(1)
        XCTAssertEqual(phone.server.calls(to: status).count, 1)

        await watcher.pause()
        phone.clock.advance(by: 2)
        await until("the loop ended") { await !watcher.isWatching(self.token) }
        phone.clock.advance(by: 120)
        let inBackground = await requests(phone, afterSettling: watcher)
        XCTAssertEqual(inBackground, 1, "no request while in the background")
        await watcher.watch(token: token)
        let stillNone = await requests(phone, afterSettling: watcher)
        XCTAssertEqual(stillNone, 1)

        await watcher.resume()
        await phone.clock.waitForSleeps(2)
        XCTAssertEqual(phone.server.calls(to: status).count, 2, "one read on return, at once")
        XCTAssertEqual(phone.clock.sleeps, [2, 10], "then the usual pace: thirty seconds have passed")
        XCTAssertNotNil(phone.store.record(for: token))
    }

    func testARequestThatWasOutWhenTheAppLeftIsNotFollowedByAnother() async {
        let phone = TestPhone()
        answers(phone, [StubTransport.statusAnswer("unknown")])
        phone.hold()
        let watcher = phone.watcher()
        phone.server.hold(status)

        await watcher.watch(token: token)
        await until("the request is out") { phone.server.calls(to: self.status).count == 1 }
        await watcher.pause()
        phone.server.release(status)
        await until("the loop ended") { await !watcher.isWatching(self.token) }

        XCTAssertEqual(phone.clock.sleeps, [])
        XCTAssertEqual(phone.said.all, [], "an answer that arrives in the background is not used")
        await watcher.resume()
        await phone.clock.waitForSleeps(1)
        XCTAssertEqual(phone.server.calls(to: status).count, 2)
    }

    func testReturningWithoutHavingLeftAsksAtOnceAndKeepsOneLoop() async {
        let phone = TestPhone()
        answers(phone, [StubTransport.statusAnswer("unknown")])
        phone.hold(reportedAgo: 60)
        let watcher = phone.watcher()

        await watcher.watch(token: token)
        await phone.clock.waitForSleeps(1)
        await watcher.resume()
        await phone.clock.waitForSleeps(2)
        XCTAssertEqual(phone.server.calls(to: status).count, 2)

        // The replaced loop's wait ends and does nothing; the live one asks again.
        phone.clock.advance(by: 10)
        await phone.clock.waitForSleeps(3)
        let made = await requests(phone, afterSettling: watcher)
        XCTAssertEqual(made, 3)
        XCTAssertEqual(phone.server.mostAtOnce(status), 1)
    }

    // MARK: After a relaunch

    func testAfterARelaunchEachHeldTokenIsReadOnceAndTheReaderStaysShut() async {
        let phone = TestPhone()
        answers(phone, [StubTransport.statusAnswer("unknown")])
        // Killed while the reader was open, and an earlier payment still awaiting confirmation.
        phone.hold(phase: .reading, startedAgo: 20, reportedAgo: nil)
        phone.hold(TestPhone.otherToken, phase: .reported, startedAgo: 90, reportedAgo: 80)
        let watcher = phone.watcher()
        let reader = FakeCardReader(script: [.approve()])

        let settled = await phone.coordinator(reader: reader, watcher: watcher).recover(afterLaunch: true)
        await phone.clock.waitForSleeps(2)

        XCTAssertEqual(settled.map(\.token), [token])
        XCTAssertEqual(settled.map(\.state), [.reported], "the server already had a report")
        XCTAssertEqual(reader.requests.count, 0, "the reader is never run again for a held token")
        XCTAssertEqual(phone.server.paths.sorted(), [status, status], "one status read per token, and nothing else sent")
        XCTAssertEqual(Set(phone.server.calls.map { $0.body["token"] as? String }), [token, TestPhone.otherToken])
        XCTAssertEqual(phone.said.all, [.checking, .checking])
        XCTAssertEqual(phone.said.afterRelaunch, [true, true])
        XCTAssertEqual(phone.clock.sleeps, [10, 10], "then the same rules")
        XCTAssertEqual(phone.phase(), .reported)

        phone.clock.advance(by: 10)
        await phone.clock.waitForSleeps(4)
        XCTAssertEqual(phone.server.calls(to: status).count, 4)
    }

    func testAfterAKillMidReadWithNothingOnFileTheAppReadsStatusThenSaysItDoesNotKnow() async {
        let phone = TestPhone()
        phone.hold(phase: .reading, startedAgo: 20, reportedAgo: nil)
        let watcher = phone.watcher()
        let reader = FakeCardReader(script: [.approve()])

        let settled = await phone.coordinator(reader: reader, watcher: watcher).recover(afterLaunch: true)
        await phone.clock.waitForSleeps(1)

        XCTAssertEqual(settled.map(\.state), [.reported])
        XCTAssertEqual(phone.server.paths, [status, StubTransport.result], "status first; then the report; no second status yet")
        XCTAssertEqual(phone.server.calls[1].body["result"] as? NSDictionary, ["status": "failed"])
        XCTAssertEqual(reader.requests.count, 0)
        XCTAssertEqual(phone.said.all, [.checking])
        XCTAssertEqual(phone.clock.sleeps, [2], "just reported: the fast pace")
    }

    func testAfterARelaunchAConfirmedOutcomeIsShownAndTheTokenForgotten() async {
        let cases: [([String: Any], ReaderConfirmation, ReaderPageState)] = [
            (StubTransport.statusAnswer("paid", reported: false), .paid, .unreported),
            (StubTransport.statusAnswer("declined", reported: true, message: "Nothing was charged."), .declined(message: "Nothing was charged."), .reported),
        ]
        for (answer, expected, state) in cases {
            let phone = TestPhone()
            answers(phone, [answer])
            phone.hold(phase: .reading, startedAgo: 200, reportedAgo: nil)
            let watcher = phone.watcher()
            let reader = FakeCardReader(script: [.approve()])
            let coordinator = phone.coordinator(reader: reader, watcher: watcher)

            let settled = await coordinator.recover(afterLaunch: true)
            await until("forgotten") { phone.store.record(for: self.token) == nil }

            XCTAssertEqual(settled.map(\.state), [state])
            XCTAssertEqual(phone.server.paths, [status], "one read; no report is needed")
            XCTAssertEqual(phone.said.all, [expected])
            XCTAssertEqual(phone.said.afterRelaunch, [true])
            XCTAssertEqual(reader.requests.count, 0)
            XCTAssertEqual(phone.clock.sleeps, [])

            // The page, reloaded, posts the token again: still no reader, and no request.
            let again = await coordinator.start(token: token)
            XCTAssertEqual(again, state)
            XCTAssertEqual(reader.requests.count, 0)
            XCTAssertEqual(phone.server.paths, [status])
        }
    }

    func testAfterARelaunchARefusalForgetsTheTokenAndSendsNothing() async {
        for code in [403, 404] {
            let phone = TestPhone()
            phone.server.script(status, [.text(code, "")])
            phone.hold(phase: .reading, startedAgo: 20, reportedAgo: nil)
            let watcher = phone.watcher()
            let reader = FakeCardReader(script: [.approve()])
            let coordinator = phone.coordinator(reader: reader, watcher: watcher)

            let settled = await coordinator.recover(afterLaunch: true)
            _ = await coordinator.recover()
            let made = await requests(phone, afterSettling: watcher)

            XCTAssertEqual(settled.map(\.state), [.unreported], "\(code)")
            XCTAssertEqual(made, 1, "never retried")
            XCTAssertEqual(phone.server.paths, [status], "no report and no cancel")
            XCTAssertNil(phone.store.record(for: token))
            XCTAssertEqual(reader.requests.count, 0)
            let again = await coordinator.start(token: token)
            XCTAssertEqual(again, .unreported)
            XCTAssertEqual(reader.requests.count, 0, "forgotten, but the reader still never opens for it")
        }
    }

    func testAnOldHeldTokenIsReadOnceOnReturnAndThenLeftAlone() async {
        let phone = TestPhone()
        answers(phone, [StubTransport.statusAnswer("unknown")])
        phone.hold(startedAgo: 3600, reportedAgo: 3590)
        let watcher = phone.watcher()

        await watcher.resume(afterRelaunch: true)
        await until("stopped") { await !watcher.isWatching(self.token) }

        XCTAssertEqual(phone.server.calls(to: status).count, 1)
        XCTAssertEqual(phone.clock.sleeps, [], "past ten minutes after start: one read and no more")
    }

    // MARK: Dropped fields, and what is kept

    func testAReportWithADroppedFieldIsStillAReport() async {
        let phone = TestPhone()
        phone.server.script(StubTransport.result, [.json(200, ["status": "unknown", "reported": true, "dropped": ["provider_reference", "auth_code"]])])
        let reader = FakeCardReader(script: [.finish(SampleCard.approved)])

        let state = await phone.coordinator(reader: reader).start(token: token)

        XCTAssertEqual(state, .reported)
        XCTAssertEqual(phone.server.calls(to: StubTransport.result).count, 1, "not sent again")
        XCTAssertEqual(phone.phase(), .reported)
        XCTAssertTrue(phone.log.lines.contains("fieldsDropped"))
        XCTAssertFalse(phone.log.lines.contains { $0.contains("provider_reference") || $0.contains("auth_code") })

        let ack = await phone.client.report(token: token, deviceID: TestPhone.deviceID, result: SampleCard.approved)
        XCTAssertEqual(ack, .success(ReaderAttemptAck(status: "unknown", reported: true, dropped: ["provider_reference", "auth_code"])))
        phone.server.script(StubTransport.result, [.json(200, ["status": "unknown", "reported": true, "dropped": "everything"])])
        let odd = await phone.client.report(token: token, deviceID: TestPhone.deviceID, result: SampleCard.approved)
        XCTAssertEqual(odd, .success(ReaderAttemptAck(status: "unknown", reported: true)))
    }

    func testNothingFromAStatusAnswerIsSavedOrLogged() async {
        let phone = TestPhone()
        var first = StubTransport.statusAnswer("unknown", amountCents: 73913)
        first["card_brand"] = "Mastercard"
        first["last_four"] = "4242"
        answers(phone, [first, StubTransport.statusAnswer("unknown", needsReview: true, message: "Cashier wording 73913.", amountCents: 73913)])
        phone.hold()
        let watcher = phone.watcher()

        await watcher.watch(token: token)
        await phone.clock.waitForSleeps(1)
        phone.clock.advance(by: 2)
        await until("stopped") { await !watcher.isWatching(self.token) }

        XCTAssertEqual(phone.said.all, [.checking, .held(message: "Cashier wording 73913.")])
        // On disk: the record's own seven fields, none of them from the answer.
        let saved = try? JSONSerialization.jsonObject(with: Data(phone.savedText.utf8)) as? [String: [String: [String: Any]]]
        XCTAssertEqual(Set(saved?["records"]?[token]?.keys.map { $0 } ?? []), ["token", "phase", "firstSeen", "startedAt", "reportedAt", "watching"])
        for word in ["Cashier", "Mastercard", "needs_review", "message", "amount", "unknown"] {
            XCTAssertFalse(phone.savedText.contains(word), word)
        }
        for line in phone.log.lines {
            for secret in ["73913", "Cashier", "Mastercard", "4242", "needs_review", "unknown"] {
                XCTAssertFalse(line.contains(secret), "\(secret) in \(line)")
            }
        }
        for line in phone.log.lines {
            XCTAssertNotNil(line.range(of: "\\A[A-Za-z]+( \\([0-9]{3}\\))?\\z", options: .regularExpression), line)
        }
    }
}
