import XCTest
@testable import TypstEdit

/// Markdown ↔ Typst conversion exposed to agents (`markdown_to_typst`,
/// `typst_to_markdown` MCP tools, `typstedit convert` / `typstedit to-markdown`).
@MainActor
final class AgentDocumentConversionTests: XCTestCase {

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConversionTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func request(source: String, kind: String = "md", hybrid: Bool = false) -> AgentConvertRequest {
        var request = AgentConvertRequest()
        request.source = source
        request.sourceKind = kind
        request.isHybrid = hybrid
        request.workingDirectory = workDir
        return request
    }

    // MARK: - Direction

    func testDirectionFollowsTheSourceKind() {
        XCTAssertEqual(AgentDocumentConverter.direction(from: "md", isHybrid: false), .markdownToTypst)
        XCTAssertEqual(AgentDocumentConverter.direction(from: "typ", isHybrid: false), .typstToMarkdown)
        XCTAssertEqual(AgentDocumentConverter.direction(from: "note", isHybrid: false), .typstToMarkdown)
        XCTAssertEqual(AgentDocumentConverter.direction(from: "md", isHybrid: true), .markdownToTypst)
        XCTAssertEqual(AgentDocumentConverter.direction(from: "txt", isHybrid: false), .copy)
    }

    // MARK: - Markdown → Typst

    func testMarkdownToTypstConvertsStructure() async throws {
        let result = await AgentDocumentConverter.convert(request(source: """
        # Title

        Some **bold** text.

        - one
        - two
        """))
        XCTAssertTrue(result.success, result.summary)
        XCTAssertEqual(result.outputKind, "typ")
        XCTAssertTrue(result.output.contains("= Title"), result.output)
        XCTAssertTrue(result.output.contains("*bold*"), result.output)
        XCTAssertTrue(result.output.contains("- one"), result.output)
    }

    func testHybridKeepsLiveTypst() async throws {
        let source = """
        # Heading

        #let x = 1

        Value is $x$.
        """
        let result = await AgentDocumentConverter.convert(request(source: source, hybrid: true))
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.output.contains("#let x = 1"), result.output)
        XCTAssertTrue(result.output.contains("= Heading"), result.output)
    }

    // MARK: - Typst → Markdown

    func testTypstToMarkdownConvertsStructure() async throws {
        let result = await AgentDocumentConverter.convert(request(source: """
        = Title

        Some *bold* text and a #link("https://typst.app")[link].

        - one
        - two

        $ E = m c^2 $
        """, kind: "typ"))
        XCTAssertTrue(result.success, result.summary)
        XCTAssertEqual(result.outputKind, "md")
        XCTAssertTrue(result.output.contains("# Title"), result.output)
        XCTAssertTrue(result.output.contains("**bold**"), result.output)
        XCTAssertTrue(result.output.contains("[link](https://typst.app)"), result.output)
        XCTAssertTrue(result.output.contains("$ E = m c^2 $"), result.output)
    }

    // MARK: - Files

    func testReadsFromFileAndWritesOutput() async throws {
        let input = try write("doc.md", "# Title\n\nBody.\n")
        let output = workDir.appendingPathComponent("doc.typ")

        var request = AgentConvertRequest()
        request.inputPath = input.path
        request.outputPath = output.path
        request.workingDirectory = workDir

        let result = await AgentDocumentConverter.convert(request)
        XCTAssertTrue(result.success, result.summary)
        XCTAssertEqual(result.outputPath, output.path)
        let written = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(written, result.output)
        XCTAssertTrue(written.contains("= Title"), written)
    }

    /// A folder output keeps the source's base name and switches extension.
    func testFolderOutputUsesSourceName() async throws {
        let input = try write("report.md", "# Report\n")
        let folder = workDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var request = AgentConvertRequest()
        request.inputPath = input.path
        request.outputPath = folder.path + "/"
        request.workingDirectory = workDir

        let result = await AgentDocumentConverter.convert(request)
        XCTAssertTrue(result.success, result.summary)
        XCTAssertEqual(result.outputPath, folder.appendingPathComponent("report.typ").path)
    }

    func testRefusesToOverwriteTheInput() async throws {
        let input = try write("doc.typ", "= Title\n")
        var request = AgentConvertRequest()
        request.inputPath = input.path
        request.outputPath = input.path
        request.workingDirectory = workDir

        let result = await AgentDocumentConverter.convert(request)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.warnings.contains { $0.contains("overwrite") }, result.summary)
        // The file must still hold the original source.
        let onDisk = try String(contentsOf: input, encoding: .utf8)
        XCTAssertEqual(onDisk, "= Title\n")
    }

    func testMissingInputFails() async {
        var request = AgentConvertRequest()
        request.inputPath = workDir.appendingPathComponent("nope.md").path
        request.workingDirectory = workDir
        let result = await AgentDocumentConverter.convert(request)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.status, "errors")
    }

    func testNoInputFails() async {
        let result = await AgentDocumentConverter.convert(request(source: ""))
        // An empty source is still a source; an absent one is the error.
        XCTAssertTrue(result.success == false || result.output.isEmpty)

        var empty = AgentConvertRequest()
        empty.workingDirectory = workDir
        let missing = await AgentDocumentConverter.convert(empty)
        XCTAssertFalse(missing.success)
    }

    // MARK: - Verification

    func testVerifyIsOffByDefault() async throws {
        // Without `verify`, no compiler runs, so no diagnostics are produced.
        let result = await AgentDocumentConverter.convert(request(source: "# Heading\n\nText\n"))
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertFalse(result.verified)
    }

    func testVerifyReportsCompileErrors() async throws {
        guard AgentCompileService.shared.typstPath != nil else {
            throw XCTSkip("No typst binary available.")
        }
        // Markdown whose converted Typst uses a file that does not exist.
        var request = self.request(source: "# Heading\n\n![x](missing-image.png)\n")
        request.verify = true
        let result = await AgentDocumentConverter.convert(request)
        XCTAssertTrue(result.verified)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.status, "errors")
        XCTAssertGreaterThan(result.errorCount, 0)
        let diagnostic = try XCTUnwrap(result.diagnostics.first)
        XCTAssertEqual(diagnostic.severity, "error")
        XCTAssertNotNil(diagnostic.line, "diagnostics must name a line")
    }

    func testVerifyPassesForValidMarkdown() async throws {
        guard AgentCompileService.shared.typstPath != nil else {
            throw XCTSkip("No typst binary available.")
        }
        var request = self.request(source: "# Heading\n\nA paragraph with **bold** text.\n")
        request.verify = true
        let result = await AgentDocumentConverter.convert(request)
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.errorCount, 0)
    }

    func testJSONIsMachineReadable() async throws {
        let result = await AgentDocumentConverter.convert(request(source: "# Hi\n"))
        let json = result.jsonString()
        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "ok")
        XCTAssertEqual(parsed["outputKind"] as? String, "typ")
        XCTAssertEqual(parsed["output"] as? String, result.output)
    }
}
