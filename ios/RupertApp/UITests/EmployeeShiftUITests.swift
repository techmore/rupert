import XCTest

/// A staff account's shift in the real app, against a local Rupert (RUPERT_DEV_ORIGIN): sign in,
/// only the tabs a staff account can open, the register up to payment, then Sign out from App
/// settings. Saves a screenshot of each step. The script a person follows for the same flow, with
/// the parts a simulator cannot do, is docs/ios/employee-test-script.md.
///
///   TEST_RUNNER_RUPERT_UI_EMAIL=sam.okafor@juniper-pine.example TEST_RUNNER_RUPERT_UI_PASSWORD=… \
///   TEST_RUNNER_RUPERT_UI_SHOTS=/abs/dir xcodebuild test -scheme RupertApp \
///     -only-testing:RupertAppUITests/EmployeeShiftUITests -destination 'platform=iOS Simulator,name=…'
///
/// The account must have the staff role (employee). The register steps run when that account's
/// workspace has a register with products (docs/ios/employee-test-script.md says how to seed one);
/// without one the test still checks the tabs and Sign out. Skipped without RUPERT_UI_EMAIL.
final class EmployeeShiftUITests: XCTestCase {
    private var app: XCUIApplication!
    private var shotDir: String?
    private var step = 0

    private var web: XCUIElementQuery { app.webViews }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        app.launchEnvironment["RUPERT_DEV_ORIGIN"] = env["RUPERT_DEV_ORIGIN"] ?? "http://127.0.0.1:3005"
        shotDir = env["RUPERT_UI_SHOTS"]
        app.launch()
    }

    func testStaffShiftFromSignInToSignOut() throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["RUPERT_UI_EMAIL"], let password = env["RUPERT_UI_PASSWORD"] else {
            throw XCTSkip("Set TEST_RUNNER_RUPERT_UI_EMAIL and TEST_RUNNER_RUPERT_UI_PASSWORD to a staff account on the local Rupert.")
        }
        addUIInterruptionMonitor(withDescription: "push soft ask") { alert in
            guard alert.staticTexts["Stay in the loop"].exists else { return false }
            alert.buttons["Not now"].tap()
            return true
        }
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 20))

        // Start signed out, whatever an earlier run left behind.
        if !web.links["Sign in"].firstMatch.waitForExistence(timeout: 8) {
            signOutFromAppSettings()
        }
        XCTAssertTrue(web.links["Sign in"].firstMatch.waitForExistence(timeout: 30), "the signed-out Time page offers Sign in")
        XCTAssertEqual(tabLabels(), ["Time", "Home", "Team Chat", "Ask Rupert", "Notifications"], "signed out, every tab is there")

        // Sign in with email and password.
        web.links["Sign in"].firstMatch.tap()
        let emailField = web.textFields.firstMatch
        if !emailField.waitForExistence(timeout: 5) {
            let toggle = web.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'mail and password'")).firstMatch
            if toggle.waitForExistence(timeout: 10) { toggle.tap() }
        }
        XCTAssertTrue(emailField.waitForExistence(timeout: 15), "email field")
        emailField.tap()
        emailField.typeText(email)
        let passwordField = web.secureTextFields.firstMatch
        passwordField.tap()
        passwordField.typeText(password)
        web.buttons["Sign in"].firstMatch.tap()
        sleep(6)
        _ = tabBar.exists // a query lets the interruption monitor see the soft ask
        sleep(2)
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Hi,'")).firstMatch.waitForExistence(timeout: 30),
                      "a staff account lands on My time")

        // Only the tabs a staff account can open: no Home (it is My time again), Team Chat or Ask Rupert.
        XCTAssertEqual(tabLabels(), ["Time", "Notifications"], "a staff account sees only the tabs it can open")
        shoot("staff-home-two-tabs")
        checkQuickActions()

        tabBar.buttons["Notifications"].tap()
        XCTAssertTrue(web.firstMatch.waitForExistence(timeout: 10))
        sleep(3)
        XCTAssertFalse(web.staticTexts.matching(NSPredicate(format: "label CONTAINS 'can use POS'")).firstMatch.exists, "Notifications opens, it does not refuse")
        shoot("staff-notifications")
        tabBar.buttons["Time"].tap()

        try ringUpASale()

        // Sign out from App settings, where people look for it.
        tabBar.buttons["Time"].tap()
        sleep(1)
        tabBar.buttons["Time"].tap() // the selected tab again: back to its first page
        sleep(3)
        signOutFromAppSettings()
        XCTAssertTrue(web.links["Sign in"].firstMatch.waitForExistence(timeout: 30), "signed out: the sign-in page")
        XCTAssertEqual(tabLabels(), ["Time", "Home", "Team Chat", "Ask Rupert", "Notifications"], "the next person starts with every tab")
        shoot("signed-out")
    }

    /// The register on one phone: pair the customer screen, add an item, hand the phone over for
    /// the tip choice, take it back and open payment. What happens after a tender is tapped depends
    /// on the store's setup, so the test records it and requires only that the app says something.
    private func ringUpASale() throws {
        let openPOS = web.links["Open POS"].firstMatch
        guard openPOS.waitForExistence(timeout: 5) else { return }
        openPOS.tap()
        let pair = web.buttons["Pair customer screen"].firstMatch
        guard pair.waitForExistence(timeout: 15) else {
            shoot("register-not-set-up")
            return
        }
        shoot("register")
        pair.tap()
        XCTAssertTrue(web.links["Open customer screen"].firstMatch.waitForExistence(timeout: 15), "the customer screen is paired")

        let tile = web.buttons.matching(NSPredicate(format: "label CONTAINS ', $'")).firstMatch
        guard tile.waitForExistence(timeout: 10) else {
            shoot("register-no-products")
            return
        }
        sleep(2) // the page has just reloaded with the paired screen
        let add = web.buttons["Add to cart"].firstMatch
        // The reloaded register puts the cursor in Search, so the keyboard covers the products.
        let keyboardDone = app.toolbars.buttons["Done"].firstMatch
        if keyboardDone.waitForExistence(timeout: 3) { keyboardDone.tap() }
        sleep(1)
        tile.tap()
        _ = add.waitForExistence(timeout: 8)
        XCTAssertTrue(add.exists, "the item sheet")
        shoot("register-item")
        add.tap()
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Cart 1 item'")).firstMatch.waitForExistence(timeout: 10), "one item in the cart")
        shoot("register-cart")

        // The customer's side, on the same phone: opens as a page with Back.
        scrollTo(web.links["Open customer screen"].firstMatch, down: true)
        web.links["Open customer screen"].firstMatch.tap()
        let noTip = web.staticTexts["No tip"].firstMatch
        XCTAssertTrue(noTip.waitForExistence(timeout: 15), "the customer screen offers a tip choice")
        sleep(3) // the customer screen polls for the cart
        shoot("customer-screen")
        noTip.tap()
        let confirm = web.buttons["Confirm my choice"].firstMatch
        if confirm.waitForExistence(timeout: 5), confirm.isEnabled {
            confirm.tap()
            sleep(2)
            shoot("customer-confirmed")
        }
        app.navigationBars.buttons.firstMatch.tap()
        sleep(4) // the register polls for the customer's confirmation

        let checkout = web.buttons["Checkout"].firstMatch
        XCTAssertTrue(checkout.waitForExistence(timeout: 10))
        scrollTo(checkout, down: false)
        guard checkout.isEnabled else {
            shoot("register-checkout-not-ready")
            return
        }
        checkout.tap()
        sleep(2)
        // The page moves as payment opens, and the tap can land on the register picker: close it.
        let picked = app.buttons.matching(NSPredicate(format: "label == 'Front counter'")).firstMatch
        if picked.exists, !web.buttons["Checkout"].firstMatch.exists || app.collectionViews.count > 0 { picked.tap(); sleep(1) }
        shoot("register-payment")
        // Cash is the tender chosen first; Card says to ask a manager when the store has none set up.
        let exact = web.buttons["Exact"].firstMatch
        guard exact.waitForExistence(timeout: 10) else { return }
        scrollTo(exact, down: false)
        if exact.isHittable { exact.tap() }
        let complete = web.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Complete cash sale'")).firstMatch
        guard complete.waitForExistence(timeout: 5) else { return }
        scrollTo(complete, down: false)
        shoot("register-cash")
        guard complete.isHittable, complete.isEnabled else { return }
        complete.tap()
        sleep(6)
        // Paid, or refused with the reason: either way the register says so.
        shoot("register-cash-outcome")
    }

    private func signOutFromAppSettings() {
        let settings = app.buttons["app-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "App settings button on the tab's first page")
        settings.tap()
        let signOut = app.buttons["sign-out"].firstMatch
        XCTAssertTrue(signOut.waitForExistence(timeout: 10), "App settings offers Sign out while signed in")
        shoot("app-settings-sign-out")
        signOut.tap()
        let confirm = app.alerts.buttons["Sign out"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Sign out asks before it signs out")
        confirm.tap()
        sleep(5)
    }

    private func tabLabels() -> [String] {
        app.tabBars.firstMatch.buttons.allElementsBoundByIndex.map(\.label)
    }

    /// Press and hold the app icon: a staff account is offered Clock in and Notifications, and not
    /// Team Chat or Ask Rupert, which it cannot open.
    private func checkQuickActions() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        let icon = springboard.icons["Rupert"].firstMatch
        guard icon.waitForExistence(timeout: 10) else {
            app.activate()
            return XCTFail("the Rupert icon is not on the Home Screen page that opens")
        }
        icon.press(forDuration: 1.5)
        let clockIn = springboard.buttons["Clock in"].firstMatch
        XCTAssertTrue(clockIn.waitForExistence(timeout: 8), "the icon's menu offers Clock in")
        XCTAssertTrue(springboard.buttons["Notifications"].firstMatch.exists, "and Notifications")
        XCTAssertFalse(springboard.buttons["Team Chat"].firstMatch.exists, "no Team Chat for a staff account")
        XCTAssertFalse(springboard.buttons["Ask Rupert"].firstMatch.exists, "no Ask Rupert for a staff account")
        shoot("quick-actions-staff")
        // Clock in opens the Time tab.
        clockIn.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Hi,'")).firstMatch.waitForExistence(timeout: 20), "Clock in opens My time")
    }

    private func scrollTo(_ element: XCUIElement, down: Bool) {
        var swipes = 0
        while element.exists && !element.isHittable && swipes < 8 {
            if down { web.firstMatch.swipeDown() } else { web.firstMatch.swipeUp() }
            swipes += 1
        }
    }

    private func shoot(_ name: String) {
        step += 1
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shotDir else { return }
        let url = URL(fileURLWithPath: shotDir).appendingPathComponent(String(format: "staff-%02d-%@.png", step, name))
        try? screenshot.pngRepresentation.write(to: url)
    }
}
