import Foundation
import UIKit

/// Appends timestamped lines to Documents/Logs/app.log (visible in Files under
/// On My iPhone › Claude Files). Writes happen on a background queue and go straight
/// to disk, so the log survives the app being force-quit after a hang.
enum AppLog {
    private static let queue = DispatchQueue(label: "AppLog")
    private static let maxBytes: UInt64 = 1_000_000

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("app.log") }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) [\(Thread.isMainThread ? "main" : "bg")] \(message)\n"
        queue.async { write(line) }
    }

    private static func write(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value, size > maxBytes {
            let previous = directory.appendingPathComponent("app.previous.log")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: url, to: previous)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// The last part of the log, for showing in the app.
    static func tail(maxBytes: Int = 16_000) -> String {
        queue.sync {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return "" }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
            return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        }
    }

    static func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("app.previous.log"))
        }
        log("Log cleared")
    }

    static func logLaunch() {
        let info = Bundle.main.infoDictionary ?? [:]
        let device = UIDevice.current
        log("===== Launch =====")
        log(
            "App \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")), bundle \(Bundle.main.bundleIdentifier ?? "?")"
        )
        log("Device \(device.model), \(device.systemName) \(device.systemVersion)")
        log(
            "Built with SDK \(info["DTSDKName"] ?? "?"), Xcode \(info["DTXcode"] ?? "?") (\(info["DTXcodeBuild"] ?? "?"))"
        )
        NSSetUncaughtExceptionHandler { exception in
            let line = "UNCAUGHT EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n"
            // Write synchronously: the process is about to die.
            if let handle = try? FileHandle(forWritingTo: AppLog.fileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            }
        }
        MainThreadWatchdog.shared.start()
    }
}

/// Logs whenever the main thread stops responding for more than a couple of seconds,
/// and how long it was stuck. A stuck main thread is what makes the app "freeze".
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    private let queue = DispatchQueue(label: "MainThreadWatchdog")
    private var timer: DispatchSourceTimer?
    private var lastResponse = Date()
    private var stallStarted: Date?
    private let lock = NSLock()

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.lastResponse = Date()
            let started = self.stallStarted
            self.stallStarted = nil
            self.lock.unlock()
            if let started {
                AppLog.log(String(format: "Main thread responsive again after %.1fs", Date().timeIntervalSince(started)))
            }
        }
        lock.lock()
        let silence = Date().timeIntervalSince(lastResponse)
        var newStall = false
        if silence > 2.5 && stallStarted == nil {
            stallStarted = lastResponse
            newStall = true
        }
        lock.unlock()
        if newStall {
            AppLog.log(String(format: "MAIN THREAD STALLED (no response for %.1fs)", silence))
        }
    }
}
