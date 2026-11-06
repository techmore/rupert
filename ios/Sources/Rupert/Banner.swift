import HotwireNative
import UIKit
import WebKit

/// The native top bar and Rupert's own header (`.app-topbar`) read as one solid banner. Rupert
/// publishes the banner colour as `--color-banner` in every appearance (application.css); the app
/// reads it after each page and again whenever the person switches appearance in the account menu.
struct BannerColors {
    var background: UIColor
    var title: UIColor
    var accent: UIColor

    /// Before the first page, and for pages without the token: Herbal, Rupert's default appearance.
    static let fallback = BannerColors(
        background: UIColor(named: "Banner", in: .module, compatibleWith: nil) ?? .secondarySystemBackground,
        title: UIColor(named: "BannerTitle", in: .module, compatibleWith: nil) ?? .label,
        accent: UIColor(named: "AccentColor", in: .module, compatibleWith: nil) ?? .tintColor
    )

    /// The last colours a page reported. New pages start with them, so the bar does not flash.
    static var current = fallback

    /// Reads the page's banner, text and accent colours, as JSON.
    static let readScript = """
    (() => {
      const css = getComputedStyle(document.documentElement);
      const value = (name) => css.getPropertyValue(name).trim();
      return JSON.stringify({ banner: value("--color-banner"), ink: value("--color-ink"), accent: value("--color-olive") });
    })()
    """

    /// Tells the app when the person picks another appearance (theme_controller sets data-theme).
    static let watchScript = """
    (() => {
      const post = () => {
        try { window.webkit.messageHandlers.rupertBanner.postMessage(\(readScript)); } catch (_) {}
      };
      new MutationObserver(post).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    })();
    """

    /// `json` from readScript; nil when the page has no banner token (another site, an older Rupert).
    init?(json: Any?) {
        guard let text = json as? String, let data = text.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let background = UIColor(hex: values["banner"]) else { return nil }
        self.background = background
        title = UIColor(hex: values["ink"]) ?? Self.fallback.title
        accent = UIColor(hex: values["accent"]) ?? Self.fallback.accent
    }

    init(background: UIColor, title: UIColor, accent: UIColor) {
        self.background = background
        self.title = title
        self.accent = accent
    }

    /// Dark banners get light status bar text, light banners dark text, whatever the phone's setting.
    func isDark(for traits: UITraitCollection) -> Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        background.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: nil)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.5
    }

    var appearance: UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = background
        // Rupert's header right below draws the dividing line.
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: title]
        appearance.largeTitleTextAttributes = [.foregroundColor: title]
        return appearance
    }
}

/// Rupert pages: Hotwire's web view controller, with the bar in the page's banner colours.
final class BannerWebViewController: HotwireWebViewController {
    private var colors = BannerColors.current

    /// The person typed in a form on this page (BannerBridge). In a sheet, closing it then asks first.
    private var edited = false

