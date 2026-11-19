import XCTest

/// What the app shows when Rupert cannot be reached, and when the session ended while the app
/// was closed. Both replace Hotwire's default pages with plain words and one clear next step.
///
///   TEST_RUNNER_RUPERT_UI_EMAIL=… TEST_RUNNER_RUPERT_UI_PASSWORD=… TEST_RUNNER_RUPERT_UI_SHOTS=/abs/dir \
///   xcodebuild test -scheme RupertApp -only-testing:RupertAppUITests/OfflineAndSessionUITests \
///     -destination 'platform=iOS Simulator,name=…'
///
/// The unreachable test needs no server. The session test needs a local Rupert and an account
/// (any role), and is skipped without RUPERT_UI_EMAIL.
final class OfflineAndSessionUITests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment
    private var step = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// Nothing listens on this port, which is what the phone sees when the shop's connection or
    /// Rupert itself is down. (The simulator shares the Mac's network, so it cannot be put
    /// offline by itself; the wording for "You're offline" is checked in ErrorTextTests.)
    func testWhenRupertCannotBeReachedThePageSaysSoAndOffersTryAgain() {
        app.launchEnvironment["RUPERT_DEV_ORIGIN"] = "http://127.0.0.1:3999"
        app.launch()

        let title = app.staticTexts["Can't reach Rupert"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "a plain page, not \"Error loading page\"")
        XCTAssertTrue(app.staticTexts["Check the shop's Wi-Fi or your cellular connection, then try again."].exists, "what to do about it")
        XCTAssertFalse(app.staticTexts["Error loading page"].exists)
        let tryAgain = app.buttons["Try Again"].firstMatch
        XCTAssertTrue(tryAgain.exists, "Try Again")
        shoot("cannot-reach-rupert")

        // Still down: Try Again tries, and the same page comes back. No blank screen, no alert.
        tryAgain.tap()
        sleep(3)
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the page is still there after a retry that fails")
        XCTAssertTrue(tryAgain.exists)
        XCTAssertEqual(app.alerts.count, 0)
    }

    /// The session cookies are gone at launch but the app still remembers a signed-in person
    /// (RUPERT_UI_DROP_SESSION, debug builds only): the app says they were signed out, in plain
    /// words, and Sign In leaves them on the sign-in page with no tab bar.
    func testASessionThatEndedWhileTheAppWasClosedIsExplained() throws {
        guard let email = env["RUPERT_UI_EMAIL"], let password = env["RUPERT_UI_PASSWORD"] else {
            throw XCTSkip("Set TEST_RUNNER_RUPERT_UI_EMAIL and TEST_RUNNER_RUPERT_UI_PASSWORD to an account on the local Rupert.")
        }
        let origin = env["RUPERT_DEV_ORIGIN"] ?? "http://127.0.0.1:3005"
        app.launchEnvironment["RUPERT_DEV_ORIGIN"] = origin
        app.launch()
        let web = app.webViews
        let signInPage = web.staticTexts["Sign in to continue."].firstMatch
        let tabBar = app.tabBars.firstMatch

        // Be signed in first.
        if signInPage.waitForExistence(timeout: 12) {
            let emailField = web.textFields.firstMatch
            XCTAssertTrue(emailField.waitForExistence(timeout: 15), "email field")
            emailField.tap()
            emailField.typeText(email)
            let passwordField = web.secureTextFields.firstMatch
            passwordField.tap()
            passwordField.typeText(password)
            web.buttons["Sign in"].firstMatch.tap()
        }
        let notNow = app.alerts.buttons["Not now"].firstMatch
        if notNow.waitForExistence(timeout: 8) { notNow.tap() }
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30), "signed in: the tab bar")
        XCTAssertEqual(app.alerts["You've been signed out"].exists, false, "signing in explains nothing")

        // Close the app; the session ends while it is closed.
        app.terminate()
        app.launchEnvironment["RUPERT_UI_DROP_SESSION"] = "1"
        app.launch()

        let notice = app.alerts["You've been signed out"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "the app says the person was signed out")
        XCTAssertTrue(notice.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Sign in again to carry on'")).firstMatch.exists, "and what to do")
        shoot("signed-out-notice")
        notice.buttons["Sign In"].tap()

        XCTAssertTrue(signInPage.waitForExistence(timeout: 20), "the sign-in page is underneath")
        XCTAssertFalse(tabBar.exists && tabBar.isHittable, "with no tab bar")
        XCTAssertEqual(app.alerts.count, 0, "the notice shows once")
        shoot("sign-in-after-notice")

        // A later launch, still signed out, says nothing more.
        app.terminate()
        app.launchEnvironment["RUPERT_UI_DROP_SESSION"] = nil
        app.launch()
        XCTAssertTrue(signInPage.waitForExistence(timeout: 30))
        sleep(2)
        XCTAssertEqual(app.alerts.count, 0, "already signed out: nothing to explain")
    }

    private func shoot(_ name: String) {
        step += 1
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shotDir = env["RUPERT_UI_SHOTS"] else { return }
        let url = URL(fileURLWithPath: shotDir).appendingPathComponent(String(format: "state-%02d-%@.png", step, name))
        try? screenshot.pngRepresentation.write(to: url)
    }
}
