import Foundation

/// One step needed to revert a change. Paths are stored in "<Root>/a/b" form so they
/// re-resolve correctly even if the app's or Madeira's container path changes.
public enum UndoStep: Codable, Equatable, Sendable {
    /// Put a backed-up item (relative to the change's backup folder) back at `target`.
    case restore(backup: String, target: String)
    /// The change created `target`; undo moves it into backups.
    case removeCreated(target: String)
    /// The change created this folder; undo removes it only if it is empty.
    case removeCreatedDirectoryIfEmpty(target: String)
    /// The change moved an item from `to` to `from`; undo moves it back.
    case moveBack(from: String, to: String)
}

public struct ChangeRecord: Codable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let tool: String
    public var summary: String
    public var steps: [UndoStep]
    public var undone: Bool

    public var jsonValue: JSONValue {
        [
            "change_id": .string(id),
            "date": JSONValue(date),
            "tool": .string(tool),
            "summary": .string(summary),
            "undone": .bool(undone),
            "steps": JSONValue(steps.count),
        ]
    }
}

/// Collects undo steps and backups while a mutating tool runs.
public final class ChangeBuilder {
    public let id: String
    public let tool: String
    let folder: URL
    private(set) var steps: [UndoStep] = []
    private var counter = 0

    init(id: String, tool: String, folder: URL) {
        self.id = id
        self.tool = tool
        self.folder = folder
    }

    /// Backs up an existing item before it is overwritten or removed. With `move`, the
    /// item is moved into the backup (cheap, used when it will be replaced or deleted).
    func backup(_ path: ResolvedPath, move: Bool) throws {
        guard FS.exists(path.url) else { return }
        counter += 1
        let relative = "\(counter)/\(path.name)"
        let destination = folder.appendingPathComponent(relative)
        try FS.createDirectory(destination.deletingLastPathComponent())
        do {
            if move {
                try FS.moveOrCopy(path.url, to: destination)
            } else {
                try FS.fm.copyItem(at: path.url, to: destination)
            }
        } catch {
            throw ToolError("Could not back up '\(path.display)' before changing it: \(error.localizedDescription)")
        }
        steps.append(.restore(backup: relative, target: path.display))
    }

    func created(_ path: ResolvedPath) {
        steps.append(.removeCreated(target: path.display))
    }

    func createdDirectory(_ path: ResolvedPath) {
        steps.append(.removeCreatedDirectoryIfEmpty(target: path.display))
    }

    func moved(from source: ResolvedPath, to destination: ResolvedPath) {
        steps.append(.moveBack(from: destination.display, to: source.display))
    }

    /// Creates a folder and any missing parents, recording each newly created level.
    func ensureDirectory(_ path: ResolvedPath) throws {
        var missing: [ResolvedPath] = []
        var current: ResolvedPath? = path
        while let candidate = current, !candidate.isRoot, !FS.exists(candidate.url) {
            missing.append(candidate)
            current = candidate.parent
        }
        if let blocking = current, !FS.isDirectory(blocking.url) {
            throw ToolError("'\(blocking.display)' is not a folder.")
        }
        for directory in missing.reversed() {
            do {
                try FS.fm.createDirectory(at: directory.url, withIntermediateDirectories: false)
            } catch {
                throw ToolError("Could not create folder '\(directory.display)': \(error.localizedDescription)")
            }
            createdDirectory(directory)
        }
    }
}

/// Persists the change log and backups, and performs undo.
public final class ChangeStore: @unchecked Sendable {
    public let directory: URL
    private let logURL: URL
    private let lock = NSLock()
    private var records: [ChangeRecord]
    private let maxRecords: Int

    public init(directory: URL, maxRecords: Int = 100) {
        self.directory = directory
        self.logURL = directory.appendingPathComponent("changes.json")
        self.maxRecords = maxRecords
        try? FS.createDirectory(directory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: logURL), let saved = try? decoder.decode([ChangeRecord].self, from: data) {
            records = saved
        } else {
            records = []
        }
    }

    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    func begin(tool: String) -> ChangeBuilder {
        let suffix = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
        let id = "ch-\(Self.idFormatter.string(from: Date()))-\(suffix)"
        return ChangeBuilder(id: id, tool: tool, folder: directory.appendingPathComponent(id))
    }

    /// Saves the change if it did anything. Returns the stored record.
    @discardableResult
    func commit(_ builder: ChangeBuilder, summary: String) -> ChangeRecord? {
        guard !builder.steps.isEmpty else {
            try? FS.fm.removeItem(at: builder.folder)
            return nil
        }
        let record = ChangeRecord(
            id: builder.id, date: Date(), tool: builder.tool, summary: summary, steps: builder.steps, undone: false)
        lock.lock()
        records.append(record)
        let pruned = records.count > maxRecords ? Array(records.prefix(records.count - maxRecords)) : []
        records.removeFirst(pruned.count)
        saveLocked()
        lock.unlock()
        for old in pruned {
            try? FS.fm.removeItem(at: directory.appendingPathComponent(old.id))
        }
        return record
    }

