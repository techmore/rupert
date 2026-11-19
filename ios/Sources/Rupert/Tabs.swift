import HotwireNative
import UIKit

/// The native tab bar, on whichever instance the app is pointed at. These replace the web top
/// bar's search, Ask Rupert, Team chat and notification buttons, which Rupert hides inside the app
/// (`.native-app` in application.css). Signed out, every tab shows Rupert's sign-in page.
///
/// Time comes first: for hourly staff the app is their clock, schedule, time off and pay
/// (`/employee`, the staff workspace), and `/login` already lands staff accounts there. Search
/// stays reachable from the top bar of every page; five tabs is the most iOS shows without a
/// "More" tab, so it left the bar when Time joined.
extension HotwireTab {
    /// The tabs this account can open (TabAccess), in the bar's order. Everything, until a
    /// signed-in page has said otherwise.
    static func all(on base: URL, allowed: Set<String>? = TabAccess.allowed) -> [HotwireTab] {
        let tabs = every(on: base)
        guard let allowed else { return tabs }
        let shown = tabs.filter { allowed.contains($0.id) }
        return shown.isEmpty ? tabs : shown
    }

    /// Every tab the app has.
    static func every(on base: URL) -> [HotwireTab] {
        [
            HotwireTab(id: "time", title: "Time", image: UIImage(systemName: "clock"),
                       url: Instance.url("/employee", on: base)),
            // /login sends a signed-in person to their start page, so Home never opens on a page
            // the app cannot show (the signed-out marketing page at / has no Turbo).
            HotwireTab(id: "home", title: "Home", image: UIImage(systemName: "house"),
                       url: Instance.url("/login", on: base)),
            HotwireTab(id: "chat", title: "Team Chat", image: UIImage(systemName: "bubble.left.and.bubble.right"),
                       url: Instance.url("/chat", on: base)),
            HotwireTab(id: "ask", title: "Ask Rupert", image: UIImage(systemName: "sparkles"),
                       url: Instance.url("/ask_rupert", on: base)),
            HotwireTab(id: "inbox", title: "Notifications", image: UIImage(systemName: "bell"),
                       url: Instance.url("/notifications", on: base)),
        ]
    }

    /// The tab a notification tap or a push deep link opens in.
    static let timeTabIndex = 0
}

/// Which tabs the signed-in account can open.
///
/// Team Chat and Ask Rupert are for administrators (and people granted Rupert Chat); for everyone
/// else those tabs only ever showed a refusal. Rupert lists the tabs an account can open in
/// `<meta name="rupert-tabs" content="time home inbox">` on its pages (ApplicationHelper#native_app_tabs)
/// and the app shows those. The server still decides what each page allows; this only removes the
/// dead ends. The list is remembered so the next launch opens with the right bar, and forgotten
/// on sign-out. A Rupert that sends no list (an older deploy) leaves every tab in place.
enum TabAccess {
    private static let key = "rupert.tabs.allowed"

    /// The page's tab list, or null on pages without the tag (signed out, other layouts, other sites).
    static let readScript = """
    (() => {
      const tag = document.querySelector('meta[name="rupert-tabs"]');
      return tag ? tag.content : null;
    })()
    """

    /// Called when a page reports a different list from the one the bar shows.
    @MainActor static var onChange: (() -> Void)?

    /// The remembered list; nil means every tab.
    static var allowed: Set<String>? {
        UserDefaults.standard.stringArray(forKey: key).map(Set.init)
    }

    /// The tab ids in a page's list that this app knows. Nil when the page has no list, or none
    /// of its ids is a tab here: the bar is never emptied by a page.
    static func parse(_ value: Any?) -> Set<String>? {
        guard let text = value as? String else { return nil }
        let known = Set(HotwireTab.every(on: Instance.controlPlane).map(\.id))
        let ids = Set(text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)).intersection(known)
        return ids.isEmpty ? nil : ids
    }

    /// Records what a rendered page reported (the result of `readScript`). Returns true when the
    /// bar should change. A page without a list changes nothing.
    @discardableResult
    static func observe(_ value: Any?) -> Bool {
        guard let new = parse(value) else { return false }
        let shownBefore = Set(HotwireTab.all(on: Instance.controlPlane).map(\.id))
        UserDefaults.standard.set(new.sorted(), forKey: key)
        return Set(HotwireTab.all(on: Instance.controlPlane).map(\.id)) != shownBefore
    }

    /// A page that says nobody is signed in (the session ran out while the app was closed, or
    /// the person signed out in a page) ends the remembered list. Returns true when the bar
    /// should change. `session` is the result of `SessionWatcher.readScript`.
    @discardableResult
    static func forgetIfSignedOut(_ session: Any?) -> Bool {
        guard session as? String == SessionWatcher.State.signedOut.rawValue, allowed != nil else { return false }
        let shownBefore = HotwireTab.all(on: Instance.controlPlane).count
        reset()
        return HotwireTab.all(on: Instance.controlPlane).count != shownBefore
    }

    /// Signed out, or another person is about to sign in: back to every tab.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
