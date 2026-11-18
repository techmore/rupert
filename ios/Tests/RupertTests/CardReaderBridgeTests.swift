import XCTest
@testable import Rupert

/// The `rupertReader` bridge: which messages and which pages the app listens to, and what it says back.
final class ReaderBridgeTests: XCTestCase {
    private let token = TestPhone.token

    func testTheTwoMessagesOfTheContract() {
        XCTAssertEqual(ReaderMessage(body: ["type": "start", "token": token]), .start(token: token))
        XCTAssertEqual(ReaderMessage(body: ["type": "cancel", "token": token]), .cancel(token: token))
        XCTAssertEqual(ReaderMessage(body: ["type": "start", "token": token] as NSDictionary)?.token, token)
    }

    func testMalformedMessagesAreRejected() {
        let bad: [Any] = [
            "start", 42, NSNull(), [token], [:] as [String: Any],
            ["type": "start"], ["token": token],
            ["type": "refund", "token": token], ["type": "START", "token": token], ["type": 1, "token": token],
            ["type": "start", "token": 12345], ["type": "start", "token": ""],
            ["type": "start", "token": String(token.dropLast())], ["type": "start", "token": token + "a"],
            ["type": "start", "token": token.uppercased()], ["type": "start", "token": String(repeating: "zz", count: 32)],
            ["type": "start", "token": token + "\n"], ["type": "start", "token": " " + token],
            // Anything beside the token: the page may not say what to charge or for what.
            ["type": "start", "token": token, "amount_cents": 100], ["type": "start", "token": token, "reference": "RR1"],
            ["type": "start", "token": token, "checkout_id": 7], ["type": "start", "token": token, "card": CardLike.number],
            ["type": "cancel", "token": token, "extra": true],
        ]
        for body in bad {
            XCTAssertNil(ReaderMessage(body: body), "\(body)")
        }
    }

    func testOnlyTheTopPageOfTheCurrentInstanceIsHeard() {
        let instance = URL(string: "https://shop.rupertpos.com")!
        XCTAssertTrue(ReaderBridge.accepts(isMainFrame: true, scheme: "https", host: "shop.rupertpos.com", port: 0, instance: instance))
        XCTAssertTrue(ReaderBridge.accepts(isMainFrame: true, scheme: "https", host: "Shop.RupertPOS.com", port: 443, instance: instance))

        // A frame inside the page, even one on the same site.
        XCTAssertFalse(ReaderBridge.accepts(isMainFrame: false, scheme: "https", host: "shop.rupertpos.com", port: 0, instance: instance))
        // Other sites, another Rupert workspace and look-alikes included.
        for host in ["evil.example", "other.rupertpos.com", "rupertpos.com", "shop.rupertpos.com.evil.example", "xshop.rupertpos.com", ""] {
            XCTAssertFalse(ReaderBridge.accepts(isMainFrame: true, scheme: "https", host: host, port: 0, instance: instance), host)
        }
        // Another scheme or port is another origin.
        XCTAssertFalse(ReaderBridge.accepts(isMainFrame: true, scheme: "http", host: "shop.rupertpos.com", port: 0, instance: instance))
        XCTAssertFalse(ReaderBridge.accepts(isMainFrame: true, scheme: "https", host: "shop.rupertpos.com", port: 8443, instance: instance))
        XCTAssertFalse(ReaderBridge.accepts(isMainFrame: true, scheme: "about", host: "", port: 0, instance: instance))
        XCTAssertFalse(ReaderBridge.accepts(isMainFrame: true, scheme: "file", host: "", port: 0, instance: instance))

        let local = URL(string: "http://127.0.0.1:3005")!
        XCTAssertTrue(ReaderBridge.accepts(isMainFrame: true, scheme: "http", host: "127.0.0.1", port: 3005, instance: local))
        XCTAssertFalse(ReaderBridge.accepts(isMainFrame: true, scheme: "http", host: "127.0.0.1", port: 3000, instance: local))
    }

    func testTheEventCarriesTheTokenAndOneWord() throws {
        for state in [ReaderPageState.reported, .unreported, .unavailable] {
            let script = ReaderBridge.eventScript(token: token, state: state)
            let prefix = "window.dispatchEvent(new CustomEvent(\"rupert:reader-result\", { detail: "
            XCTAssertTrue(script.hasPrefix(prefix))
            XCTAssertTrue(script.hasSuffix(" }))"))
            let json = String(script.dropFirst(prefix.count).dropLast(4))
            let detail = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
            XCTAssertEqual(detail, ["token": token, "state": state.rawValue])
        }
        XCTAssertEqual(ReaderBridge.handlerName, "rupertReader")
    }

