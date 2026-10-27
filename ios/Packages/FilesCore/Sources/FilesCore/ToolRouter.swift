import Foundation

/// Executes MCP tool calls against the shared folders. The tool names and arguments
/// mirror relay/src/tools.ts.
public final class ToolRouter: @unchecked Sendable {
    let rootsProvider: @Sendable () -> [Root]
    let allowChanges: @Sendable () -> Bool
    let deviceInfo: @Sendable () -> [String: JSONValue]
    public let changes: ChangeStore
    let jobs = JobManager()
    let session: URLSession

    /// How long download/extract calls wait before handing back a job id.
    var jobWaitSeconds: TimeInterval = 25

    public init(
        changes: ChangeStore,
        roots: @escaping @Sendable () -> [Root],
        allowChanges: @escaping @Sendable () -> Bool,
        deviceInfo: @escaping @Sendable () -> [String: JSONValue] = { [:] },
        session: URLSession = .shared
    ) {
        self.changes = changes
        self.rootsProvider = roots
        self.allowChanges = allowChanges
        self.deviceInfo = deviceInfo
        self.session = session
    }

    var resolver: PathResolver { PathResolver(roots: rootsProvider()) }

    public static let mutatingTools: Set<String> = [
        "write_file", "edit_file", "make_directory", "copy", "move", "delete", "download_url", "extract_archive",
        "undo_change",
    ]

    public func handle(tool: String, arguments: [String: JSONValue]) async -> ToolResult {
        let args = ToolArguments(arguments)
        do {
            if Self.mutatingTools.contains(tool) && !(tool == "extract_archive" && args.bool("list_only")) {
                try requireChanges()
            }
            switch tool {
            case "device_status": return deviceStatus()
            case "list_directory": return try await background { try self.listDirectory(args) }
            case "file_info": return try await background { try self.fileInfo(args) }
            case "read_file": return try await background { try self.readFile(args) }
            case "tail_file": return try await background { try self.tailFile(args) }
            case "search": return try await background { try self.search(args) }
            case "recent_files": return try await background { try self.recentFiles(args) }
            case "write_file": return try await background { try self.writeFile(args) }
            case "edit_file": return try await background { try self.editFile(args) }
            case "make_directory": return try await background { try self.makeDirectory(args) }
            case "copy": return try await background { try self.copy(args) }
            case "move": return try await background { try self.move(args) }
            case "delete": return try await background { try self.delete(args) }
            case "download_url": return try await downloadURL(args)
            case "extract_archive": return try await extractArchive(args)
            case "job_status": return try jobs.status(args.requiredString("job_id"))
            case "list_changes": return listChanges(args)
            case "undo_change":
                let id = try args.requiredString("change_id")
                let resolver = self.resolver
                return try await background { ToolResult.text(try self.changes.undo(id: id, resolver: resolver)) }
            default:
                return .error("Unknown tool '\(tool)'. The app may be older than the relay; update it.")
            }
        } catch let error as ToolError {
            return .error(error.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    func background<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    func requireChanges() throws {
        guard allowChanges() else {
            throw ToolError(
                "Changes are turned off in the Claude Files Access app. Ask the user to enable \"Allow changes\" if they want this change made."
            )
        }
    }

    func deviceStatus() -> ToolResult {
        let roots = rootsProvider()
        var status: [String: JSONValue] = [
            "connected": true,
            "allow_changes": .bool(allowChanges()),
            "path_format": .string("<Root>/sub/folder/file, e.g. \(roots.first?.name ?? "Madeira")/..."),
            "roots": .array(
                roots.map { root in
                    ["name": .string(root.name), "available": .bool(FS.isDirectory(root.url))]
                }),
            "recent_changes": JSONValue(changes.list(limit: 1000).filter { !$0.undone }.count),
        ]
        for (key, value) in deviceInfo() { status[key] = value }
        if roots.isEmpty {
            status["hint"] = "No folders are shared yet. Ask the user to tap \"Add Folder\" in the app and pick the Madeira folder."
        }
        return .json(.object(status))
    }

    func listChanges(_ args: ToolArguments) -> ToolResult {
        let records = changes.list(limit: args.int("limit", default: 20, min: 1, max: 200))
        if records.isEmpty { return .text("No changes have been made through this connector yet.") }
        return .json(.array(records.map(\.jsonValue)))
    }
}
