import UIKit
import WebKit

/// What the app says when the session ends without the person asking for it.
///
/// Rupert signs people out after a while, and when their password or access changes. The app
/// used to show that as the web's "Please sign in" notice on whatever page was next, with the
/// tabs still in place. Now the tab bar goes, the sign-in page shows (SceneController), and this
/// says in plain words what happened and what to do. A sign-out the person asked for (App
/// settings, a Sign out or delete button in a page) says nothing: they know.
enum SessionEnd {
    /// How long after a Sign out tap a signed-out page still counts as that tap's doing.
    static let grace: TimeInterval = 60

    /// When the person last asked to sign out, in the app or in a page.
    @MainActor private(set) static var askedAt: Date?

    @MainActor
    static func personAskedToSignOut(at date: Date = Date()) {
        askedAt = date
    }

    /// True when a change to signed out should be explained: someone was signed in, and nobody
    /// asked to sign out in the last minute.
    static func unexpected(wasSignedIn: Bool, askedAt: Date?, now: Date = Date()) -> Bool {
        guard wasSignedIn else { return false }
        guard let askedAt else { return true }
        let elapsed = now.timeIntervalSince(askedAt)
        return elapsed < 0 || elapsed > grace
    }

    static let title = "You've been signed out"
    static let message = "Rupert signs you out after a while, and when your password or access changes, to keep the shop's account safe. Sign in again to carry on. If you were clocked in, you still are."
    static let action = "Sign In"

    /// The notice, over whatever is on screen (the sign-in page, once the tabs restart).
    @MainActor
    static func present(from root: UIViewController?) {
        guard let root else { return }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        guard !(top is UIAlertController) else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "session-ended"
        alert.addAction(UIAlertAction(title: action, style: .default))
        top.present(alert, animated: true)
    }

    /// Tells the app when the person submits a form that signs them out or deletes something
    /// (Rupert's Sign out and delete buttons are forms with the DELETE method).
    static let watchScript = """
    (() => {
      addEventListener("submit", (event) => {
        const form = event.target;
        if (!event.isTrusted || !(form instanceof HTMLFormElement)) return;
        let path = "";
        try { path = new URL(form.action, location.href).pathname; } catch (_) {}
        const method = (form.querySelector('input[name="_method"]') || {}).value || form.method || "";
        if (path === "/logout" || String(method).toLowerCase() === "delete") {
          try { window.webkit.messageHandlers.rupertSession.postMessage("signing-out"); } catch (_) {}
        }
      }, true);
    })();
    """

#if DEBUG
    /// Debug builds only, for the UI test: `RUPERT_UI_DROP_SESSION=1` in the launch environment
    /// deletes the session cookies before the first page loads and leaves everything the app
    /// remembers in place, which is what a session that ran out while the app was closed looks
    /// like. Release builds do not contain this.
    static var dropsSessionAtLaunch: Bool {
        ProcessInfo.processInfo.environment["RUPERT_UI_DROP_SESSION"] == "1"
    }

    static func dropSession(then done: @escaping @MainActor () -> Void) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            let deleted = DispatchGroup()
            for cookie in cookies {
                deleted.enter()
                store.delete(cookie) { deleted.leave() }
            }
            deleted.notify(queue: .main) { MainActor.assumeIsolated { done() } }
        }
    }
#endif
}
