import FilesCore
import Foundation
import UIKit

/// Runs the Claude file bridge inside another app (Madeira) after being injected into
/// its IPA. Because it runs in the host app's own process, it can read and change the
/// host's data folder directly: no Files picker and no cross-app permission needed.
///
/// Configuration comes from `ClaudeBridge.json` inside this framework (written by
/// tools/inject_claude_bridge.py) and can be overridden by
/// `Documents/ClaudeBridge/config.json` in the host app's data folder.
@objc(ClaudeBridgeStarter)
public final class ClaudeBridgeStarter: NSObject {
    @MainActor private static var bridge: ClaudeBridge?

    @objc public static func start() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard bridge == nil else { return }
                bridge = ClaudeBridge()
            }
        }
    }
}

struct BridgeConfig: Codable {
    var relayURL: String
    var token: String
    var allowChanges: Bool?
}

@MainActor
final class ClaudeBridge {
    private let relay = RelayClient()
    private let router: ToolRouter
    private let config: BridgeConfig?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeBridge", isDirectory: true)
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let hostName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Host"
        BridgeLog.log("===== Claude bridge starting in \(hostName) (\(Bundle.main.bundleIdentifier ?? "?")) =====")

        let config = Self.loadConfig()
        self.config = config
        let allowChanges = config?.allowChanges ?? true

        // The whole app container: Documents (Madeira's wine prefix lives in
        // Documents/wine), Library and tmp.
        let rootName = hostName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "")
        let roots = [Root(name: rootName.isEmpty ? "Host" : rootName, url: Self.home)]
        let device = UIDevice.current
        let info: [String: JSONValue] = [
            "host_app": .string(hostName),
            "bridge": "injected ClaudeBridge.framework",
            "device": .string(device.model),
            "system": .string("\(device.systemName) \(device.systemVersion)"),
            "bridge_folder": .string("\(rootName)/Documents/ClaudeBridge (log: bridge.log, backups: Backups)"),
        ]
        router = ToolRouter(
            changes: ChangeStore(directory: Self.folder.appendingPathComponent("Backups", isDirectory: true)),
            roots: { roots },
            allowChanges: { allowChanges },
            deviceInfo: { info })

        relay.onStateChange = { state in BridgeLog.log("Relay: \(state)") }
        relay.handleCall = { [weak self] tool, arguments in
            guard let self else { return .error("The bridge is shutting down.") }
            let started = Date()
            let result = await self.router.handle(tool: tool, arguments: arguments)
            BridgeLog.log(
                String(format: "Tool %@ %@ in %.2fs", tool, result.isError ? "FAILED" : "ok", Date().timeIntervalSince(started)))
            return result
        }

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        }
        connect()
    }

    private static func loadConfig() -> BridgeConfig? {
        let override = folder.appendingPathComponent("config.json")
        let bundled = Bundle(for: ClaudeBridgeStarter.self).url(forResource: "ClaudeBridge", withExtension: "json")
        for url in [override, bundled].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let config = try JSONDecoder().decode(BridgeConfig.self, from: data)
                BridgeLog.log("Config loaded from \(url.lastPathComponent == "config.json" ? "Documents/ClaudeBridge/config.json" : "the framework")")
                return config
            } catch {
                BridgeLog.log("Config at \(url.path) is invalid: \(error)")
            }
        }
        BridgeLog.log("No config found; the bridge stays offline. Re-run inject_claude_bridge.py with --connector-url.")
        return nil
    }

    private var socketURL: URL? {
        guard let config else { return nil }
        var base = config.relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("https://") {
            base = "wss://" + base.dropFirst(8)
        } else if base.hasPrefix("http://") {
            base = "ws://" + base.dropFirst(7)
        }
        return URL(string: "\(base)/\(config.token)/device")
    }

    private func connect() {
        guard let url = socketURL else { return }
        relay.start(url: url)
    }

    private func becameActive() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        connect()
    }

    private func enteredBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ClaudeBridge") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.relay.stop()
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
    }
}

/// Appends to Documents/ClaudeBridge/bridge.log in the host app's data folder.
enum BridgeLog {
    private static let queue = DispatchQueue(label: "ClaudeBridgeLog")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let url = ClaudeBridge.folder.appendingPathComponent("bridge.log")
            let fm = FileManager.default
            try? fm.createDirectory(at: ClaudeBridge.folder, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 1_000_000 {
                try? fm.removeItem(at: url)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
