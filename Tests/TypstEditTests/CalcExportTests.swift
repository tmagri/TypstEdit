import XCTest
@testable import TypstEdit

/// Every export path runs the calculator's static compilation: PDF export,
/// image export (PNG/SVG, including Markdown and Notes) and "Export as
/// Standard Typst", whose output must compile with the plain typst binary.
@MainActor
final class CalcExportTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalcExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func requireToolchain(needsPlugin: Bool = true) throws {
        guard CASEngine.isAvailable else { throw XCTSkip("typstedit-cas not built") }
        if needsPlugin { guard CalcPlugin.isAvailable else { throw XCTSkip("TypstEditCalc.wasm not built") } }
    }

    private func typstBinary() throws -> String {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("typst-aarch64-apple-darwin/typst").path,
            "/opt/homebrew/bin/typst", "/usr/local/bin/typst",
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("typst binary not found")
        }
        return path
    }

    /// Compiles `file` with the plain typst binary — no TypstEdit anything.
    private func compilesWithStockTypst(_ file: URL) throws -> (Bool, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try typstBinary())
        process.arguments = ["compile", file.path, directory.appendingPathComponent("stock.pdf").path,
                             "--root", file.deletingLastPathComponent().path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    private let calcDocument = """
    #let a = calc-param(2)
    = Report
    Value: #calc("2^10")
    #for n in range(3) [ J#n = #calc("BesselJ(n, 6)") ]
    #plot(x => BesselJ(a, x), 0, 20)
    #plot(points: #calc-table("sin(x)", x, 0, 6, 12), x-min: 0, x-max: 6)
    """

    // MARK: - Standard Typst

    func testStandardTypstExportCompilesWithStockTypst() async throws {
        try requireToolchain()
        let destination = directory.appendingPathComponent("report-standard.typ")
        let result = await TypstCompiler().exportStandardTypst(
            content: calcDocument, fileExtension: "typ", destination: destination)
        XCTAssertTrue(result.success, result.error ?? "")
        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertFalse(text.contains("#calc("), "every #calc must be inlined")
        XCTAssertFalse(text.contains("#calc-table("), "every #calc-table must be inlined")
        XCTAssertTrue(text.contains("1024"))
        XCTAssertTrue(text.contains("0.150645257"), "J0(6) from the loop specialisation")
        XCTAssertTrue(text.hasPrefix("#import \"TypstEditCalcBridge.typ\": "), "plot/BesselJ need the bundled bridge")
        // The sidecars sit next to the document, and the trio compiles anywhere.
        XCTAssertEqual(Set(result.files.map(\.lastPathComponent)),
                       ["report-standard.typ", "TypstEditCalcBridge.typ", "TypstEditCalc.wasm"])
        let (ok, output) = try compilesWithStockTypst(destination)
        XCTAssertTrue(ok, output)
    }

    func testStandardTypstExportWithoutRuntimeFunctionsNeedsNoSidecars() async throws {
        try requireToolchain(needsPlugin: false)
        let destination = directory.appendingPathComponent("values.typ")
        let source = """
        #let rate = calc-param(0.05)
        Rate #rate, growth #calc("(1+0.05)^10"), loop #for k in (1, 2) [#calc("k*10") ]
        """
        let result = await TypstCompiler().exportStandardTypst(
            content: source, fileExtension: "typ", destination: destination)
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["values.typ"])
        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertFalse(text.contains("calc"), "nothing calculator-specific may remain:\n\(text)")
        XCTAssertTrue(text.contains("#let rate = (0.05)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(CalcPlugin.wasmFileName).path))
        let (ok, output) = try compilesWithStockTypst(destination)
        XCTAssertTrue(ok, output)
    }

    func testStandardTypstExportFromNoteAndMarkdown() async throws {
        try requireToolchain()
        for (ext, source) in [
            ("note", "# Note title\n\nThe value is #calc(\"3*7\").\n\n#plot(calc-fn(\"erf\"), -2, 2)\n"),
            ("md", "# Markdown\n\nSome **bold** text and #calc(\"6*7\").\n"),
        ] {
            let destination = directory.appendingPathComponent("from-\(ext).typ")
            let result = await TypstCompiler().exportStandardTypst(
                content: source, fileExtension: ext, destination: destination)
            XCTAssertTrue(result.success, "\(ext): \(result.error ?? "")")
            let text = try String(contentsOf: destination, encoding: .utf8)
            XCTAssertFalse(text.contains("#calc("), "\(ext): \(text)")
            XCTAssertTrue(text.contains(ext == "note" ? "21" : "42"), text)
            let (ok, output) = try compilesWithStockTypst(destination)
            XCTAssertTrue(ok, "\(ext): \(output)")
        }
    }

    func testStandardTypstExportRefusesUnevaluableCalls() async throws {
        try requireToolchain(needsPlugin: false)
        let destination = directory.appendingPathComponent("bad.typ")
        let result = await TypstCompiler().exportStandardTypst(
            content: "#calc(\"2 +\")", fileExtension: "typ", destination: destination)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("could not be evaluated") ?? false, result.error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "nothing half-done is written")
    }

    // MARK: - PDF and image exports run the same step

    func testPDFExportRunsStaticCompilation() async throws {
        try requireToolchain()
        let original = directory.appendingPathComponent("doc.typ")
        try calcDocument.write(to: original, atomically: true, encoding: .utf8)
        let result = await TypstCompiler().compileClean(
            content: calcDocument, fileExtension: "typ", originalFileURL: original, projectRoot: directory)
        XCTAssertTrue(result.success, result.error ?? "")
    }

    func testImageExportsRunStaticCompilationForEverySourceKind() async throws {
        try requireToolchain()
        let sources: [(String, String)] = [
            ("typ", calcDocument),
            ("note", "# Note\n\nValue #calc(\"2+2\").\n\n#plot(calc-fn(\"besselj\", 0), 0, 10)\n"),
            ("md", "# Markdown\n\nValue #calc(\"2+2\") and #for n in range(2) [#calc(\"n+1\") ]\n"),
        ]
        for (ext, source) in sources {
            for format in ["png", "svg"] {
                let original = directory.appendingPathComponent("doc-\(ext).\(ext)")
                try source.write(to: original, atomically: true, encoding: .utf8)
                let output = directory.appendingPathComponent("out-\(ext).\(format)")
                let result = await TypstCompiler().exportFormatted(
                    content: source, fileExtension: ext, originalFileURL: original,
                    outputURL: output, format: format, projectRoot: directory)
                XCTAssertTrue(result.success, "\(ext)→\(format): \(result.error ?? "")")
                let written = TypstCompiler.firstGeneratedExportURL(for: TypstCompiler.exportDestinationURL(for: format, requested: output))
                XCTAssertNotNil(written, "\(ext)→\(format): no output file")
                XCTAssertGreaterThan((try? Data(contentsOf: written ?? output))?.count ?? 0, 100, "\(ext)→\(format)")
            }
        }
    }

    // MARK: - Export file lookup (pre-existing bug found here)

    func testFirstGeneratedExportURLFindsTheFilesTypstWrites() throws {
        for name in ["report-1.png", "report-2.png", "report-10.png", "report-x.png", "reportage-1.png"] {
            try Data([0]).write(to: directory.appendingPathComponent(name))
        }
        let template = TypstCompiler.exportDestinationURL(for: "png", requested: directory.appendingPathComponent("report.png"))
        XCTAssertEqual(TypstCompiler.firstGeneratedExportURL(for: template)?.lastPathComponent, "report-1.png")
    }
}
