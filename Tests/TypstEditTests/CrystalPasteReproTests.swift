import XCTest
@testable import TypstEdit

/// Regression tests for pasting a Markdown document full of register-style `$` hex
/// tokens (e.g. `$4017`) mixed into bold text and inline code into a `.note` file.
/// Root cause of the original breakage: `autoFixBrokenNoteSyntax` counted `$` inside
/// inline code spans as unclosed math and appended bogus closing dollars, which
/// paired currency dollars into math regions that swallowed whole paragraphs.
@MainActor
final class CrystalPasteReproTests: XCTestCase {

    /// The exact pipeline TypstCompiler.updateContent runs for `.note` files.
    private func notePipeline(_ source: String) -> (output: String, warnings: [TypstError]) {
        let autoFixed = TypstCompiler.autoFixBrokenNoteSyntax(source)
        let delimited = TypstCompiler.delimitImproperOperators(autoFixed)
        let cleaned = AICompletionService.shared.sanitizeMarkdownToTypst(delimited.output, isHybrid: true)
        return (cleaned, delimited.warnings)
    }

    private var typstPath: String? {
        [
            // Package root when run via `swift test`; $HOME-relative otherwise.
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("typst-aarch64-apple-darwin/typst").path,
            NSString(string: "~/Desktop/TypstEdit/typst-aarch64-apple-darwin/typst").expandingTildeInPath,
            "/opt/homebrew/bin/typst",
            "/usr/local/bin/typst",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func compileErrors(_ source: String) -> String {
        guard let typstPath = typstPath else { return "" }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("crystal-repro-\(UUID().uuidString).typ")
        let pdf = tmp.deletingPathExtension().appendingPathExtension("pdf")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: pdf)
        }
        do { try source.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { return "Failed to write temp source: \(error)" }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: typstPath)
        proc.arguments = ["compile", tmp.path, pdf.path]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = pipe
        do { try proc.run() }
        catch { return "Failed to launch typst: \(error)" }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - AutoFix: dollars inside inline code

    func testAutoFixIgnoresDollarsInsideInlineCode() {
        // The `$2002` lives inside a code span — the line has NO unpaired math.
        let input = #"keeps the `$2002` vblank-race guard on while the CPU outruns the PPU."#
        let output = TypstCompiler.autoFixBrokenNoteSyntax(input)
        XCTAssertEqual(output, input, "A `$` inside inline code must not be treated as unclosed math")
    }

    func testAutoFixDoesNotCloseCurrencyNextToCode() {
        // One real currency `$4017`; the `_`/`=` that used to veto the currency
        // heuristic live inside code spans and must not count.
        let input = #"feeds APU `PHI2` ($4017 `write_ce`, `aclk2`) here"#
        let output = TypstCompiler.autoFixBrokenNoteSyntax(input)
        XCTAssertFalse(output.hasSuffix("$"), "Currency dollar next to code must not be closed into math: \(output)")
        XCTAssertEqual(output, input)
    }

    func testAutoFixStillClosesGenuinelyUnclosedMath() {
        let input = "$B=p(1+i)^{t}+∑_{k=1}^"
        let output = TypstCompiler.autoFixBrokenNoteSyntax(input)
        XCTAssertEqual(output, "$B=p(1+i)^{t}+∑_{k=1}^{}$")
    }

    func testAutoFixDoesNotPairMultipleRegisterNames() {
        // Three register dollars on one line (odd count!) are still currency, not
        // an unclosed math block.
        let input = #"**NEW native PHI2 + $4017 write hold.** Only $4017 latches on `write_ce`, and $4015 reads are level-clear."#
        let output = TypstCompiler.autoFixBrokenNoteSyntax(input)
        XCTAssertEqual(output.components(separatedBy: "$").count - 1,
                       input.components(separatedBy: "$").count - 1,
                       "No dollars may be added or removed: \(output)")
    }

    func testAutoFixDoesNotTouchCodeSpanContent() {
        // A trailing `+` inside a code span used to be "fixed" into `+ ""`.
        let input = #"the expression `$b +$` is user code"#
        let output = TypstCompiler.autoFixBrokenNoteSyntax(input)
        XCTAssertEqual(output, input, "Math fixes must not rewrite inside code spans: \(output)")
    }

    // MARK: - Delimiting: Markdown headings survive

    func testDelimitPreservesMarkdownHeadings() {
        let inputs = ["# Title", "## Section", "### 4. Sub", "> ## Quoted"]
        for input in inputs {
            let (output, warnings) = TypstCompiler.delimitImproperOperators(input)
            XCTAssertFalse(output.contains("\\#"), "Heading must not be escaped: \(input) → \(output)")
            XCTAssertTrue(warnings.isEmpty, "Heading must not warn: \(input)")
        }
    }

    func testDelimitStillEscapesNonHeadingHash() {
        let (output, warnings) = TypstCompiler.delimitImproperOperators("text with stray # here")
        XCTAssertTrue(output.contains("\\#"), "Stray # must be escaped: \(output)")
        XCTAssertEqual(warnings.count, 1)
    }

    func testNotePipelineConvertsHeadingsToTypst() {
        let (out, _) = notePipeline("# Title\n\nbody text\n")
        XCTAssertTrue(out.contains("= Title"), "Markdown heading should become Typst heading: \(out)")
    }

    // MARK: - End-to-end

    /// A `$4017`-style token next to bold and inline code must survive the whole
    /// note pipeline as literal text — never a bogus math region.
    func testCurrencyDollarNearBoldAndCodeStaysLiteral() {
        let cases: [String] = [
            "**NEW native PHI2 + $4017 write hold.** Only $4017 latches on `write_ce`.",
            "| `phi2_native` | native | feeds APU `PHI2` ($4017 `write_ce`, `aclk2`) |",
            "- **$4015 read-clear delayed ≤1 native cycle** right after a $4017 write (~0.6 µs).",
            "validates $4017 hold.",
            "handshakes (DMC ack hold, $4017 write hold) make CPU-rate events never miss.",
        ]
        for (i, input) in cases.enumerated() {
            let (out, _) = notePipeline(input)
            let dollars = out.components(separatedBy: "\\$").count - 1
            let expected = input.components(separatedBy: "$").count - 1
            XCTAssertEqual(dollars, expected, "Case \(i) lost or paired a currency dollar: \(out)")
        }
    }

    func testCurrencyDollarCasesCompile() {
        let cases: [String] = [
            "**NEW native PHI2 + $4017 write hold.** Only $4017 latches on `write_ce`.",
            "| `phi2_native` | native | feeds APU `PHI2` ($4017 `write_ce`, `aclk2`) |\n|---|---|---|\n| a | b | c |",
            "- **$4015 read-clear delayed ≤1 native cycle** right after a $4017 write (~0.6 µs).",
            "```systemverilog\nreg x = 1'b0;\n```\n\nTetris mid-frame `$2006` scroll test.",
        ]
        for (i, input) in cases.enumerated() {
            let (out, _) = notePipeline(input)
            let errs = compileErrors(out)
            XCTAssertEqual(errs, "", "Case \(i) should compile cleanly, got: \(errs)\n--- source ---\n\(out)")
        }
    }

    /// The full reported document must convert and compile in note mode.
    func testCrystalDocumentNotePipelineCompiles() throws {
        let url = URL(fileURLWithPath: NSString(string: "~/Desktop/i-am-developing-an-proud-crystal.md").expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Fixture document not present")
        }
        let md = try String(contentsOf: url, encoding: .utf8)
        let (typ, warnings) = notePipeline(md)
        print("[CRYSTAL] warnings: \(warnings.count), output: \(typ.count) chars")

        // Headings must convert (they used to be escaped to literal \#\# text).
        XCTAssertTrue(typ.contains("= Replace Async-OC"), "H1 should become a Typst heading")

        let errs = compileErrors(typ)
        if !errs.isEmpty { print("[CRYSTAL] errors:\n\(errs.prefix(2000))") }
        XCTAssertEqual(errs, "", "Crystal document should compile cleanly in note mode")
    }

    // MARK: - Shadow → source line map

    func testBuildLineMapIdentityForPassthrough() {
        let src = "# Heading\n\nSome paragraph text.\n- item one\n- item two"
        let out = TypstCompiler.buildLineMap(source: src, output: src)
        for (outLine, srcLine) in out {
            XCTAssertEqual(outLine, srcLine, "Identity document should map line \(outLine) to itself")
        }
    }

    func testBuildLineMapTracksExpansion() {
        // A table (3 source lines) expands to a multi-line #table call; the line
        // AFTER the table must still map to the source line after the table.
        let src = """
        # Intro

        | A | B |
        |---|---|
        | 1 | 2 |

        After the table.
        """
        let out = """
        = Intro

        #table(
          columns: 2,
          table.header[A][B],
          [1],
          [2],
        )

        After the table.
        """
        let map = TypstCompiler.buildLineMap(source: src, output: out)
        // "After the table." is output line 10 (the table call expands 3 source
        // lines into 7) → source line 7
        XCTAssertEqual(map[10], 7, "Line after an expanded table should map past it: \(map)")
        // The heading is line 1 → 1
        XCTAssertEqual(map[1], 1)
    }

    func testBuildLineMapTracksInlineChanges() {
        // Markdown heading converts to `=`, escapes are inserted — normalized
        // matching must still find the right source line.
        let src = "## Real Section\n\nContent with $4017 here.\n"
        let out = "= Real Section\n\nContent with \\$4017 here.\n"
        let map = TypstCompiler.buildLineMap(source: src, output: out)
        XCTAssertEqual(map[1], 1, "Heading line should map to heading line: \(map)")
        XCTAssertEqual(map[3], 3, "Converted paragraph should map to its source line: \(map)")
    }
}
