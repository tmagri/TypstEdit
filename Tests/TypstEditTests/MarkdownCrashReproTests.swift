import XCTest
import Markdown
@testable import TypstEdit

/// Stage-by-stage profile of the Markdown→Typst pipeline against
/// Docs/typst-documentation.md (1.2 MB rough PDF conversion) to find the
/// crash/hang. Each stage prints its own timing so the last printed stage
/// before a hang is the culprit.
final class MarkdownCrashReproTests: XCTestCase {

    private var docText: String? {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile
            .deletingLastPathComponent() // TypstEditTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let docURL = root.appendingPathComponent("Docs/typst-documentation.md")
        return try? String(contentsOf: docURL, encoding: .utf8)
    }

    private func stage(_ name: String, _ body: () -> Void) {
        let start = Date()
        print("[REPRO] === \(name) START", terminator: "")
        fflush(stdout)
        body()
        print(" done in \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        fflush(stdout)
    }

    func testProfilePipeline() throws {
        let text = try XCTUnwrap(docText)
        print("[REPRO] doc bytes: \(text.utf8.count), utf16: \(text.utf16.count)")
        fflush(stdout)

        // Stage 0: CRLF normalization
        var work = text
        stage("CRLF") {
            work = work.replacingOccurrences(of: "\r\n", with: "\n")
        }

        // Markers are picked BEFORE extraction in the real pipeline.
        let markers = PlaceholderMarkers(for: work)
        print("[REPRO] markers: \(markers.code.value), \(markers.math.value), \(markers.escape.value), \(markers.typst.value)")
        fflush(stdout)

        // Stage A: docDot (⋅/· at line starts → spaces)
        stage("docDot") {
            let processed = NSMutableString(string: work)
            for match in AICompletionRegex.docDot.matches(in: work, options: [], range: NSRange(0..<processed.length)).reversed() {
                let replaced = processed.substring(with: match.range)
                    .replacingOccurrences(of: "⋅", with: " ")
                    .replacingOccurrences(of: "·", with: " ")
                processed.replaceCharacters(in: match.range, with: replaced)
            }
            work = processed as String
        }

        // Stage B: fenced + inline code extraction
        var codeRegions: [String] = []
        stage("codeBlock") {
            let processed = NSMutableString(string: work)
            let matches = AICompletionRegex.codeBlock.matches(in: work, options: [], range: NSRange(0..<processed.length))
            print("[REPRO] codeBlock matches: \(matches.count)")
            fflush(stdout)
            for match in matches.reversed() {
                codeRegions.append(processed.substring(with: match.range))
                processed.replaceCharacters(in: match.range, with: PlaceholderMarkers.token(kind: markers.code, index: codeRegions.count - 1))
            }
            work = processed as String
        }

        // Stage C: math extraction + LaTeX→Typst conversion
        var mathRegions: [(raw: String, typst: String)] = []
        stage("mathBlock") {
            let processed = NSMutableString(string: work)
            let matches = AICompletionRegex.mathBlock.matches(in: work, options: [], range: NSRange(0..<processed.length))
            print("[REPRO] mathBlock matches: \(matches.count)")
            fflush(stdout)
            for match in matches.reversed() {
                let raw = processed.substring(with: match.range)
                let latex = Self.strippedMathDelimiters(raw)
                mathRegions.append((raw, LyxToTypstConverter.convertLatexMathToTypst(latex)))
                processed.replaceCharacters(in: match.range, with: PlaceholderMarkers.token(kind: markers.math, index: mathRegions.count - 1))
            }
            work = processed as String
        }

        // Stage D: backslash escapes
        var escapeRegions: [String] = []
        stage("backslashEscape") {
            let processed = NSMutableString(string: work)
            let matches = AICompletionRegex.backslashEscape.matches(in: work, options: [], range: NSRange(0..<processed.length))
            print("[REPRO] backslashEscape matches: \(matches.count)")
            fflush(stdout)
            for match in matches.reversed() {
                escapeRegions.append(processed.substring(with: match.range))
                processed.replaceCharacters(in: match.range, with: PlaceholderMarkers.token(kind: markers.escape, index: escapeRegions.count - 1))
            }
            work = processed as String
        }

        // Stage E: footnote definitions
        var footnoteDefs: [String: String] = [:]
        stage("fnDef") {
            let processed = NSMutableString(string: work)
            let matches = AICompletionRegex.fnDef.matches(in: work, options: [], range: NSRange(0..<processed.length))
            print("[REPRO] fnDef matches: \(matches.count)")
            fflush(stdout)
            for match in matches.reversed() {
                let id = processed.substring(with: match.range(at: 1))
                let body = processed.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                footnoteDefs[id] = body
                processed.replaceCharacters(in: match.range, with: "")
            }
            work = processed as String
        }

        // Stage F: cmark parse
        var document: Document!
        stage("Document(parsing:)") {
            document = Document(parsing: work, options: [.disableSmartOpts, .disableSourcePosOpts])
        }

        // Stage G: AST walk
        var result = ""
        stage("TypstMarkupVisitor") {
            let scan = try! NSRegularExpression(
                pattern: "[\(markers.codeText)\(markers.mathText)\(markers.escapeText)\(markers.typstText)][\(PlaceholderMarkers.vsStartText)-\(PlaceholderMarkers.vsEndText)]+"
            )
            var visitor = TypstMarkupVisitor(
                isHybrid: false,
                codeRegions: codeRegions,
                mathRegions: mathRegions,
                escapeRegions: escapeRegions,
                typstRegions: [],
                footnoteDefs: footnoteDefs,
                markers: markers,
                placeholderScan: scan
            )
            result = visitor.visit(document)
        }
        print("[REPRO] result utf16: \(result.utf16.count)")
        fflush(stdout)

        // Stage H: post-passes
        stage("markdownAbbr") {
            result = AICompletionRegex.markdownAbbr
                .stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..<result.endIndex, in: result), withTemplate: "\\\\*[$1]:")
        }
        stage("stringLiteral") {
            let processed = NSMutableString(string: result)
            for match in AICompletionRegex.stringLiteral.matches(in: result, options: [], range: NSRange(0..<processed.length)).reversed() {
                let unescaped = processed.substring(with: match.range)
                    .replacingOccurrences(of: "\\_", with: "_")
                    .replacingOccurrences(of: "\\*", with: "*")
                    .replacingOccurrences(of: "\\#", with: "#")
                    .replacingOccurrences(of: "\\`", with: "`")
                processed.replaceCharacters(in: match.range, with: unescaped)
            }
            result = processed as String
        }

