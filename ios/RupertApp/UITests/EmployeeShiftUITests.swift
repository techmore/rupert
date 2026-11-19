import XCTest

/// A staff account's shift in the real app, against a local Rupert (RUPERT_DEV_ORIGIN): the
/// sign-in page with no tab bar while signed out, sign in,
/// only the tabs a staff account can open, a cash sale on the register from the first item to the
/// receipt, then Sign out from App settings. Saves a screenshot of each step. The script a person follows for the same flow, with
/// the parts a simulator cannot do, is docs/ios/employee-test-script.md.
///
///   TEST_RUNNER_RUPERT_UI_EMAIL=sam.okafor@juniper-pine.example TEST_RUNNER_RUPERT_UI_PASSWORD=… \
///   TEST_RUNNER_RUPERT_UI_SHOTS=/abs/dir xcodebuild test -scheme RupertApp \
///     -only-testing:RupertAppUITests/EmployeeShiftUITests -destination 'platform=iOS Simulator,name=…'
///
/// The account must have the staff role (employee). The register steps run when that account's
/// workspace has a register with products: start Rupert with web/test/support/sim_register.ru
/// (docs/ios/employee-test-script.md). Without a register the test still checks the tabs and
/// Sign out. Skipped without RUPERT_UI_EMAIL.
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
        let signInPage = web.staticTexts["Sign in to continue."].firstMatch

        // Start signed out, whatever an earlier run left behind.
        if !signInPage.waitForExistence(timeout: 12) {
            signOutFromAppSettings()
        }
        XCTAssertTrue(signInPage.waitForExistence(timeout: 30), "signed out, the app shows the sign-in page")
        XCTAssertFalse(tabBar.exists && tabBar.isHittable, "signed out, there is no tab bar")
        shoot("signed-out-sign-in-page")

        // Sign in with email and password.
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
        checkFormSheet()
        tabBar.buttons["Time"].tap() // the selected tab again: back to its first page
        sleep(2)

        try ringUpASale()

        // Sign out from App settings, where people look for it.
        tabBar.buttons["Time"].tap()
        sleep(1)
        tabBar.buttons["Time"].tap() // the selected tab again: back to its first page
        sleep(3)
        signOutFromAppSettings()
        XCTAssertTrue(signInPage.waitForExistence(timeout: 30), "signed out: the sign-in page")
        XCTAssertFalse(tabBar.exists && tabBar.isHittable, "the next person starts on the sign-in page with no tab bar")
        XCTAssertTrue(app.buttons["app-settings"].firstMatch.waitForExistence(timeout: 10), "App settings stays reachable on the sign-in page")
        shoot("signed-out")
    }

    /// The register on one phone: pair the customer screen, add an item, hand the phone over for
    /// the tip choice, take it back, take exact cash and open the receipt. The register is the
    /// made-up one in web/test/support/sim_register.rb; nothing leaves the machine.
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
        let handOver = web.links["Hand to customer for tip"].firstMatch
        XCTAssertTrue(web.staticTexts["Customer screen paired"].firstMatch.waitForExistence(timeout: 15), "the customer screen is paired")

        let tile = web.buttons.matching(NSPredicate(format: "label CONTAINS ', $'")).firstMatch
        guard tile.waitForExistence(timeout: 10) else {
            shoot("register-no-products")
            return
        }
        sleep(2) // the page has just reloaded with the paired screen
        let add = web.buttons["Add to cart"].firstMatch
        // On a phone the register leaves the keyboard down until Search is tapped, so the
        // products are in view and the strip above them is short.
        XCTAssertFalse(app.keyboards.firstMatch.exists, "no keyboard over the products when the register opens")
        XCTAssertTrue(tile.isHittable, "the first product is on screen without scrolling")
        shoot("register-paired")
        tile.tap()
        _ = add.waitForExistence(timeout: 8)
        XCTAssertTrue(add.exists, "the item sheet")
        shoot("register-item")
        add.tap()
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Cart 1 item'")).firstMatch.waitForExistence(timeout: 10), "one item in the cart")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "adding an item does not raise the keyboard")
        shoot("register-cart")

        // The customer's side, on the same phone: the cart offers the hand-over, which opens as
        // a page with Back.
        let cartBar = web.links.matching(NSPredicate(format: "label BEGINSWITH 'Cart · 1 item'")).firstMatch
        XCTAssertTrue(cartBar.waitForExistence(timeout: 5), "the cart bar shows the count and total")
        cartBar.tap()
        XCTAssertTrue(handOver.waitForExistence(timeout: 5), "the cart offers to hand the phone to the customer")
        scrollTo(handOver, down: false)
        shoot("register-hand-over")
        handOver.tap()
        let noTip = web.staticTexts["No tip"].firstMatch
        XCTAssertTrue(noTip.waitForExistence(timeout: 15), "the customer screen offers a tip choice")
        sleep(3) // the customer screen polls for the cart
        shoot("customer-screen")
        noTip.tap()
        let confirm = web.buttons["Confirm my choice"].firstMatch
        if confirm.waitForExistence(timeout: 5), confirm.isEnabled {
            confirm.tap()
            XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label CONTAINS 'hand the phone back to the cashier'")).firstMatch.waitForExistence(timeout: 10), "the customer is told to hand the phone back")
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
        // Too little cash is refused in words, in a box that stands out, and nothing is sold.
        let cash = web.textFields["Cash received"].firstMatch
        if cash.waitForExistence(timeout: 5) {
            cash.tap()
            cash.typeText("5")
            let done = app.toolbars.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 3) { done.tap() }
            let short = web.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Complete cash sale'")).firstMatch
            scrollTo(short, down: false)
            short.tap()
            XCTAssertTrue(web.staticTexts["Cash received is less than the total."].firstMatch.waitForExistence(timeout: 10), "too little cash is refused in words")
            shoot("register-cash-refused")
            scrollTo(exact, down: true)
        }
        if exact.isHittable { exact.tap() }
        let complete = web.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Complete cash sale'")).firstMatch
        guard complete.waitForExistence(timeout: 5) else { return }
        scrollTo(complete, down: false)
        shoot("register-cash")
        guard complete.isHittable, complete.isEnabled else { return }
        complete.tap()
        // The test register (web/test/support/sim_register.rb) takes cash, so the sale completes:
        // paid, change due (none, the cash was exact), a receipt, and the next sale one tap away.
        let paid = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Paid'")).firstMatch
        let said = web.staticTexts.matching(NSPredicate(format: "label CONTAINS 'could not' OR label CONTAINS 'signed out' OR label CONTAINS 'Insufficient' OR label CONTAINS 'incomplete'")).firstMatch
        if !paid.waitForExistence(timeout: 20) {
            shoot("register-cash-refused")
            XCTFail("the cash sale did not complete: \(said.exists ? said.label : "the register said nothing"). Start Rupert with test/support/sim_register.ru (docs/ios/employee-test-script.md).")
            return
        }
        XCTAssertTrue(paid.label.contains("Change $0.00"), "exact cash leaves no change: \(paid.label)")
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Receipt '")).firstMatch.waitForExistence(timeout: 5), "the receipt number")
        let receipt = web.links["Open receipt"].firstMatch
        XCTAssertTrue(receipt.exists, "a link to the receipt")
        let newSale = web.buttons["New sale"].firstMatch
        XCTAssertTrue(newSale.exists, "New sale")
        scrollTo(newSale, down: false)
        shoot("register-cash-paid")

        // The receipt is this sale's: paid, cash, the item.
        receipt.tap()
        XCTAssertTrue(web.staticTexts["Receipt"].firstMatch.waitForExistence(timeout: 15), "the receipt page")
        XCTAssertTrue(web.staticTexts["Paid"].firstMatch.waitForExistence(timeout: 5), "the receipt says Paid")
        shoot("receipt")
        app.navigationBars.buttons.firstMatch.tap()

        // Back on the register the paid cart is not offered again: it starts the next sale.
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Cart 0 items'")).firstMatch.waitForExistence(timeout: 15), "the paid cart is gone after the receipt")
        XCTAssertTrue(web.staticTexts["The last sale is paid. Ready for the next one."].firstMatch.waitForExistence(timeout: 5), "the register says the last sale is paid")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "no keyboard over the tab bar")
        shoot("register-next-sale")
    }

    /// A form opens as a sheet with Cancel, not a Done tick that throws the form away; once
    /// something is typed, Cancel asks before discarding it. My availability (Schedule → More)
    /// is a sheet every staff account has.
    private func checkFormSheet() {
        let schedule = web.links["Schedule"].firstMatch
        guard schedule.waitForExistence(timeout: 10) else { return XCTFail("the Schedule pill") }
        schedule.tap()
        let cancel = app.navigationBars.buttons["Cancel"].firstMatch
        func openAvailability() {
            let availability = web.descendants(matching: .any).matching(NSPredicate(format: "label == 'My availability'")).firstMatch
            if !availability.waitForExistence(timeout: 3) {
                let more = web.descendants(matching: .any).matching(NSPredicate(format: "label == 'More'")).firstMatch
                XCTAssertTrue(more.waitForExistence(timeout: 10), "the Schedule page's More menu")
                more.tap()
            }
            XCTAssertTrue(availability.waitForExistence(timeout: 5), "My availability")
            // On a phone this menu opens partly off the left edge, so tap the part that shows.
            if availability.isHittable { availability.tap() } else { availability.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
            XCTAssertTrue(cancel.waitForExistence(timeout: 15), "the form sheet has Cancel")
        }
        openAvailability()
        XCTAssertFalse(app.navigationBars.buttons["Done"].exists, "and no Done that reads as save")
        sleep(2)
        shoot("form-sheet")

        // Nothing typed yet: Cancel just closes.
        cancel.tap()
        sleep(2)
        XCTAssertFalse(cancel.exists, "Cancel closes an untouched form without asking")
        XCTAssertFalse(app.buttons["Discard Changes"].exists)

        // Type something: Cancel asks first.
        openAvailability()
        let note = web.textFields.firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), "the note field")
        note.tap()
        note.typeText("School run")
        cancel.tap()
        let discard = app.buttons["Discard Changes"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "Cancel asks before discarding a changed form")
        shoot("form-sheet-discard")
        // Keep Editing is a button on older iOS; where the question is a popover, a tap outside it.
        let keep = app.buttons["Keep Editing"].firstMatch
        if keep.exists { keep.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap() }
        sleep(1)
        XCTAssertFalse(discard.exists, "the question went away")
        XCTAssertTrue(cancel.exists, "and the form is still open")
        cancel.tap()
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        sleep(2)
        XCTAssertFalse(cancel.exists, "Discard Changes closes the sheet")
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