    /// The first page of a sheet: forms (`/new`, `/edit`) open as sheets (path-configuration.json).
    private var isSheetRoot: Bool {
        presentingViewController != nil && navigationController?.viewControllers.first === self
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        colors.isDark(for: traitCollection) ? .lightContent : .darkContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        apply(colors)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        apply(colors)
        // A tab's first page carries the App settings button (AppSettings.swift).
        if navigationController?.viewControllers.first === self, presentingViewController == nil {
            AppSettings.addButton(to: self)
        }
        if isSheetRoot { addCancelButton() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A swipe down on a sheet with edits asks before discarding them (see formEdited()).
        if isSheetRoot { navigationController?.presentationController?.delegate = self }
    }

    override func visitableDidActivateWebView(_ webView: WKWebView) {
        super.visitableDidActivateWebView(webView)
        BannerBridge.shared.pages.setObject(self, forKey: webView)
    }

    override func visitableDidRender() {
        super.visitableDidRender()
        // Page titles end in " · Rupert" for browser tabs; the app's bar does not need it.
        if let title = navigationItem.title, title.hasSuffix(" · Rupert") {
            navigationItem.title = String(title.dropLast(" · Rupert".count))
        }
        guard let webView = visitableView.webView else { return }
        // Sheets have their own title and Cancel; Rupert hides its menu bar and "Next" card in them.
        if presentingViewController != nil {
            webView.evaluateJavaScript("document.documentElement.dataset.nativeModal = ''")
        }
        TextSize.apply(to: webView)
        webView.evaluateJavaScript(BannerColors.readScript) { [weak self] value, _ in
            self?.apply(BannerColors(json: value) ?? .fallback)
        }
        publishBottomInset()
        // A sign-in or sign-out in this page restarts every tab (SessionWatcher).
        if Instance.isRupert(webView.url) {
            webView.evaluateJavaScript(SessionWatcher.readScript) { value, _ in
                SessionWatcher.shared.observe(value)
            }
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        publishBottomInset()
    }

    /// Pages scroll under the floating tab bar, which is fine for scrolling content but hides the
    /// bottom of full-height panels (Ask Rupert's question box). Rupert pads those panels by
    /// `--native-bottom-inset` (application.css), which the app sets to the tab bar's height.
    private func publishBottomInset() {
        guard isViewLoaded, let webView = visitableView.webView else { return }
        webView.evaluateJavaScript(Self.bottomInsetScript(view.safeAreaInsets.bottom))
    }

    static func bottomInsetScript(_ inset: CGFloat) -> String {
        let points = max(0, Int(inset.rounded()))
        return "document.documentElement.style.setProperty('--native-bottom-inset', '\(points)px')"
    }

    func apply(_ colors: BannerColors) {
        self.colors = colors
        BannerColors.current = colors
        // Rupert's appearance is chosen in the account menu, not by the phone's dark mode, so the
        // tab bar, sheets, alerts, keyboard and loading screens follow the page. Without this a dark
        // phone showed a black tab bar and black loading screens around light pages.
        if let window = view.window {
            PageStyle.apply(colors.isDark(for: traitCollection) ? .dark : .light, to: window)
        }
        let appearance = colors.appearance
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
        if navigationController?.topViewController === self {
            navigationController?.navigationBar.tintColor = colors.accent
            navigationController?.setNeedsStatusBarAppearanceUpdate()
        }
    }
}

/// Light or dark native chrome, following the appearance the person picked in Rupert. The last one
/// is remembered so the next launch starts in it instead of flashing the phone's setting.
enum PageStyle {
    private static let key = "rupert.pageStyle"

    static var last: UIUserInterfaceStyle {
        switch UserDefaults.standard.string(forKey: key) {
        case "dark": return .dark
        // Before any page: Herbal, Rupert's default appearance, is light.
        default: return .light
        }
    }

    static func apply(_ style: UIUserInterfaceStyle, to window: UIWindow) {
        guard window.overrideUserInterfaceStyle != style else { return }
        window.overrideUserInterfaceStyle = style
        UserDefaults.standard.set(style == .dark ? "dark" : "light", forKey: key)
    }
}

// MARK: Form sheets

/// Hotwire's Done tick on sheets read as "save" but threw the form away, and a swipe down did the
/// same without a word. Sheets now have Cancel, as in Mail or Calendar, and once the person has
/// typed something, Cancel and the swipe both ask before discarding it.
extension BannerWebViewController: UIAdaptivePresentationControllerDelegate {
    func formEdited() {
        guard presentingViewController != nil, !edited else { return }
        edited = true
        navigationController?.isModalInPresentation = true
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        confirmDiscard()
    }

    private func addCancelButton() {
        guard navigationItem.leftBarButtonItem == nil else { return }
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.cancel()
        })
    }

    private func cancel() {
        let edits = navigationController?.viewControllers.contains { ($0 as? BannerWebViewController)?.edited == true } ?? edited
        if edits { confirmDiscard() } else { dismiss(animated: true) }
    }

    private func confirmDiscard() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Discard Changes", style: .destructive) { [weak self] _ in
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            self?.dismiss(animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
        (navigationController ?? self).present(sheet, animated: true)
    }
}

/// Lets the top page decide the status bar text colour, so it stays readable on the banner.
final class BannerNavigationController: HotwireNavigationController {
    override var childForStatusBarStyle: UIViewController? { topViewController }
}

/// Receives the page's appearance changes and hands them to the page showing that web view.
final class BannerBridge: NSObject, WKScriptMessageHandler {
    static let shared = BannerBridge()
    let pages = NSMapTable<WKWebView, BannerWebViewController>.weakToWeakObjects()

    /// Tells the app the first time the person changes a field in one of the page's forms.
    static let formEditScript = """
    (() => {
      const post = (event) => {
        if (!event.isTrusted || !(event.target instanceof Element) || !event.target.closest("form")) return;
        try { window.webkit.messageHandlers.rupertForm.postMessage("edited"); } catch (_) {}
      };
      addEventListener("input", post, true);
      addEventListener("change", post, true);
    })();
    """

    static func install(in controller: WKUserContentController) {
        controller.add(shared, name: "rupertBanner")
        controller.add(shared, name: "rupertForm")
        controller.addUserScript(WKUserScript(source: BannerColors.watchScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: formEditScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let webView = message.webView,
              let page = pages.object(forKey: webView) else { return }
        if message.name == "rupertForm" {
            page.formEdited()
        } else if let colors = BannerColors(json: message.body) {
            page.apply(colors)
        }
    }
}

private extension UIColor {
    /// "#rrggbb" or "#rgb", as CSS custom properties hold them.
    convenience init?(hex: String?) {
        guard var digits = hex?.trimmingCharacters(in: .whitespaces), digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
