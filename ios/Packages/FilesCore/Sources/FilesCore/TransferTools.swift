import Foundation

extension ToolRouter {
    // MARK: download_url

    func downloadURL(_ args: ToolArguments) async throws -> ToolResult {
        let urlString = try args.requiredString("url")
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
        else {
            throw ToolError("url must be an http(s) URL.")
        }
        let destinationArg = try args.requiredString("destination")
        let destination = try resolver.resolve(destinationArg)
        let overwrite = args.bool("overwrite")
        let intoFolder = destinationArg.hasSuffix("/") || destinationArg.hasSuffix("\\") || FS.isDirectory(destination.url)

        if !intoFolder {
            guard !destination.isRoot else { throw ToolError("destination must be a file path or a folder.") }
            if FS.exists(destination.url) && !overwrite {
                throw ToolError("'\(destination.display)' already exists. Pass overwrite=true to replace it (it will be backed up).")
            }
        }

        let session = self.session
        let changes = self.changes
        let id = jobs.start(kind: "download", description: "\(urlString) -> \(destination.display)") {
            do {
                let (tempURL, response) = try await session.download(from: url)
                defer { try? FS.fm.removeItem(at: tempURL) }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return .error("Download failed: HTTP \(http.statusCode) for \(urlString).")
                }
                var target = destination
                if intoFolder {
                    var name = response.suggestedFilename ?? url.lastPathComponent
                    if name.isEmpty || name == "/" { name = "download" }
                    target = destination.appending(name.replacingOccurrences(of: "/", with: "_"))
                }
                let size = (try? FS.fm.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
                let replaced = FS.exists(target.url)
                if replaced && !overwrite {
                    return .error("'\(target.display)' already exists. Pass overwrite=true to replace it (it will be backed up).")
                }
                let finalTarget = target
                let (_, record) = try changes.perform(tool: "download_url", summary: { _ in "download \(finalTarget.display)" }) {
                    change in
                    try change.ensureDirectory(finalTarget.parent!)
                    if replaced { try change.backup(finalTarget, move: true) }
                    do {
                        try FS.moveOrCopy(tempURL, to: finalTarget.url)
                    } catch {
                        throw ToolError("Could not save the download: \(error.localizedDescription)")
                    }
                    change.created(finalTarget)
                }
                return .text(
                    "Downloaded \(urlString) to \(finalTarget.display) (\(Format.bytes(size)))\(self.changeNote(record))."
                )
            } catch let error as ToolError {
                return .error(error.message)
            } catch {
                return .error("Download failed: \(error.localizedDescription)")
            }
        }
        return await jobs.wait(id, timeout: jobWaitSeconds)
    }

    // MARK: extract_archive

    func extractArchive(_ args: ToolArguments) async throws -> ToolResult {
        let resolver = self.resolver
        let archive = try resolver.resolve(try args.requiredString("path"))
        _ = try fileSize(archive.url)
        let strip = args.int("strip_components", default: 0, min: 0, max: 32)

        if args.bool("list_only") {
            return try await background { try self.listArchive(archive) }
        }

        let destination = try resolver.resolve(try args.requiredString("destination"))
        let overwrite = args.bool("overwrite")
        let id = jobs.start(kind: "extract", description: "\(archive.display) -> \(destination.display)") {
            do {
                return try self.extract(archive, into: destination, strip: strip, overwrite: overwrite)
            } catch let error as ToolError {
                return .error(error.message)
            } catch {
                return .error("Extraction failed: \(error.localizedDescription)")
            }
        }
        return await jobs.wait(id, timeout: jobWaitSeconds)
    }

