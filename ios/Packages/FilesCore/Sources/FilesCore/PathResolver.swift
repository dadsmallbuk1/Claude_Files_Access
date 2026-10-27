import Foundation

/// A folder the user shared with the app (via the Files folder picker).
public struct Root: Sendable, Equatable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// A path that has been resolved to a location inside one of the roots.
public struct ResolvedPath: Sendable, Equatable {
    public let root: Root
    /// Path components below the root.
    public let components: [String]

    public var url: URL {
        components.reduce(root.url) { $0.appendingPathComponent($1) }
    }

    /// The path as Claude sees it: "<Root>/a/b".
    public var display: String {
        ([root.name] + components).joined(separator: "/")
    }

    public var isRoot: Bool { components.isEmpty }

    public var name: String { components.last ?? root.name }

    public var parent: ResolvedPath? {
        isRoot ? nil : ResolvedPath(root: root, components: Array(components.dropLast()))
    }

    public func appending(_ component: String) -> ResolvedPath {
        ResolvedPath(root: root, components: components + [component])
    }

    public func appending(components more: [String]) -> ResolvedPath {
        ResolvedPath(root: root, components: components + more)
    }
}

/// Maps "<Root>/sub/path" strings onto file URLs, refusing anything that would
/// escape the shared roots.
public struct PathResolver: Sendable {
    public let roots: [Root]

    public init(roots: [Root]) {
        self.roots = roots
    }

    /// Splits a user-supplied path into clean components. Accepts "/" or "\" separators.
    public static func components(of path: String) throws -> [String] {
        var result: [String] = []
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        for part in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(part)
            if component == "." { continue }
            if component == ".." {
                if result.count <= 1 { throw ToolError("Path '\(path)' escapes its shared folder.") }
                result.removeLast()
                continue
            }
            if component.contains("\0") { throw ToolError("Path contains a NUL character.") }
            result.append(component)
        }
        return result
    }

    public func root(named name: String) -> Root? {
        roots.first { $0.name == name } ?? roots.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Resolves a path. Returns nil for the empty path (meaning "list the roots").
    public func resolveOptional(_ path: String) throws -> ResolvedPath? {
        let parts = try Self.components(of: path.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let first = parts.first else { return nil }
        guard let root = root(named: first) else {
            let available = roots.map { "'\($0.name)'" }.joined(separator: ", ")
            if roots.isEmpty {
                throw ToolError("No folders are shared yet. Ask the user to add a folder in the Claude Files Access app.")
            }
            throw ToolError("Unknown root '\(first)'. Paths must start with one of: \(available).")
        }
        return ResolvedPath(root: root, components: Array(parts.dropFirst()))
    }

    public func resolve(_ path: String) throws -> ResolvedPath {
        guard let resolved = try resolveOptional(path) else {
            throw ToolError("A path is required, e.g. '\(roots.first?.name ?? "Madeira")/...'.")
        }
        return resolved
    }
}
