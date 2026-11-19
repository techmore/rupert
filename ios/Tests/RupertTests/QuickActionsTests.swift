import HotwireNative
import XCTest
@testable import Rupert

/// Team Chat and Ask Rupert in the app icon's menu follow the account's tabs (QuickActions.swift).
final class QuickActionsTests: XCTestCase {
    private func ids(_ allowed: Set<String>?) -> [String] {
        QuickActions.items(allowed: allowed).map(QuickActions.tabID(of:))
    }

    func testStaffGetNoTeamChatOrAskRupert() {
        // What Rupert lists for a staff account, and for a cashier, shift lead or manager.
        XCTAssertEqual(ids(["time", "inbox"]), [])
        XCTAssertEqual(ids(["time", "home", "inbox"]), [])
    }

    func testAdministratorsGetBothInTheTabBarsOrder() {
        XCTAssertEqual(ids(["time", "home", "chat", "ask", "inbox"]), ["chat", "ask"])
        let items = QuickActions.items(allowed: ["chat", "ask"])
        XCTAssertEqual(items.map(\.localizedTitle), ["Team Chat", "Ask Rupert"])
        XCTAssertEqual(items.map(\.type), ["com.rupertpos.Rupert.chat", "com.rupertpos.Rupert.ask"])
    }

    func testAnAccountWithOnlyOneGetsOnlyThatOne() {
        XCTAssertEqual(ids(["time", "home", "chat", "inbox"]), ["chat"])
    }

    func testSignedOutOrNotYetKnownAddsNone() {
        XCTAssertEqual(ids(nil), [])
    }

    func testEveryAddedQuickActionHasATabToOpen() {
        let tabs = HotwireTab.every(on: URL(string: "https://pos.rupertpos.com")!).map(\.id)
        for id in QuickActions.roleLimited {
            XCTAssertTrue(tabs.contains(id), "quick action \(id) has no tab to open")
        }
    }
}