        // Stage I: line map (runs on every updateContent for .md/.note)
        stage("buildLineMap") {
            _ = TypstCompiler.buildLineMap(source: text, output: result)
        }

        print("[REPRO] PIPELINE COMPLETE, final utf16: \(result.utf16.count)")

        // Dump the converted output so the real typst CLI can be run on it.
        let dumpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typstedit-repro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
        let dumpURL = dumpDir.appendingPathComponent("converted.typ")
        try? result.write(to: dumpURL, atomically: true, encoding: .utf8)
        print("[REPRO] converted output written to \(dumpURL.path) (\(result.utf8.count) bytes)")
        fflush(stdout)
    }

    /// Local copy of the (private) delimiter stripper in AICompletionService.
    private static func strippedMathDelimiters(_ raw: String) -> String {
        if raw.hasPrefix("$$") && raw.hasSuffix("$$") && raw.count >= 4 {
            return String(raw.dropFirst(2).dropLast(2))
        }
        if raw.hasPrefix("\\[") && raw.hasSuffix("\\]") && raw.count >= 4 {
            return String(raw.dropFirst(2).dropLast(2))
        }
        if raw.hasPrefix("\\(") && raw.hasSuffix("\\)") && raw.count >= 4 {
            return String(raw.dropFirst(2).dropLast(2))
        }
        if raw.hasPrefix("$") && raw.hasSuffix("$") && raw.count >= 2 {
            return String(raw.dropFirst(1).dropLast(1))
        }
        return raw
    }
}

/// Regression tests for the diagnostic-pipeline flood protection that keeps
/// TypstEdit responsive on documents that produce thousands of compile errors
/// (e.g. a rough PDF→Markdown conversion). Before the fix, each diagnostic
/// block triggered an O(n) issue rebuild + a UI publish, and the lenient
/// fallback fixer rewrote the shadow file per block — a self-sustaining
/// fix→recompile storm on the main thread.
@MainActor
final class DiagnosticFloodTests: XCTestCase {

    private final class NotificationCounter {
        var count = 0
        func hit() { count += 1 }
    }

    /// `typst watch` prints the status marker BEFORE the cycle's diagnostics,
    /// with an `[HH:MM:SS]` prefix; each diagnostic block ends with a blank line.
    private func diagnosticBlock(line: Int, message: String) -> String {
        """
        error: \(message)
          ┌─ flood-test.typ:\(line):1
          │
        \(line) │ broken text
          │      ^
          │

        """ + "\n" // the blank line terminates the diagnostic block
    }

