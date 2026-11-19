import XCTest
@testable import Rupert

/// When the app explains a sign-out (SessionEnd.swift): only when nobody asked for it.
final class SessionEndTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testASessionThatRanOutIsExplained() {
        XCTAssertTrue(SessionEnd.unexpected(wasSignedIn: true, askedAt: nil, now: now))
    }

    func testASignOutThePersonAskedForIsNot() {
        XCTAssertFalse(SessionEnd.unexpected(wasSignedIn: true, askedAt: now.addingTimeInterval(-2), now: now))
        XCTAssertFalse(SessionEnd.unexpected(wasSignedIn: true, askedAt: now.addingTimeInterval(-SessionEnd.grace), now: now))
    }

    func testAnOldSignOutDoesNotExcuseALaterExpiry() {
        // Signed out yesterday, signed in again, and today the session ran out.
        XCTAssertTrue(SessionEnd.unexpected(wasSignedIn: true, askedAt: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(SessionEnd.unexpected(wasSignedIn: true, askedAt: now.addingTimeInterval(-SessionEnd.grace - 1), now: now))
    }

    func testAClockSetBackDoesNotHideTheNotice() {
        XCTAssertTrue(SessionEnd.unexpected(wasSignedIn: true, askedAt: now.addingTimeInterval(300), now: now))
    }

    func testNobodyWasSignedInSoThereIsNothingToExplain() {
        XCTAssertFalse(SessionEnd.unexpected(wasSignedIn: false, askedAt: nil, now: now))
    }

    func testTheNoticeSaysWhatHappenedAndWhatToDoInPlainWords() {
        XCTAssertEqual(SessionEnd.title, "You've been signed out")
        XCTAssertTrue(SessionEnd.message.contains("Sign in again"))
        XCTAssertTrue(SessionEnd.message.contains("clocked in"))
        for jargon in ["session", "token", "cookie", "401", "expired", "authenticat"] {
            XCTAssertFalse(SessionEnd.message.lowercased().contains(jargon), "no \(jargon) in the notice")
        }
    }

    func testThePageScriptReportsSignOutAndDeleteForms() {
        XCTAssertTrue(SessionEnd.watchScript.contains("\"/logout\""))
        XCTAssertTrue(SessionEnd.watchScript.contains("rupertSession"))
        XCTAssertTrue(SessionEnd.watchScript.contains("isTrusted"), "only the person's own tap counts")
    }
}
