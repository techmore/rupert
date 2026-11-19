import WebKit
import HotwireNative
import UIKit

/// The one window: a tab bar where each tab keeps its own navigation stack of Rupert pages, on the
/// instance the app is pointed at (Instance.current).
final class SceneController: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private lazy var tabBarController = HotwireTabBarController(navigatorDelegate: self, lazyLoadTabs: true)
    /// The tabs in the bar now, in order.
    private var shownTabs: [HotwireTab] = []

    private func load(_ tabs: [HotwireTab]) {
        shownTabs = tabs
        tabBarController.load(tabs)
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.tintColor = UIColor(named: "AccentColor", in: .module, compatibleWith: nil)
        window.rootViewController = tabBarController
        window.makeKeyAndVisible()
        self.window = window

        signedIn = UserDefaults.standard.bool(forKey: Self.signedInKey)
#if DEBUG
        if SessionEnd.dropsSessionAtLaunch {
            // UI test: the session ran out while the app was closed.
            SessionEnd.dropSession { [weak self] in
                guard let self else { return }
                self.load(self.currentTabs())
                self.select(0)
            }
        } else {
            load(currentTabs())
        }
#else
        load(currentTabs())
#endif
        showTabs(signedIn, animated: false)
        AppLock.shared.attach(to: window)
        AppSettings.openInApp = { [weak self] url in
            self?.tabBarController.activeNavigator.route(url)
        }
        // A tapped notification opens its page in the Time tab.
        PushRegistration.shared.openInApp = { [weak self] url in
            guard let self else { return }
            self.select(HotwireTab.timeTabIndex)
            self.tabBarController.activeNavigator.route(url)
        }
        PushRegistration.shared.flushPending()
        if let shortcut = connectionOptions.shortcutItem {
            _ = open(shortcut)
        }

        GoogleSignIn.shared.onSignedIn = { [weak self] landing in
            self?.show(instance: Instance.httpsOrigin(landing) ?? Instance.current, landing: landing)
        }
        WorkspaceHandoff.shared.onOpened = { [weak self] origin, landing in
            self?.show(instance: origin, landing: landing)
        }
        AppSettings.switchWorkspace = { [weak self] in self?.signOut(leavingWorkspace: true) }
        AppSettings.signOut = { [weak self] in self?.signOut(leavingWorkspace: false) }
        // A page listed different tabs for this account (TabAccess): show those.
        TabAccess.onChange = { [weak self] in self?.scheduleRestart() }
        SessionWatcher.shared.onState = { [weak self] state in
            self?.showTabs(state == .signedIn, animated: true)
        }
        SessionWatcher.shared.onChange = { [weak self] state in
            // Signed out: Rupert must stop pushing to this phone, and the next person starts with every tab.
            if state == .signedOut {
                PushRegistration.shared.forget()
                TabAccess.reset()
            }
            self?.scheduleRestart()
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        AppLock.shared.sceneDidEnterBackground()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AppLock.shared.sceneDidBecomeActive()
    }

    /// Home Screen quick actions (Info.plist UIApplicationShortcutItems): open that tab.
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(open(shortcutItem))
    }

    private func open(_ shortcut: UIApplicationShortcutItem) -> Bool {
        // Signed out there is only the sign-in page; the app opens on it.
        guard signedIn else { return true }
        let tab = shortcut.type.components(separatedBy: ".").last ?? ""
        // A quick action for a tab this account does not have (Team Chat for staff) opens the first tab.
        select(HotwireTab.all(on: Instance.current).firstIndex(where: { $0.id == tab }) ?? 0)
        return true
    }

    private static let signedInKey = "rupert.signedIn"
    private var signedIn = false

    private var restartScheduled = false

    /// Signed in: the tabs this account can open. Signed out: Home alone, which is the sign-in
    /// page (/login). One page, so one request starts the new session; with several tabs loading
    /// at once, each began a session of its own and the sign-in form could be left holding a
    /// token for a session that had been replaced ("Can't verify CSRF token").
    private func currentTabs() -> [HotwireTab] {
        signedIn ? HotwireTab.all(on: Instance.current) : SignedOut.tabs(on: Instance.current)
    }

    /// Signed out, every tab showed a sign-in page of its own, most of them under a "Please sign
    /// in" error. Now only Home's shows, without the tab bar; the tabs come back with the
    /// sign-in. Remembered across launches, so a signed-out start does not flash the tabs.
    /// `restart: false` when the caller loads the tabs itself.
    private func showTabs(_ visible: Bool, animated: Bool, restart: Bool = true) {
        let changed = signedIn != visible
        signedIn = visible
        UserDefaults.standard.set(visible, forKey: Self.signedInKey)
        if changed, restart { scheduleRestart() }
        // Signed out without asking (the session ran out, the password changed): say so, once
        // the sign-in page is up.
        if changed, !visible, SessionEnd.unexpected(wasSignedIn: true, askedAt: SessionEnd.askedAt) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                SessionEnd.present(from: self?.tabBarController)
            }
        }
        if #available(iOS 18.0, *) {
            if tabBarController.isTabBarHidden == visible {
                tabBarController.setTabBarHidden(!visible, animated: animated)
            }
        } else {
            tabBarController.tabBar.isHidden = !visible
        }
    }

    /// Selecting a tab in code skips the tab bar's delegate, which is where lazily loaded tabs
    /// start. Without the start, a quick action to a tab not opened yet showed an endless spinner.
    private func select(_ index: Int) {
        tabBarController.selectedIndex = index
        tabBarController.activeNavigator.start()
    }

    /// Restart the tabs once, on the next turn of the main queue. A sign-in or sign-out is noticed
    /// while the old page is still finishing its visit; replacing the tabs from inside that
    /// callback left the new first tab without a visit in release builds. Several things can ask
    /// in the same turn (the session, the tab list, the tab bar); the tabs load once.
    private func scheduleRestart() {
        guard !restartScheduled else { return }
        restartScheduled = true
        DispatchQueue.main.async { [weak self] in self?.restartTabs() }
    }

    /// A page showed that the person signed in or out: start every tab over on its first page,
    /// staying on the selected tab. Old pages (and their back stacks) are dropped with their web views.
    private func restartTabs() {
        restartScheduled = false
        // Stay on the same tab by name: the bar may have gained or lost tabs (TabAccess).
        let selected = shownTabs.indices.contains(tabBarController.selectedIndex) ? shownTabs[tabBarController.selectedIndex].id : nil
        load(currentTabs())
        select(shownTabs.firstIndex(where: { $0.id == selected }) ?? 0)
        // Just signed in: offer push notifications from the fresh page once it is on screen.
        if SessionWatcher.shared.state == .signedIn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let top = self.tabBarController.selectedViewController else { return }
                PushRegistration.shared.askIfNeeded(from: (top as? UINavigationController)?.topViewController ?? top)
            }
        }
    }

    /// Settings → Sign out, and Settings → Switch workspace: stop this phone's notifications, drop
    /// every Rupert cookie and cached page the web views hold (the session on the workspace and on
    /// the control plane), and start again on the sign-in page: this workspace's for Sign out, the
    /// control plane's for Switch workspace. Nothing of the last person is left on screen. Rupert
    /// keeps its session in the cookie, so dropping the cookie ends the session.
    private func signOut(leavingWorkspace: Bool) {
        SessionEnd.personAskedToSignOut()
        PushRegistration.shared.forget()
        let store = WKWebsiteDataStore.default()
        // The cookies are the session: delete them one by one and wait only for that. Clearing
        // everything in one call did not finish while a page's service worker was alive (the staff
        // pages register one), which left the person signed in.
        store.httpCookieStore.getAllCookies { [weak self] cookies in
            let deleted = DispatchGroup()
            for cookie in cookies {
                deleted.enter()
                store.httpCookieStore.delete(cookie) { deleted.leave() }
            }
            deleted.notify(queue: .main) {
                // Cached pages and page storage go too, without waiting. Cookies are left out of
                // this pass so that, finishing late, it can never remove the next person's session.
                var rest = WKWebsiteDataStore.allWebsiteDataTypes()
                rest.remove(WKWebsiteDataTypeCookies)
                store.removeData(ofTypes: rest, modifiedSince: .distantPast) {}
                if leavingWorkspace { Instance.leaveWorkspace() }
                TabAccess.reset()
                // Marking signed out hides the tab bar; the restart then loads the sign-in page,
                // on the control plane after Switch workspace.
                SessionWatcher.shared.set(.signedOut)
                self?.scheduleRestart()
            }
        }
    }

    /// Point every tab at `instance` (after a sign-in or a workspace handoff) and open `landing`
    /// on Home. Each tab starts over, since they all showed the sign-in page or the control plane.
    private func show(instance: URL, landing: URL) {
        Instance.setCurrent(instance)
        // The tabs are loaded here, with the landing page; no restart on top of that.
        showTabs(true, animated: true, restart: false)
        SessionWatcher.shared.set(.signedIn)
        let tabs = HotwireTab.all(on: instance)
        load(tabs)
        select(0)
        if landing.path != "/" || landing.query != nil, let home = tabs.first,
           let navigator = tabBarController.navigator(for: home) {
            navigator.route(landing, options: VisitOptions(action: .replace))
        }
    }
}

extension SceneController: NavigatorDelegate {
    func visitableDidFailRequest(_ visitable: any Visitable, error: HotwireNativeError, retryHandler: RetryBlock?) {
        // Rupert's JavaScript did not start: the error page (RupertErrorView) offers the page's own
        // diagnostics as "Copy Details for Support". They used to arrive in an alert on top of the
        // error page, user agent and import map included.
        if case .load = error, let presenter = visitable as? ErrorPresenter {
            let webView = tabBarController.activeNavigator.activeWebView
            Task { @MainActor in
                let details = await WebViewSupport.report(from: webView)
                ErrorDetails.latest = "\(error.localizedDescription)\n\n\(details)"
                presenter.presentError(error) { retryHandler?() }
            }
            return
        }
        if let presenter = visitable as? ErrorPresenter {
            presenter.presentError(error) { retryHandler?() }
            return
        }
        let alert = UIAlertController(title: "Rupert could not load this page",
                                      message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Try Again", style: .default) { _ in retryHandler?() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        tabBarController.activeNavigator.present(alert, animated: true)
    }
}
