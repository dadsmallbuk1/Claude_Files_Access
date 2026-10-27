import Foundation

/// Text encodings commonly found in Wine prefixes and Windows game folders.
public enum TextEncoding: String, Sendable {
    case utf8
    case utf8BOM = "utf8-bom"
    case utf16LE = "utf16le-bom"
    case utf16BE = "utf16be-bom"
    case utf16LENoBOM = "utf16le"
    case utf16BENoBOM = "utf16be"
    case windows1252

    var bom: [UInt8] {
        switch self {
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        default: return []
        }
    }

    var isUTF16: Bool { [.utf16LE, .utf16BE, .utf16LENoBOM, .utf16BENoBOM].contains(self) }

    /// The same encoding for a slice that does not start at the BOM.
    var withoutBOM: TextEncoding {
        switch self {
        case .utf8BOM: return .utf8
        case .utf16LE: return .utf16LENoBOM
        case .utf16BE: return .utf16BENoBOM
        default: return self
        }
    }
}

public enum TextCodec {
    /// Guesses the encoding of a file from its first bytes.
    public static func detect(_ data: Data) -> TextEncoding {
        let bytes = [UInt8](data.prefix(4096))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
        if bytes.starts(with: [0xFF, 0xFE]) { return .utf16LE }
        if bytes.starts(with: [0xFE, 0xFF]) { return .utf16BE }
        if looksLikeUTF16LE(bytes) { return .utf16LENoBOM }
        let sample = data.prefix(65536)
        if String(data: sample, encoding: .utf8) != nil { return .utf8 }
        // A file prefix may end in the middle of a multi-byte character.
        if sample.count >= 4096, String(data: sample.trimmingIncompleteUTF8(), encoding: .utf8) != nil { return .utf8 }
        return .windows1252
    }

    /// UTF-16LE text without a BOM has lots of zero bytes at odd offsets and few at even ones.
    static func looksLikeUTF16LE(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 8 else { return false }
        var oddZeros = 0
        var evenZeros = 0
        for (index, byte) in bytes.enumerated() where byte == 0 {
            if index % 2 == 1 { oddZeros += 1 } else { evenZeros += 1 }
        }
        let pairs = bytes.count / 2
        return oddZeros * 10 > pairs * 6 && evenZeros * 20 <= pairs
    }

    /// Whether data looks like text rather than binary.
    public static func isText(_ data: Data) -> Bool {
        let encoding = detect(data)
        if encoding.isUTF16 { return true }
        let sample = data.prefix(8192)
        if sample.isEmpty { return true }
        var control = 0
        for byte in sample {
            if byte == 0 { return false }
            if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x0C && byte != 0x1B {
                control += 1
            }
        }
        return control * 100 / sample.count < 5
    }

    /// Decodes text, never failing: invalid sequences become U+FFFD.
    public static func decode(_ data: Data, as encoding: TextEncoding) -> String {
        var body = data
        if !encoding.bom.isEmpty, body.starts(with: encoding.bom) { body = body.dropFirst(encoding.bom.count) }
        switch encoding {
        case .utf8, .utf8BOM:
            return String(decoding: body, as: UTF8.self)
        case .utf16LE, .utf16LENoBOM:
            return decodeUTF16(body, littleEndian: true)
        case .utf16BE, .utf16BENoBOM:
            return decodeUTF16(body, littleEndian: false)
        case .windows1252:
            return String(data: body, encoding: .windowsCP1252) ?? String(decoding: body, as: UTF8.self)
        }
    }

    public static func decode(_ data: Data) -> (String, TextEncoding) {
        let encoding = detect(data)
        return (decode(data, as: encoding), encoding)
    }

    private static func decodeUTF16(_ data: Data, littleEndian: Bool) -> String {
        let bytes = [UInt8](data)
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            let a = UInt16(bytes[index])
            let b = UInt16(bytes[index + 1])
            units.append(littleEndian ? (a | (b << 8)) : ((a << 8) | b))
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Encodes text in the given encoding, including its BOM.
    public static func encode(_ text: String, as encoding: TextEncoding) -> Data {
        var data = Data(encoding.bom)
        switch encoding {
        case .utf8, .utf8BOM:
            data.append(Data(text.utf8))
        case .utf16LE, .utf16LENoBOM, .utf16BE, .utf16BENoBOM:
            let littleEndian = encoding == .utf16LE || encoding == .utf16LENoBOM
            for unit in text.utf16 {
                if littleEndian {
                    data.append(UInt8(unit & 0xFF))
                    data.append(UInt8(unit >> 8))
                } else {
                    data.append(UInt8(unit >> 8))
                    data.append(UInt8(unit & 0xFF))
                }
            }
        case .windows1252:
            data.append(text.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data(text.utf8))
        }
        return data
    }
}

extension String {
    /// Splits into lines on any line ending. Note that Swift treats "\r\n" as a single
    /// Character, so `split(separator: "\n")` would not split Windows text.
    func lines() -> [Substring] {
        split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }
}

extension Data {
    /// Drops a trailing partial UTF-8 sequence so a prefix of a UTF-8 file still validates.
    func trimmingIncompleteUTF8() -> Data {
        var index = endIndex
        var continuationBytes = 0
        while index > startIndex && continuationBytes < 3 {
            let byte = self[index - 1]
            if byte & 0xC0 == 0x80 {
                continuationBytes += 1
                index -= 1
                continue
            }
            if byte & 0x80 == 0 { return self }
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
            return continuationBytes + 1 < needed ? self[startIndex..<(index - 1)] : self
        }
        return self
    }
}
