import HotwireNative
import UIKit

/// The Home Screen quick actions (press and hold the app icon).
///
/// Clock in and Notifications are in Info.plist: every account has those tabs, and they are there
/// before the app has ever been opened. Team Chat and Ask Rupert are for administrators (and
/// people granted Rupert Chat), so they used to sit in the menu of staff who could only be
/// refused by them. They are now added by the app, and only while the signed-in account's own
/// tab list (TabAccess) has them. Signed out, or before a page has listed the tabs, they are
/// left off.
enum QuickActions {
    /// Tabs only some roles can open; every other quick action is static (Info.plist).
    static let roleLimited = ["chat", "ask"]

    static let typePrefix = "com.rupertpos.Rupert."

    /// The quick actions to add for an account that can open `allowed` (nil: not known).
    static func items(allowed: Set<String>?, on base: URL = Instance.controlPlane) -> [UIApplicationShortcutItem] {
        guard let allowed else { return [] }
        return HotwireTab.every(on: base)
            .filter { roleLimited.contains($0.id) && allowed.contains($0.id) }
            .map { tab in
                UIApplicationShortcutItem(type: typePrefix + tab.id, localizedTitle: tab.title, localizedSubtitle: nil,
                                          icon: UIApplicationShortcutIcon(systemImageName: symbols[tab.id] ?? "square"), userInfo: nil)
            }
    }

    private static let symbols = ["chat": "bubble.left.and.bubble.right", "ask": "sparkles"]

    /// The tab a quick action opens.
    static func tabID(of shortcut: UIApplicationShortcutItem) -> String {
        shortcut.type.components(separatedBy: ".").last ?? ""
    }

    /// Bring the icon's menu in line with the account. iOS keeps the list between launches, so
    /// this runs whenever the tabs are loaded (launch, sign-in, sign-out, a new tab list).
    @MainActor
    static func refresh(allowed: Set<String>? = TabAccess.allowed) {
        let wanted = items(allowed: allowed)
        if (UIApplication.shared.shortcutItems ?? []).map(\.type) != wanted.map(\.type) {
            UIApplication.shared.shortcutItems = wanted
        }
    }
}
