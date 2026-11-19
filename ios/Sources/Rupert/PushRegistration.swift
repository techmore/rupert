import UIKit
import UserNotifications
import WebKit

/// Push notifications for time & pay: schedule posted or changed, a request decided, a shift offered,
/// a forgotten clock-out, a break due. Rupert sends them through APNs (`PushNotifier` on the server)
/// to the token this app registers at `POST /native/push_devices` for the signed-in person.
///
/// The ask is soft: the first time a signed-in page renders, the app explains what the
/// notifications are for and only then shows the system prompt. "Not now" is remembered; the
/// person can turn them on later from Notifications in the Time tab (the page says to use iPhone
/// Settings), and iOS Settings → Rupert controls them from then on.
final class PushRegistration: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushRegistration()

    private let askedKey = "rupert.push.asked"
    private let tokenKey = "rupert.push.tokenDigest"
    private let hostKey = "rupert.push.registeredHost"
    private var pendingURL: URL?

    /// Called by SceneController: open a URL in the Time tab.
    @MainActor var openInApp: ((URL) -> Void)?

    override private init() {
        super.init()
    }

    func attach() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks once, after a signed-in Rupert page has rendered, from the page's own view controller.
    @MainActor
    func askIfNeeded(from controller: UIViewController) {
        guard SessionWatcher.shared.state == .signedIn else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
#if DEBUG
            NSLog("push: authorization status %d, asked %d", settings.authorizationStatus.rawValue, UserDefaults.standard.bool(forKey: self.askedKey) ? 1 : 0)
#endif
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            case .notDetermined:
                guard !UserDefaults.standard.bool(forKey: self.askedKey) else { return }
                DispatchQueue.main.async { self.softAsk(from: controller) }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    @MainActor
    private func softAsk(from controller: UIViewController) {
        // The page that noticed the sign-in is being replaced (tabs restart); only a page that is
        // on screen can present, and the question counts as asked once it is answered.
        guard controller.viewIfLoaded?.window != nil, controller.presentedViewController == nil else {
#if DEBUG
            NSLog("push: soft ask skipped, page not on screen (%@)", String(describing: type(of: controller)))
#endif
            return
        }
        let alert = UIAlertController(
            title: "Stay in the loop",
            message: "Get told when your schedule is posted, a request is approved, a shift is offered, or you forgot to clock out. You choose which ones in Notifications.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not now", style: .cancel) { [askedKey] _ in
            UserDefaults.standard.set(true, forKey: askedKey)
        })
        alert.addAction(UIAlertAction(title: "Turn on", style: .default) { [askedKey] _ in
            UserDefaults.standard.set(true, forKey: askedKey)
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                guard granted else { return }
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            }
        })
        controller.present(alert, animated: true)
    }

    /// The APNs token arrived (AppDelegate): send it to Rupert with the session cookie.
    func register(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: Instance.url("/native/push_devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Rupert iOS/\(Instance.appVersion)", forHTTPHeaderField: "User-Agent")
        let body: [String: String] = [
            "platform": "ios", "token": token, "app_version": Instance.appVersion,
            "environment": Self.isSandboxBuild ? "sandbox" : "production",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // The session cookie lives in the web views' own store, which URLSession does not read:
        // copy the cookies for this instance onto the request, so the token is registered to the
        // person who is signed in here and to nobody else.
        Self.withWebCookies(request) { [weak self] request in
            URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let self, let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let digest = json["token_digest"] as? String else { return }
                UserDefaults.standard.set(digest, forKey: self.tokenKey)
                UserDefaults.standard.set(request.url?.host, forKey: self.hostKey)
            }.resume()
        }
    }

    /// Signed out, or moving to another workspace: tell the Rupert this phone registered with to
    /// stop sending to it. Needs no session (the digest of the phone's own token is the proof), so
    /// it works after the sign-out it follows. The next person is asked about notifications afresh.
    func forget() {
        UserDefaults.standard.removeObject(forKey: askedKey)
        guard let digest = UserDefaults.standard.string(forKey: tokenKey) else { return }
        let registeredOn = UserDefaults.standard.string(forKey: hostKey).flatMap { Instance.httpsOrigin("https://\($0)") }
        var request = URLRequest(url: Instance.url("/native/push_devices/\(digest)", on: registeredOn ?? Instance.current))
        request.httpMethod = "DELETE"
        request.httpShouldHandleCookies = false
        URLSession.shared.dataTask(with: request).resume()
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: hostKey)
    }

    /// Adds the web views' cookies for the request's host to the request.
    static func withWebCookies(_ request: URLRequest, then send: @escaping (URLRequest) -> Void) {
        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                var request = request
                let fields = HTTPCookie.requestHeaderFields(with: cookies.filter { cookieApplies($0, to: request.url) })
                fields.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                request.httpShouldHandleCookies = false
                send(request)
            }
        }
    }

    /// Whether a cookie belongs on a request to `url`: same host or a parent domain, and never a
    /// Secure cookie over plain http.
    static func cookieApplies(_ cookie: HTTPCookie, to url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        if cookie.isSecure && url.scheme != "https" { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
    }

    /// Debug and TestFlight-less builds talk to the APNs sandbox; App Store builds to production.
    static var isSandboxBuild: Bool {
#if DEBUG
        return true
#else
        return false
#endif
    }

    // MARK: UNUserNotificationCenterDelegate

    /// A notification arrived while the app is open: show it as a banner anyway (the bell page is
    /// not always the one on screen).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .badge, .sound])
    }

    /// Tapped: open the page the notification points at, in the Time tab.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let url = Self.url(in: response.notification.request.content.userInfo) {
            DispatchQueue.main.async { [weak self] in
                if let open = self?.openInApp { open(url) } else { self?.pendingURL = url }
            }
        }
        completionHandler()
    }

    /// Where a notification wants to go: Rupert's `url` field, a path on the current instance.
    /// Anything that names a host or a scheme is ignored, another Rupert workspace's address
    /// included: a payload is data, not a command, and it never moves the app between workspaces.
    static func url(in userInfo: [AnyHashable: Any]) -> URL? {
        guard let path = userInfo["url"] as? String, path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\") else { return nil }
        let url = Instance.url(path)
        return url.host == Instance.current.host ? url : nil
    }

    /// A tap that arrived before the window existed.
    @MainActor
    func flushPending() {
        guard let url = pendingURL, let open = openInApp else { return }
        pendingURL = nil
        open(url)
    }
}
