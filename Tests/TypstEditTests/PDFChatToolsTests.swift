import XCTest
import PDFKit
import CoreText
@testable import TypstEdit

/// PDFs drawn by the tests, so no fixture files are needed.
enum PDFTestFixtures {
    /// Title, two paragraphs, and a ruled table with a merged header row.
    /// `formulas` adds centred display formulas between paragraphs.
    /// `pages` repeats the page (only the first one has content).
    static func draw(to url: URL, formulas: [String] = [], pages: Int = 1) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        func line(_ string: String, size: CGFloat, bold: Bool) -> CTLine {
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
        }
        func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false) {
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line(string, size: size, bold: bold), context)
        }
        /// Centred on the paragraph lines around it, as display math is.
        func centred(_ string: String, between text: String, y: CGFloat, size: CGFloat) {
            let width = CGFloat(CTLineGetTypographicBounds(line(string, size: size, bold: false), nil, nil, nil))
            let block = CGFloat(CTLineGetTypographicBounds(line(text, size: size, bold: false), nil, nil, nil))
            context.textPosition = CGPoint(x: 72 + (block - width) / 2, y: y)
            CTLineDraw(line(string, size: size, bold: false), context)
        }
        for page in 0..<pages {
            context.beginPDFPage(nil)
            if page == 0 {
                text("Quarterly Report", x: 72, y: 720, size: 20, bold: true)
                text("Revenue grew in every region this quarter.", x: 72, y: 680, size: 11)
                var y: CGFloat = 640
                let after = "The relation above holds for every region in the report."
                for formula in formulas {
                    centred(formula, between: after, y: y, size: 11)
                    text(after, x: 72, y: y - 30, size: 11)
                    y -= 70
                }
                text("Costs stayed flat compared with last year.", x: 72, y: y, size: 11)
                let top = y - 40
                context.setStrokeColor(gray: 0, alpha: 1)
                context.setLineWidth(0.8)
                for dy in [0.0, 20, 40, 60] as [CGFloat] {
                    context.move(to: CGPoint(x: 72, y: top - dy)); context.addLine(to: CGPoint(x: 372, y: top - dy))
                }
                for x in [72.0, 372] as [CGFloat] { context.move(to: CGPoint(x: x, y: top - 60)); context.addLine(to: CGPoint(x: x, y: top)) }
                context.move(to: CGPoint(x: 222, y: top - 60)); context.addLine(to: CGPoint(x: 222, y: top - 20))
                context.strokePath()
                text("Sales by Region", x: 180, y: top - 14, size: 11, bold: true)
                text("North", x: 80, y: top - 34, size: 11); text("120", x: 230, y: top - 34, size: 11)
                text("South", x: 80, y: top - 54, size: 11); text("95", x: 230, y: top - 54, size: 11)
            } else {
                text("Page \(page + 1) continues the report with more detail.", x: 72, y: 700, size: 11)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }
}

/// The chat's `read_pdf` / `import_pdf` tools, and how a PDF import treats a
/// busy local model.
@MainActor
final class PDFChatToolsTests: XCTestCase {
    private var root: URL!
    private var executor: LocalToolExecutor!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFChatTools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executor = LocalToolExecutor()
        executor.scope = .project(root: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func run(_ tool: String, _ arguments: [String: Any], approve: Bool = true,
                     seen: ((PendingApprovalKind) -> Void)? = nil) async throws -> String {
        try await executor.execute(toolName: tool, arguments: arguments) { kind in
            seen?(kind)
            return approve
        }
    }

    // MARK: - Tools

    func testToolsAreOffered() {
        let names = Set(executor.toolDescriptors().map(\.name))
        XCTAssertTrue(names.contains("read_pdf"))
        XCTAssertTrue(names.contains("import_pdf"))
        XCTAssertTrue(AIChatManager.isPlanModeBlockedTool("project__import_pdf"))
        XCTAssertFalse(AIChatManager.isPlanModeBlockedTool("project__read_pdf"))
    }

    func testReadPDFReturnsMarkdownAndWritesNothing() async throws {
        try PDFTestFixtures.draw(to: root.appendingPathComponent("report.pdf"))
        let out = try await run("read_pdf", ["path": "report.pdf"])
        XCTAssertTrue(out.hasPrefix("PDF 'report.pdf', pages 1-1 of 1"), out)
        XCTAssertTrue(out.contains("# Quarterly Report"), out)
        XCTAssertTrue(out.contains("| North | 120 |"), out)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["report.pdf"])
    }