    func listArchive(_ archive: ResolvedPath) throws -> ToolResult {
        let (format, entries) = try ArchiveReader.read(archive.url)
        let limit = 1000
        var lines = entries.prefix(limit).map { entry -> String in
            switch entry.kind {
            case .directory: return entry.path.hasSuffix("/") ? entry.path : entry.path + "/"
            case .symlink: return "\(entry.path) -> \(entry.linkTarget ?? "?")  (symlink, will be skipped)"
            case .other: return "\(entry.path)  (special entry, will be skipped)"
            case .file: return "\(entry.path)  [\(Format.bytes(entry.size))]"
            }
        }
        if entries.count > limit { lines.append("... \(entries.count - limit) more entries") }
        let total = entries.filter { $0.kind == .file }.reduce(UInt64(0)) { $0 + $1.size }
        return .text(
            "\(archive.display): \(format.rawValue), \(entries.count) entries, \(Format.bytes(total)) uncompressed\n"
                + lines.joined(separator: "\n"))
    }

    func extract(_ archive: ResolvedPath, into destination: ResolvedPath, strip: Int, overwrite: Bool) throws
        -> ToolResult
    {
        let (format, entries) = try ArchiveReader.read(archive.url)

        var directories: [ResolvedPath] = []
        var files: [(ArchiveEntry, ResolvedPath)] = []
        var skipped: [String] = []
        for entry in entries {
            guard let parts = ArchiveReader.safeComponents(entry.path, strip: strip) else {
                if !entry.path.isEmpty && strip == 0 { skipped.append("\(entry.path) (unsafe path)") }
                continue
            }
            let target = destination.appending(components: parts)
            switch entry.kind {
            case .directory: directories.append(target)
            case .file: files.append((entry, target))
            case .symlink, .other: skipped.append("\(entry.path) (\(entry.kind.rawValue))")
            }
        }
        guard !files.isEmpty || !directories.isEmpty else {
            throw ToolError("Nothing to extract (check strip_components).")
        }

        let conflicts = files.filter { FS.exists($0.1.url) }.map(\.1)
        if let folder = conflicts.first(where: { FS.isDirectory($0.url) }) {
            throw ToolError("'\(folder.display)' is a folder but the archive has a file there.")
        }
        if !conflicts.isEmpty && !overwrite {
            let shown = conflicts.prefix(15).map { "- \($0.display)" }.joined(separator: "\n")
            throw ToolError(
                "\(conflicts.count) file(s) already exist. Nothing was extracted. Pass overwrite=true to replace them (they will be backed up):\n\(shown)"
            )
        }

        var written = 0
        var bytes: UInt64 = 0
        let (_, record) = try changes.perform(
            tool: "extract_archive", summary: { _ in "extract \(archive.display) -> \(destination.display)" }
        ) { change in
            try change.ensureDirectory(destination)
            for directory in directories { try change.ensureDirectory(directory) }
            for (entry, target) in files {
                try change.ensureDirectory(target.parent!)
                let data = try entry.data()
                if FS.exists(target.url) { try change.backup(target, move: true) }
                try writeData(data, to: target.url)
                change.created(target)
                written += 1
                bytes += UInt64(data.count)
            }
        }

        // Summarise what landed at the top level of the destination.
        var topLevel: [String] = []
        for (_, target) in files {
            let rel = Array(target.components.dropFirst(destination.components.count))
            if let first = rel.first {
                let item = rel.count > 1 ? first + "/" : first
                if !topLevel.contains(item) { topLevel.append(item) }
            }
        }

        var output =
            "Extracted \(written) file(s) (\(Format.bytes(bytes))) from \(archive.display) [\(format.rawValue)] into \(destination.display)"
        output += "; \(conflicts.count) existing file(s) replaced and backed up" + changeNote(record) + "."
        if !topLevel.isEmpty {
            output += "\nTop level: " + topLevel.prefix(30).joined(separator: ", ")
            if topLevel.count > 30 { output += ", ..." }
        }
        if !skipped.isEmpty {
            output += "\nSkipped \(skipped.count): " + skipped.prefix(10).joined(separator: ", ")
        }
        return .text(output)
    }
}
