import Foundation

public struct ArchiveEntry {
    public enum Kind: String { case file, directory, symlink, other }

    /// Path inside the archive, with "/" separators.
    public let path: String
    public let kind: Kind
    public let size: UInt64
    public let linkTarget: String?
    let loadData: () throws -> Data

    public func data() throws -> Data { try loadData() }
}

public enum ArchiveFormat: String {
    case zip
    case tar
    case tarGzip = "tar.gz"
    case tarXz = "tar.xz"
    case tarZstd = "tar.zst"
    case gzip = "gz"
    case xz
    case zstd = "zst"
}

public enum ArchiveReader {
    public static func read(_ url: URL) throws -> (ArchiveFormat, [ArchiveEntry]) {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw ToolError("Cannot read archive '\(url.lastPathComponent)': \(error.localizedDescription)")
        }
        return try read(data, fileName: url.lastPathComponent)
    }

    public static func read(_ data: Data, fileName: String) throws -> (ArchiveFormat, [ArchiveEntry]) {
        let magic = [UInt8](data.prefix(8))
        func starts(_ prefix: [UInt8]) -> Bool { magic.starts(with: prefix) }

        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) {
            return (.zip, try Zip.entries(data))
        }
        if starts([0x1F, 0x8B]) {
            return try tarOrSingle(Decompress.gunzip(data), tarFormat: .tarGzip, singleFormat: .gzip, fileName: fileName)
        }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            return try tarOrSingle(Decompress.unxz(data), tarFormat: .tarXz, singleFormat: .xz, fileName: fileName)
        }
        if starts([0x28, 0xB5, 0x2F, 0xFD]) {
            return try tarOrSingle(Decompress.unzstd(data), tarFormat: .tarZstd, singleFormat: .zstd, fileName: fileName)
        }
        if Tar.looksLikeTar(data) {
            return (.tar, try Tar.entries(data))
        }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) {
            throw ToolError(
                "7-Zip (.7z) archives are not supported. Ask the user to extract it with another app (e.g. Files, iZip) into a shared folder."
            )
        }
        if starts([0x52, 0x61, 0x72, 0x21]) {
            throw ToolError("RAR archives are not supported. Ask the user to extract it with another app into a shared folder.")
        }
        if starts([0x42, 0x5A, 0x68]) {
            throw ToolError("bzip2 archives are not supported.")
        }
        throw ToolError("'\(fileName)' is not a recognised archive (zip, tar, tar.gz, tar.xz or tar.zst).")
    }

    private static func tarOrSingle(
        _ decompressed: Data, tarFormat: ArchiveFormat, singleFormat: ArchiveFormat, fileName: String
    ) throws -> (ArchiveFormat, [ArchiveEntry]) {
        if Tar.looksLikeTar(decompressed) {
            return (tarFormat, try Tar.entries(decompressed))
        }
        // A single compressed file, e.g. "foo.dll.gz".
        var name = fileName
        for suffix in [".gz", ".xz", ".zst", ".tgz", ".txz"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        if name.isEmpty || name == fileName { name += ".out" }
        let entry = ArchiveEntry(
            path: name, kind: .file, size: UInt64(decompressed.count), linkTarget: nil, loadData: { decompressed })
        return (singleFormat, [entry])
    }

    /// Cleans an archive entry path: strips leading "/" and "./", rejects "..".
    /// Returns nil for entries that must be skipped.
    static func safeComponents(_ path: String, strip: Int) -> [String]? {
        var parts: [String] = []
        for part in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { return nil }
            parts.append(String(part))
        }
        guard parts.count > strip else { return nil }
        return Array(parts.dropFirst(strip))
    }
}
