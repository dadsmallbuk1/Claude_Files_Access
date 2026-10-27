import XCTest

@testable import FilesCore

final class PathResolverTests: XCTestCase {
    let resolver = PathResolver(roots: [
        Root(name: "Madeira", url: URL(fileURLWithPath: "/tmp/m")),
        Root(name: "Downloads", url: URL(fileURLWithPath: "/tmp/d")),
    ])

    func testResolvesRootRelativePaths() throws {
        let path = try resolver.resolve("Madeira/prefix/drive_c/windows")
        XCTAssertEqual(path.root.name, "Madeira")
        XCTAssertEqual(path.components, ["prefix", "drive_c", "windows"])
        XCTAssertEqual(path.url.path, "/tmp/m/prefix/drive_c/windows")
        XCTAssertEqual(path.display, "Madeira/prefix/drive_c/windows")
    }

    func testAcceptsBackslashesLeadingSlashAndCaseInsensitiveRoot() throws {
        let path = try resolver.resolve("/madeira\\drive_c\\./windows/")
        XCTAssertEqual(path.display, "Madeira/drive_c/windows")
    }

    func testDotDotStaysInsideRoot() throws {
        XCTAssertEqual(try resolver.resolve("Madeira/a/b/../c").display, "Madeira/a/c")
        XCTAssertThrowsError(try resolver.resolve("Madeira/../Downloads/x"))
        XCTAssertThrowsError(try resolver.resolve("Madeira/a/../../etc"))
    }

    func testEmptyPathMeansRootsAndUnknownRootFails() throws {
        XCTAssertNil(try resolver.resolveOptional(""))
        XCTAssertThrowsError(try resolver.resolve("Nope/file"))
    }
}

final class TextCodecTests: XCTestCase {
    func testDetectsEncodings() {
        XCTAssertEqual(TextCodec.detect(Data("plain ascii".utf8)), .utf8)
        XCTAssertEqual(TextCodec.detect(Data([0xEF, 0xBB, 0xBF]) + Data("x".utf8)), .utf8BOM)
        XCTAssertEqual(TextCodec.detect(TextCodec.encode("hello world", as: .utf16LE)), .utf16LE)
        XCTAssertEqual(TextCodec.detect(TextCodec.encode("hello world, no bom", as: .utf16LENoBOM)), .utf16LENoBOM)
        XCTAssertEqual(TextCodec.detect(Data([0x63, 0x61, 0x66, 0xE9])), .windows1252)
    }

    func testRoundTripsUTF16() {
        for encoding in [TextEncoding.utf16LE, .utf16BE, .utf8BOM, .utf8] {
            let text = "[Settings]\r\nName=Café ✓\r\n"
            let data = TextCodec.encode(text, as: encoding)
            let (decoded, detected) = TextCodec.decode(data)
            XCTAssertEqual(detected, encoding)
            XCTAssertEqual(decoded, text)
        }
    }

    func testBinaryDetection() {
        XCTAssertTrue(TextCodec.isText(Data("log line\n".utf8)))
        XCTAssertTrue(TextCodec.isText(TextCodec.encode("utf16 log", as: .utf16LE)))
        XCTAssertFalse(TextCodec.isText(Data([0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00])))
    }

    func testTrimsPartialUTF8() {
        let full = Data("ab✓".utf8)  // ✓ is 3 bytes
        XCTAssertEqual(full.prefix(4).trimmingIncompleteUTF8(), Data("ab".utf8))
        XCTAssertEqual(full.trimmingIncompleteUTF8(), full)
    }
}

final class GlobTests: XCTestCase {
    func testGlobMatching() throws {
        XCTAssertTrue(try Glob("*.log").matches("DXVK_D3D11.LOG"))
        XCTAssertTrue(try Glob("d3d1?.dll").matches("d3d11.dll"))
        XCTAssertFalse(try Glob("d3d1?.dll").matches("d3d9.dll"))
        XCTAssertTrue(try Glob("[!x]*.txt").matches("a.txt"))
        XCTAssertFalse(try Glob("[!x]*.txt").matches("x.txt"))
        XCTAssertTrue(try Glob("file(1).txt").matches("file(1).txt"))
    }
}

