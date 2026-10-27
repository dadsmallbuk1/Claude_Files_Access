import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

extension ToolRouter {
    static let maxReadBytes = 262_144
    static let searchDeadline: TimeInterval = 25
    static let maxContentSearchBytes: UInt64 = 20 * 1024 * 1024
    static let peExtensions: Set<String> = ["exe", "dll", "sys", "drv", "ocx", "acm", "ax", "cpl", "scr", "asi"]

    // MARK: list_directory

    func listDirectory(_ args: ToolArguments) throws -> ToolResult {
        let resolver = self.resolver
        guard let target = try resolver.resolveOptional(args.string("path") ?? "") else {
            if resolver.roots.isEmpty {
                return .text("No folders are shared yet. Ask the user to tap \"Add Folder\" in the Claude Files Access app.")
            }
            let lines = resolver.roots.map { root in
                "\(root.name)/" + (FS.isDirectory(root.url) ? "" : "  (unavailable - ask the user to re-add it)")
            }
            return .text("Shared folders (roots):\n" + lines.joined(separator: "\n"))
        }

        let info = try FS.info(target.url)
        if info.kind != .directory && !FS.isDirectory(target.url) {
            return .text("\(target.display) is a file: \(Format.bytes(info.size)), modified \(Format.date(info.modified)).")
        }

        let depth = args.int("depth", default: 1, min: 1, max: 8)
        let maxEntries = args.int("max_entries", default: 500, min: 1, max: 5000)
        let includeHidden = args.bool("include_hidden")

        var lines: [String] = []
        var total = 0
        var truncated = false
        _ = try FS.walk(target.url, maxDepth: depth, includeHidden: includeHidden) { entry, relative, level in
            total += 1
            if lines.count >= maxEntries {
                truncated = true
                return false
            }
            let indent = String(repeating: "  ", count: level - 1)
            let name = entry.url.lastPathComponent
            switch entry.kind {
            case .directory:
                lines.append("\(indent)\(name)/")
            case .symlink:
                lines.append("\(indent)\(name) -> \(entry.symlinkTarget ?? "?")")
            case .file, .other:
                lines.append("\(indent)\(name)  [\(Format.bytes(entry.size)), \(Format.date(entry.modified))]")
            }
            return true
        }

        var output = "\(target.display)/\n"
        output += lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")
        if truncated {
            output += "\n... listing stopped at \(maxEntries) entries. List a subfolder or raise max_entries."
        }
        return .text(output)
    }

    // MARK: file_info

    func fileInfo(_ args: ToolArguments) throws -> ToolResult {
        let target = try resolver.resolve(try args.requiredString("path"))
        let info = try FS.info(target.url)
        var result: [String: JSONValue] = [
            "path": .string(target.display),
            "type": .string(info.kind.rawValue),
            "modified": JSONValue(info.modified),
            "created": JSONValue(info.created),
        ]
        if let link = info.symlinkTarget { result["symlink_target"] = .string(link) }

        if FS.isDirectory(target.url) {
            result["type"] = .string(info.kind == .symlink ? "symlink to folder" : "directory")
            let children = (try? FS.fm.contentsOfDirectory(atPath: target.url.path)) ?? []
            result["items"] = JSONValue(children.count)
            return .json(.object(result))
        }

        let size = (try? fileSize(target.url)) ?? info.size
        result["size_bytes"] = JSONValue(size)
        result["size"] = .string(Format.bytes(size))

        let head = try readBytes(target.url, offset: 0, length: 4096)
        if let pe = PEInfo.read(head) {
            result["pe"] = [
                "machine": .string(pe.machine),
                "bitness": .string(pe.bitness),
                "format": .string(pe.format),
                "is_dll": .bool(pe.isDLL),
                "subsystem": JSONValue(pe.subsystem),
            ]
        } else if TextCodec.isText(head) {
            result["text_encoding"] = .string(TextCodec.detect(head).rawValue)
        } else {
            result["binary"] = true
        }

        if args.bool("sha256") {
            result["sha256"] = .string(try sha256(target.url))
        }
        return .json(.object(result))
    }

    func sha256(_ url: URL) throws -> String {
        #if canImport(CryptoKit)
            guard let handle = try? FileHandle(forReadingFrom: url) else { throw ToolError("Cannot open file.") }
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
            throw ToolError("SHA-256 is not available on this platform.")
        #endif
    }

