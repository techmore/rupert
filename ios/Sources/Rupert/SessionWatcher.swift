import Foundation

/// Notices when the person signs in or out inside a page, so every tab follows.
///
/// Each tab keeps its own web view. Signing in with email and password on Home left a tab opened
/// earlier on "Please sign in", and signing out left other tabs showing business pages. Rupert
/// marks every page in the app with `<meta name="rupert-session" content="signed-in|signed-out">`
/// (layouts/application.html.erb). When a page reports a different state from the last one, the
/// app starts every tab over (SceneController).
final class SessionWatcher {
    enum State: String {
        case signedIn = "signed-in"
        case signedOut = "signed-out"
    }

    static let shared = SessionWatcher()

    /// The page's session state, or null on pages without the tag (other layouts, other sites).
    static let readScript = """
    (() => {
      const tag = document.querySelector('meta[name="rupert-session"]');
      return tag ? tag.content : null;
    })()
    """

    /// What the last Rupert page said; nil until a page has said anything.
    private(set) var state: State?

    /// Called once per sign-in or sign-out a page reveals.
    var onChange: ((State) -> Void)?

    /// Records what a rendered page reported (the result of `readScript`). Returns true, and calls
    /// `onChange`, when that differs from the last known state.
    @discardableResult
    func observe(_ value: Any?) -> Bool {
        guard let text = value as? String, let new = State(rawValue: text) else { return false }
        let old = state
        state = new
        guard let old, old != new else { return false }
        onChange?(new)
        return true
    }

    /// The app changed the session itself (Google sign-in, workspace handoff) and reloads the tabs
    /// on its own, so the next page should not count as a change.
    func set(_ new: State) {
        state = new
    }
}
