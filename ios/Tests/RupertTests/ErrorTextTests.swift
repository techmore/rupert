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
