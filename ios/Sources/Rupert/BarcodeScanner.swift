import UIKit
import VisionKit
import WebKit

/// Reads barcodes with the camera for Rupert's inventory scan page (/inventory_counts/:id/scan).
///
/// The page shows "Scan with camera" when the `rupertScanner` message handler exists
/// (inventory_count_scanner_controller.js). The app opens the system barcode scanner (VisionKit),
/// and hands the first code back to the page as a `rupert:scanned` event, which saves it.
final class BarcodeScanner: NSObject, WKScriptMessageHandler {
    static let shared = BarcodeScanner()

    static func install(in controller: WKUserContentController) {
        controller.add(shared, name: "rupertScanner")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView else { return }
        Task { @MainActor in self.scan(for: webView) }
    }

    @MainActor
    private func scan(for webView: WKWebView) {
        guard let presenter = webView.window?.rootViewController?.topmostPresented else { return }
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            let reason = DataScannerViewController.isSupported
                ? "Allow camera access for Rupert in Settings to scan barcodes."
                : "This device cannot read barcodes with its camera. Type the code or use a barcode scanner instead."
            let alert = UIAlertController(title: "Camera scanning is unavailable", message: reason, preferredStyle: .alert)
            if DataScannerViewController.isSupported, let settings = URL(string: UIApplication.openSettingsURLString) {
                alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in UIApplication.shared.open(settings) })
            }
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            presenter.present(alert, animated: true)
            return
        }

        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode()], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isHighlightingEnabled: true)
        let session = ScanSession(webView: webView)
        scanner.delegate = session
        objc_setAssociatedObject(scanner, &ScanSession.key, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let navigation = UINavigationController(rootViewController: scanner)
        scanner.navigationItem.title = "Scan a barcode"
        scanner.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak navigation] _ in
            navigation?.dismiss(animated: true)
        })
        navigation.modalPresentationStyle = .fullScreen
        presenter.present(navigation, animated: true) {
            try? scanner.startScanning()
        }
    }
}

/// One camera session: the first barcode read goes back to the page, then the scanner closes.
private final class ScanSession: NSObject, DataScannerViewControllerDelegate {
    static var key = 0
    weak var webView: WKWebView?
    private var done = false

    init(webView: WKWebView) {
        self.webView = webView
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in addedItems {
            if case let .barcode(barcode) = item, let code = barcode.payloadStringValue, !code.isEmpty {
                finish(dataScanner, code: code)
                return
            }
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
        if case let .barcode(barcode) = item, let code = barcode.payloadStringValue, !code.isEmpty {
            finish(dataScanner, code: code)
        }
    }

    private func finish(_ dataScanner: DataScannerViewController, code: String) {
        guard !done else { return }
        done = true
        dataScanner.stopScanning()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let detail = (try? JSONSerialization.data(withJSONObject: [code], options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let script = "window.dispatchEvent(new CustomEvent('rupert:scanned', { detail: \(detail)[0] }))"
        dataScanner.dismiss(animated: true) { [weak webView] in
            webView?.evaluateJavaScript(script)
        }
    }
}

extension UIViewController {
    /// The controller on top of everything this one presents.
    var topmostPresented: UIViewController {
        var top = self
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
