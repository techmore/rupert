import XCTest

/// Drives the real app against a local Rupert (RUPERT_DEV_ORIGIN) through the staff sign-in and
/// the Time tab's pages, saving a screenshot of each step. Used to verify the flows an App Store
/// reviewer will take and to produce docs/time-and-pay/screenshots/ios-*.png.
///
///   RUPERT_UI_EMAIL=sam.okafor@juniper-pine.example RUPERT_UI_PASSWORD=… RUPERT_UI_SHOTS=/abs/dir \
///   xcodebuild test -scheme RupertApp -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:RupertAppUITests
///
/// Without RUPERT_UI_EMAIL the test only checks that the app shows the Time tab and the sign-in page.
final class TimeFlowsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var shotDir: String?
    private var step = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        app.launchEnvironment["RUPERT_DEV_ORIGIN"] = env["RUPERT_DEV_ORIGIN"] ?? "http://127.0.0.1:3005"
        shotDir = env["RUPERT_UI_SHOTS"]
        app.launch()
    }

    func testTimeTabSignInAndPages() throws {
        let env = ProcessInfo.processInfo.environment
        // XCTest dismisses system-style alerts on its own; record the push soft ask before it does.
        addUIInterruptionMonitor(withDescription: "push soft ask") { [weak self] alert in
            guard alert.staticTexts["Stay in the loop"].exists else { return false }
            self?.shoot("push-soft-ask")
            alert.buttons["Not now"].tap()
            return true
        }
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 20))
        XCTAssertTrue(tabBar.buttons["Time"].exists, "Time is a tab")
        XCTAssertTrue(tabBar.buttons["Home"].exists)
        XCTAssertFalse(tabBar.buttons["Search"].exists, "Search left the bar to make room for Time")

        // A previous run may have left the person signed in: sign out through the page first, which
        // also exercises the session watcher (tabs restart) and forgetting the push token.
        let signOut = app.webViews.buttons["Sign out"].firstMatch
        if signOut.waitForExistence(timeout: 8) {
            // Sign out sits in the page footer inside the app (the web brand row is hidden there).
            var swipes = 0
            while !signOut.isHittable && swipes < 8 { app.webViews.firstMatch.swipeUp(); swipes += 1 }
            signOut.tap()
            sleep(4)
        }
        // Signed out: the Time tab shows My time with a Sign in button.
        let signIn = app.webViews.links["Sign in"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 30), "the signed-out Time page offers Sign in\n\(app.webViews.firstMatch.debugDescription.prefix(3000))")
        shoot("time-signed-out")

        guard let email = env["RUPERT_UI_EMAIL"], let password = env["RUPERT_UI_PASSWORD"] else { return }
        signIn.tap()
        sleep(3)
        shoot("sign-in-page")
        let emailField = app.webViews.textFields.firstMatch
        if !emailField.waitForExistence(timeout: 5) {
            let toggle = app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'mail and password'")).firstMatch
            if toggle.waitForExistence(timeout: 10) { toggle.tap() }
        }
        XCTAssertTrue(emailField.waitForExistence(timeout: 15), "email field\n\(app.webViews.firstMatch.debugDescription.prefix(4000))")
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.webViews.secureTextFields.firstMatch
        passwordField.tap()
        passwordField.typeText(password)
        shoot("sign-in-form")
        app.webViews.buttons["Sign in"].firstMatch.tap()

        // The soft ask for notifications appears once after sign-in.
        sleep(6)
        _ = app.tabBars.firstMatch.exists // a query lets the interruption monitor see the alert
        sleep(2)
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Hi,'")).firstMatch.waitForExistence(timeout: 30),
                      "the Time tab lands on the staff home after sign-in")
        shoot("time-home")

        // The staff nav pills are on every Time page. Timesheets sits past the right edge on a phone
        // (XCUITest cannot judge hittability of an off-screen web link), so this walks the four on screen.
        for (label, pill) in [("schedule", "Schedule"), ("time-off", "Time off"), ("pay", "Pay")] {
            let link = app.webViews.links[pill].firstMatch
            guard link.waitForExistence(timeout: 10) else { continue }
            link.tap()
            sleep(3)
            shoot(label)
        }

        tabBar.buttons["Notifications"].tap()
        sleep(3)
        shoot("notifications")

        // App settings sheet: lock, workspace, delete account.
        tabBar.buttons["Time"].tap()
        sleep(1)
        tabBar.buttons["Time"].tap() // tapping the selected tab again pops to its first page
        sleep(3)
        let settings = app.buttons["app-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "App settings button on the Time tab's first page")
        settings.tap()
        sleep(2)
        shoot("app-settings")
        app.buttons["Done"].firstMatch.tap()
    }

    private func shoot(_ name: String) {
        step += 1
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shotDir else { return }
        let url = URL(fileURLWithPath: shotDir).appendingPathComponent(String(format: "ios-%02d-%@.png", step, name))
        try? screenshot.pngRepresentation.write(to: url)
    }
}
