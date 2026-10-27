import FilesCore
import SwiftUI
import UIKit

/// Values read by the tool router from background threads.
final class SharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _roots: [Root] = []
    private var _allowChanges = true

    var roots: [Root] {
        get { lock.lock(); defer { lock.unlock() }; return _roots }
        set { lock.lock(); _roots = newValue; lock.unlock() }
    }

    var allowChanges: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _allowChanges }
        set { lock.lock(); _allowChanges = newValue; lock.unlock() }
    }
}

struct ActivityItem: Identifiable {
    let id = UUID()
    let date: Date
    let tool: String
    let detail: String
    let isError: Bool
    let duration: TimeInterval
}

@MainActor
final class AppModel: ObservableObject {
    @Published var relayBaseURL: String {
        didSet {
            UserDefaults.standard.set(relayBaseURL, forKey: "relayBaseURL")
            if relay.state != .disconnected { connect() }
        }
    }
    @Published var allowChanges: Bool {
        didSet {
            UserDefaults.standard.set(allowChanges, forKey: "allowChanges")
            shared.allowChanges = allowChanges
        }
    }
    @Published var keepScreenAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenAwake, forKey: "keepScreenAwake")
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
        }
    }
    @Published private(set) var token: String
    @Published private(set) var folders: [SharedFolder] = []
    @Published private(set) var connection: RelayClient.State = .disconnected
    @Published private(set) var activity: [ActivityItem] = []
    @Published private(set) var backupSize: String = "-"
    @Published var errorMessage: String?

    let shared: SharedState
    let folderStore = FolderStore()
    let router: ToolRouter
    private let relay = RelayClient()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static var backupsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
    }

    init() {
        let defaults = UserDefaults.standard
        let allowChangesSetting = defaults.object(forKey: "allowChanges") as? Bool ?? true
        relayBaseURL = defaults.string(forKey: "relayBaseURL") ?? ""
        allowChanges = allowChangesSetting
        keepScreenAwake = defaults.bool(forKey: "keepScreenAwake")

        var savedToken = Keychain.read("relayToken") ?? ""
        if savedToken.count < 32 {
            savedToken = Keychain.makeSecret()
            Keychain.write(savedToken, for: "relayToken")
        }
        token = savedToken

        let shared = SharedState()
        shared.allowChanges = allowChangesSetting
        self.shared = shared
        let device = UIDevice.current
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let deviceInfo: [String: JSONValue] = [
            "app_version": .string(appVersion),
            "device": .string(device.model),
            "system": .string("\(device.systemName) \(device.systemVersion)"),
        ]
        router = ToolRouter(
            changes: ChangeStore(directory: Self.backupsDirectory),
            roots: { shared.roots },
            allowChanges: { shared.allowChanges },
            deviceInfo: { deviceInfo })

        relay.onStateChange = { [weak self] state in self?.connection = state }
        relay.handleCall = { [weak self] tool, arguments in
            guard let self else { return .error("The app is shutting down.") }
            return await self.run(tool: tool, arguments: arguments)
        }

        reloadFolders()
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
    }

    // MARK: Connection

    var connectorURL: String? {
        guard let base = normalizedBase() else { return nil }
        return "\(base)/\(token)/mcp"
    }

    private func normalizedBase() -> String? {
        var base = relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        if !base.contains("://") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base), let scheme = url.scheme, ["https", "http"].contains(scheme), url.host != nil
        else { return nil }
        return base
    }

    private var deviceSocketURL: URL? {
        guard let base = normalizedBase() else { return nil }
        let wsBase = base.hasPrefix("https://") ? "wss://" + base.dropFirst(8) : "ws://" + base.dropFirst(7)
        return URL(string: "\(wsBase)/\(token)/device")
    }

    func connect() {
        guard let url = deviceSocketURL else {
            relay.stop()
            return
        }
        relay.start(url: url)
    }

    func disconnect() {
        relay.stop()
    }

    func regenerateToken() {
        token = Keychain.makeSecret()
        Keychain.write(token, for: "relayToken")
        if connection != .disconnected {
            relay.stop()
            connect()
        }
    }

    func sceneDidChange(to phase: ScenePhase) {
        switch phase {
        case .active:
            endBackgroundTask()
            reloadFolders()
            connect()
        case .background:
            // iOS gives a short grace period; after that the socket is closed and
            // reopened when the app comes back.
            guard backgroundTask == .invalid else { return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "relay") { [weak self] in
                Task { @MainActor in
                    self?.relay.stop()
                    self?.endBackgroundTask()
                }
            }
        default:
            break
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Tool calls

    private func run(tool: String, arguments: [String: JSONValue]) async -> ToolResult {
        let started = Date()
        let result = await router.handle(tool: tool, arguments: arguments)
        let detail = ["path", "source", "url", "change_id", "job_id"]
            .compactMap { arguments[$0]?.stringValue }
            .joined(separator: " → ")
        activity.insert(
            ActivityItem(
                date: started, tool: tool, detail: result.isError ? "\(detail)\n\(result.text.prefix(200))" : detail,
                isError: result.isError, duration: Date().timeIntervalSince(started)), at: 0)
        if activity.count > 100 { activity.removeLast(activity.count - 100) }
        if ToolRouter.mutatingTools.contains(tool) { refreshBackupSize() }
        return result
    }

    // MARK: Folders

    func reloadFolders() {
        shared.roots = folderStore.resolveRoots()
        folders = folderStore.folders
        refreshBackupSize()
    }

    func addFolder(_ url: URL) {
        do {
            _ = try folderStore.add(url)
            reloadFolders()
        } catch {
            errorMessage = "Could not add the folder: \(error.localizedDescription)"
        }
    }

    func removeFolders(at offsets: IndexSet) {
        for index in offsets { folderStore.remove(folders[index].id) }
        reloadFolders()
    }

    func renameFolder(_ folder: SharedFolder, to name: String) {
        folderStore.rename(folder.id, to: name)
        // Re-resolve so the root uses the new name.
        reloadFolders()
    }

    func isAvailable(_ folder: SharedFolder) -> Bool {
        folderStore.isAvailable(folder)
    }

    // MARK: Backups

    func refreshBackupSize() {
        let changes = router.changes
        Task.detached {
            let size = ByteCountFormatter.string(fromByteCount: Int64(changes.backupSize), countStyle: .file)
            await MainActor.run { self.backupSize = size }
        }
    }

    func clearBackups() {
        router.changes.clearAll()
        refreshBackupSize()
    }
}
