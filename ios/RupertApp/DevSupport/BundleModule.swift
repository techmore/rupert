import Foundation

// SwiftPM generates `Bundle.module` for the package's resources. In the Xcode app target the same
// sources are compiled straight into the app, whose resources live in the main bundle.
extension Bundle {
    static var module: Bundle { .main }
}
