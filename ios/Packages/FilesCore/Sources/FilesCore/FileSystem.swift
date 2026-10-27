import Foundation

/// Metadata for one directory entry.
public struct EntryInfo: Sendable {
    public enum Kind: String, Sendable { case file, directory, symlink, other }

    public let url: URL
    public let kind: Kind
    public let size: UInt64
    public let modified: Date?
    public let created: Date?
    public let symlinkTarget: String?

    public var isDirectory: Bool { kind == .directory }
}

enum FS {
    static let fm = FileManager.default
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        .creationDateKey,
    ]

    /// Information about an item without following a final symlink.
    static func info(_ url: URL) throws -> EntryInfo {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fm.attributesOfItem(atPath: url.path)
        } catch {
            throw ToolError("'\(url.lastPathComponent)' does not exist or cannot be read.")
        }
        let type = attributes[.type] as? FileAttributeType
        let kind: EntryInfo.Kind
        switch type {
        case .typeDirectory?: kind = .directory
        case .typeRegular?: kind = .file
        case .typeSymbolicLink?: kind = .symlink
        default: kind = .other
        }
        let target = kind == .symlink ? try? fm.destinationOfSymbolicLink(atPath: url.path) : nil
        return EntryInfo(
            url: url,
            kind: kind,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attributes[.modificationDate] as? Date,
            created: attributes[.creationDate] as? Date,
            symlinkTarget: target
        )
    }

    static func exists(_ url: URL) -> Bool {
        // fileExists follows symlinks; also count dangling symlinks as existing.
        fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Directory entries sorted by name (case-insensitive). Does not follow symlinked folders.
    static func children(of url: URL, includeHidden: Bool) throws -> [EntryInfo] {
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: resourceKeys, options: includeHidden ? [] : [.skipsHiddenFiles])
        } catch {
            throw ToolError("Cannot list '\(url.lastPathComponent)': \(error.localizedDescription)")
        }
        return urls
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { childURL in
                guard let values = try? childURL.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
                let kind: EntryInfo.Kind
                if values.isSymbolicLink == true {
                    kind = .symlink
                } else if values.isDirectory == true {
                    kind = .directory
                } else if values.isRegularFile == true {
                    kind = .file
                } else {
                    kind = .other
                }
                let target = kind == .symlink ? try? fm.destinationOfSymbolicLink(atPath: childURL.path) : nil
                return EntryInfo(
                    url: childURL,
                    kind: kind,
                    size: UInt64(values.fileSize ?? 0),
                    modified: values.contentModificationDate,
                    created: values.creationDate,
                    symlinkTarget: target
                )
            }
    }

    /// Depth-first walk that never descends into symlinks. `visit` returns false to stop.
    static func walk(
        _ url: URL, relative: [String] = [], depth: Int = 1, maxDepth: Int, includeHidden: Bool,
        visit: (EntryInfo, [String], Int) throws -> Bool
    ) throws -> Bool {
        let entries: [EntryInfo]
        do {
            entries = try children(of: url, includeHidden: includeHidden)
        } catch {
            return true  // Skip unreadable folders.
        }
        for entry in entries {
            let rel = relative + [entry.url.lastPathComponent]
            if try !visit(entry, rel, depth) { return false }
            if entry.kind == .directory && depth < maxDepth {
                if try !walk(
                    entry.url, relative: rel, depth: depth + 1, maxDepth: maxDepth, includeHidden: includeHidden,
                    visit: visit)
                {
                    return false
                }
            }
        }
        return true
    }

    static func createDirectory(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Moves an item, falling back to copy + delete when a rename is not possible (e.g. across volumes).
    static func moveOrCopy(_ source: URL, to destination: URL) throws {
        do {
            try fm.moveItem(at: source, to: destination)
        } catch {
            try fm.copyItem(at: source, to: destination)
            try fm.removeItem(at: source)
        }
    }

    static func directorySize(_ url: URL) -> UInt64 {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += UInt64(values?.fileSize ?? 0) }
        }
        return total
    }
}

enum Format {
    static func bytes(_ count: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(count)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(count) B" : String(format: "%.1f %@", value, units[unit])
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func date(_ date: Date?) -> String {
        guard let date else { return "-" }
        return dateFormatter.string(from: date)
    }

    static func iso(_ date: Date?) -> JSONValue {
        JSONValue(date)
    }
}