    func testReadPDFDefaultsToFirstPagesOfALongPDF() async throws {
        try PDFTestFixtures.draw(to: root.appendingPathComponent("long.pdf"), pages: LocalToolExecutor.defaultPDFPages + 3)
        let out = try await run("read_pdf", ["path": "long.pdf"])
        XCTAssertTrue(out.contains("pages 1-\(LocalToolExecutor.defaultPDFPages) of \(LocalToolExecutor.defaultPDFPages + 3)"), out)
        XCTAssertTrue(out.contains("pass pages"), out)
    }

    func testReadPDFRejectsOtherFiles() async throws {
        try "text".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        do {
            _ = try await run("read_pdf", ["path": "notes.txt"])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not a PDF"), error.localizedDescription)
        }
    }

    func testImportPDFWritesTypstAfterApproval() async throws {
        try PDFTestFixtures.draw(to: root.appendingPathComponent("report.pdf"))
        var approval: PendingApprovalKind?
        let out = try await run("import_pdf", ["path": "report.pdf", "output": "imported/"]) { approval = $0 }
        guard case .pdfImport(let source, let destination, let pages, let aiModel, let existing)? = approval else {
            return XCTFail("expected a .pdfImport approval, got \(String(describing: approval))")
        }
        XCTAssertEqual(source, "report.pdf")
        XCTAssertEqual(destination, "imported/report.typ")
        XCTAssertEqual(pages, "1-1 of 1")
        XCTAssertNil(aiModel)
        XCTAssertFalse(existing)
        let typst = try String(contentsOf: root.appendingPathComponent("imported/report.typ"), encoding: .utf8)
        XCTAssertTrue(typst.contains("= Quarterly Report"), typst)
        XCTAssertTrue(typst.contains("table.cell(colspan: 2)"), typst)
        XCTAssertTrue(out.contains("imported/report.typ"), out)
    }