    func testTheInstallIdentifierIsStableAndInTheServersForm() throws {
        let suite = "rupert.reader.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = InstallIdentifier.current(in: defaults)
        XCTAssertNotNil(first.range(of: "^[A-Za-z0-9-]{16,64}$", options: .regularExpression))
        XCTAssertEqual(InstallIdentifier.current(in: defaults), first)

        defaults.set("short", forKey: InstallIdentifier.key)
        XCTAssertNotEqual(InstallIdentifier.current(in: defaults), "short")

        // The server refuses a request with anything shaped like a card number, an identifier included.
        XCTAssertFalse(InstallIdentifier.isUsable("a1b2c3d4-" + CardLike.grouped + "11111111"))
        XCTAssertFalse(InstallIdentifier.isUsable("abcdefab-cdef-4abc-8def-123456789012"))
        XCTAssertTrue(InstallIdentifier.isUsable(TestPhone.deviceID))
        defaults.set("abcdefab-cdef-4abc-8def-123456789012", forKey: InstallIdentifier.key)
        XCTAssertTrue(InstallIdentifier.isUsable(InstallIdentifier.current(in: defaults)))
    }
}

/// What may leave the reader: an outcome and six facts, in the server's accepted forms.
final class CardReadResultTests: XCTestCase {
    /// The fields of a report the server keeps (REPORT_KEYS in Pos::DeviceReaderPayment).
    private let accepted: Set<String> = ["status", "provider_reference", "amount_cents", "card_brand", "last_four", "entry_method", "auth_code"]

    func testAResultHasTheWhitelistedFieldsAndNoOthers() {
        let fields = Set(Mirror(reflecting: SampleCard.approved).children.compactMap(\.label))
        XCTAssertEqual(fields, ["status", "providerReference", "amountCents", "cardBrand", "lastFour", "entryMethod", "approvalCode"])
        XCTAssertEqual(Set(SampleCard.approved.reportFields.keys), accepted)
        XCTAssertEqual(CardReadResult.Status.allCases.map(\.rawValue), ["approved", "declined", "cancelled", "failed", "timedOut"])
        XCTAssertEqual(CardBrand.allCases.map(\.rawValue), ["Visa", "Mastercard", "Amex", "Discover", "JCB"])
        XCTAssertEqual(CardEntryMethod.allCases.map(\.rawValue), ["contactless", "chip", "swipe", "manual"])
    }

    func testARequestToAReaderCarriesOnlyWhatTheServerSaid() {
        let request = CardReadRequest(reference: "RR1", amountCents: 1, tipCents: 0, currency: "USD", expiresAt: Date(), providerParameters: [:])
        XCTAssertEqual(Set(Mirror(reflecting: request).children.compactMap(\.label)),
                       ["reference", "amountCents", "tipCents", "currency", "expiresAt", "providerParameters"])
    }

    func testValuesOutsideTheAcceptedFormAreDropped() {
        // A careless reader that puts card data where it does not belong.
        let careless = CardReadResult(status: .approved, providerReference: CardLike.number, amountCents: 1166, cardBrand: .visa,
                                      lastFour: CardLike.number, entryMethod: .chip, approvalCode: String(CardLike.number.prefix(12)))
        XCTAssertNil(careless.providerReference)
        XCTAssertNil(careless.lastFour)
        XCTAssertNil(careless.approvalCode)
        XCTAssertEqual(Set(careless.reportFields.keys), ["status", "amount_cents", "card_brand", "entry_method"])

        XCTAssertNil(CardReadResult(status: .approved, providerReference: "ref " + CardLike.grouped).providerReference)
        XCTAssertNil(CardReadResult(status: .approved, providerReference: "TXN-" + CardLike.number).providerReference)
        XCTAssertNil(CardReadResult(status: .approved, providerReference: String(repeating: "a", count: 41)).providerReference)
        XCTAssertNil(CardReadResult(status: .approved, lastFour: "123").lastFour)
        XCTAssertNil(CardReadResult(status: .approved, lastFour: "12a4").lastFour)
        XCTAssertNil(CardReadResult(status: .approved, lastFour: "١٢٣٤").lastFour)
        XCTAssertNil(CardReadResult(status: .approved, lastFour: "1234\n").lastFour)
        XCTAssertNil(CardReadResult(status: .approved, approvalCode: "A1 B2").approvalCode)
        XCTAssertNil(CardReadResult(status: .approved, approvalCode: CardLike.track2).approvalCode)
        XCTAssertNil(CardReadResult(status: .approved, amountCents: 0).amountCents)
        XCTAssertNil(CardReadResult(status: .approved, amountCents: -5).amountCents)
        XCTAssertNil(CardReadResult(status: .approved, amountCents: 10_000_000).amountCents)

        XCTAssertEqual(SampleCard.approved.providerReference, "TXN-77aa88bb")
        XCTAssertEqual(SampleCard.approved.statusOnly, CardReadResult(status: .approved))
    }