final class PEInfoTests: XCTestCase {
    static func fakePE(machine: UInt16, magic: UInt16, dll: Bool) -> Data {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        bytes[0x3C] = 0x80
        bytes[0x80] = 0x50
        bytes[0x81] = 0x45
        bytes[0x84] = UInt8(machine & 0xFF)
        bytes[0x85] = UInt8(machine >> 8)
        let characteristics: UInt16 = dll ? 0x2102 : 0x0102
        bytes[0x84 + 18] = UInt8(characteristics & 0xFF)
        bytes[0x84 + 19] = UInt8(characteristics >> 8)
        bytes[0x98] = UInt8(magic & 0xFF)
        bytes[0x99] = UInt8(magic >> 8)
        bytes[0x98 + 68] = 2
        return Data(bytes)
    }

    func testReadsArchitecture() {
        let x64 = PEInfo.read(Self.fakePE(machine: 0x8664, magic: 0x20B, dll: true))
        XCTAssertEqual(x64?.machine, "x64")
        XCTAssertEqual(x64?.bitness, "64-bit")
        XCTAssertEqual(x64?.format, "PE32+")
        XCTAssertEqual(x64?.isDLL, true)
        XCTAssertEqual(x64?.subsystem, "Windows GUI")

        let x86 = PEInfo.read(Self.fakePE(machine: 0x14C, magic: 0x10B, dll: false))
        XCTAssertEqual(x86?.bitness, "32-bit")
        XCTAssertEqual(x86?.isDLL, false)

        XCTAssertNil(PEInfo.read(Data("not a pe file at all".utf8)))
    }
}

final class ArchiveTests: XCTestCase {
    func checkEntries(_ data: Data, name: String, format expected: ArchiveFormat) throws {
        let (format, entries) = try ArchiveReader.read(data, fileName: name)
        XCTAssertEqual(format, expected, name)
        let files = Dictionary(
            entries.filter { $0.kind == .file }.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(try files["dxvk-2.4/x64/d3d11.dll"]?.data(), Data("x64-d3d11".utf8), name)
        XCTAssertEqual(try files["dxvk-2.4/x32/d3d11.dll"]?.data(), Data("x32-d3d11".utf8), name)
        XCTAssertEqual(try files["dxvk-2.4/README.md"]?.data(), Data("# DXVK\nline two\n".utf8), name)
        XCTAssertEqual(
            try files["dxvk-2.4/" + String(repeating: "a", count: 120) + "/long.txt"]?.data(), Data("long name".utf8),
            name)
    }

    func testTarFormats() throws {
        try checkEntries(Fixtures.tar, name: "dxvk.tar", format: .tar)
        try checkEntries(Fixtures.tarGz, name: "dxvk.tar.gz", format: .tarGzip)
        try checkEntries(Fixtures.tarXz, name: "dxvk.tar.xz", format: .tarXz)
        try checkEntries(Fixtures.tarZst, name: "dxvk.tar.zst", format: .tarZstd)
    }

    func testTarSpecialEntries() throws {
        let (_, entries) = try ArchiveReader.read(Fixtures.tar, fileName: "x.tar")
        let link = entries.first { $0.path == "dxvk-2.4/link" }
        XCTAssertEqual(link?.kind, .symlink)
        XCTAssertEqual(link?.linkTarget, "README.md")
        XCTAssertTrue(entries.contains { $0.path == "dxvk-2.4/x64" && $0.kind == .directory })
        XCTAssertTrue(entries.contains { $0.path == "../evil.txt" })
    }

    func testZip() throws {
        try checkEntries(Fixtures.zip, name: "dxvk.zip", format: .zip)
    }

    func testSingleGzip() throws {
        let (format, entries) = try ArchiveReader.read(Fixtures.singleGz, fileName: "notes.txt.gz")
        XCTAssertEqual(format, .gzip)
        XCTAssertEqual(entries.first?.path, "notes.txt")
        XCTAssertEqual(try entries.first?.data(), Data("hello from gzip\n".utf8))
    }

    func testSafeComponents() {
        XCTAssertEqual(ArchiveReader.safeComponents("./a/b/c.dll", strip: 1), ["b", "c.dll"])
        XCTAssertEqual(ArchiveReader.safeComponents("/abs/x", strip: 0), ["abs", "x"])
        XCTAssertNil(ArchiveReader.safeComponents("../evil", strip: 0))
        XCTAssertNil(ArchiveReader.safeComponents("top/", strip: 1))
    }

    func testRejectsUnknownFormats() {
        XCTAssertThrowsError(try ArchiveReader.read(Data("just text, not an archive".utf8), fileName: "a.bin"))
        XCTAssertThrowsError(try ArchiveReader.read(Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4]), fileName: "a.7z"))
    }
}
