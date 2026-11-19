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

        load(HotwireTab.all(on: Instance.current))
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
        TabAccess.onChange = { [weak self] in
            DispatchQueue.main.async { self?.restartTabs() }
        }
        SessionWatcher.shared.onChange = { [weak self] state in
            // Signed out: Rupert must stop pushing to this phone, and the next person starts with every tab.
            if state == .signedOut {
                PushRegistration.shared.forget()
                TabAccess.reset()
            }
            // The change is noticed while the old page is still finishing its visit; replacing the
            // tabs from inside that callback left the new Home tab without a visit in release builds.
            DispatchQueue.main.async { self?.restartTabs() }
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
        let tab = shortcut.type.components(separatedBy: ".").last ?? ""
        // A quick action for a tab this account does not have (Team Chat for staff) opens the first tab.
        select(HotwireTab.all(on: Instance.current).firstIndex(where: { $0.id == tab }) ?? 0)
        return true
    }

    /// Selecting a tab in code skips the tab bar's delegate, which is where lazily loaded tabs
    /// start. Without the start, a quick action to a tab not opened yet showed an endless spinner.
    private func select(_ index: Int) {
        tabBarController.selectedIndex = index
        tabBarController.activeNavigator.start()
    }

    /// A page showed that the person signed in or out: start every tab over on its first page,
    /// staying on the selected tab. Old pages (and their back stacks) are dropped with their web views.
    private func restartTabs() {
        // Stay on the same tab by name: the bar may have gained or lost tabs (TabAccess).
        let selected = shownTabs.indices.contains(tabBarController.selectedIndex) ? shownTabs[tabBarController.selectedIndex].id : nil
        load(HotwireTab.all(on: Instance.current))
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
                SessionWatcher.shared.set(.signedOut)
                TabAccess.reset()
                guard let self else { return }
                self.load(HotwireTab.all(on: Instance.current))
                self.select(0)
            }
        }
    }

    /// Point every tab at `instance` (after a sign-in or a workspace handoff) and open `landing`
    /// on Home. Each tab starts over, since they all showed the sign-in page or the control plane.
    private func show(instance: URL, landing: URL) {
        Instance.setCurrent(instance)
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
        // Rupert's JavaScript did not start: say why, with the page's own diagnostics.
        if case .load = error {
            let webView = tabBarController.activeNavigator.activeWebView
            Task { @MainActor in
                let details = await WebViewSupport.report(from: webView)
                let alert = UIAlertController(title: "Rupert's page did not start",
                                              message: "\(error.localizedDescription)\n\n\(details)", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Copy Details", style: .default) { _ in
                    UIPasteboard.general.string = details
                })
                alert.addAction(UIAlertAction(title: "Try Again", style: .cancel) { _ in retryHandler?() })
                self.tabBarController.activeNavigator.present(alert, animated: true)
            }
            if let presenter = visitable as? ErrorPresenter {
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
