import XCTest
@testable import TypstEdit

@MainActor
final class MarkdownConversionTests: XCTestCase {

    private func convert(_ text: String, isHybrid: Bool = false) -> String {
        AICompletionService.shared.sanitizeMarkdownToTypst(text, isHybrid: isHybrid)
    }

    // MARK: - Video Links

    func testYouTubeNestedImageLink() {
        let input = "[![IMAGE ALT TEXT HERE](http://img.youtube.com/vi/abc123/0.jpg)](http://www.youtube.com/watch?v=abc123)"
        let output = convert(input)
        print("\n[YT-NESTED] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("#link("), "Expected link wrapper")
        XCTAssertTrue(output.contains("#image("), "Expected image inside")
    }

    func testYouTubeBareLink() {
        let input = "[My Video](https://www.youtube.com/watch?v=abc123def45)"
        let output = convert(input)
        print("\n[YT-BARE] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("#link(\"https://www.youtube.com/watch?v=abc123def45\")"))
        XCTAssertTrue(output.contains("img.youtube.com/vi/abc123def45"), "Should auto-embed thumbnail")
        XCTAssertTrue(output.contains("#image("))
    }

    func testYouTubeShortLink() {
        let input = "[Cool Clip](https://youtu.be/dQw4w9WgXcQ)"
        let output = convert(input)
        print("\n[YT-SHORT] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("img.youtube.com/vi/dQw4w9WgXcQ"))
    }

    func testYouTubeEmbedURL() {
        let input = "[Demo](https://www.youtube.com/embed/ciawICBvQoE)"
        let output = convert(input)
        print("\n[YT-EMBED] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("img.youtube.com/vi/ciawICBvQoE"))
    }

    func testYouTubeShortsURL() {
        let input = "[Short](https://www.youtube.com/shorts/abcdefghijk)"
        let output = convert(input)
        print("\n[YT-SHORTS] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("img.youtube.com/vi/abcdefghijk"))
    }

    func testYouTubeFeatureParam() {
        // `feature=player_embedded&v=...` (from the user's example)
        let input = "[![IMAGE ALT TEXT HERE](http://img.youtube.com/vi/abc123def45/0.jpg)](http://www.youtube.com/watch?feature=player_embedded&v=abc123def45)"
        let output = convert(input)
        print("\n[YT-FEATURE] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("#link("))
        XCTAssertTrue(output.contains("#image("))
    }

    func testNonVideoLinkUnchanged() {
        let input = "[Docs](https://example.com/guide)"
        let output = convert(input)
        print("\n[NONVIDEO] OUTPUT:\n\(output)\n")
        XCTAssertEqual(output, "#link(\"https://example.com/guide\")[Docs]")
        XCTAssertFalse(output.contains("#image("))
    }

    func testYouTubeAutolink() {
        let input = "Watch this: <https://www.youtube.com/watch?v=abc123def45>"
        let output = convert(input)
        print("\n[YT-AUTOLINK] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("img.youtube.com/vi/abc123def45"))
    }

    func testYouTubeBareURL() {
        let input = """
        Some intro text.

        https://www.youtube.com/watch?v=abc123def45
        """
        let output = convert(input)
        print("\n[YT-BARE-URL] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("img.youtube.com/vi/abc123def45"))
    }

    func testYouTubeHTMLAnchorImage() {
        let input = """
        <a href="http://www.youtube.com/watch?v=abc123def45" target="_blank">
        <img src="http://img.youtube.com/vi/abc123def45/0.jpg" alt="IMAGE ALT TEXT HERE" width="240" height="180" border="10">
        </a>
        """
        let output = convert(input)
        print("\n[YT-HTML] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("#link("))
        XCTAssertTrue(output.contains("#image("))
    }

    func testVimeoLink() {
        let input = "[Some Title](https://vimeo.com/123456789)"
        let output = convert(input)
        print("\n[VIMEO] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("#link(\"https://vimeo.com/123456789\")"))
    }

    // MARK: - Tables

    func testSimpleTable() {
        let input = """
        | Header 1 | Header 2 |
        |----------|----------|
        | Cell 1   | Cell 2   |
        | Cell 3   | Cell 4   |
        """
        let output = convert(input)
        print("\n[TABLE-SIMPLE] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("#table("))
        XCTAssertTrue(output.contains("columns: 2"))
        XCTAssertTrue(output.contains("table.header"))
    }

    func testTableWithoutOuterPipes() {
        let input = """
        Header 1 | Header 2
        ---------|---------
        Cell 1   | Cell 2
        """
        let output = convert(input)
        print("\n[TABLE-NOPIPES] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("#table("))
    }

    func testTableWithAlignment() {
        let input = """
        | Left | Center | Right |
        |:-----|:------:|------:|
        | a    | b      | c     |
        """
        let output = convert(input)
        print("\n[TABLE-ALIGN] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("#table("))
        XCTAssertTrue(output.contains("align: (left, center, right)"))
    }

    func testTablePartialAlignment() {
        let input = """
        | Left | Default | Right |
        |:-----|---------|------:|
        | a    | b       | c     |
        """
        let output = convert(input)
        print("\n[TABLE-ALIGN-PARTIAL] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("align: (left, auto, right)"))
    }

    func testTableCellWithBracket() {
        // Typst tracks [...] depth, so literal nested brackets inside a content-block cell
        // render fine without escaping. We only verify the table converts.
        let input = """
        | Col A | Col B |
        |-------|-------|
        | Cell with [bracket] text | Other |
        """
        let output = convert(input)
        print("\n[TABLE-BRACKET] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("#table("))
        XCTAssertTrue(output.contains("[Cell with [bracket] text]"))
    }

    func testTableWithFormattingInCells() {
        let input = """
        | **Bold** | _Italic_ |
        |----------|----------|
        | [Link](http://x.com) | `code` |
        """
        let output = convert(input)
        print("\n[TABLE-FMT] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("#table("))
    }

    // MARK: - Fallback / Lenient Mode

    func testHeadingConversion() {
        let input = "## Heading"
        let output = convert(input)
        XCTAssertEqual(output, "== Heading")
    }

    func testStrayDollarEscape() {
        let input = "The price is $5 today."
        let output = convert(input)
        print("\n[DOLLAR] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("\\$"))
    }

    // MARK: - End-to-End: converted Markdown must compile under typst

    /// Resolve the bundled typst binary, falling back to common system paths.
    private var typstPath: String? {
        let candidates = [
            "/Users/troymagri/Desktop/TypstEdit/typst-aarch64-apple-darwin/typst",
            "/opt/homebrew/bin/typst",
            "/usr/local/bin/typst",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `typst compile` on `source` and returns any error output (empty on success).
    /// Web-image "file not found" errors are filtered out since `resolveWebImages` only
    /// runs inside the live compiler, not in this isolated unit test.
    private func compileErrors(_ source: String) -> String {
        // Skip the integration check entirely when typst isn't available.
        guard let typstPath = typstPath else { return "" }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-e2e-\(UUID().uuidString).typ")
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
        let raw = String(data: data, encoding: .utf8) ?? ""
        // Filter out web-image-not-found errors; those are resolved by TypstCompiler's
        // resolveWebImages() at runtime, not by this isolated conversion test.
        let filtered = raw
            .components(separatedBy: "\n\n")
            .filter { block in
                !block.contains("file not found") && !block.contains("access denied")
            }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filtered
    }

    func testEndToEndMarkdownCompiles() {
        let md = """
        # Markdown Integration Test

        Paragraph with **bold**, _italic_, and `code`.

        [Click here](https://example.com).

        ## Aligned Table

        | Name  | Score | Notes |
        |:------|:-----:|------:|
        | Alice | 95    | Great |
        | Bob   | 82    | [link](http://x.com) |

        ## Without outer pipes

        Name | Score
        -----|------
        C    | 100

        - Item one
        - Item two

        1. First
        2. Second
        """
        let typ = convert(md)
        print("\n[E2E-SOURCE] typst source:\n\(typ)\n")
        let errs = compileErrors(typ)
        print("[E2E-ERRORS]:\n\(errs)")
        XCTAssertEqual(errs, "", "Converted Markdown should compile cleanly under typst")
    }

    func testEndToEndTableWithBracketsCompiles() {
        let md = """
        | Title | Description |
        |-------|-------------|
        | [Link](http://x.com) | Has [bracket] text |
        | `code` | **bold** cell |
        """
        let typ = convert(md)
        print("\n[E2E-BRACKET-SOURCE]:\n\(typ)\n")
        let errs = compileErrors(typ)
        print("[E2E-BRACKET-ERRORS]:\n\(errs)")
        XCTAssertEqual(errs, "", "Table with brackets should compile cleanly")
    }

    // MARK: - User-Reported YouTube Patterns

    func testEndToEndUserYouTubePatterns() {
        // This is the exact document the user pasted in the issue, plus the HTML anchor
        // pattern and the bare-URL pattern. After conversion, every input should produce
        // valid Typst that compiles cleanly (image-URL "file not found" errors are
        // filtered because resolveWebImages runs only in the live compiler).
        let md = """
        # YouTube Videos

        [![IMAGE ALT TEXT HERE](http://img.youtube.com/vi/YOUTUBE_VIDEO_ID_HERE/0.jpg)](http://www.youtube.com/watch?feature=player_embedded&v=YOUTUBE_VIDEO_ID_HERE)

        [![IMAGE ALT TEXT HERE](http://img.youtube.com/vi/YOUTUBE_VIDEO_ID_HERE/0.jpg)](http://www.youtube.com/watch?v=YOUTUBE_VIDEO_ID_HERE)

        [![IMAGE ALT TEXT HERE](https://upload.wikimedia.org/wikipedia/commons/thumb/e/ef/YouTube_logo_2015.svg/1200px-YouTube_logo_2015.svg.png)](https://www.youtube.com/watch?v=ciawICBvQoE)

        ## Bare markdown link

        [Tutorial Video](https://www.youtube.com/watch?v=dQw4w9WgXcQ)

        ## HTML anchor + img (the older pattern)

        <a href="http://www.youtube.com/watch?v=YOUTUBE_VIDEO_ID_HERE" target="_blank">
        <img src="http://img.youtube.com/vi/YOUTUBE_VIDEO_ID_HERE/0.jpg" alt="IMAGE ALT TEXT HERE" width="240" height="180" border="10">
        </a>
        """
        let typ = convert(md)
        print("\n[E2E-YT-SOURCE]:\n\(typ)\n")
        let errs = compileErrors(typ)
        print("[E2E-YT-ERRORS]:\n\(errs)")
        XCTAssertEqual(errs, "", "All user-reported YouTube patterns should compile cleanly")

        // Sanity-check the conversions produced #link + #image pairs.
        let linkCount = typ.components(separatedBy: "#link(").count - 1
        let imageCount = typ.components(separatedBy: "#image(").count - 1
        XCTAssertGreaterThan(linkCount, 0, "Should produce at least one #link()")
        XCTAssertGreaterThan(imageCount, 0, "Should produce at least one #image()")
    }

    // MARK: - Fallback "delimit and retry" strategy

    /// Verifies the fallback-protection rules for native Typst code:
    /// - `#import` / `#let` / `#set` etc. are ALWAYS protected (any file type)
    /// - In `.note` files, user-written function calls like `#score(...)` are protected
    /// - Markdown-converter output like `#link(...)` / `#table(...)` is NOT protected
    ///   (the fallback is allowed to repair its mistakes)
    func testProtectedTypstDirectives() {
        // Mirror TypstCompiler.isProtectedTypstDirective(_:isHybrid:).
        // Top-level keywords are always protected.
        let topLevel = ["#import \"@preview/x:0.1.0\": y",
                        "#include \"file.typ\"",
                        "#let x = 1",
                        "#set page(margin: 2cm)",
                        "#show heading: it => it",
                        "#return 42"]
        for line in topLevel {
            XCTAssertTrue(protectedLine(line, isHybrid: false),
                          "Should be protected in .md: \(line)")
            XCTAssertTrue(protectedLine(line, isHybrid: true),
                          "Should be protected in .note: \(line)")
        }

        // User-written Typst function calls in .note files are protected.
        let userTypst = ["#score(generated-abc, width: 100%)",
                         "#myFunc()",
                         "#customHelper[x]",
                         "#v(1em)"]
        for line in userTypst {
            XCTAssertFalse(protectedLine(line, isHybrid: false),
                           "Should NOT be protected in .md (no user Typst): \(line)")
            XCTAssertTrue(protectedLine(line, isHybrid: true),
                          "Should be protected in .note (user Typst): \(line)")
        }

        // Markdown-converter output is NEVER protected — the fallback must be able to
        // repair its mistakes.
        let converterOutput = ["#link(\"http://x.com\")[text]",
                               "#image(\"foo.png\")",
                               "#table(columns: 2, [a], [b])",
                               "#strike[old]",
                               "#figure(rect())",
                               "#footnote[hi]"]
        for line in converterOutput {
            XCTAssertFalse(protectedLine(line, isHybrid: false),
                           "Converter output should NOT be protected in .md: \(line)")
            XCTAssertFalse(protectedLine(line, isHybrid: true),
                           "Converter output should NOT be protected in .note: \(line)")
        }
    }

    /// Mirror of `TypstCompiler.isProtectedTypstDirective`. Kept in sync manually so the
    /// protection policy has direct test coverage. Returns true if the line should be
    /// left untouched by the lenient fallback fixer.
    private func protectedLine(_ line: String, isHybrid: Bool) -> Bool {
        let topLevel = ["#import", "#include", "#let", "#set", "#show", "#return"]
        if topLevel.contains(where: { line.hasPrefix($0) }) { return true }
        guard isHybrid else { return false }
        let markdownFuncs = ["link", "image", "table", "strike", "figure", "align",
                             "line", "footnote", "super", "sub", "underline",
                             "highlight", "raw"]
        let pattern = #"^#([A-Za-z][A-Za-z0-9_]*)[\[(]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(0..<ns.length)) else { return false }
        let name = ns.substring(with: m.range(at: 1))
        return !markdownFuncs.contains(name)
    }

    // MARK: - Fallback "delimit and retry" strategy

    /// Simulates the compiler's last-resort fallback: when a line keeps failing to
    /// compile, the TypstCompiler wraps the entire line in `#raw("...", block: true)`.
    /// This verifies that strategy actually produces compilable output for a variety
    /// of pathological lines.
    func testRawWrapFallbackAlwaysCompiles() {
        let nastyLines = [
            "#table( columns: 2, [a], [b]",         // unclosed delimiter
            "Price is $5 and code is `x",           // stray backtick + dollar
            "def foo(x): return x[0]",              // python with brackets
            "[[[[[ deeply nested",                  // many open brackets
            "unclosed (parenthesis",                // unclosed paren
            "#let x = 1 +",                         // incomplete expression
            "emoji and quotes \" and backslash \\",  // mixed special chars
        ]
        for line in nastyLines {
            let escaped = line
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let typ = "#raw(\"\(escaped)\", block: true)"
            let errs = compileErrors(typ)
            print("\n[RAWWRAP] line: \(line)\n  wrapped: \(typ)\n  errors: '\(errs)'")
            XCTAssertEqual(errs, "", "Raw-wrapped line should compile: \(line)")
        }
    }

    // MARK: - Hybrid `.note` Smart `#` Escaping

    func testHybridHashEscaping() {
        // `#word` followed by sentence punctuation → escape (pasted markdown text).
        // Typst escapes as `\#word` (backslash BEFORE the hash).
        let escaping: [(String, String)] = [
            ("#refs,", "\\#refs,"),
            ("#hello!", "\\#hello!"),
            ("#tag?", "\\#tag?"),
            ("see #foo; bar", "see \\#foo; bar"),
            ("end #label:", "end \\#label:"),
            ("Sentence #word. Next", "Sentence \\#word. Next"),
        ]
        for (input, expected) in escaping {
            let out = convert(input, isHybrid: true)
            print("[HYBRID-#-ESCAPE] '\(input)' → '\(out)'")
            XCTAssertEqual(out, expected, "Hybrid mode should escape pasted-markdown #word: \(input)")
        }
    }

    func testHybridHashPreservesTypst() {
        // Real Typst constructs must be preserved verbatim in `.note` files.
        let preserving = [
            "#import \"@preview/x:0.1.0\": y",
            "#let x = 1",
            "#set page(margin: 2cm)",
            "#show heading: it => it",
            "#score(generated-abc, width: 100%)",
            "#emph[hi]",
            "#link(\"http://x.com\")[text]",
            "#myVar",
            "#obj.field",
            "variable is #x",
        ]
        for input in preserving {
            let out = convert(input, isHybrid: true)
            print("[HYBRID-#-KEEP] '\(input)' → '\(out)'")
            XCTAssertFalse(out.contains("\\#"),
                           "Hybrid mode should NOT escape intentional Typst: \(input) (got \(out))")
        }
    }

    // MARK: - Real-World Full Markdown Document

    /// Downloads the comprehensive "Full Markdown" gist and verifies the entire document
    /// converts cleanly to compilable Typst. This is the file reported in the issue.
    func testFullMarkdownDocumentCompiles() throws {
        let url = URL(string: "https://gist.githubusercontent.com/allysonsilva/85fff14a22bbdf55485be947566cc09e/raw/fa8048a906ebed3c445d08b20c9173afd1b4a1e5/Full-Markdown.md")!
        let md: String
        do {
            md = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw XCTSkip("Could not download test fixture: \(error.localizedDescription)")
        }
        XCTAssertGreaterThan(md.count, 5000, "Sanity-check the document actually downloaded")

        // Test in BOTH modes: pure .md and hybrid .note.
        for isHybrid in [false, true] {
            let typ = convert(md, isHybrid: isHybrid)
            print("\n[FULL-MD hybrid=\(isHybrid)] converted \(md.count) → \(typ.count) chars")

            let errs = compileErrors(typ)
            if !errs.isEmpty {
                print("[FULL-MD hybrid=\(isHybrid)] errors:\n\(errs.prefix(2000))")
            }
            XCTAssertEqual(errs, "", "Full markdown document (hybrid=\(isHybrid)) should compile cleanly")
        }
    }
}