    func testNothingButTheWhitelistReachesTheServerFromACarelessReader() async {
        let phone = TestPhone()
        let careless = CardReadResult(status: .declined, providerReference: CardLike.other, amountCents: 1166, cardBrand: .mastercard,
                                      lastFour: CardLike.other, entryMethod: .swipe, approvalCode: CardLike.track1)
        _ = await phone.coordinator(reader: FakeCardReader(script: [.finish(careless)])).start(token: TestPhone.token)

        for call in phone.server.calls {
            XCTAssertNil(call.raw.range(of: "[0-9]{12,}", options: .regularExpression), "nothing shaped like a card number is sent")
            XCTAssertFalse(call.raw.contains(CardLike.other.prefix(4)))
        }
        let report = phone.server.calls(to: StubTransport.result)[0].body
        XCTAssertEqual(Set(report.keys), ["token", "device_id", "result"])
        XCTAssertTrue(Set((report["result"] as? [String: Any] ?? [:]).keys).isSubset(of: accepted))
    }

    func testNumbersInAnAnswerMustBeWholeNumbers() {
        XCTAssertEqual(ReaderAttemptClient.integer(1166), 1166)
        XCTAssertEqual(ReaderAttemptClient.integer(NSNumber(value: 1166.0)), 1166)
        XCTAssertNil(ReaderAttemptClient.integer(true))
        XCTAssertNil(ReaderAttemptClient.integer(11.66))
        XCTAssertNil(ReaderAttemptClient.integer("1166"))
        XCTAssertNil(ReaderAttemptClient.integer(nil))
        XCTAssertNotNil(ReaderAttemptClient.date("2026-11-18T15:03:00Z"))
        XCTAssertNotNil(ReaderAttemptClient.date("2026-11-18T15:03:00.123Z"))
        XCTAssertNil(ReaderAttemptClient.date("tomorrow"))
    }
}

/// The fake reader exists for tests and debug builds only, and no build here has a real one.
final class CardReaderBuildTests: XCTestCase {
    func testWithNothingAskedForThereIsNoReader() async {
        let reader = CardReaders.make(environment: [:])
        XCTAssertTrue(reader is UnavailableCardReader)
        let availability = await reader.availability()
        XCTAssertEqual(availability, .unavailable(.notConfigured))
        let unrelated = CardReaders.make(environment: ["IOS_FAKE_CARD_READER": "yes", "RUPERT_DEV_ORIGIN": "http://127.0.0.1:3005"])
        XCTAssertTrue(unrelated is UnavailableCardReader)
    }

    func testADebugBuildGetsTheFakeOnlyWhenItsEnvironmentAsks() {
        // Tests are a debug build. A release build has no FakeCardReader to return (next test).
        for word in ["approved", "declined", "cancelled", "failed", "timeout", "hang"] {
            XCTAssertTrue(CardReaders.make(environment: ["IOS_FAKE_CARD_READER": word]) is FakeCardReader, word)
        }
    }

    /// Reads the app's own sources: the fake is inside `#if DEBUG` wherever it is named, so a
    /// release build cannot contain it or choose it. Nothing imports a card reader framework or
    /// asks for its entitlement.
    func testTheFakeReaderIsCompiledOnlyIntoDebugBuilds() throws {
        let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = ios.appendingPathComponent("Sources/Rupert")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        try XCTSkipIf(files.isEmpty, "The sources are not next to the tests on this machine.")
        XCTAssertTrue(files.contains { $0.lastPathComponent == "FakeCardReader.swift" })

        var mentions = 0
        for file in files {
            var conditions: [String] = []
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines) {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("#if ") {
                    conditions.append(String(text.dropFirst(4)))
                } else if text.hasPrefix("#else") || text.hasPrefix("#elseif") {
                    conditions[conditions.count - 1] = "not " + conditions[conditions.count - 1]
                } else if text.hasPrefix("#endif") {
                    conditions.removeLast()
                } else if !text.hasPrefix("//") {
                    if text.contains("FakeCardReader") {
                        mentions += 1
                        XCTAssertTrue(conditions.contains("DEBUG"), "\(file.lastPathComponent): FakeCardReader outside #if DEBUG: \(text)")
                    }
                    XCTAssertFalse(text.contains("import ProximityReader"), file.lastPathComponent)
                }
            }
            XCTAssertTrue(conditions.isEmpty, file.lastPathComponent)
        }
        XCTAssertGreaterThan(mentions, 1)

        for name in ["RupertApp/RupertApp.entitlements", "RupertApp/project.yml", "Info.plist", "xtool.yml"] {
            let text = try String(contentsOf: ios.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("proximity-reader"), "\(name) must not ask for the card reader entitlement")
            XCTAssertFalse(text.contains("IOS_CARD_READER_PROVIDER"), "\(name): no reader is built into this repository's app")
            XCTAssertFalse(text.contains("IOS_FAKE_CARD_READER"), "\(name): no scheme turns the fake on by default")
        }
    }
}
