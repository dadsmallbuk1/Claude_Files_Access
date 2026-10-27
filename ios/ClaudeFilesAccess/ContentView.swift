import FilesCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var logText = ""
    @State private var showingLog = false
    @State private var confirmNewSecret = false
    @State private var confirmClearBackups = false
    @State private var renaming: SharedFolder?
    @State private var newName = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                connectorSection
                foldersSection
                optionsSection
                activitySection
                troubleshootingSection
                logSection
                helpSection
            }
            .navigationTitle("Claude Files Access")
            .sheet(isPresented: $showingLog) { logSheet }
            .alert("Rename folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let folder = renaming { model.renameFolder(folder, to: newName) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("Claude uses this name at the start of paths, e.g. \"\(newName.isEmpty ? "Madeira" : newName)/...\".")
            }
            .alert(
                "Picker Test", isPresented: Binding(get: { model.noticeMessage != nil }, set: { if !$0 { model.noticeMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.noticeMessage ?? "")
            }
            .alert(
                "Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Circle().fill(statusColor).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    if case .failed(let reason) = model.connection {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.connection == .disconnected {
                    Button("Connect") { model.connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.connectorURL == nil)
                } else {
                    Button("Disconnect") { model.disconnect() }
                        .buttonStyle(.bordered)
                }
            }
        } footer: {
            Text("Keep this app open while Claude works. On iPad you can put it in Split View next to Madeira.")
        }
    }

    private var connectorSection: some View {
        Section {
            TextField("https://claude-files-relay.<you>.workers.dev", text: $model.relayBaseURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())

            if let url = model.connectorURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connector URL for Claude").font(.caption).foregroundStyle(.secondary)
                    Text(url)
                        .font(.caption.monospaced())
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    HStack {
                        Button(copied ? "Copied" : "Copy URL") {
                            UIPasteboard.general.string = url
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        }
                        .buttonStyle(.bordered)
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.bordered)
                    }
                }
            }

            Button("Generate New Secret", role: .destructive) { confirmNewSecret = true }
                .confirmationDialog(
                    "Generate a new secret?", isPresented: $confirmNewSecret, titleVisibility: .visible
                ) {
                    Button("Generate", role: .destructive) { model.regenerateToken() }
                } message: {
                    Text("The current connector URL stops working. You'll need to update the connector in Claude.")
                }
        } header: {
            Text("Relay")
        } footer: {
            Text(
                "Enter the URL of your Cloudflare relay, then add the connector URL in Claude: Settings › Connectors › Add custom connector. The URL contains a secret, so don't share it."
            )
        }
    }

    private var foldersSection: some View {
        Section {
            ForEach(model.folders) { folder in
                HStack {
                    Image(systemName: model.isAvailable(folder) ? "folder.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.isAvailable(folder) ? Color.accentColor : .orange)
                    VStack(alignment: .leading) {
                        Text(folder.name)
                        if !model.isAvailable(folder) {
                            Text("Unavailable - remove and add it again").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    Button("Rename") {
                        newName = folder.name
                        renaming = folder
                    }
                }
                .swipeActions(edge: .leading) {
                    Button("Rename") {
                        newName = folder.name
                        renaming = folder
                    }
                    .tint(.blue)
                }
            }
            .onDelete { model.removeFolders(at: $0) }

            Button {
                model.presentFolderPicker()
            } label: {
                HStack {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                    if model.addingFolder {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(model.addingFolder)

        } header: {
            Text("Shared Folders")
        } footer: {
            Text(
                "Pick On My iPhone/iPad › Madeira (or the folder with your Wine prefix). Claude can only see folders listed here, plus this app's own folder (AppData)."
            )
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Allow Changes", isOn: $model.allowChanges)
            Toggle("Keep Screen Awake", isOn: $model.keepScreenAwake)
            HStack {
                Text("Backups")
                Spacer()
                Text(model.backupSize).foregroundStyle(.secondary)
            }
            Button("Clear Backups", role: .destructive) { confirmClearBackups = true }
                .confirmationDialog("Delete all backups?", isPresented: $confirmClearBackups, titleVisibility: .visible) {
                    Button("Delete Backups", role: .destructive) { model.clearBackups() }
                } message: {
                    Text("Claude will no longer be able to undo earlier changes.")
                }
        } header: {
            Text("Options")
        } footer: {
            Text(
                "With Allow Changes off, Claude can only read. Every change is backed up first (On My iPhone › Claude Files › Backups) and can be undone by asking Claude."
            )
        }
    }

    private var activitySection: some View {
        Section("Activity") {
            if model.activity.isEmpty {
                Text("No requests yet.").foregroundStyle(.secondary)
            }
            ForEach(model.activity.prefix(50)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: item.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(item.isError ? .red : .green)
                        Text(item.tool).font(.callout.monospaced())
                        Spacer()
                        Text(item.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    if !item.detail.isEmpty {
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
            }
        }
    }

    private var troubleshootingSection: some View {
        Section {
            Button("Add Folder by Ticking It") { model.presentFolderPicker(.folderWithCheckmarks) }
            Button("Test: Pick Any File") { model.testFilePicker() }
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text(
                "If Add Folder's Open button does nothing: try Add Folder by Ticking It (tap Select in the picker, tick the Madeira folder, then tap Open). Test: Pick Any File only checks whether the picker can return anything to this app; it doesn't add the file."
            )
        }
    }

    private var logSection: some View {
        Section {
            Button {
                logText = AppLog.tail()
                showingLog = true
            } label: {
                Label("View Log", systemImage: "doc.text.magnifyingglass")
            }
            ShareLink(item: AppLog.fileURL) {
                Label("Share Log File", systemImage: "square.and.arrow.up")
            }
            Button("Clear Log", role: .destructive) { AppLog.clear() }
        } header: {
            Text("Log")
        } footer: {
            Text(
                "Saved in Files › On My iPhone › Claude Files › Logs › app.log. Claude can also read it through the AppData folder."
            )
        }
    }

    private var logSheet: some View {
        NavigationStack {
            ScrollView {
                Text(logText.isEmpty ? "The log is empty." : logText)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingLog = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") { logText = AppLog.tail() }
                }
            }
        }
    }

    private var helpSection: some View {
        Section("How It Works") {
            Text(
                "Claude calls your relay, the relay forwards each request to this app, and the app reads or changes files in your shared folders. Nothing is stored on the relay."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private var statusColor: Color {
        switch model.connection {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var statusTitle: String {
        switch model.connection {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .failed: return "Reconnecting..."
        case .disconnected: return model.connectorURL == nil ? "Enter your relay URL" : "Not connected"
        }
    }
}
