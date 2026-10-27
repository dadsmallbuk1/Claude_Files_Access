import UIKit
import UniformTypeIdentifiers

/// Presents the system folder picker straight from UIKit (Apple's intended usage).
@MainActor
final class FolderPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = FolderPicker()

    private var onPick: ((URL) -> Void)?

    func present(onPick: @escaping (URL) -> Void) {
        guard let presenter = Self.topViewController() else {
            AppLog.log("Folder picker: no view controller to present from")
            return
        }
        self.onPick = onPick

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self

        AppLog.log("Folder picker: presenting")
        let started = Date()
        presenter.present(picker, animated: true) {
            AppLog.log(String(format: "Folder picker: presented after %.2fs", Date().timeIntervalSince(started)))
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        AppLog.log("Folder picker: picked \(urls.map(\.path))")
        if let url = urls.first { onPick?(url) }
        onPick = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        AppLog.log("Folder picker: cancelled")
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
