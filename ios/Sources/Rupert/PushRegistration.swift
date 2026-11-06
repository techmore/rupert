import UIKit
import UserNotifications

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
        // The web views' session cookie lives in the shared cookie storage; the task shares it.
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let digest = json["token_digest"] as? String else { return }
            UserDefaults.standard.set(digest, forKey: self.tokenKey)
        }.resume()
    }

    /// Signed out: tell Rupert to stop sending to this phone.
    func forget() {
        guard let digest = UserDefaults.standard.string(forKey: tokenKey) else { return }
        var request = URLRequest(url: Instance.url("/native/push_devices/\(digest)"))
        request.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: request).resume()
        UserDefaults.standard.removeObject(forKey: tokenKey)
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

    /// Where a notification wants to go: Rupert's `url` field on the current instance. Other hosts
    /// and schemes are ignored (a payload is data, not a command).
    static func url(in userInfo: [AnyHashable: Any]) -> URL? {
        guard let path = userInfo["url"] as? String, !path.isEmpty else { return nil }
        let url = Instance.url(path)
        return Instance.isRupert(url) || url.host == Instance.current.host ? url : nil
    }

    /// A tap that arrived before the window existed.
    @MainActor
    func flushPending() {
        guard let url = pendingURL, let open = openInApp else { return }
        pendingURL = nil
        open(url)
    }
}
