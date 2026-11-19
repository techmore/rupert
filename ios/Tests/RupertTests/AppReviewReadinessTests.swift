import HotwireNative
import XCTest
@testable import Rupert

/// Behaviour App Review exercises: tabs following a sign-in or sign-out, the bottom inset for
/// full-height panels, Rupert's own sites, and the Info.plist privacy keys.
final class SessionWatcherTests: XCTestCase {
    func testFirstPageSetsTheStateWithoutRestartingTabs() {
        let watcher = SessionWatcher()
        var changes: [SessionWatcher.State] = []
        watcher.onChange = { changes.append($0) }

        XCTAssertFalse(watcher.observe("signed-out"))
        XCTAssertEqual(watcher.state, .signedOut)
        XCTAssertEqual(changes, [])
    }

    func testSigningInInAPageRestartsTabsOnce() {
        let watcher = SessionWatcher()
        var changes: [SessionWatcher.State] = []
        watcher.onChange = { changes.append($0) }

        watcher.observe("signed-out")
        XCTAssertTrue(watcher.observe("signed-in"))
        XCTAssertFalse(watcher.observe("signed-in"), "later signed-in pages are not a change")
        XCTAssertEqual(changes, [.signedIn])
    }

    func testSigningOutRestartsTabs() {
        let watcher = SessionWatcher()
        var changes: [SessionWatcher.State] = []
        watcher.onChange = { changes.append($0) }

        watcher.observe("signed-in")
        XCTAssertTrue(watcher.observe("signed-out"))
        XCTAssertEqual(changes, [.signedOut])
    }

    func testPagesWithoutTheTagAreIgnored() {
        let watcher = SessionWatcher()
        var changes: [SessionWatcher.State] = []
        watcher.onChange = { changes.append($0) }

        watcher.observe("signed-out")
        XCTAssertFalse(watcher.observe(nil))
        XCTAssertFalse(watcher.observe(NSNull()))
        XCTAssertFalse(watcher.observe("something-else"))
        XCTAssertFalse(watcher.observe(42))
        XCTAssertEqual(watcher.state, .signedOut)
        XCTAssertEqual(changes, [])
    }

    func testTheStateIsSetBeforeTabsRestart() {
        // Restarting the tabs renders pages again; they must not count as a second change.
        let watcher = SessionWatcher()
        var stateDuringChange: SessionWatcher.State?
        watcher.onChange = { _ in stateDuringChange = watcher.state }

        watcher.observe("signed-out")
        watcher.observe("signed-in")
        XCTAssertEqual(stateDuringChange, .signedIn)
    }

    func testAnAppSignInDoesNotRestartTabsAgain() {
        // Google sign-in and the workspace handoff reload the tabs themselves.
        let watcher = SessionWatcher()
        var changes: [SessionWatcher.State] = []
        watcher.onChange = { changes.append($0) }

        watcher.observe("signed-out")
        watcher.set(.signedIn)
        XCTAssertFalse(watcher.observe("signed-in"))
        XCTAssertEqual(changes, [])
    }
}

final class BottomInsetTests: XCTestCase {
    func testScriptSetsTheCSSVariableInWholePoints() {
        XCTAssertEqual(BannerWebViewController.bottomInsetScript(83.4),
                       "document.documentElement.style.setProperty('--native-bottom-inset', '83px')")
        XCTAssertEqual(BannerWebViewController.bottomInsetScript(0),
                       "document.documentElement.style.setProperty('--native-bottom-inset', '0px')")
        XCTAssertEqual(BannerWebViewController.bottomInsetScript(-5),
                       "document.documentElement.style.setProperty('--native-bottom-inset', '0px')")
    }
}

final class InstanceTests: XCTestCase {
    func testOnlyHTTPSRupertSitesStayInTheApp() {
        XCTAssertTrue(Instance.isRupert(URL(string: "https://pos.rupertpos.com/chat")))
        XCTAssertTrue(Instance.isRupert(URL(string: "https://rupertpos.com/")))
        XCTAssertFalse(Instance.isRupert(URL(string: "http://pos.rupertpos.com/chat")))
        XCTAssertFalse(Instance.isRupert(URL(string: "https://rupertpos.com.evil.example/")))
        XCTAssertFalse(Instance.isRupert(URL(string: "https://evilrupertpos.com/")))
        XCTAssertFalse(Instance.isRupert(nil))
    }

    func testOriginsKeepOnlySchemeHostAndPort() {
        XCTAssertEqual(Instance.httpsOrigin("https://shop.example:8443/path?q=1")?.absoluteString, "https://shop.example:8443")
        XCTAssertNil(Instance.httpsOrigin("http://shop.example"))
        XCTAssertNil(Instance.httpsOrigin("rupert://workspace"))
    }
}

/// The checked-in Info.plist (ios/Info.plist), read from the source tree.
final class InfoPlistTests: XCTestCase {
    private func plist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testEveryPrivacySensitiveFeatureHasAUsageString() throws {
        let info = try plist()
        // Camera (barcode scanning and photos), photo picking, saving an image from a page (WebKit
        // crashes the app without this key), video sound and the Face ID lock.
        for key in ["NSCameraUsageDescription", "NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription",
                    "NSMicrophoneUsageDescription", "NSFaceIDUsageDescription"] {
            let text = info[key] as? String
            XCTAssertNotNil(text, "\(key) is missing")
            XCTAssertGreaterThan(text?.count ?? 0, 30, "\(key) should say why Rupert needs it")
        }
    }