    func testDeniedImportWritesNothing() async throws {
        try PDFTestFixtures.draw(to: root.appendingPathComponent("report.pdf"))
        do {
            _ = try await run("import_pdf", ["path": "report.pdf"], approve: false)
            XCTFail("expected approvalDenied")
        } catch LocalToolError.approvalDenied {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("report.typ").path))
    }

    func testImportOfVeryLongPDFNeedsPages() async throws {
        try PDFTestFixtures.draw(to: root.appendingPathComponent("book.pdf"), pages: LocalToolExecutor.maxPDFPagesPerImport + 1)
        do {
            _ = try await run("import_pdf", ["path": "book.pdf"])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Pass pages"), error.localizedDescription)
        }
    }

    // MARK: - MCP server

    /// `tools/call read_pdf` through the real JSON-RPC handler.
    func testMCPReadPDF() async throws {
        let url = root.appendingPathComponent("report.pdf")
        try PDFTestFixtures.draw(to: url)
        let pipe = Pipe()
        let server = TypstEditMCPServer(output: ProtocolOutput(fileDescriptor: pipe.fileHandleForWriting.fileDescriptor))
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                   "params": ["name": "read_pdf", "arguments": ["path": url.path]]]
        await server.handle(String(data: try JSONSerialization.data(withJSONObject: call), encoding: .utf8)!)
        try pipe.fileHandleForWriting.close()

        let line = try XCTUnwrap(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(reply["id"] as? Int, 7)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = try XCTUnwrap(((result["content"] as? [[String: Any]])?.first)?["text"] as? String)
        XCTAssertTrue(text.contains("# Quarterly Report"), text)
        XCTAssertTrue(text.contains("| North | 120 |"), text)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["pageCount"] as? Int, 1)
        XCTAssertEqual(structured["lastPage"] as? Int, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["report.pdf"], "read_pdf writes nothing")
    }

    func testMCPReadPDFReportsErrors() async throws {
        try "text".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let pipe = Pipe()
        let server = TypstEditMCPServer(output: ProtocolOutput(fileDescriptor: pipe.fileHandleForWriting.fileDescriptor))
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 8, "method": "tools/call",
                                   "params": ["name": "read_pdf", "arguments": ["path": root.appendingPathComponent("notes.txt").path]]]
        await server.handle(String(data: try JSONSerialization.data(withJSONObject: call), encoding: .utf8)!)
        try pipe.fileHandleForWriting.close()
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: pipe.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = (((result["content"] as? [[String: Any]])?.first)?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("is not a PDF"), text)
    }

    // MARK: - Progress

    func testProgressTracksPagesAndPhases() {
        let progress = PDFImportProgress(fileName: "book.pdf", totalPages: 1550)
        progress.apply("Reading page 1 of 1550…")
        XCTAssertEqual(progress.phase, .reading)
        XCTAssertEqual(progress.page, 1)
        progress.apply("Reading page 800 of 1550…")
        XCTAssertEqual(progress.page, 800)
        XCTAssertEqual(progress.fraction, 0.05 + (800.0 / 1550.0) * 0.65, accuracy: 0.001)
        progress.apply("Analysing layout of page 801…")
        XCTAssertEqual(progress.phase, .analysing)
        XCTAssertEqual(progress.page, 801)
        progress.apply("Saving figures…")
        XCTAssertEqual(progress.phase, .figures)
        XCTAssertGreaterThan(progress.fraction, 0.7)
        progress.apply("Writing Typst…")
        XCTAssertEqual(progress.phase, .writing)
        XCTAssertFalse(progress.isFinished)
        XCTAssertEqual(progress.log.count, 5)
    }

    func testProgressEndsInFinishedOrFailed() {
        let finished = PDFImportProgress(fileName: "a.pdf", totalPages: 2)
        finished.finish(output: URL(fileURLWithPath: "/tmp/a.typ"))
        XCTAssertEqual(finished.phase, .finished)
        XCTAssertTrue(finished.isFinished)
        XCTAssertEqual(finished.fraction, 1)
        XCTAssertEqual(finished.outputURL?.lastPathComponent, "a.typ")

        let failed = PDFImportProgress(fileName: "b.pdf", totalPages: 2)
        failed.fail("The PDF is password protected.")
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertTrue(failed.isFinished)
        XCTAssertEqual(failed.failure, "The PDF is password protected.")
        XCTAssertTrue(failed.message.contains("password"))

        let cancelled = PDFImportProgress(fileName: "c.pdf", totalPages: 2)
        cancelled.markCancelled()
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertTrue(cancelled.isFinished)
    }

    /// The importer reports "Reading page N of M" for every page, which is
    /// what the window counts.
    @MainActor
    func testImportReportsProgressPerPage() async throws {
        let url = root.appendingPathComponent("three.pdf")
        try PDFTestFixtures.draw(to: url, pages: 3)
        let progress = PDFImportProgress(fileName: "three.pdf", totalPages: 3)
        let importer = PDFImporter(sourceURL: url, outputDirectory: root, baseName: "three")
        _ = try await importer.run(progress: progress.progressHandler())
        // The importer delivers updates through a task; give them a moment.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(progress.log.contains { $0.hasPrefix("Reading page 3 of 3") }, "\(progress.log)")
        XCTAssertEqual(progress.page, 3)
        XCTAssertFalse(progress.log.isEmpty)
    }

    /// `import_pdf` reports into the chat's live status line.
    @MainActor
    func testImportPDFReportsProgressToTheChat() async throws {
        try PDFTestFixtures.draw(to: root.appendingPathComponent("report.pdf"), pages: 2)
        let lines = LineBox()
        executor.onProgress = { line in Task { @MainActor in lines.append(line) } }
        _ = try await run("import_pdf", ["path": "report.pdf"])
        try await Task.sleep(nanoseconds: 300_000_000)
        let seen = lines.all
        XCTAssertTrue(seen.contains { $0.hasPrefix("Importing report.pdf: Reading page 2 of 2") }, "\(seen)")
    }

    private final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    // MARK: - Busy local model

    func testActivityCountsRequestsPerServer() async {
        let activity = ModelServerActivity.shared
        let lmStudio = URL(string: "http://127.0.0.1:41234/v1/chat/completions")!
        let same = URL(string: "http://localhost:41234/v1/embeddings")!
        let other = URL(string: "http://localhost:41235/v1/chat/completions")!
        let ticket = activity.begin(lmStudio)
        XCTAssertTrue(activity.isBusy(same), "localhost and 127.0.0.1 are one server")
        XCTAssertFalse(activity.isBusy(other))
        let stillBusy = await activity.waitUntilIdle(same, timeout: 0.3)
        XCTAssertFalse(stillBusy)
        activity.end(ticket)
        let idle = await activity.waitUntilIdle(same, timeout: 0.3)
        XCTAssertTrue(idle)
    }

    /// While the local model is busy, the import does not queue behind it:
    /// it gives up after the idle wait, sends nothing else, and keeps the
    /// formulas as images with a note naming the server.
    func testImportStopsUsingABusyLocalModel() async throws {
        let url = root.appendingPathComponent("formulas.pdf")
        try PDFTestFixtures.draw(to: url, formulas: ["E = m c + 1", "F = m a - 2"])
        let server = URL(string: "http://localhost:41299/v1/chat/completions")!
        let chat = ModelServerActivity.shared.begin(server)   // the chat holds the model
        defer { ModelServerActivity.shared.end(chat) }

        var importer = PDFImporter(sourceURL: url, outputDirectory: root, baseName: "formulas")
        importer.aiTarget = PDFImportAI.Target(url: server, headers: [:], model: "local", style: .openAI,
                                               timeout: 5, maxTokens: 100, isLocal: true, idleWait: 0.3)
        let started = Date()
        let result = try await importer.run()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "must not wait on the busy model per item")
        let formulas = result.document.blocks.filter { $0.kind == .formula }
        XCTAssertEqual(formulas.count, 2, result.typst)
        let note = result.warnings.joined(separator: " ")
        XCTAssertTrue(note.contains("localhost:41299"), note)
        XCTAssertTrue(note.contains("stopped using AI"), note)
        XCTAssertTrue(note.contains("2 of 2"), note)
        XCTAssertTrue(result.typst.contains("TODO(import): formula shown as an image"), result.typst)
    }

    /// Cancel Import must stop an AI import promptly. The AI phase waits for
    /// a busy local model; cancelling has to interrupt that wait, not run to
    /// its 30-second timeout and then carry on with the next item.
    func testCancellingStopsTheAIImport() async throws {
        let url = root.appendingPathComponent("formulas.pdf")
        try PDFTestFixtures.draw(to: url, formulas: ["E = m c + 1", "F = m a - 2", "G = m g + 3"])
        let server = URL(string: "http://localhost:41298/v1/chat/completions")!
        let chat = ModelServerActivity.shared.begin(server)
        defer { ModelServerActivity.shared.end(chat) }

        var importer = PDFImporter(sourceURL: url, outputDirectory: root, baseName: "cancelled")
        // A long idle wait, so only cancellation can end this quickly.
        importer.aiTarget = PDFImportAI.Target(url: server, headers: [:], model: "local", style: .openAI,
                                               timeout: 60, maxTokens: 100, isLocal: true, idleWait: 60)
        let started = Date()
        let task = Task { try await importer.run() }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled import must not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "Cancel must interrupt the AI wait, not time it out")
        // Nothing was written for a cancelled import.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled.typ").path))
    }
}
