import Foundation

/// POSIX ustar / GNU / pax tar reader.
enum Tar {
    static func looksLikeTar(_ data: Data) -> Bool {
        guard data.count >= 512 else { return false }
        let base = data.startIndex
        if data[(base + 257)..<(base + 262)].elementsEqual("ustar".utf8) { return true }
        // Old v7 archives have no magic: verify the header checksum instead.
        let stored = octal(data, base + 148, 8)
        guard stored > 0 else { return false }
        return stored == checksum(data, base)
    }

    private static func checksum(_ data: Data, _ header: Int) -> UInt64 {
        var sum: UInt64 = 0
        for index in 0..<512 {
            sum += (148..<156).contains(index) ? 0x20 : UInt64(data[header + index])
        }
        return sum
    }

    private static func string(_ data: Data, _ offset: Int, _ length: Int) -> String {
        let field = data[offset..<(offset + length)]
        let end = field.firstIndex(of: 0) ?? field.endIndex
        return String(decoding: field[field.startIndex..<end], as: UTF8.self)
    }

    private static func octal(_ data: Data, _ offset: Int, _ length: Int) -> UInt64 {
        let field = data[offset..<(offset + length)]
        if let first = field.first, first & 0x80 != 0 {
            // GNU base-256 encoding for large values.
            var value: UInt64 = UInt64(first & 0x7F)
            for byte in field.dropFirst() { value = value << 8 | UInt64(byte) }
            return value
        }
        var value: UInt64 = 0
        for byte in field {
            if byte == 0x20 || byte == 0 {
                if value > 0 { break } else { continue }
            }
            guard byte >= 0x30 && byte <= 0x37 else { break }
            value = value * 8 + UInt64(byte - 0x30)
        }
        return value
    }

    /// Parses pax extended header records: "<len> key=value\n".
    private static func paxRecords(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let record = line[line.index(after: space)...]
            guard let equals = record.firstIndex(of: "=") else { continue }
            result[String(record[..<equals])] = String(record[record.index(after: equals)...])
        }
        return result
    }

    static func entries(_ data: Data) throws -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        let base = data.startIndex
        var offset = 0
        var longName: String?
        var longLink: String?
        var pax: [String: String] = [:]

        while offset + 512 <= data.count {
            let header = base + offset
            if data[header..<(header + 512)].allSatisfy({ $0 == 0 }) { break }

            let size = Int(octal(data, header + 124, 12))
            let type = data[header + 156]
            let dataStart = header + 512
            guard size >= 0, dataStart + size <= data.endIndex else {
                throw ToolError("The tar archive is truncated or corrupt.")
            }
            let next = offset + 512 + (size + 511) / 512 * 512
            let body = data[dataStart..<(dataStart + size)]

            switch type {
            case UInt8(ascii: "L"):
                longName = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
                offset = next
                continue
            case UInt8(ascii: "K"):
                longLink = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
                offset = next
                continue
            case UInt8(ascii: "x"):
                pax = paxRecords(Data(body))
                offset = next
                continue
            case UInt8(ascii: "g"):
                offset = next
                continue
            default:
                break
            }

            var name = string(data, header, 100)
            if data[(header + 257)..<(header + 262)].elementsEqual("ustar".utf8) {
                let prefix = string(data, header + 345, 155)
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            let path = pax["path"] ?? longName ?? name
            let link = pax["linkpath"] ?? longLink ?? string(data, header + 157, 100)
            longName = nil
            longLink = nil
            pax = [:]

            let kind: ArchiveEntry.Kind
            switch type {
            case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
                kind = path.hasSuffix("/") ? .directory : .file
            case UInt8(ascii: "5"):
                kind = .directory
            case UInt8(ascii: "2"):
                kind = .symlink
            default:
                kind = .other
            }

            entries.append(
                ArchiveEntry(
                    path: path, kind: kind, size: UInt64(size), linkTarget: kind == .symlink ? link : nil,
                    loadData: { Data(body) }))
            offset = next
        }
        return entries
    }
}