    func readBytes(_ url: URL, offset: UInt64, length: Int) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ToolError("Cannot open '\(url.lastPathComponent)': \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }

    func fileSize(_ url: URL) throws -> UInt64 {
        guard let attributes = try? FS.fm.attributesOfItem(atPath: url.resolvingSymlinksInPath().path) else {
            throw ToolError("'\(url.lastPathComponent)' does not exist or cannot be read.")
        }
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            throw ToolError("'\(url.lastPathComponent)' is a folder. Use list_directory.")
        }
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    // MARK: read_file

    func readFile(_ args: ToolArguments) throws -> ToolResult {
        let target = try resolver.resolve(try args.requiredString("path"))
        let size = try fileSize(target.url)
        var offset = UInt64(max(0, args.int("offset", default: 0)))
        let length = args.int("length", default: 65536, min: 1, max: Self.maxReadBytes)
        let encoding = args.string("encoding") ?? "auto"
        let ext = target.url.pathExtension.lowercased()

        if encoding == "auto", offset == 0, let mime = ImageSupport.mimeType(forExtension: ext) {
            let data = try readBytes(target.url, offset: 0, length: Int(min(size, 30 * 1024 * 1024)))
            if let prepared = ImageSupport.prepareForClaude(data, mimeType: mime) {
                return .image(
                    prepared.data, mimeType: prepared.mimeType,
                    caption: "\(target.display) (\(Format.bytes(size)))\(prepared.note)")
            }
        }

        if offset > size { offset = size }
        if encoding == "base64" {
            let data = try readBytes(target.url, offset: offset, length: length)
            let end = offset + UInt64(data.count)
            return .json([
                "path": .string(target.display),
                "offset": JSONValue(offset),
                "bytes_read": JSONValue(data.count),
                "total_size": JSONValue(size),
                "more_after_offset": end < size ? JSONValue(end) : .null,
                "base64": .string(data.base64EncodedString()),
            ])
        }

        let head = try readBytes(target.url, offset: 0, length: 4096)
        let detected = TextCodec.detect(head)
        if encoding == "auto" && !TextCodec.isText(head) {
            var description = "\(target.display) is a binary file (\(Format.bytes(size)))."
            if let pe = PEInfo.read(head) {
                description += " It is a \(pe.bitness) \(pe.machine) \(pe.isDLL ? "DLL" : "executable")."
            }
            description += " Use file_info for details, or read_file with encoding='base64' for raw bytes."
            return .text(description)
        }
        if detected.isUTF16 && offset % 2 == 1 { offset -= 1 }

        let data = try readBytes(target.url, offset: offset, length: length)
        var text = TextCodec.decode(data, as: offset == 0 ? detected : detected.withoutBOM)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let end = offset + UInt64(data.count)
        var header = "[\(target.display): bytes \(offset)-\(end) of \(size), \(detected.rawValue)]"
        if end < size { header += " [more: continue with offset=\(end)]" }
        return .text(header + "\n" + text)
    }

    // MARK: tail_file

    func tailFile(_ args: ToolArguments) throws -> ToolResult {
        let target = try resolver.resolve(try args.requiredString("path"))
        let size = try fileSize(target.url)
        let wanted = args.int("lines", default: 200, min: 1, max: 5000)
        let head = try readBytes(target.url, offset: 0, length: 4096)
        let encoding = TextCodec.detect(head)
        if !TextCodec.isText(head) {
            return .error("\(target.display) looks like a binary file; tail_file only works on text.")
        }

        var chunk: UInt64 = 64 * 1024
        var lines: [Substring] = []
        var text = ""
        let cap: UInt64 = 8 * 1024 * 1024
        while true {
            var start = size > chunk ? size - chunk : 0
            if encoding.isUTF16 && start % 2 == 1 { start += 1 }
            let data = try readBytes(target.url, offset: start, length: Int(size - start))
            text = TextCodec.decode(data, as: start == 0 ? encoding : encoding.withoutBOM)
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if start > 0 { lines.removeFirst() }  // Probably a partial line.
            if lines.last?.isEmpty == true { lines.removeLast() }
            if lines.count >= wanted || start == 0 || chunk >= cap { break }
            chunk *= 4
        }

        let tail = lines.suffix(wanted).map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        let modified = (try? FS.info(target.url))?.modified
        let header =
            "[last \(tail.count) lines of \(target.display) - \(Format.bytes(size)), modified \(Format.date(modified))]"
        return .text(header + "\n" + tail.joined(separator: "\n"))
    }

    // MARK: search

    func search(_ args: ToolArguments) throws -> ToolResult {
        let target = try resolver.resolve(try args.requiredString("path"))
        let namePattern = args.string("name_pattern").flatMap { $0.isEmpty ? nil : $0 }
        let contentPattern = args.string("content_pattern").flatMap { $0.isEmpty ? nil : $0 }
        guard namePattern != nil || contentPattern != nil else {
            throw ToolError("Give a name_pattern, a content_pattern, or both.")
        }
        let glob = try namePattern.map { try Glob($0) }
        let caseSensitive = args.bool("case_sensitive")
        let maxResults = args.int("max_results", default: 100, min: 1, max: 1000)
        let includeHidden = args.bool("include_hidden")

        var regex: NSRegularExpression?
        if let contentPattern, args.bool("regex") {
            do {
                regex = try NSRegularExpression(
                    pattern: contentPattern, options: caseSensitive ? [] : [.caseInsensitive])
            } catch {
                throw ToolError("Invalid regular expression: \(error.localizedDescription)")
            }
        }

        func lineMatches(_ line: Substring) -> Bool {
            guard let contentPattern else { return false }
            let string = String(line)
            if let regex {
                return regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
            }
            return string.range(of: contentPattern, options: caseSensitive ? [] : [.caseInsensitive]) != nil
        }

        let deadline = Date().addingTimeInterval(Self.searchDeadline)
        var results: [String] = []
        var resultCount = 0
        var scanned = 0
        var stopReason: String?

        let isFileTarget = !FS.isDirectory(target.url)
        let visit: (EntryInfo, [String], Int) throws -> Bool = { entry, relative, _ in
            if Date() > deadline {
                stopReason = "time limit reached"
                return false
            }
            guard entry.kind == .file else { return true }
            scanned += 1
            let name = entry.url.lastPathComponent
            if let glob, !glob.matches(name) { return true }
            let display = isFileTarget ? target.display : target.appending(components: relative).display

            guard contentPattern != nil else {
                results.append("\(display)  [\(Format.bytes(entry.size)), \(Format.date(entry.modified))]")
                resultCount += 1
                if resultCount >= maxResults {
                    stopReason = "max_results reached"
                    return false
                }
                return true
            }

            guard entry.size <= Self.maxContentSearchBytes,
                let data = try? Data(contentsOf: entry.url, options: .alwaysMapped),
                TextCodec.isText(data)
            else { return true }
            let text = TextCodec.decode(data).0
            var fileMatches: [String] = []
            var lineNumber = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                lineNumber += 1
                guard lineMatches(line) else { continue }
                var shown = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if shown.count > 300 { shown = String(shown.prefix(300)) + "..." }
                fileMatches.append("  \(lineNumber): \(shown)")
                resultCount += 1
                if fileMatches.count >= 20 || resultCount >= maxResults { break }
            }
            if !fileMatches.isEmpty {
                results.append(display + "\n" + fileMatches.joined(separator: "\n"))
            }
            if resultCount >= maxResults {
                stopReason = "max_results reached"
                return false
            }
            return true
        }

        if isFileTarget {
            _ = try visit(try FS.info(target.url), [], 1)
        } else {
            _ = try FS.walk(target.url, maxDepth: 64, includeHidden: includeHidden, visit: visit)
        }

        var output = results.isEmpty ? "No matches in \(target.display)." : results.joined(separator: "\n")
        output += "\n[\(scanned) files scanned"
        if let stopReason { output += "; stopped early: \(stopReason)" }
        output += "]"
        return .text(output)
    }

