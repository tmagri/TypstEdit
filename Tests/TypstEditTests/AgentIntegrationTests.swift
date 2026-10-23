import XCTest
@testable import TypstEdit

/// Headless CLI / MCP integration used by external tools and AI agents.
@MainActor
final class AgentIntegrationTests: XCTestCase {

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentIntegrationTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func requireTypst() throws {
        if AgentCompileService.shared.typstPath == nil {
            throw XCTSkip("No typst binary available (set TYPSTEDIT_TYPST to run these tests).")
        }
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Hidden shadow files and temp folders must never be left next to user files.
    private func assertNoLeftovers(file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
        XCTAssertFalse(names.contains { $0.contains(".typstedit-") }, "leftover shadow file: \(names)", file: file, line: line)
        XCTAssertFalse(names.contains("temp"), "leftover temp folder", file: file, line: line)
    }

    // MARK: - Entry point routing

    func testOnlyKnownSubcommandsRunHeadless() {
        XCTAssertEqual(TypstEditCLI.invocation(from: ["/x/TypstEdit", "compile", "a.typ"]), ["compile", "a.typ"])
        XCTAssertEqual(TypstEditCLI.invocation(from: ["/x/TypstEdit", "mcp"]), ["mcp"])
        XCTAssertNil(TypstEditCLI.invocation(from: ["/x/TypstEdit"]))
        // Launch Services / Xcode arguments must still start the GUI.
        XCTAssertNil(TypstEditCLI.invocation(from: ["/x/TypstEdit", "-psn_0_12345"]))
        XCTAssertNil(TypstEditCLI.invocation(from: ["/x/TypstEdit", "-NSDocumentRevisionsDebugMode", "YES"]))
        XCTAssertNil(TypstEditCLI.invocation(from: ["/x/TypstEdit", "/Users/me/report.typ"]))
    }

    // MARK: - Compile service

    func testCompileTypWritesPDFAndReportsNoDiagnostics() async throws {
        try requireTypst()
        let input = try write("ok.typ", "= Hello\n\nWorld")
        var request = AgentCompileRequest()
        request.inputPath = input.path
        let result = await AgentCompileService.shared.compile(request)

        XCTAssertTrue(result.success, result.summary)
        XCTAssertEqual(result.errorCount, 0)
        XCTAssertEqual(result.outputs.map { URL(fileURLWithPath: $0).lastPathComponent }, ["ok.pdf"])
        try assertNoLeftovers()
    }

    func testCheckReportsErrorLocationInOriginalFile() async throws {
        try requireTypst()
        let input = try write("bad.typ", "Line one\n#undefinedthing\n")
        var request = AgentCompileRequest()
        request.inputPath = input.path
        request.checkOnly = true
        let result = await AgentCompileService.shared.compile(request)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorCount, 1)
        let diagnostic = try XCTUnwrap(result.diagnostics.first)
        XCTAssertEqual(diagnostic.line, 2)
        XCTAssertEqual(diagnostic.column, 2)
        XCTAssertEqual(diagnostic.file.map { URL(fileURLWithPath: $0).lastPathComponent }, "bad.typ")
        XCTAssertTrue(result.outputs.isEmpty, "check must not keep output files")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.appendingPathComponent("bad.pdf").path))
    }

    func testMarkdownErrorsAreReportedAgainstTheMarkdownFile() async throws {
        try requireTypst()
        // A shadow copy is compiled; diagnostics must still name the .md file.
        let input = try write("doc.md", "# Title\n\nText\n\n#import \"missing-module.typ\": x\n")
        var request = AgentCompileRequest()
        request.inputPath = input.path
        request.checkOnly = true
        let result = await AgentCompileService.shared.compile(request)

        XCTAssertTrue(result.notes.contains { $0.contains("Markdown") })
        for diagnostic in result.diagnostics where diagnostic.file?.hasSuffix(".typ") == true {
            XCTAssertFalse(diagnostic.file!.contains(".typstedit-"), "shadow path leaked: \(diagnostic.file!)")
        }
        try assertNoLeftovers()
    }

    func testInlineSourceAndMultiPagePNG() async throws {
        try requireTypst()
        var request = AgentCompileRequest()
        request.source = "#set page(width: 3cm, height: 2cm)\nA\n#pagebreak()\nB"
        request.format = .png
        request.ppi = 30
        request.outputPath = workDir.appendingPathComponent("page.png").path
        let result = await AgentCompileService.shared.compile(request)

        XCTAssertTrue(result.success, result.summary)
        XCTAssertEqual(result.outputs.count, 2)
        XCTAssertTrue(result.outputs.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }

    func testMissingInputFailsWithMessage() async {
        var request = AgentCompileRequest()
        request.inputPath = workDir.appendingPathComponent("nope.typ").path
        let result = await AgentCompileService.shared.compile(request)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorCount, 1)
    }

    // MARK: - MCP

    func testMCPToolDefinitionsAreValid() throws {
        let tools = TypstEditMCPServer.toolDefinitions
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                       ["typst_check", "typst_compile", "typst_render_preview", "typstedit_open", "typstedit_info"])
        for tool in tools {
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertTrue(JSONSerialization.isValidJSONObject(tool))
        }
    }

    // MARK: - Install / config

    func testShimInstallsAndNeverOverwritesForeignFiles() throws {
        let bin = workDir.appendingPathComponent("bin")
        let url = try AgentIntegrationManager.installCommandLineTool(into: bin)
        XCTAssertTrue(AgentIntegrationManager.isOurShim(url))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
        // Reinstalling over our own shim is fine.
        XCTAssertNoThrow(try AgentIntegrationManager.installCommandLineTool(into: bin))

        try "#!/bin/sh\necho other tool\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AgentIntegrationManager.installCommandLineTool(into: bin))
    }

    func testConfigSnippetsAreValid() throws {
        let command = "/Applications/Type Edit.app/Contents/MacOS/TypstEdit"
        for client in [AgentIntegrationManager.AgentClient.generic, .opencode, .claudeDesktop] {
            let snippet = AgentIntegrationManager.configSnippet(for: client, command: command)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(snippet.utf8)), "\(client) snippet is not JSON")
            XCTAssertTrue(snippet.contains(command))
        }
        let claude = AgentIntegrationManager.configSnippet(for: .claudeCode, command: command)
        XCTAssertTrue(claude.contains("'\(command)' mcp"), claude)
        XCTAssertTrue(AgentIntegrationManager.configSnippet(for: .codex, command: command).contains("args = [\"mcp\"]"))
    }
}
