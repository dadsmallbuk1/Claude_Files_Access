import FilesCore
import Foundation

/// A folder the user shared: either picked in the Files picker (persisted as a
/// security-scoped bookmark) or chosen in the built-in browser by path, which works
/// when the app is not sandboxed from other apps (e.g. under LiveContainer).
struct SharedFolder: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var bookmark: Data
    /// Set for folders added by path.
    var path: String?
    /// The same location relative to the folder that contains this app's home folder,
    /// used if the absolute path moves (e.g. the hosting app's container changed).
    var pathFromHomeParent: String?
}

/// Keeps access to the folders the user shared, across launches.
final class FolderStore {
    private let defaultsKey = "sharedFolders"
    private(set) var folders: [SharedFolder] = []
    private var accessedURLs: [UUID: URL] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
            let saved = try? JSONDecoder().decode([SharedFolder].self, from: data)
        {
            folders = saved
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Resolves every bookmark and starts security-scoped access. Folders that can no
    /// longer be resolved are kept (so the user sees them) but are not returned as roots.
    func resolveRoots() -> [Root] {
        var roots: [Root] = []
        var changed = false
        for index in folders.indices {
            let folder = folders[index]
            if let url = accessedURLs[folder.id] {
                roots.append(Root(name: folder.name, url: url))
                continue
            }
            if let path = folder.path {
                var url = URL(fileURLWithPath: path, isDirectory: true)
                if !Self.isDirectory(url), let relative = folder.pathFromHomeParent {
                    url = Self.homeParent.appendingPathComponent(relative, isDirectory: true)
                }
                guard Self.isDirectory(url) else { continue }
                accessedURLs[folder.id] = url
                roots.append(Root(name: folder.name, url: url))
                continue
            }
            var stale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: folder.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            else { continue }
            guard url.startAccessingSecurityScopedResource() else { continue }
            accessedURLs[folder.id] = url
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                folders[index].bookmark = fresh
                changed = true
            }
            roots.append(Root(name: folder.name, url: url))
        }
        if changed { save() }
        return roots
    }

    func isAvailable(_ folder: SharedFolder) -> Bool {
        accessedURLs[folder.id] != nil
    }

    func location(of folder: SharedFolder) -> String? {
        accessedURLs[folder.id]?.path
    }

    /// Creates a persistent bookmark for a folder from the document picker. This can
    /// block on file coordination with the providing app, so call it off the main thread.
    static func makeBookmark(for url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static var homeParent: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).deletingLastPathComponent()
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Adds a folder chosen in the built-in browser.
    func addPath(_ url: URL, name: String? = nil) -> SharedFolder {
        let path = url.standardizedFileURL.path
        let parentPath = Self.homeParent.standardizedFileURL.path + "/"
        var folder = SharedFolder(
            id: UUID(), name: uniqueName(for: name ?? url.lastPathComponent), bookmark: Data(), path: path)
        if path.hasPrefix(parentPath) { folder.pathFromHomeParent = String(path.dropFirst(parentPath.count)) }
        accessedURLs[folder.id] = url
        folders.append(folder)
        save()
        return folder
    }

    /// Adds a folder using a bookmark from `makeBookmark(for:)`.
    func add(_ url: URL, bookmark: Data) -> SharedFolder {
        let folder = SharedFolder(id: UUID(), name: uniqueName(for: url.lastPathComponent), bookmark: bookmark)
        // Keep using the picker's URL this session rather than resolving the bookmark again.
        if url.startAccessingSecurityScopedResource() { accessedURLs[folder.id] = url }
        folders.append(folder)
        save()
        return folder
    }

    func remove(_ id: UUID) {
        if let url = accessedURLs.removeValue(forKey: id) { url.stopAccessingSecurityScopedResource() }
        folders.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: UUID, to newName: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let cleaned = Self.clean(newName)
        guard !cleaned.isEmpty, cleaned != folders[index].name else { return }
        folders[index].name = uniqueName(for: cleaned, excluding: id)
        save()
    }

    private static func clean(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func uniqueName(for raw: String, excluding: UUID? = nil) -> String {
        let base = Self.clean(raw).isEmpty ? "Folder" : Self.clean(raw)
        let taken = Set(folders.filter { $0.id != excluding }.map { $0.name.lowercased() })
        var name = base
        var counter = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return name
    }
}
