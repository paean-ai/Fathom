import XCTest
@testable import Fathom

final class FileToolsTests: XCTestCase {

    /// Make a fresh temp directory as the sandbox root.
    private func tempSandbox() throws -> FileSandbox {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fathom-filetools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FileSandbox(root: dir)
    }

    // MARK: Sandbox confinement (the security boundary)

    func testSandboxRejectsEscapes() {
        let box = FileSandbox(root: URL(fileURLWithPath: "/tmp/work"))
        XCTAssertNotNil(box.resolve("a/b.txt"))
        XCTAssertNotNil(box.resolve("/tmp/work/inside.txt"))
        XCTAssertNil(box.resolve("../etc/passwd"))         // climbs out
        XCTAssertNil(box.resolve("/etc/passwd"))           // absolute outside
        XCTAssertNil(box.resolve("a/../../b"))             // sneaky climb
    }

    // MARK: Glob matcher (pure)

    func testGlobMatcher() {
        XCTAssertTrue(Glob.match("*.swift", "Main.swift"))
        XCTAssertFalse(Glob.match("*.swift", "src/Main.swift"))   // * doesn't cross /
        XCTAssertTrue(Glob.match("**/*.swift", "src/Main.swift"))
        XCTAssertTrue(Glob.match("**/*.swift", "Main.swift"))     // **/ also matches zero dirs
        XCTAssertTrue(Glob.match("src/?.txt", "src/a.txt"))
        XCTAssertFalse(Glob.match("src/?.txt", "src/ab.txt"))
    }

    // MARK: Round-trip write → read → edit

    func testWriteReadEdit() async throws {
        let box = try tempSandbox()
        let write = await WriteFileTool(sandbox: box).invoke(arguments: #"{"path":"a/hello.txt","content":"hello world"}"#)
        XCTAssertTrue(write.contains("Wrote"))

        let read = await ReadFileTool(sandbox: box).invoke(arguments: #"{"path":"a/hello.txt"}"#)
        XCTAssertEqual(read, "hello world")

        let edit = await EditFileTool(sandbox: box).invoke(arguments: #"{"path":"a/hello.txt","old_string":"world","new_string":"Fathom"}"#)
        XCTAssertTrue(edit.contains("Edited"))
        let read2 = await ReadFileTool(sandbox: box).invoke(arguments: #"{"path":"a/hello.txt"}"#)
        XCTAssertEqual(read2, "hello Fathom")
    }

    func testEditFailsWhenNotUnique() async throws {
        let box = try tempSandbox()
        _ = await WriteFileTool(sandbox: box).invoke(arguments: #"{"path":"x.txt","content":"a a a"}"#)
        let edit = await EditFileTool(sandbox: box).invoke(arguments: #"{"path":"x.txt","old_string":"a","new_string":"b"}"#)
        XCTAssertTrue(edit.contains("appears 3 times"))
    }

    // MARK: list / glob / grep over a real tree

    func testListGlobGrep() async throws {
        let box = try tempSandbox()
        _ = await WriteFileTool(sandbox: box).invoke(arguments: #"{"path":"src/A.swift","content":"let token = 1\nprint(token)"}"#)
        _ = await WriteFileTool(sandbox: box).invoke(arguments: #"{"path":"src/B.swift","content":"let other = 2"}"#)
        _ = await WriteFileTool(sandbox: box).invoke(arguments: #"{"path":"README.md","content":"docs"}"#)

        let list = await ListDirTool(sandbox: box).invoke(arguments: #"{"path":"src"}"#)
        XCTAssertTrue(list.contains("A.swift"))
        XCTAssertTrue(list.contains("B.swift"))

        let glob = await GlobTool(sandbox: box).invoke(arguments: #"{"pattern":"**/*.swift"}"#)
        XCTAssertTrue(glob.contains("src/A.swift"))
        XCTAssertFalse(glob.contains("README.md"))

        let grep = await GrepTool(sandbox: box).invoke(arguments: #"{"pattern":"token","in":"**/*.swift"}"#)
        XCTAssertTrue(grep.contains("src/A.swift:1:"))
        XCTAssertFalse(grep.contains("B.swift"))
    }

    // MARK: run_command

    func testRunCommand() async throws {
        let box = try tempSandbox()
        let out = await RunCommandTool(sandbox: box).invoke(arguments: #"{"command":"echo hello-fathom"}"#)
        XCTAssertEqual(out, "hello-fathom")
        let fail = await RunCommandTool(sandbox: box).invoke(arguments: #"{"command":"exit 3"}"#)
        XCTAssertTrue(fail.contains("[exit 3]"))
    }

    func testCodingToolsBundle() throws {
        let tools = try tempSandbox().codingTools()
        let names = Set(tools.map(\.name))
        XCTAssertEqual(names, ["read_file", "write_file", "edit_file", "list_dir", "glob", "grep", "run_command"])
    }
}
