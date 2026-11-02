import LocalAuthentication
import UIKit

/// Optional Face ID (or Touch ID, or the device passcode) lock for the app: Rupert holds sales,
/// payroll and bookkeeping, and phones get handed around a shop. Turned on in App settings.
/// While locked, a cover hides the pages, also in the app switcher.
@MainActor
final class AppLock {
    static let shared = AppLock()

    private static let enabledKey = "rupert.requireDeviceAuthentication"
    private static let graceKey = "rupert.lockGraceSeconds"

    /// The cover sits in its own window above the app's, so an alert or sheet that opens while the
    /// app is locked (a sign-in problem, a scanner) cannot show above it.
    private var coverWindow: UIWindow?
    private var locked = false
    private var authenticating = false
    /// Ask once each time the app comes back, not again after the person cancels Face ID.
    private var askWhenActive = false
    private var backgroundedAt: Date?
    private weak var window: UIWindow?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// How long Rupert may be in the background before it asks again; 0 asks every time. A quick
    /// look at the calculator or a text should not need Face ID at the counter.
    var gracePeriod: TimeInterval {
        get { UserDefaults.standard.double(forKey: Self.graceKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.graceKey) }
    }

    static let gracePeriods: [(seconds: TimeInterval, label: String)] = [
        (0, "Immediately"), (60, "After 1 minute"), (300, "After 5 minutes"), (900, "After 15 minutes"),
    ]

    /// "Face ID", "Touch ID", "Optic ID" or "Passcode", for labels. Read once: asking
    /// LocalAuthentication on every settings render stalled the main thread.
    static let methodName: String = {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }()

    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func attach(to window: UIWindow) {
        self.window = window
        if isEnabled {
            lock()
            askWhenActive = true
        }
    }

    /// The app went to the background: cover it now, so the app switcher shows no business data.
    func sceneDidEnterBackground() {
        guard isEnabled else { return }
        if !locked { backgroundedAt = Date() }
        lock()
        askWhenActive = true
    }

    /// The app is in front again: ask for Face ID if it is locked, unless it was away only briefly.
    func sceneDidBecomeActive() {
        guard locked, askWhenActive else { return }
        askWhenActive = false
        if let since = backgroundedAt, Date().timeIntervalSince(since) < gracePeriod {
            finishUnlock()
            return
        }
        unlock()
    }

    /// Asks once, for turning the lock on in settings.
    func confirm(reason: String) async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    private func lock() {
        locked = true
        guard coverWindow == nil, let scene = window?.windowScene else { return }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        cover.overrideUserInterfaceStyle = window?.overrideUserInterfaceStyle ?? .unspecified
        cover.tintColor = window?.tintColor
        cover.rootViewController = LockViewController { [weak self] in self?.unlock() }
        cover.isHidden = false
        // Taking key status also puts away the keyboard of a half-typed field.
        cover.makeKey()
        coverWindow = cover
        UIAccessibility.post(notification: .screenChanged, argument: nil)
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
        backgroundedAt = nil
        guard let cover = coverWindow else { return }
        coverWindow = nil
        window?.makeKey()
        UIView.animate(withDuration: 0.2, animations: { cover.alpha = 0 }) { _ in
            cover.isHidden = true
        }
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
}

/// What a locked app shows: a lock, a line saying so and an Unlock button. It wraps at every text
/// size and is the only thing VoiceOver reads while it shows.
private final class LockViewController: UIViewController {
    private let onUnlock: () -> Void

    init(onUnlock: @escaping () -> Void) {
        self.onUnlock = onUnlock
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(named: "LaunchBackground", in: .module, compatibleWith: nil) ?? .systemBackground
        view.accessibilityViewIsModal = true

        let symbol = UIImageView(image: UIImage(systemName: "lock.fill"))
        symbol.tintColor = UIColor(named: "AccentColor", in: .module, compatibleWith: nil) ?? .tintColor
        symbol.preferredSymbolConfiguration = .init(textStyle: .largeTitle, scale: .large)
        symbol.adjustsImageSizeForAccessibilityContentSizeCategory = true

        let title = UILabel()
        title.text = "Rupert is locked"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        title.textAlignment = .center
        title.accessibilityTraits = .header

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Unlock with \(AppLock.methodName)"
        configuration.cornerStyle = .large
        configuration.buttonSize = .large
        configuration.titleAlignment = .center
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            outgoing.paragraphStyle = paragraph
            return outgoing
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onUnlock() })
        button.titleLabel?.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [symbol, title, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)

        let content = scroll.contentLayoutGuide
        let frame = scroll.frameLayoutGuide
        let margins = view.readableContentGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: frame.widthAnchor),
            // Centred on the screen while it fits; scrolls at the largest text sizes.
            stack.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor),
            button.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        stack.isLayoutMarginsRelativeArrangement = false
        stack.distribution = .fill
        // Vertical centring inside a stack taller than its content: spacers above and below.
        let top = UIView(), bottom = UIView()
        stack.insertArrangedSubview(top, at: 0)
        stack.addArrangedSubview(bottom)
        top.heightAnchor.constraint(equalTo: bottom.heightAnchor).isActive = true
    }
}
