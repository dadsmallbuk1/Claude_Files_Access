import Foundation

/// Minimal reader for Windows PE headers (.exe/.dll), enough to tell 32-bit from 64-bit.
public struct PEInfo: Equatable, Sendable {
    public let machine: String
    public let format: String
    public let isDLL: Bool
    public let subsystem: String?

    public var bitness: String {
        switch machine {
        case "x86", "ARM (32-bit)": return "32-bit"
        case "x64", "ARM64": return "64-bit"
        default: return "unknown"
        }
    }

    public static func read(_ data: Data) -> PEInfo? {
        let bytes = [UInt8](data.prefix(4096))
        guard bytes.count >= 0x40, bytes[0] == 0x4D, bytes[1] == 0x5A else { return nil }  // "MZ"
        let peOffset = Int(readUInt32(bytes, 0x3C))
        guard peOffset > 0, peOffset + 26 <= bytes.count,
            bytes[peOffset] == 0x50, bytes[peOffset + 1] == 0x45, bytes[peOffset + 2] == 0, bytes[peOffset + 3] == 0
        else { return nil }

        let coff = peOffset + 4
        let machineCode = readUInt16(bytes, coff)
        let characteristics = readUInt16(bytes, coff + 18)
        let optionalHeader = coff + 20
        let magic = readUInt16(bytes, optionalHeader)

        let machine: String
        switch machineCode {
        case 0x014C: machine = "x86"
        case 0x8664: machine = "x64"
        case 0xAA64: machine = "ARM64"
        case 0x01C4: machine = "ARM (32-bit)"
        default: machine = String(format: "0x%04X", machineCode)
        }

        let format: String
        switch magic {
        case 0x10B: format = "PE32"
        case 0x20B: format = "PE32+"
        default: format = String(format: "0x%04X", magic)
        }

        // Subsystem sits at offset 68 in both PE32 and PE32+ optional headers.
        var subsystem: String?
        if optionalHeader + 70 <= bytes.count {
            switch readUInt16(bytes, optionalHeader + 68) {
            case 2: subsystem = "Windows GUI"
            case 3: subsystem = "Windows console"
            case 1: subsystem = "Native"
            default: subsystem = nil
            }
        }

        return PEInfo(machine: machine, format: format, isDLL: characteristics & 0x2000 != 0, subsystem: subsystem)
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
