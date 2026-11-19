import HotwireNative
import XCTest
@testable import Rupert

/// The words on the error page for each kind of failure (ErrorView.swift).
final class ErrorTextTests: XCTestCase {
    func testOfflineSaysOfflineAndReloadsWhenBackOnline() {
        let text = ErrorText(.web(WebError(urlError: URLError(.notConnectedToInternet))))
        XCTAssertEqual(text.title, "You're offline")
        XCTAssertTrue(text.isConnection)
    }

    func testServerDownSaysRupertCannotBeReached() {
        let text = ErrorText(.web(WebError(urlError: URLError(.cannotConnectToHost))))
        XCTAssertEqual(text.title, "Can't reach Rupert")
        XCTAssertTrue(text.isConnection)
    }

    func testASlowConnectionSaysSoAndIsWorthRetrying() {
        let text = ErrorText(.web(WebError(urlError: URLError(.timedOut))))
        XCTAssertEqual(text.title, "Rupert is taking too long")
        XCTAssertTrue(text.isConnection)
    }

    func testNoPageShowsTheSystemsTechnicalWording() throws {
        // Anything without words of its own still reads as a sentence a cashier can act on.
        let odd = URLError(.badServerResponse)
        let web = ErrorText(.web(WebError(urlError: odd)))
        XCTAssertEqual(web.title, "This page did not load")
        XCTAssertFalse(web.message.contains(odd.localizedDescription))
        let http = ErrorText(.http(try XCTUnwrap(HTTPError(statusCode: 418))))
        XCTAssertEqual(http.title, "This page did not load")
        for text in [web, http] {
            XCTAssertTrue(text.message.contains("Try again"))
            XCTAssertFalse(text.message.lowercased().contains("error"))
        }
    }

    func testHTTPStatusesGetTheirOwnWords() throws {
        func title(_ status: Int) throws -> String {
            ErrorText(.http(try XCTUnwrap(HTTPError(statusCode: status)))).title
        }
        XCTAssertEqual(try title(403), "You don't have access to this page")
        XCTAssertEqual(try title(404), "This page isn't here")
        XCTAssertEqual(try title(500), "Rupert had a problem")
        XCTAssertFalse(ErrorText(.http(try XCTUnwrap(HTTPError(statusCode: 500)))).isConnection)
    }
}
