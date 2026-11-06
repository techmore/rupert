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
    static func all(on base: URL) -> [HotwireTab] {
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
