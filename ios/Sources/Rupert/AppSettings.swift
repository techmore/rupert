import SwiftUI
import UIKit

/// App settings: a native sheet behind the person button on each tab's first page. The app lock,
/// where the app is pointed, help, privacy and deleting your account.
struct AppSettingsView: View {
    /// Opens a Rupert page in the current tab (the sheet closes first).
    var open: (URL) -> Void
    var close: () -> Void

    @State private var lockEnabled = AppLock.shared.isEnabled
    @State private var lockAvailable = AppLock.isAvailable
    private let method = AppLock.methodName

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Require \(method)", isOn: Binding(get: { lockEnabled }, set: setLock(_:)))
                        .disabled(!lockAvailable)
                } header: {
                    Text("Security")
                } footer: {
                    Text(lockAvailable
                        ? "Ask for \(method) each time Rupert comes back to the screen. The app switcher shows a cover instead of your pages."
                        : "Set a passcode on this iPhone to lock Rupert.")
                }

                Section("Workspace") {
                    LabeledContent("Connected to", value: Instance.current.host ?? "")
                }

                Section("Help") {
                    Button("Support") { open(Instance.url("/support", on: Instance.controlPlane)) }
                    Button("Report a problem") { open(Instance.url("/feedback_reports")) }
                    Button("Privacy policy") { open(Instance.url("/privacy", on: Instance.controlPlane)) }
                }

                Section {
                    Button("Delete account", role: .destructive) { open(Instance.url("/account/delete")) }
                } footer: {
                    Text("Erases your name, email and sign-in from Rupert. You confirm on the next page.")
                }

                Section {
                    LabeledContent("Version", value: Instance.appVersion)
                }
            }
            .navigationTitle("App settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                }
            }
        }
    }

    private func setLock(_ on: Bool) {
        guard on else {
            lockEnabled = false
            AppLock.shared.isEnabled = false
            return
        }
        Task { @MainActor in
            // Turning it on proves the person can unlock, so nobody locks themselves out.
            let ok = await AppLock.shared.confirm(reason: "Turn on \(method) for Rupert")
            lockEnabled = ok
            AppLock.shared.isEnabled = ok
        }
    }
}

/// Puts the person button on a tab's first page and presents the settings sheet.
enum AppSettings {
    /// Set by SceneController: open a URL in the selected tab.
    @MainActor static var openInApp: ((URL) -> Void)?

    @MainActor
    static func addButton(to controller: UIViewController) {
        guard controller.navigationItem.rightBarButtonItems?.contains(where: { $0.accessibilityIdentifier == "app-settings" }) != true else { return }
        let item = UIBarButtonItem(image: UIImage(systemName: "person.crop.circle"), primaryAction: UIAction { [weak controller] _ in
            guard let controller else { return }
            present(from: controller)
        })
        item.accessibilityLabel = "App settings"
        item.accessibilityIdentifier = "app-settings"
        controller.navigationItem.rightBarButtonItems = (controller.navigationItem.rightBarButtonItems ?? []) + [item]
    }

    @MainActor
    static func present(from controller: UIViewController) {
        weak var host: UIViewController?
        let view = AppSettingsView(
            open: { url in
                host?.dismiss(animated: true) { openInApp?(url) }
            },
            close: { host?.dismiss(animated: true) }
        )
        let sheet = UIHostingController(rootView: view)
        host = sheet
        sheet.sheetPresentationController?.detents = [.large()]
        controller.present(sheet, animated: true)
    }
}
