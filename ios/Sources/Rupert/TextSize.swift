import UIKit
import WebKit

/// Rupert's pages follow the iPhone's text size (Settings › Accessibility › Display & Text Size).
///
/// The pages size text in CSS, so on their own they ignore Dynamic Type: at the largest sizes only
/// the native title and tab labels grew. Rupert's CSS is in rem, so the app scales the root font
/// size by the ratio of the body text size to its default (17 pt). Text and spacing grow and the
/// layout still reflows to the phone's width (WKWebView's pageZoom did not reflow). Capped so
/// tables and forms still fit a phone.
@MainActor
enum TextSize {
    static let range: ClosedRange<CGFloat> = 0.85...1.5

    private static let webViews = NSHashTable<WKWebView>.weakObjects()
    private static var observer: NSObjectProtocol?

    static func zoom(for category: UIContentSizeCategory) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize
        return min(max(body / 17, range.lowerBound), range.upperBound)
    }

    static var currentZoom: CGFloat {
        zoom(for: UIApplication.shared.preferredContentSizeCategory)
    }

    static func script(_ zoom: CGFloat) -> String {
        "document.documentElement.style.fontSize = '\(Int((zoom * 100).rounded()))%'"
    }

    /// Scales `webView`'s pages from their first paint, and again whenever the text size changes.
    static func follow(_ webView: WKWebView) {
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: script(currentZoom), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webViews.add(webView)
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    webViews.allObjects.forEach(apply(to:))
                }
            }
        }
    }

    /// The text size now; also run after each render, for pages loaded after a change.
    static func apply(to webView: WKWebView) {
        webView.evaluateJavaScript(script(currentZoom))
    }
}