    /// Runs a mutation, committing whatever it recorded even if it fails partway.
    func perform<T>(tool: String, summary: (T?) -> String, _ body: (ChangeBuilder) throws -> T) throws -> (
        T, ChangeRecord?
    ) {
        let builder = begin(tool: tool)
        do {
            let value = try body(builder)
            return (value, commit(builder, summary: summary(value)))
        } catch {
            if let record = commit(builder, summary: summary(nil) + " (failed partway)") {
                throw ToolError(
                    "\((error as? ToolError)?.message ?? error.localizedDescription) "
                        + "Partial changes were recorded as \(record.id) and can be reverted with undo_change.")
            }
            throw error
        }
    }

    public func list(limit: Int) -> [ChangeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(records.suffix(limit).reversed())
    }

    public func clearAll() {
        lock.lock()
        records.removeAll()
        lock.unlock()
        if let contents = try? FS.fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in contents { try? FS.fm.removeItem(at: url) }
        }
        lock.lock()
        saveLocked()
        lock.unlock()
    }

    public var backupSize: UInt64 { FS.directorySize(directory) }

    private func saveLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(records) {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    /// Reverts a change. Returns a human-readable report.
    func undo(id: String, resolver: PathResolver) throws -> String {
        lock.lock()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            throw ToolError("No change with id '\(id)'. Use list_changes to see recent changes.")
        }
        let record = records[index]
        lock.unlock()
        if record.undone { throw ToolError("Change \(id) was already undone.") }

        let folder = directory.appendingPathComponent(id)
        let trash = folder.appendingPathComponent("replaced-by-undo-\(Int(Date().timeIntervalSince1970))")
        var trashCounter = 0
        var done: [String] = []
        var problems: [String] = []

        func moveToTrash(_ url: URL) throws {
            trashCounter += 1
            let destination = trash.appendingPathComponent("\(trashCounter)/\(url.lastPathComponent)")
            try FS.createDirectory(destination.deletingLastPathComponent())
            try FS.moveOrCopy(url, to: destination)
        }

        for step in record.steps.reversed() {
            do {
                switch step {
                case .restore(let backup, let target):
                    let path = try resolver.resolve(target)
                    let source = folder.appendingPathComponent(backup)
                    guard FS.exists(source) else {
                        problems.append("Backup for \(target) is missing.")
                        continue
                    }
                    if FS.exists(path.url) { try moveToTrash(path.url) }
                    try FS.createDirectory(path.url.deletingLastPathComponent())
                    try FS.moveOrCopy(source, to: path.url)
                    done.append("restored \(target)")
                case .removeCreated(let target):
                    let path = try resolver.resolve(target)
                    if FS.exists(path.url) {
                        try moveToTrash(path.url)
                        done.append("removed \(target)")
                    }
                case .removeCreatedDirectoryIfEmpty(let target):
                    let path = try resolver.resolve(target)
                    if FS.isDirectory(path.url),
                        (try? FS.fm.contentsOfDirectory(atPath: path.url.path))?.isEmpty == true
                    {
                        try FS.fm.removeItem(at: path.url)
                        done.append("removed folder \(target)")
                    }
                case .moveBack(let from, let to):
                    let source = try resolver.resolve(from)
                    let destination = try resolver.resolve(to)
                    guard FS.exists(source.url) else {
                        problems.append("\(from) no longer exists, so it could not be moved back to \(to).")
                        continue
                    }
                    guard !FS.exists(destination.url) else {
                        problems.append("\(to) already exists, so \(from) was not moved back.")
                        continue
                    }
                    try FS.createDirectory(destination.url.deletingLastPathComponent())
                    try FS.moveOrCopy(source.url, to: destination.url)
                    done.append("moved \(from) back to \(to)")
                }
            } catch {
                problems.append((error as? ToolError)?.message ?? error.localizedDescription)
            }
        }

        lock.lock()
        if let current = records.firstIndex(where: { $0.id == id }) { records[current].undone = true }
        saveLocked()
        lock.unlock()

        var report = "Undid \(id) (\(record.summary)).\n"
        report += done.isEmpty ? "Nothing needed restoring.\n" : done.map { "- \($0)" }.joined(separator: "\n") + "\n"
        if trashCounter > 0 {
            report += "Items that were replaced by the undo were kept in the app's backups.\n"
        }
        if !problems.isEmpty {
            report += "Problems:\n" + problems.map { "- \($0)" }.joined(separator: "\n")
        }
        return report
    }
}
