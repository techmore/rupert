import AVFoundation
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
        guard DataScannerViewController.isSupported else {
            showProblem("This device cannot read barcodes with its camera. Type the code or use a barcode scanner instead.",
                        settings: false, on: presenter)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            // First scan: ask for the camera here, instead of telling the person to go to Settings
            // for a permission they were never asked for.
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.scan(for: webView) }
                }
            }
            return
        case .denied, .restricted:
            showProblem("Allow camera access for Rupert in Settings to scan barcodes.", settings: true, on: presenter)
            return
        default:
            break
        }
        guard DataScannerViewController.isAvailable else {
            showProblem("The camera is in use or restricted on this device. Type the code instead.", settings: false, on: presenter)
            return
        }

        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode()], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isHighlightingEnabled: true)
        let session = ScanSession(webView: webView)
        scanner.delegate = session
        objc_setAssociatedObject(scanner, &ScanSession.key, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        addHint(to: scanner)

        let navigation = UINavigationController(rootViewController: scanner)
        scanner.navigationItem.title = "Scan a Barcode"
        scanner.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak navigation] _ in
            Torch.set(false)
            navigation?.dismiss(animated: true)
        })
        if Torch.isAvailable {
            scanner.navigationItem.rightBarButtonItem = Torch.button()
        }
        navigation.modalPresentationStyle = .fullScreen
        presenter.present(navigation, animated: true) {
            do {
                try scanner.startScanning()
            } catch {
                navigation.dismiss(animated: true) {
                    self.showProblem("The camera did not start. Try again, or type the code.", settings: false, on: presenter)
                }
            }
        }
    }

    /// A line under the viewfinder saying what to do, in the system's material.
    @MainActor
    private func addHint(to scanner: DataScannerViewController) {
        let label = UILabel()
        label.text = "Point the camera at a barcode. It saves as soon as it reads one."
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        background.layer.cornerRadius = 14
        background.clipsToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        background.contentView.addSubview(label)
        let overlay = scanner.overlayContainerView
        overlay.addSubview(background)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: background.contentView.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: background.contentView.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: background.contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: background.contentView.trailingAnchor, constant: -14),
            background.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            background.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.readableContentGuide.leadingAnchor),
            background.trailingAnchor.constraint(lessThanOrEqualTo: overlay.readableContentGuide.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    @MainActor
    private func showProblem(_ reason: String, settings: Bool, on presenter: UIViewController) {
        let alert = UIAlertController(title: "Camera scanning is unavailable", message: reason, preferredStyle: .alert)
        if settings, let url = URL(string: UIApplication.openSettingsURLString) {
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in UIApplication.shared.open(url) })
        }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        presenter.present(alert, animated: true)
    }
}

/// The phone's flashlight, for barcodes in a dim stockroom.
@MainActor
private enum Torch {
    static var isAvailable: Bool { AVCaptureDevice.default(for: .video)?.hasTorch ?? false }

    static func set(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch,
              (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    static func button() -> UIBarButtonItem {
        let item = UIBarButtonItem()
        var on = false
        let update = {
            item.image = UIImage(systemName: on ? "flashlight.on.fill" : "flashlight.off.fill")
            item.accessibilityLabel = on ? "Turn off flashlight" : "Turn on flashlight"
        }
        update()
        item.primaryAction = UIAction(image: item.image) { _ in
            on.toggle()
            set(on)
            update()
        }
        update()
        return item
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
        Task { @MainActor in Torch.set(false) }
        let detail = (try? JSONSerialization.data(withJSONObject: [code], options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let script = "window.dispatchEvent(new CustomEvent('rupert:scanned', { detail: \(detail)[0] }))"
        dataScanner.dismiss(animated: true) { [weak webView] in
            webView?.evaluateJavaScript(script)
            UIAccessibility.post(notification: .announcement, argument: "Scanned \(code)")
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