    func testNoTrackingOrLocationIsDeclared() throws {
        let info = try plist()
        for key in ["NSUserTrackingUsageDescription", "NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription",
                    "NSBluetoothAlwaysUsageDescription", "NSContactsUsageDescription"] {
            XCTAssertNil(info[key], "\(key) is declared but the app does not use it")
        }
    }

    func testExportComplianceAndControlPlane() throws {
        let info = try plist()
        XCTAssertEqual(info["ITSAppUsesNonExemptEncryption"] as? Bool, false)
        XCTAssertEqual(info["RupertControlPlaneURL"] as? String, "https://pos.rupertpos.com")
    }

    func testVersionIsTheTimeAndPayRelease() throws {
        let info = try plist()
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "1.1.0")
    }

    func testQuickActionsMatchTheTabs() throws {
        let info = try plist()
        let items = try XCTUnwrap(info["UIApplicationShortcutItems"] as? [[String: Any]])
        let types = items.compactMap { ($0["UIApplicationShortcutItemType"] as? String)?.components(separatedBy: ".").last }
        let tabs = HotwireTab.all(on: URL(string: "https://pos.rupertpos.com")!).map(\.id)
        for type in types {
            XCTAssertTrue(tabs.contains(type), "quick action \(type) has no tab to open")
        }
        XCTAssertTrue(types.contains("time"), "Clock in is a Home Screen quick action")
    }
}

/// The Time tab and push notifications (time & pay).
final class TimeTabTests: XCTestCase {
    func testTimeIsTheFirstTabAndThereAreFive() {
        let tabs = HotwireTab.all(on: URL(string: "https://pos.rupertpos.com")!)
        XCTAssertEqual(tabs.count, 5, "iOS shows at most five tabs without a More tab")
        XCTAssertEqual(tabs.first?.id, "time")
        XCTAssertEqual(tabs.first?.url.path, "/employee")
        XCTAssertEqual(HotwireTab.timeTabIndex, 0)
        XCTAssertFalse(tabs.contains { $0.id == "search" })
    }

    func testNotificationPayloadsOnlyOpenRupertPages() {
        XCTAssertEqual(PushRegistration.url(in: ["url": "/employee/schedule"])?.path, "/employee/schedule")
        XCTAssertEqual(PushRegistration.url(in: ["url": "/employee/schedule"])?.host, Instance.current.host)
        XCTAssertNil(PushRegistration.url(in: ["url": "https://evil.example/phish"]))
        XCTAssertNil(PushRegistration.url(in: ["url": "https://other-shop.rupertpos.com/employee"]), "never another workspace's address")
        XCTAssertNil(PushRegistration.url(in: ["url": "//evil.example/phish"]))
        XCTAssertNil(PushRegistration.url(in: ["url": "employee/schedule"]))
        XCTAssertNil(PushRegistration.url(in: ["url": ""]))
        XCTAssertNil(PushRegistration.url(in: [:]))
    }

    func testSessionCookiesGoOnlyToTheirOwnHost() {
        func cookie(_ domain: String, secure: Bool = true) -> HTTPCookie {
            HTTPCookie(properties: [.name: "_rupert_session", .value: "x", .domain: domain, .path: "/", .secure: secure ? "TRUE" : "FALSE"])!
        }
        let shop = URL(string: "https://north.rupertpos.com/native/push_devices")
        XCTAssertTrue(PushRegistration.cookieApplies(cookie("north.rupertpos.com"), to: shop))
        XCTAssertTrue(PushRegistration.cookieApplies(cookie(".rupertpos.com"), to: shop))
        XCTAssertFalse(PushRegistration.cookieApplies(cookie("south.rupertpos.com"), to: shop), "another workspace's session is never sent")
        XCTAssertFalse(PushRegistration.cookieApplies(cookie("evilrupertpos.com"), to: URL(string: "https://rupertpos.com/")))
        XCTAssertFalse(PushRegistration.cookieApplies(cookie("north.rupertpos.com"), to: URL(string: "http://north.rupertpos.com/")))
    }

    func testLeavingAWorkspaceReturnsToTheControlPlane() {
        Instance.setCurrent(URL(string: "https://north.example.org")!)
        XCTAssertTrue(Instance.isOnWorkspaceInstance)
        Instance.leaveWorkspace()
        XCTAssertFalse(Instance.isOnWorkspaceInstance)
        XCTAssertEqual(Instance.current.host, Instance.controlPlane.host)
    }

    func testBundledPathConfigurationOpensTimeFormsAsSheets() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "path-configuration", withExtension: "json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rules = try XCTUnwrap(json["rules"] as? [[String: Any]])
        let modal = rules.filter { ($0["properties"] as? [String: Any])?["context"] as? String == "modal" }
            .flatMap { $0["patterns"] as? [String] ?? [] }
        XCTAssertTrue(modal.contains { $0.contains("/employee/time-off/new") })
        XCTAssertTrue(modal.contains { $0.contains("/time_clock/shifts/") })
    }
}
