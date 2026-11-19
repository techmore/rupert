import HotwireNative
import XCTest
@testable import Rupert

/// The tab bar shows the tabs the signed-in account can open (TabAccess). Staff accounts do not
/// get Team Chat or Ask Rupert, which only ever refused them.
final class TabAccessTests: XCTestCase {
    private let base = URL(string: "https://pos.rupertpos.com")!

    override func setUp() {
        super.setUp()
        TabAccess.reset()
    }

    override func tearDown() {
        TabAccess.reset()
        super.tearDown()
    }

    func testEveryTabShowsUntilAPageListsThem() {
        XCTAssertNil(TabAccess.allowed)
        XCTAssertEqual(HotwireTab.all(on: base).map(\.id), ["time", "home", "chat", "ask", "inbox"])
    }

    func testAStaffAccountGetsTimeAndNotificationsOnly() {
        XCTAssertTrue(TabAccess.observe("time inbox"), "the bar changes")
        XCTAssertEqual(HotwireTab.all(on: base).map(\.id), ["time", "inbox"])
        XCTAssertEqual(HotwireTab.all(on: base).first?.id, "time", "notifications still open in the first tab")
    }

    func testACashierKeepsHomeButNotChatOrAsk() {
        TabAccess.observe("time home inbox")
        XCTAssertEqual(HotwireTab.all(on: base).map(\.id), ["time", "home", "inbox"])
    }

    func testTheSameListAgainIsNotAChange() {
        XCTAssertTrue(TabAccess.observe("time inbox"))
        XCTAssertFalse(TabAccess.observe("time inbox"))
        XCTAssertFalse(TabAccess.observe("inbox,time"), "order and separators do not matter")
        XCTAssertTrue(TabAccess.observe("time home chat ask inbox"), "an administrator signing in gets every tab back")
    }

    func testEveryTabListedIsNotAChangeFromTheDefault() {
        XCTAssertFalse(TabAccess.observe("time home chat ask inbox"))
    }

    func testPagesWithoutAListChangeNothing() {
        TabAccess.observe("time inbox")
        XCTAssertFalse(TabAccess.observe(nil), "signed-out pages, the register and other sites carry no list")
        XCTAssertFalse(TabAccess.observe(NSNull()))
        XCTAssertFalse(TabAccess.observe(42))
        XCTAssertEqual(TabAccess.allowed, ["time", "inbox"])
    }

    func testAPageCanNeverEmptyTheBar() {
        XCTAssertFalse(TabAccess.observe(""))
        XCTAssertFalse(TabAccess.observe("   "))
        XCTAssertFalse(TabAccess.observe("settings admin"), "ids this app does not know are ignored")
        XCTAssertNil(TabAccess.allowed)
        XCTAssertEqual(HotwireTab.all(on: base).count, 5)
        XCTAssertEqual(HotwireTab.all(on: base, allowed: []).count, 5)
        XCTAssertEqual(HotwireTab.all(on: base, allowed: ["nothing-here"]).count, 5)
    }

    func testUnknownIdsAreDroppedAndKnownOnesKept() {
        TabAccess.observe("time future-tab inbox")
        XCTAssertEqual(TabAccess.allowed, ["time", "inbox"])
    }

    func testSigningOutBringsEveryTabBack() {
        TabAccess.observe("time inbox")
        TabAccess.reset()
        XCTAssertNil(TabAccess.allowed)
        XCTAssertEqual(HotwireTab.all(on: base).count, 5)
    }

    func testASignedOutPageEndsTheRememberedList() {
        TabAccess.observe("time inbox")
        XCTAssertFalse(TabAccess.forgetIfSignedOut("signed-in"))
        XCTAssertFalse(TabAccess.forgetIfSignedOut(nil), "a page without the session tag says nothing")
        XCTAssertEqual(HotwireTab.all(on: base).count, 2)
        XCTAssertTrue(TabAccess.forgetIfSignedOut("signed-out"), "the session ran out while the app was closed")
        XCTAssertEqual(HotwireTab.all(on: base).count, 5)
        XCTAssertFalse(TabAccess.forgetIfSignedOut("signed-out"), "only once")
    }

    func testTheListIsRememberedForTheNextLaunch() {
        TabAccess.observe("time inbox")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "rupert.tabs.allowed"), ["inbox", "time"])
    }

    func testTabsKeepTheirPagesWhenFiltered() {
        let tabs = HotwireTab.all(on: base, allowed: ["time", "inbox"])
        XCTAssertEqual(tabs.map(\.url.path), ["/employee", "/notifications"])
    }
}
