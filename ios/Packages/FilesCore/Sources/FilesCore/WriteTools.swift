import Foundation

extension ToolRouter {
    func changeNote(_ record: ChangeRecord?) -> String {
        guard let record else { return "" }
        return " (change \(record.id); revert with undo_change)"
    }

    func writeData(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ToolError("Could not write '\(url.lastPathComponent)': \(error.localizedDescription)")
        }
    }

    // MARK: write_file

    func writeFile(_ args: ToolArguments) throws -> ToolResult {
        let target = try resolver.resolve(try args.requiredString("path"))
        guard !target.isRoot else { throw ToolError("Cannot write to a root folder itself.") }
        let content = try args.requiredString("content")
        let mode = args.string("mode") ?? "overwrite"
        let isBase64 = args.string("encoding") == "base64"
        guard ["overwrite", "append", "create"].contains(mode) else {
            throw ToolError("mode must be overwrite, append or create.")
        }

        let exists = FS.exists(target.url)
        if exists && FS.isDirectory(target.url) { throw ToolError("'\(target.display)' is a folder.") }
        if exists && mode == "create" {
            throw ToolError("'\(target.display)' already exists. Use mode='overwrite' to replace it (it will be backed up).")
        }

        // Text keeps the existing file's encoding (e.g. UTF-16 for some Windows configs).
        let existingEncoding: TextEncoding? =
            exists && !isBase64 ? (try? readBytes(target.url, offset: 0, length: 4096)).map(TextCodec.detect) : nil
        let data: Data
        if isBase64 {
            guard let decoded = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
                throw ToolError("content is not valid base64.")
            }
            data = decoded
        } else if let existingEncoding, existingEncoding != .windows1252 {
            data = TextCodec.encode(content, as: mode == "append" ? existingEncoding.withoutBOM : existingEncoding)
        } else {
            data = Data(content.utf8)
        }

        let (_, record) = try changes.perform(tool: "write_file", summary: { _ in "\(mode) \(target.display)" }) {
            change in
            try change.ensureDirectory(target.parent!)
            if exists {
                try change.backup(target, move: false)
                if mode == "append" {
                    let handle = try FileHandle(forWritingTo: target.url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try writeData(data, to: target.url)
                }
            } else {
                try writeData(data, to: target.url)
                change.created(target)
            }
        }
        let verb = mode == "append" ? "Appended" : exists ? "Overwrote" : "Created"
        return .text("\(verb) \(target.display) (\(Format.bytes(UInt64(data.count))) written)\(changeNote(record)).")
    }

    // MARK: edit_file

    func editFile(_ args: ToolArguments) throws -> ToolResult {
        let target = try resolver.resolve(try args.requiredString("path"))
        var oldText = try args.requiredString("old_text")
        var newText = try args.requiredString("new_text")
        let replaceAll = args.bool("replace_all")
        guard !oldText.isEmpty else { throw ToolError("old_text must not be empty.") }

        let size = try fileSize(target.url)
        guard size <= 20 * 1024 * 1024 else { throw ToolError("File is too large to edit (\(Format.bytes(size))).") }
        let data = try Data(contentsOf: target.url)
        guard TextCodec.isText(data) else { throw ToolError("'\(target.display)' is not a text file.") }
        let (text, encoding) = TextCodec.decode(data)
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text

        var count = body.components(separatedBy: oldText).count - 1
        // Windows files use CRLF; Claude usually sends LF.
        if count == 0 && body.contains("\r\n") && oldText.contains("\n") && !oldText.contains("\r\n") {
            oldText = oldText.replacingOccurrences(of: "\n", with: "\r\n")
            newText = newText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            count = body.components(separatedBy: oldText).count - 1
        }
        if count == 0 {
            throw ToolError(
                "old_text was not found in \(target.display). Read the file first and copy the text exactly (including whitespace)."
            )
        }
        if count > 1 && !replaceAll {
            throw ToolError(
                "old_text appears \(count) times in \(target.display). Add more surrounding text to make it unique, or set replace_all=true."
            )
        }

        let updated: String
        if replaceAll {
            updated = body.replacingOccurrences(of: oldText, with: newText)
        } else {
            let range = body.range(of: oldText)!
            updated = body.replacingCharacters(in: range, with: newText)
        }
        let output = TextCodec.encode(updated, as: encoding)

        let (_, record) = try changes.perform(tool: "edit_file", summary: { _ in "edit \(target.display)" }) { change in
            try change.backup(target, move: false)
            try writeData(output, to: target.url)
        }
        return .text(
            "Replaced \(replaceAll ? count : 1) occurrence\(replaceAll && count > 1 ? "s" : "") in \(target.display) (encoding \(encoding.rawValue) kept)\(changeNote(record))."
        )
    }

    // MARK: make_directory

    func makeDirectory(_ args: ToolArguments) throws -> ToolResult {
        let target = try resolver.resolve(try args.requiredString("path"))
        if FS.isDirectory(target.url) { return .text("\(target.display) already exists.") }
        let (_, record) = try changes.perform(tool: "make_directory", summary: { _ in "mkdir \(target.display)" }) {
            change in
            try change.ensureDirectory(target)
        }
        return .text("Created folder \(target.display)\(changeNote(record)).")
    }

    // MARK: copy / move

    /// Resolves source and destination for copy/move, applying "into folder" semantics.
    private func transferPaths(_ args: ToolArguments) throws -> (ResolvedPath, ResolvedPath) {
        let resolver = self.resolver
        let source = try resolver.resolve(try args.requiredString("source"))
        var destination = try resolver.resolve(try args.requiredString("destination"))
        guard FS.exists(source.url) else { throw ToolError("'\(source.display)' does not exist.") }
        if FS.isDirectory(destination.url) && (try? FS.info(destination.url).kind) != .symlink
            && destination != source
        {
            destination = destination.appending(source.name)
        }
        guard !destination.isRoot else { throw ToolError("Cannot replace a root folder.") }
        if destination == source { throw ToolError("Source and destination are the same.") }
        if destination.root == source.root && destination.components.starts(with: source.components) {
            throw ToolError("Cannot copy or move a folder into itself.")
        }
        if FS.exists(destination.url) && !args.bool("overwrite") {
            throw ToolError(
                "'\(destination.display)' already exists. Pass overwrite=true to replace it (the old one is backed up).")
        }
        return (source, destination)
    }

    func copy(_ args: ToolArguments) throws -> ToolResult {
        let (source, destination) = try transferPaths(args)
        let replaced = FS.exists(destination.url)
        let (_, record) = try changes.perform(
            tool: "copy", summary: { _ in "copy \(source.display) -> \(destination.display)" }
        ) { change in
            try change.ensureDirectory(destination.parent!)
            if replaced { try change.backup(destination, move: true) }
            do {
                try FS.fm.copyItem(at: source.url, to: destination.url)
            } catch {
                throw ToolError("Copy failed: \(error.localizedDescription)")
            }
            change.created(destination)
        }
        return .text(
            "Copied \(source.display) to \(destination.display)\(replaced ? " (replaced the old one)" : "")\(changeNote(record)).")
    }

    func move(_ args: ToolArguments) throws -> ToolResult {
        let (source, destination) = try transferPaths(args)
        guard !source.isRoot else { throw ToolError("Cannot move a root folder.") }
        let replaced = FS.exists(destination.url)
        let (_, record) = try changes.perform(
            tool: "move", summary: { _ in "move \(source.display) -> \(destination.display)" }
        ) { change in
            try change.ensureDirectory(destination.parent!)
            if replaced { try change.backup(destination, move: true) }
            do {
                try FS.moveOrCopy(source.url, to: destination.url)
            } catch {
                throw ToolError("Move failed: \(error.localizedDescription)")
            }
            change.moved(from: source, to: destination)
        }
        return .text(
            "Moved \(source.display) to \(destination.display)\(replaced ? " (replaced the old one)" : "")\(changeNote(record)).")
    }

    // MARK: delete

    func delete(_ args: ToolArguments) throws -> ToolResult {
        let target = try resolver.resolve(try args.requiredString("path"))
        guard !target.isRoot else { throw ToolError("Cannot delete a root folder.") }
        guard FS.exists(target.url) else { throw ToolError("'\(target.display)' does not exist.") }
        let (_, record) = try changes.perform(tool: "delete", summary: { _ in "delete \(target.display)" }) { change in
            try change.backup(target, move: true)
        }
        return .text("Deleted \(target.display) (kept in the app's backups)\(changeNote(record)).")
    }
}