    // MARK: recent_files

    func recentFiles(_ args: ToolArguments) throws -> ToolResult {
        let target = try resolver.resolve(try args.requiredString("path"))
        let limit = args.int("limit", default: 50, min: 1, max: 500)
        let cutoff = args.optionalInt("within_minutes").map { Date().addingTimeInterval(-Double($0) * 60) }
        let deadline = Date().addingTimeInterval(Self.searchDeadline)
        var found: [(String, Date, UInt64)] = []
        var timedOut = false

        _ = try FS.walk(target.url, maxDepth: 64, includeHidden: args.bool("include_hidden")) { entry, relative, _ in
            if Date() > deadline {
                timedOut = true
                return false
            }
            guard entry.kind == .file, let modified = entry.modified else { return true }
            if let cutoff, modified < cutoff { return true }
            found.append((target.appending(components: relative).display, modified, entry.size))
            return true
        }

        found.sort { $0.1 > $1.1 }
        let now = Date()
        let lines = found.prefix(limit).map { path, modified, size in
            "\(Format.date(modified))  (\(Self.age(now.timeIntervalSince(modified))) ago)  \(Format.bytes(size))  \(path)"
        }
        var output = lines.isEmpty ? "No matching files in \(target.display)." : lines.joined(separator: "\n")
        if found.count > limit { output += "\n... \(found.count - limit) more" }
        if timedOut { output += "\n[stopped early: time limit reached; narrow the folder]" }
        return .text(output)
    }

    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 120 { return "\(s)s" }
        if s < 7200 { return "\(s / 60)m" }
        if s < 172_800 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
