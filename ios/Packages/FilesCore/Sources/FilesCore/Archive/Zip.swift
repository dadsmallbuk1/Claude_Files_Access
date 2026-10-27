import Foundation

/// Zip reader (stored and deflate entries, including zip64).
enum Zip {
    private static func u16(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) | Int(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(data[offset]) | UInt64(data[offset + 1]) << 8 | UInt64(data[offset + 2]) << 16
            | UInt64(data[offset + 3]) << 24
    }

    private static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        u32(data, offset) | u32(data, offset + 4) << 32
    }

    static func entries(_ input: Data) throws -> [ArchiveEntry] {
        // Work on a zero-based buffer so offsets from the file can be used directly.
        let data = input.startIndex == 0 ? input : Data(input)
        let corrupt = ToolError("The zip archive is truncated or corrupt.")
        guard data.count >= 22 else { throw corrupt }

        // Find the End Of Central Directory record, scanning back over a possible comment.
        var eocd = -1
        var position = data.count - 22
        let lowest = max(0, data.count - 22 - 65535)
        while position >= lowest {
            if data[position] == 0x50, data[position + 1] == 0x4B, data[position + 2] == 0x05,
                data[position + 3] == 0x06
            {
                eocd = position
                break
            }
            position -= 1
        }
        guard eocd >= 0 else { throw corrupt }

        var count = UInt64(u16(data, eocd + 10))
        var directoryOffset = u32(data, eocd + 16)

        if count == 0xFFFF || directoryOffset == 0xFFFF_FFFF {
            // zip64: the locator sits just before the EOCD record.
            let locator = eocd - 20
            guard locator >= 0, u32(data, locator) == 0x0706_4B50 else { throw corrupt }
            let record = Int(u64(data, locator + 8))
            guard record + 56 <= data.count, u32(data, record) == 0x0606_4B50 else { throw corrupt }
            count = u64(data, record + 32)
            directoryOffset = u64(data, record + 48)
        }

        var entries: [ArchiveEntry] = []
        var offset = Int(directoryOffset)
        for _ in 0..<count {
            guard offset + 46 <= data.count, u32(data, offset) == 0x0201_4B50 else { throw corrupt }
            let flags = u16(data, offset + 8)
            let method = u16(data, offset + 10)
            var compressedSize = u32(data, offset + 20)
            var uncompressedSize = u32(data, offset + 24)
            let nameLength = u16(data, offset + 28)
            let extraLength = u16(data, offset + 30)
            let commentLength = u16(data, offset + 32)
            let externalAttributes = u32(data, offset + 38)
            var localOffset = u32(data, offset + 42)
            let nameStart = offset + 46
            guard nameStart + nameLength + extraLength <= data.count else { throw corrupt }

            let nameData = data[nameStart..<(nameStart + nameLength)]
            let name =
                flags & 0x800 != 0
                ? String(decoding: nameData, as: UTF8.self)
                : (String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .windowsCP1252) ?? "?")

            // zip64 extra field replaces any 0xFFFFFFFF values, in this order.
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = u16(data, extra)
                let size = u16(data, extra + 2)
                if id == 0x0001 {
                    var field = extra + 4
                    if uncompressedSize == 0xFFFF_FFFF { uncompressedSize = u64(data, field); field += 8 }
                    if compressedSize == 0xFFFF_FFFF { compressedSize = u64(data, field); field += 8 }
                    if localOffset == 0xFFFF_FFFF { localOffset = u64(data, field) }
                }
                extra += 4 + size
            }

            let unixMode = (externalAttributes >> 16) & 0o170000
            let kind: ArchiveEntry.Kind
            if name.hasSuffix("/") {
                kind = .directory
            } else if unixMode == 0o120000 {
                kind = .symlink
            } else {
                kind = .file
            }

            let entryName = name
            let entryCompressed = Int(compressedSize)
            let entryUncompressed = uncompressedSize
            let entryLocal = Int(localOffset)
            let load: () throws -> Data = {
                if flags & 0x1 != 0 { throw ToolError("'\(entryName)' is encrypted; password-protected zips are not supported.") }
                guard entryLocal + 30 <= data.count, u32(data, entryLocal) == 0x0403_4B50 else { throw corrupt }
                let start = entryLocal + 30 + u16(data, entryLocal + 26) + u16(data, entryLocal + 28)
                guard start + entryCompressed <= data.count else { throw corrupt }
                let compressed = data[start..<(start + entryCompressed)]
                let output: Data
                switch method {
                case 0: output = Data(compressed)
                case 8: output = try Decompress.inflate(compressed)
                default:
                    throw ToolError("'\(entryName)' uses an unsupported zip compression method (\(method)).")
                }
                guard UInt64(output.count) == entryUncompressed else {
                    throw ToolError("'\(entryName)' decompressed to the wrong size; the archive may be corrupt.")
                }
                return output
            }

            entries.append(
                ArchiveEntry(
                    path: kind == .directory ? String(name.trimmingSuffix("/")) : name, kind: kind, size: uncompressedSize, linkTarget: nil, loadData: load))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }
}