    private func observePublishes() -> (counter: NotificationCounter, token: NSObjectProtocol) {
        let counter = NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .typstErrorsUpdated, object: nil, queue: nil
        ) { _ in counter.hit() }
        return (counter, token)
    }

    func testFloodBatchPublishesOnceAndCapped() async throws {
        let compiler = TypstCompiler()
        compiler.setDiagnosticDocumentForTesting(fileName: "flood-test.typ")
        let (counter, token) = observePublishes()
        defer { NotificationCenter.default.removeObserver(token) }

        // 600 diagnostics in one cycle — far above the 100-diagnostic flood limit.
        var stream = "compiling ...\n[10:00:00] compiled with errors\n"
        for i in 1...600 {
            stream += diagnosticBlock(line: i, message: "unknown variable: v\(i)")
        }
        compiler.feedWatchOutputForTesting(stream)

        let state = compiler.floodGuardDebugState
        XCTAssertEqual(state.batchDiagnosticCount, 600)
        XCTAssertEqual(
            state.pendingFallbackLineCount, 0,
            "fallback-line queueing must stop once the cycle floods")

        // Let the debounced publish fire (250 ms debounce).
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(
            counter.count, 1,
            "a flooded batch must publish once after the stream pauses, not once per block")
        XCTAssertEqual(compiler.errors.count, 251, "published list must be capped at 250 + the '… more' marker")
        XCTAssertTrue(
            compiler.errors.last?.message.contains("more issue") ?? false,
            "the cap must be announced by a trailing marker")
    }

    func testSmallBatchDedupsAndCoalescesPublishes() async throws {
        let compiler = TypstCompiler()
        compiler.setDiagnosticDocumentForTesting(fileName: "flood-test.typ")
        compiler.setShadowURLForTesting(nil) // no shadow file → no rewrite → publishes go through
        let (counter, token) = observePublishes()
        defer { NotificationCenter.default.removeObserver(token) }

        var stream = "compiling ...\n[10:00:00] compiled with errors\n"
        stream += diagnosticBlock(line: 2, message: "unknown variable: x")
        stream += diagnosticBlock(line: 3, message: "unknown variable: y")
        stream += diagnosticBlock(line: 2, message: "unknown variable: x") // duplicate of the first
        compiler.feedWatchOutputForTesting(stream)

        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(counter.count, 1, "blocks completing within the debounce window must coalesce into one publish")
        XCTAssertEqual(compiler.errors.count, 2, "same line+file+message diagnostics must deduplicate")
    }

    func testFallbackRewriteSuppressesPublishUntilRecompile() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typstedit-flood-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shadowURL = dir.appendingPathComponent("flood-test.typ")
        try "broken text\nmore broken text\n".write(to: shadowURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let compiler = TypstCompiler()
        compiler.setDiagnosticDocumentForTesting(fileName: "flood-test.typ")
        compiler.setShadowURLForTesting(shadowURL)
        let (counter, token) = observePublishes()
        defer { NotificationCenter.default.removeObserver(token) }

        var stream = "compiling ...\n[10:00:00] compiled with errors\n"
        stream += diagnosticBlock(line: 1, message: "unknown variable: x")
        compiler.feedWatchOutputForTesting(stream)
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertTrue(
            compiler.floodGuardDebugState.pendingRewrite,
            "a queued fallback rewrite must suppress publication of transient errors")
        XCTAssertEqual(counter.count, 0, "no publish while a fix→recompile cycle is pending")
    }

    func testFallbackChaseBudgetStopsOscillatingCascade() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typstedit-flood-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shadowURL = dir.appendingPathComponent("flood-test.typ")
        var body = ""
        for i in 1...5 { body += "broken line \(i) ~ x @ y\n" }
        try body.write(to: shadowURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let compiler = TypstCompiler()
        compiler.setDiagnosticDocumentForTesting(fileName: "flood-test.typ")
        compiler.setShadowURLForTesting(shadowURL)

        // Feed one fix→recompile cycle per call; every block completes with a
        // blank line, so each repair happens synchronously at block end.
        func feedCycle(line: Int) {
            compiler.feedWatchOutputForTesting(
                "compiling ...\n[10:00:00] compiled with errors\n"
                + diagnosticBlock(line: line, message: "cycle \(line)"))
        }

        for i in 1...3 { feedCycle(line: i) }
        let afterThreeCycles = try String(contentsOf: shadowURL, encoding: .utf8)
        XCTAssertNotEqual(afterThreeCycles, body, "small batches must still be repaired line-by-line")

        // A fourth rewrite is refused: the chase budget (3 cycles) is spent,
        // which is what stops an oscillating cascade from recompiling forever.
        feedCycle(line: 4)
        let afterBudget = try String(contentsOf: shadowURL, encoding: .utf8)
        XCTAssertEqual(afterBudget, afterThreeCycles, "the fix→recompile chase must stop after 3 cycles")
        XCTAssertTrue(
            afterBudget.contains("broken line 4"),
            "line 4 must remain untouched once the budget is spent")
        XCTAssertEqual(compiler.floodGuardDebugState.fallbackCycleCount, 3)
    }
}
