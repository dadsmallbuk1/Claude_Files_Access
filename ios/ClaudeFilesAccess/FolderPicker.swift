import UIKit
import UniformTypeIdentifiers

/// Presents the system Files picker straight from UIKit (Apple's intended usage).
@MainActor
final class FolderPicker: NSObject, UIDocumentPickerDelegate {
    enum Kind: String {
        /// Navigate into a folder and tap Open.
        case folder
        /// Tap Select, tick a folder and tap Open (a different path through the picker).
        case folderWithCheckmarks
        /// Pick any single file; used only to test whether picking works at all.
        case fileTest
    }

    static let shared = FolderPicker()

    private var onPick: ((URL) -> Void)?
    private var kind: Kind = .folder

    func present(_ kind: Kind, onPick: @escaping (URL) -> Void) {
        guard let presenter = Self.topViewController() else {
            AppLog.log("Picker: no view controller to present from")
            return
        }
        self.onPick = onPick
        self.kind = kind

        let picker: UIDocumentPickerViewController
        switch kind {
        case .folder:
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.allowsMultipleSelection = false
        case .folderWithCheckmarks:
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.allowsMultipleSelection = true
        case .fileTest:
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
            picker.allowsMultipleSelection = false
        }
        picker.delegate = self

        AppLog.log("Picker (\(kind.rawValue)): presenting")
        let started = Date()
        presenter.present(picker, animated: true) {
            AppLog.log(String(format: "Picker (%@): presented after %.2fs", kind.rawValue, Date().timeIntervalSince(started)))
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        AppLog.log("Picker (\(kind.rawValue)): picked \(urls.map(\.path))")
        if let url = urls.first { onPick?(url) }
        onPick = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        AppLog.log("Picker (\(kind.rawValue)): cancelled")
        onPick = nil
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
