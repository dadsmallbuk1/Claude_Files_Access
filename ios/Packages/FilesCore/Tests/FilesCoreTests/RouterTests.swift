import XCTest

@testable import FilesCore

final class RouterTests: XCTestCase {
    var base: URL!
    var madeira: URL!
    var staging: URL!
    var router: ToolRouter!
    var allowChanges = true

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("FilesCoreTests-\(UUID().uuidString)")
        madeira = base.appendingPathComponent("Madeira")
        staging = base.appendingPathComponent("Staging")
        let prefix = madeira.appendingPathComponent("prefix/drive_c/windows")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("system32"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("syswow64"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("original d3d11".utf8).write(to: prefix.appendingPathComponent("system32/d3d11.dll"))
        try Data((1...500).map { "line \($0)" }.joined(separator: "\n").utf8)
            .write(to: madeira.appendingPathComponent("wine.log"))
        try TextCodec.encode("[Video]\r\nWidth=1280\r\nHeight=720\r\n", as: .utf16LE)
            .write(to: madeira.appendingPathComponent("settings.ini"))
        try FileManager.default.createSymbolicLink(
            at: madeira.appendingPathComponent("prefix/z:"), withDestinationURL: URL(fileURLWithPath: "/"))

        let roots = [Root(name: "Madeira", url: madeira), Root(name: "Staging", url: staging)]
        router = ToolRouter(
            changes: ChangeStore(directory: base.appendingPathComponent("Backups")),
            roots: { roots },
            allowChanges: { [unowned self] in self.allowChanges })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    func call(_ tool: String, _ args: [String: JSONValue] = [:], expectError: Bool = false,
              file: StaticString = #filePath, line: UInt = #line) async -> ToolResult {
        let result = await router.handle(tool: tool, arguments: args)
        XCTAssertEqual(result.isError, expectError, "\(tool): \(result.text)", file: file, line: line)
        return result
    }

    func contents(_ relative: String) throws -> String {
        String(decoding: try Data(contentsOf: madeira.appendingPathComponent(relative)), as: UTF8.self)
    }

    func changeId(_ result: ToolResult) -> String? {
        guard let range = result.text.range(of: #"ch-[0-9]{8}-[0-9]{6}-[0-9a-f]{4}"#, options: .regularExpression)
        else { return nil }
        return String(result.text[range])
    }

    func testStatusAndListing() async throws {
        let status = await call("device_status")
        XCTAssertTrue(status.text.contains("\"Madeira\""))

        let roots = await call("list_directory")
        XCTAssertTrue(roots.text.contains("Madeira/"))
        XCTAssertTrue(roots.text.contains("Staging/"))

        let tree = await call("list_directory", ["path": "Madeira", "depth": 5])
        XCTAssertTrue(tree.text.contains("system32/"))
        XCTAssertTrue(tree.text.contains("d3d11.dll"))
        // Symlinks are shown but not followed.
        XCTAssertTrue(tree.text.contains("z: -> /"))
        XCTAssertFalse(tree.text.contains("usr/"))

        await call("list_directory", ["path": "Madeira/../.."], expectError: true)
    }

    func testReadTailAndSearch() async throws {
        let read = await call("read_file", ["path": "Madeira/wine.log", "length": 20])
        XCTAssertTrue(read.text.contains("line 1\nline 2"))
        XCTAssertTrue(read.text.contains("continue with offset=20"))

        let tail = await call("tail_file", ["path": "Madeira/wine.log", "lines": 3])
        XCTAssertTrue(tail.text.hasSuffix("line 498\nline 499\nline 500"))

        try Data("first\r\nsecond\r\nthird\r\n".utf8).write(to: madeira.appendingPathComponent("crlf.log"))
        let crlfTail = await call("tail_file", ["path": "Madeira/crlf.log", "lines": 2])
        XCTAssertTrue(crlfTail.text.hasSuffix("]\nsecond\nthird"), crlfTail.text)

        let utf16 = await call("read_file", ["path": "Madeira/settings.ini"])
        XCTAssertTrue(utf16.text.contains("Width=1280"))
        XCTAssertTrue(utf16.text.contains("utf16le-bom"))

        let byName = await call("search", ["path": "Madeira", "name_pattern": "D3D*.DLL"])
        XCTAssertTrue(byName.text.contains("Madeira/prefix/drive_c/windows/system32/d3d11.dll"))

        let byContent = await call("search", ["path": "Madeira", "content_pattern": "height="])
        XCTAssertTrue(byContent.text.contains("settings.ini\n  3: Height=720"), byContent.text)

        let regex = await call("search", ["path": "Madeira", "content_pattern": "^line 49[0-9]$", "regex": true])
        XCTAssertTrue(regex.text.contains("499: line 499"))

        let recent = await call("recent_files", ["path": "Madeira", "within_minutes": 5])
        XCTAssertTrue(recent.text.contains("Madeira/wine.log"))
    }

    func testWriteEditAndUndo() async throws {
        let created = await call("write_file", ["path": "Madeira/new/dir/dxvk.conf", "content": "dxgi.maxFrameRate = 60\n"])
        XCTAssertEqual(try contents("new/dir/dxvk.conf"), "dxgi.maxFrameRate = 60\n")
        await call("write_file", ["path": "Madeira/new/dir/dxvk.conf", "content": "x", "mode": "create"], expectError: true)

        // Edit keeps UTF-16 and CRLF even though Claude sends LF.
        let edit = await call("edit_file", ["path": "Madeira/settings.ini", "old_text": "Width=1280\nHeight=720", "new_text": "Width=1920\nHeight=1080"])
        let edited = try Data(contentsOf: madeira.appendingPathComponent("settings.ini"))
        XCTAssertEqual(TextCodec.detect(edited), .utf16LE)
        XCTAssertEqual(TextCodec.decode(edited).0, "[Video]\r\nWidth=1920\r\nHeight=1080\r\n")

        let editId = try XCTUnwrap(changeId(edit))
        await call("undo_change", ["change_id": .string(editId)])
        XCTAssertEqual(TextCodec.decode(try Data(contentsOf: madeira.appendingPathComponent("settings.ini"))).0,
                       "[Video]\r\nWidth=1280\r\nHeight=720\r\n")
        await call("undo_change", ["change_id": .string(editId)], expectError: true)

        // Undoing the creation removes the file and the folders it created.
        let createdId = try XCTUnwrap(changeId(created))
        await call("undo_change", ["change_id": .string(createdId)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: madeira.appendingPathComponent("new").path))

        let changes = await call("list_changes")
        XCTAssertTrue(changes.text.contains(editId))
    }

    func testCopyMoveDeleteWithBackups() async throws {
        try Data("dxvk d3d11".utf8).write(to: staging.appendingPathComponent("d3d11.dll"))
        let system32 = "Madeira/prefix/drive_c/windows/system32"

        await call("copy", ["source": "Staging/d3d11.dll", "destination": .string(system32)], expectError: true)
        let copy = await call("copy", ["source": "Staging/d3d11.dll", "destination": .string(system32), "overwrite": true])
        XCTAssertEqual(try contents("prefix/drive_c/windows/system32/d3d11.dll"), "dxvk d3d11")
        await call("undo_change", ["change_id": .string(try XCTUnwrap(changeId(copy)))])
        XCTAssertEqual(try contents("prefix/drive_c/windows/system32/d3d11.dll"), "original d3d11")

        let move = await call("move", ["source": "Madeira/wine.log", "destination": "Madeira/old.log"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: madeira.appendingPathComponent("wine.log").path))
        await call("undo_change", ["change_id": .string(try XCTUnwrap(changeId(move)))])
        XCTAssertTrue(FileManager.default.fileExists(atPath: madeira.appendingPathComponent("wine.log").path))

        let delete = await call("delete", ["path": "Madeira/prefix/drive_c/windows/syswow64"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: madeira.appendingPathComponent("prefix/drive_c/windows/syswow64").path))
        await call("undo_change", ["change_id": .string(try XCTUnwrap(changeId(delete)))])
        XCTAssertTrue(FileManager.default.fileExists(atPath: madeira.appendingPathComponent("prefix/drive_c/windows/syswow64").path))

        await call("delete", ["path": "Madeira"], expectError: true)
        await call("copy", ["source": "Madeira/prefix", "destination": "Madeira/prefix/drive_c"], expectError: true)
    }

    func testExtractArchiveWithStripAndOverwrite() async throws {
        try Fixtures.tarGz.write(to: staging.appendingPathComponent("dxvk-2.4.tar.gz"))

        let listing = await call("extract_archive", ["path": "Staging/dxvk-2.4.tar.gz", "list_only": true])
        XCTAssertTrue(listing.text.contains("tar.gz"))
        XCTAssertTrue(listing.text.contains("dxvk-2.4/x64/d3d11.dll"))

        let extracted = await call("extract_archive", ["path": "Staging/dxvk-2.4.tar.gz", "destination": "Staging/dxvk", "strip_components": 1])
        XCTAssertTrue(extracted.text.contains("Skipped"))
        let x64 = staging.appendingPathComponent("dxvk/x64/d3d11.dll")
        XCTAssertEqual(try Data(contentsOf: x64), Data("x64-d3d11".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("evil.txt").path))

        // Extract the x64 folder's contents over system32: refuses without overwrite.
        await call("extract_archive", ["path": "Staging/dxvk-2.4.tar.gz", "destination": "Madeira/prefix/drive_c/windows/system32", "strip_components": 2], expectError: true)
        XCTAssertEqual(try contents("prefix/drive_c/windows/system32/d3d11.dll"), "original d3d11")

        let undoId = try XCTUnwrap(changeId(extracted))
        await call("undo_change", ["change_id": .string(undoId)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("dxvk").path))
    }

    func testChangesCanBeDisabled() async throws {
        allowChanges = false
        await call("write_file", ["path": "Madeira/x.txt", "content": "x"], expectError: true)
        await call("delete", ["path": "Madeira/wine.log"], expectError: true)
        await call("read_file", ["path": "Madeira/wine.log"])
        try Fixtures.zip.write(to: staging.appendingPathComponent("a.zip"))
        await call("extract_archive", ["path": "Staging/a.zip", "list_only": true])
    }

    func testFileInfoReportsPEArchitecture() async throws {
        try PEInfoTests.fakePE(machine: 0x14C, magic: 0x10B, dll: true)
            .write(to: madeira.appendingPathComponent("prefix/drive_c/windows/syswow64/d3d9.dll"))
        let info = await call("file_info", ["path": "Madeira/prefix/drive_c/windows/syswow64/d3d9.dll", "sha256": true])
        XCTAssertTrue(info.text.contains("\"bitness\" : \"32-bit\""))
        XCTAssertTrue(info.text.contains("\"sha256\""))

        let binaryRead = await call("read_file", ["path": "Madeira/prefix/drive_c/windows/syswow64/d3d9.dll"])
        XCTAssertTrue(binaryRead.text.contains("binary file"))
        let base64 = await call("read_file", ["path": "Madeira/prefix/drive_c/windows/syswow64/d3d9.dll", "encoding": "base64", "length": 2])
        XCTAssertTrue(base64.text.contains("\"base64\" : \"TVo=\""))
    }
}
