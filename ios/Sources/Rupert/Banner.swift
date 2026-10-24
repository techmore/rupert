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
    }

    override func visitableDidActivateWebView(_ webView: WKWebView) {
        super.visitableDidActivateWebView(webView)
        BannerBridge.shared.pages.setObject(self, forKey: webView)
    }

    override func visitableDidRender() {
        super.visitableDidRender()
        guard let webView = visitableView.webView else { return }
        webView.evaluateJavaScript(BannerColors.readScript) { [weak self] value, _ in
            self?.apply(BannerColors(json: value) ?? .fallback)
        }
    }

    func apply(_ colors: BannerColors) {
        self.colors = colors
        BannerColors.current = colors
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

/// Lets the top page decide the status bar text colour, so it stays readable on the banner.
final class BannerNavigationController: HotwireNavigationController {
    override var childForStatusBarStyle: UIViewController? { topViewController }
}

/// Receives the page's appearance changes and hands them to the page showing that web view.
final class BannerBridge: NSObject, WKScriptMessageHandler {
    static let shared = BannerBridge()
    let pages = NSMapTable<WKWebView, BannerWebViewController>.weakToWeakObjects()

    static func install(in controller: WKUserContentController) {
        controller.add(shared, name: "rupertBanner")
        controller.addUserScript(WKUserScript(source: BannerColors.watchScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let page = pages.object(forKey: webView),
              let colors = BannerColors(json: message.body) else { return }
        page.apply(colors)
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
