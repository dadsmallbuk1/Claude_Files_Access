import SwiftUI

/// Browses the file system directly, without the Files picker. This only reaches other
/// apps' folders when the app is not sandboxed from them, e.g. when both run inside
/// LiveContainer, where each app's data folder is a sibling of this app's home folder.
struct FolderBrowserView: View {
    let onChoose: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var current: URL = FolderStore.homeParent
    @State private var entries: [Entry] = []
    @State private var error: String?

    struct Entry: Identifiable {
        let url: URL
        let isDirectory: Bool
        let label: String?
        var id: String { url.path }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(current.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button {
                        AppLog.log("Folder browser: chose \(current.path)")
                        onChoose(current)
                        dismiss()
                    } label: {
                        Label("Share This Folder", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(error != nil)
                    if current.path != "/" {
                        Button {
                            open(current.deletingLastPathComponent())
                        } label: {
                            Label("Up One Level", systemImage: "arrow.up.circle")
                        }
                    }
                } footer: {
                    Text(
                        "Folders named with long IDs are app data folders; the app's ID is shown under each. Open Madeira's folder, then tap Share This Folder."
                    )
                }

                Section("Jump To") {
                    Button("Other Apps' Data Folders") { open(FolderStore.homeParent) }
                    Button("This App's Folder") { open(URL(fileURLWithPath: NSHomeDirectory())) }
                }

                Section("Contents") {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else if entries.isEmpty {
                        Text("No folders here.").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        Button {
                            open(entry.url)
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.url.lastPathComponent).foregroundStyle(.primary)
                                    if let label = entry.label {
                                        Text(label).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Browse Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { open(current) }
        }
    }

    private func open(_ url: URL) {
        current = url
        let fm = FileManager.default
        do {
            let children = try fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
            entries = children
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { Entry(url: $0, isDirectory: true, label: Self.appLabel(for: $0)) }
            error = nil
            AppLog.log("Folder browser: listed \(url.path) (\(entries.count) folders)")
        } catch {
            entries = []
            self.error = "Can't open this folder: \(error.localizedDescription)"
            AppLog.log("Folder browser: cannot list \(url.path): \(error)")
        }
    }

    /// Identifies an app data folder by the preference files inside it, which are
    /// named after the app's bundle ID (e.g. Library/Preferences/com.example.app.plist).
    nonisolated static func appLabel(for url: URL) -> String? {
        let preferences = url.appendingPathComponent("Library/Preferences")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: preferences.path) else { return nil }
        let ids = names
            .filter { $0.hasSuffix(".plist") && !$0.hasPrefix("com.apple.") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(6)) }
            .sorted { $0.count < $1.count }
        guard !ids.isEmpty else { return nil }
        return ids.prefix(2).joined(separator: ", ")
    }
}
