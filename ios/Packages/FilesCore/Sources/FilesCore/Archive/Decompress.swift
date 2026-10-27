import Foundation
import libzstd

/// Single-stream decompressors. gzip/deflate/xz use Apple's Compression framework
/// (via NSData); zstd uses the reference library.
enum Decompress {
    /// Raw DEFLATE (RFC 1951), as used inside zip and gzip.
    static func inflate(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        do {
            return try (Data(data) as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw ToolError("Corrupt deflate data: \(error.localizedDescription)")
        }
    }

    /// gzip (RFC 1952): parses the header, then inflates the DEFLATE body.
    static func gunzip(_ data: Data) throws -> Data {
        let bytes = data
        let base = bytes.startIndex
        guard bytes.count >= 18, bytes[base] == 0x1F, bytes[base + 1] == 0x8B else {
            throw ToolError("Not a gzip file.")
        }
        guard bytes[base + 2] == 8 else { throw ToolError("Unsupported gzip compression method.") }
        let flags = bytes[base + 3]
        var offset = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard bytes.count >= offset + 2 else { throw ToolError("Truncated gzip header.") }
            let length = Int(bytes[base + offset]) | Int(bytes[base + offset + 1]) << 8
            offset += 2 + length
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT: NUL-terminated
            while offset < bytes.count && bytes[base + offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC
        guard offset < bytes.count - 8 else { throw ToolError("Truncated gzip file.") }
        return try inflate(bytes[(base + offset)..<(bytes.endIndex - 8)])
    }

    /// xz container with LZMA2 (Apple's `.lzma` algorithm is xz-framed).
    static func unxz(_ data: Data) throws -> Data {
        do {
            return try (Data(data) as NSData).decompressed(using: .lzma) as Data
        } catch {
            throw ToolError("Could not decompress xz data: \(error.localizedDescription)")
        }
    }

    static func unzstd(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        guard let stream = ZSTD_createDStream() else { throw ToolError("zstd: out of memory.") }
        defer { ZSTD_freeDStream(stream) }
        ZSTD_initDStream(stream)

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            var outputFilled = false
            repeat {
                try chunk.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                    var out = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                    let result = ZSTD_decompressStream(stream, &out, &input)
                    if ZSTD_isError(result) != 0 {
                        throw ToolError("zstd: \(String(cString: ZSTD_getErrorName(result)))")
                    }
                    output.append(destination.bindMemory(to: UInt8.self).baseAddress!, count: out.pos)
                    outputFilled = out.pos == out.size
                }
            } while input.pos < input.size || outputFilled
        }
        return output
    }
}
