import LocalAuthentication
import UIKit

/// Optional Face ID (or Touch ID, or the device passcode) lock for the app: Rupert holds sales,
/// payroll and bookkeeping, and phones get handed around a shop. Turned on in App settings.
/// While locked, a cover hides the pages, also in the app switcher.
@MainActor
final class AppLock {
    static let shared = AppLock()

    private static let enabledKey = "rupert.requireDeviceAuthentication"
    private var cover: UIView?
    private var locked = false
    private var authenticating = false
    private weak var window: UIWindow?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// "Face ID", "Touch ID", "Optic ID" or "Passcode", for labels.
    static var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func attach(to window: UIWindow) {
        self.window = window
        if isEnabled { lock() }
    }

    /// The app went to the background: cover it now, so the app switcher shows no business data.
    func sceneDidEnterBackground() {
        if isEnabled { lock() }
    }

    /// The app is in front again: ask for Face ID if it is locked.
    func sceneDidBecomeActive() {
        if locked { unlock() }
    }

    /// Asks once, for turning the lock on in settings.
    func confirm(reason: String) async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    private func lock() {
        locked = true
        guard cover == nil, let window else { return }
        let cover = LockCover(frame: window.bounds) { [weak self] in self?.unlock() }
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(cover)
        self.cover = cover
    }

    private func unlock() {
        guard locked, !authenticating else { return }
        guard Self.isAvailable else {
            // The passcode was removed from the phone: nothing left to check against.
            finishUnlock()
            return
        }
        authenticating = true
        Task {
            let ok = await confirm(reason: "Unlock Rupert")
            authenticating = false
            if ok { finishUnlock() }
        }
    }

    private func finishUnlock() {
        locked = false
        UIView.animate(withDuration: 0.2, animations: { self.cover?.alpha = 0 }) { _ in
            self.cover?.removeFromSuperview()
            self.cover = nil
        }
    }
}

/// What a locked app shows: Rupert's icon colour, a lock and an Unlock button.
private final class LockCover: UIView {
    private let onUnlock: () -> Void

    init(frame: CGRect, onUnlock: @escaping () -> Void) {
        self.onUnlock = onUnlock
        super.init(frame: frame)
        backgroundColor = UIColor(named: "LaunchBackground", in: .module, compatibleWith: nil) ?? .systemBackground

        let symbol = UIImageView(image: UIImage(systemName: "lock.fill"))
        symbol.tintColor = UIColor(named: "AccentColor", in: .module, compatibleWith: nil) ?? .tintColor
        symbol.preferredSymbolConfiguration = .init(pointSize: 44, weight: .regular)

        let title = UILabel()
        title.text = "Rupert is locked"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Unlock with \(AppLock.methodName)"
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onUnlock() })

        let stack = UIStackView(arrangedSubviews: [symbol, title, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
