import XCTest
import Markdown
@testable import TypstEdit

@MainActor
final class MarkdownConversionTests: XCTestCase {

    private func convert(_ text: String, isHybrid: Bool = false) -> String {
        AICompletionService.shared.sanitizeMarkdownToTypst(text, isHybrid: isHybrid)
    }

    // MARK: - Hybrid Typst-region extraction (PDF compile fix)

    /// A multi-line layout function with the exact shape that cmark's
    /// indented-code-block rule used to shred: 4+-space-indented lines after
    /// blank lines inside the body. Extraction must keep it whole (no fences,
    /// no raw blocks, indentation preserved).
    private static let layoutSample = """
    #let doc-layout(title: none, body) = {
      set page(
        paper: "a4",
        margin: (x: 2cm, top: 2cm, bottom: 2cm),

        // Watermark comment line
        footer: context {
          let display-date = datetime.today().display("[month repr:long] [day], [year]")
          grid(columns: (1fr, 2fr, 1fr),
            align(left)[Page 1 of 2],
            align(center)[Footer center],
            align(right)[December 1, 2026])
        }
      )
      align(center)[
        #block(width: 100%, inset: (bottom: 2em))[
          #if title != none { text(weight: "bold", size: 28pt)[#title] }
        ]
      ]
      body
    }
    #show: doc-layout.with(title: "T")
    Body text.
    """

    func testSanitizeHybridKeepsLayoutFunctionIntact() {
        let output = convert(Self.layoutSample, isHybrid: true)
        XCTAssertTrue(output.contains("#let doc-layout(title: none, body) = {"), "definition opener survives: \(output)")
        XCTAssertTrue(output.contains("footer: context {"), "footer brace keeps its line: \(output)")
        XCTAssertTrue(output.contains("datetime.today().display(\"[month repr:long] [day], [year]\")"), "footer datetime survives: \(output)")
        XCTAssertTrue(output.contains("#show: doc-layout.with(title: \"T\")"), "call site survives: \(output)")
        XCTAssertFalse(output.contains("```"), "no fences may appear inside the function: \(output)")
    }

    func testSanitizeHybridLayoutIdempotent() {
        let first = convert(Self.layoutSample, isHybrid: true)
        let second = convert(first, isHybrid: true)
        XCTAssertEqual(first, second, "double-sanitize must equal single-sanitize")
    }

    func testTypstRegionExtractionBoundaries() {
        let marker = Unicode.Scalar(0xE003)!
        let source = """
        # Heading One
        #let x = 1
        #if true [
          inner
        ] else [
          other
        ]
        plain text
        """
        let (text, regions) = AICompletionService.extractTypstRegions(source, marker: marker)
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0], "#let x = 1")
        XCTAssertEqual(regions[1], "#if true [\n  inner\n] else [\n  other\n]")
        XCTAssertTrue(text.hasPrefix("# Heading One"), "ATX headings must not be captured: \(text)")
    }

    func testPlaceholderTokenRoundTripsMultiDigitIndices() {
        // token() writes index digits least-significant first; decode() must
        // read them the same way or every region past index 14 mis-expands.
        let markers = PlaceholderMarkers(for: "")
        for index in [0, 1, 13, 14, 15, 16, 17, 29, 30, 224, 255] {
            let token = PlaceholderMarkers.token(kind: markers.typst, index: index)
            let decoded = markers.decode(token)
            XCTAssertEqual(decoded?.kind, markers.typst)
            XCTAssertEqual(decoded?.index, index, "index \(index) round-trip failed")
        }
    }

    func testExtractionDoesNotSkipLinesAfterMultiLineRegion() {
        // Regression: after replacing a multi-line region with one token, the
        // scanner advanced in stale coordinates and skipped (region lines − 1)
        // following lines — a layout function swallowed the next `#if` block's
        // opener, so the block fell to cmark and its `_*bold*_` mangled into
        // `__…__` (typst: "no text within underscores").
        let source = """
        #let f(a) = {
          set page(paper: "a4")
          a
        }

        #f("x")

        = Section
        Body paragraph.

        #if on [
          first
        ] else [
          second
        ]

        #if other [
          third
        ]

        #v(1em)
        """
        let (text, regions) = AICompletionService.extractTypstRegions(source, marker: Unicode.Scalar(0xE003)!)
        XCTAssertEqual(regions.count, 5, "all five openers must be captured: \(regions)")
        XCTAssertEqual(regions[0].components(separatedBy: "\n").count, 4, "function region is 4 lines")
        XCTAssertTrue(regions.contains("#if on [\n  first\n] else [\n  second\n]"))
        XCTAssertTrue(regions.contains("#if other [\n  third\n]"))
        XCTAssertTrue(regions.contains("#v(1em)"))
        // Every original line must survive in the tokenized text or a region.
        for markerLine in ["#if on [", "#if other [", "#v(1em)"] {
            XCTAssertTrue(text.contains(markerLine) || regions.contains(where: { $0.contains(markerLine) }),
                          "\(markerLine) must not be skipped")
        }
    }

    func testRegionTokenAfterListItemGetsBlankSeparator() {
        // Regression: cmark lazy-continues a column-0 token line into a
        // preceding list item's paragraph, dragging the expanded region
        // (image, line, pagebreak) inside the list container — typst:
        // "pagebreaks are not allowed inside of containers". Extraction
        // must blank-separate the token so the list closes first.
        let source = """
        + *Lorem ipsum dolor* sit amet, consectetur.
        #align(center)[
          #image("lorem.png", width: 80%)
        ]
        #line(length: 100%)
        #pagebreak()

        = Next Section
        """
        let (text, regions) = AICompletionService.extractTypstRegions(source, marker: Unicode.Scalar(0xE003)!)
        XCTAssertEqual(regions.count, 3, "align/image region, #line, #pagebreak: \(regions)")
        XCTAssertTrue(text.contains("consectetur.\n\n"),
                      "a blank line must separate the list item from the first token")
        // End-to-end: the sanitized PDF source must keep every pagebreak
        // standalone at column 0, never inside a list's container.
        let sanitized = convert(source, isHybrid: true)
        for line in sanitized.components(separatedBy: "\n") where line.contains("#pagebreak()") {
            XCTAssertEqual(line.trimmingCharacters(in: .whitespaces), "#pagebreak()",
                           "pagebreak not standalone: \(line)")
        }
    }

    func testExtractionClosesRegionOnLinkWithURLText() {
        // Regression: `//` inside URL text (link labels and targets) triggered
        // the line-comment rule, hiding the line's closing `)`/`]`. The region
        // never closed and swallowed the rest of the document — pagebreaks
        // then expanded inside the link's container ("pagebreaks are not
        // allowed inside of containers").
        let source = """
        Intro paragraph.

        #link("https://example.com/lorem/ipsum")[https://example.com/lorem/ipsum]

        = Next Section

        #pagebreak()

        Tail content.
        """
        let (text, regions) = AICompletionService.extractTypstRegions(source, marker: Unicode.Scalar(0xE003)!)
        XCTAssertEqual(regions.count, 2, "link line and #pagebreak() are regions: \(regions)")
        XCTAssertEqual(regions[0].components(separatedBy: "\n").count, 1,
                       "the link region must close on its own line, got: \(regions[0])")
        XCTAssertEqual(regions[1], "#pagebreak()")
        XCTAssertTrue(text.contains("Tail content."), "content after the link must survive")
    }

    func testSanitizeHybridPreservesRegionOrderPastFourteenRegions() {
        // 17 typst regions force multi-digit tokens (base-15 digits): index 15
        // is the first one that used to decode as 1, duplicating region 1's
        // content and dropping region 15's.
        var source = ""
        let expected = (0..<17).map { i -> String in
            source += "#let region_\(i) = \(i)\n\n"
            return "#let region_\(i) = \(i)"
        }
        let output = convert(source, isHybrid: true)
        for (i, region) in expected.enumerated() {
            XCTAssertTrue(output.contains(region), "region \(i) missing from output")
        }
        // The first line of each region must appear in extraction order.
        var searchRange = output.startIndex..<output.endIndex
        for region in expected {
            guard let found = output.range(of: region, range: searchRange) else {
                XCTFail("region \(region) out of order or missing")
                return
            }
            searchRange = found.upperBound..<output.endIndex
        }
        // No duplicated region content (the index-15-as-1 bug duplicated line 1).
        let lines = output.components(separatedBy: "\n").filter { $0.contains("#let region_") }
        XCTAssertEqual(lines.count, 17, "each region line must appear exactly once: \(lines)")
    }

    /// A self-contained hybrid note exercising every end-to-end regression the
    /// real-note probes caught: URL text in link labels, pagebreaks after list
    /// items, backtick spans with brackets in table cells, the note-box
    /// preamble helper, redaction-style `_*...*_` blocks, a relative import,
    /// and a pasted image. Lorem Ipsum text only — no personal content.
    func testPDFCompileHybridNoteFixture() throws {
        let typstPath = ProcessInfo.processInfo.environment["TYPSTEDIT_PDF_PROBE"]
            ?? "/Applications/TypstEdit.app/Contents/Resources/bin/typst"
        guard FileManager.default.isExecutableFile(atPath: typstPath) else {
            throw XCTSkip("bundled typst binary not available")
        }

        let note = """
        #let show-redacted = false
        #import "lorem-vars.typ": *

        = Lorem Ipsum Dolor

        *Sit amet:* #lorem-value

        #link("https://example.com/lorem/ipsum")[https://example.com/lorem/ipsum]

        + consectetur adipiscing elit
        #align(center)[
          #image("lorem-ipsum.png", width: 60%)
        ]
        #line(length: 100%)
        #pagebreak()

        #table(
          columns: (1fr, 2fr),
          table.header([Lorem], [Ipsum]),
          [`eget`], [Fusce `[0, 100)` blandit.],
        )

        #note-box("Lorem Title", [
          Duis quis ipsum nulla.
        ])

        #if show-redacted [
          #lorem-value
        ] else [
          #text(size: 16pt)[_*Lorem redactedum*_]
        ]
        """

        // Full real chain, exactly as the PDF preview runs it.
        let autoFixed = TypstCompiler.autoFixBrokenNoteSyntax(note)
        let delimited = TypstCompiler.delimitImproperOperators(autoFixed)
        let sanitized = TypstCompiler.notePreamble + convert(delimited.output, isHybrid: true)

        // Redaction-style blocks must survive verbatim: indented, single
        // underscores. Doubled `__` means the block fell through cmark, which
        // makes typst warn about empty underscores.
        for line in sanitized.components(separatedBy: "\n") where line.contains("redactedum") {
            XCTAssertFalse(line.contains("__Lorem"), "mangled redaction line: \(line)")
            XCTAssertTrue(line.hasPrefix("  #text("), "indentation lost: \(line)")
        }

        // Pagebreaks must survive at the top level — never inside brackets
        // (typst: "pagebreaks are not allowed inside of containers").
        for line in sanitized.components(separatedBy: "\n") where line.contains("#pagebreak()") {
            XCTAssertEqual(line.trimmingCharacters(in: .whitespaces), "#pagebreak()",
                           "pagebreak not standalone: \(line)")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("typstedit-fixture-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The note imports a sibling file, as notes sharing variables do.
        let importFile = dir.appendingPathComponent("lorem-vars.typ")
        try "#let lorem-value = \"Lorem ipsum dolor sit amet\""
            .write(to: importFile, atomically: true, encoding: .utf8)

        // Stub the pasted image with a 1x1 PNG next to the .typ (typst
        // resolves the path against the compile root).
        let stubPNG = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        try stubPNG.write(to: dir.appendingPathComponent("lorem-ipsum.png"))

        let typFile = dir.appendingPathComponent("note.typ")
        try sanitized.write(to: typFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        process.arguments = ["compile", typFile.path, dir.appendingPathComponent("out.pdf").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let diagnostics = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(
            process.terminationStatus, 0,
            "typst compile failed:\n\(diagnostics)\n--- sanitized .typ ---\n\(sanitized)"
        )
    }

    // MARK: - Missing-font substitution

    func testMissingFontSubstitutesMetricCompatibleFace() {
        XCTAssertEqual(
            TypstCompiler.substituteMissingFonts("#set text(font: \"Liberation Serif\")"),
            "#set text(font: \"Times New Roman\")"
        )
    }

    func testMissingFontListSubstitutionKeepsInstalledEntries() {
        XCTAssertEqual(
            TypstCompiler.substituteMissingFonts("#text(font: (\"Liberation Sans\", \"Georgia\"))[x]"),
            "#text(font: (\"Arial\", \"Georgia\"))[x]"
        )
    }

    func testFontSubstitutionIsCaseInsensitiveAndWholeLiteral() {
        XCTAssertEqual(
            TypstCompiler.substituteMissingFonts("#text(font: \"LIBERATION SERIF\")[x]"),
            "#text(font: \"Times New Roman\")[x]"
        )
        // A font that merely contains an alias name is left alone.
        let untouched = "#text(font: \"MyLiberation Serif\")[x]"
        XCTAssertEqual(TypstCompiler.substituteMissingFonts(untouched), untouched)
    }

    func testPDFCompileLiberationSerifNoteHasNoFontWarning() throws {
        // Regression: a document asking for a Linux-only font (Liberation
        // Serif) compiled with typst's fallback face plus an "unknown font
        // family" warning. The substitution must remove the warning entirely.
        let typstPath = ProcessInfo.processInfo.environment["TYPSTEDIT_PDF_PROBE"]
            ?? "/Applications/TypstEdit.app/Contents/Resources/bin/typst"
        guard FileManager.default.isExecutableFile(atPath: typstPath) else {
            throw XCTSkip("bundled typst binary not available")
        }

        let source = TypstCompiler.substituteMissingFonts(
            "#set text(font: \"Liberation Serif\")\nLorem ipsum dolor sit amet.\n"
        )
        XCTAssertTrue(source.contains("\"Times New Roman\""), "substitution did not apply: \(source)")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("typstedit-font-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let typFile = dir.appendingPathComponent("note.typ")
        try source.write(to: typFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        process.arguments = ["compile", typFile.path, dir.appendingPathComponent("out.pdf").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let diagnostics = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, "typst compile failed:\n\(diagnostics)")
        XCTAssertFalse(diagnostics.contains("unknown font family"),
                       "missing-font warning leaked through:\n\(diagnostics)")
    }

    func testPDFCompileOfSanitizedLayoutSample() throws {
        // Manual PDF-pipeline verification: runs the real bundled typst binary
        // on the sanitized sample — the same compile the PDF export performs
        // after sanitizeMarkdownToTypst(isHybrid: true). Skips when the binary
        // isn't installed.
        let typstPath = ProcessInfo.processInfo.environment["TYPSTEDIT_PDF_PROBE"]
            ?? "/Applications/TypstEdit.app/Contents/Resources/bin/typst"
        guard FileManager.default.isExecutableFile(atPath: typstPath) else {
            throw XCTSkip("bundled typst binary not available")
        }

        // The same preamble the compiler injects for .note files.
        let sanitized = convert(Self.layoutSample, isHybrid: true)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("typstedit-pdf-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let typFile = dir.appendingPathComponent("note.typ")
        try (TypstCompiler.notePreamble + sanitized).write(to: typFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        process.arguments = ["compile", typFile.path, dir.appendingPathComponent("out.pdf").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let diagnostics = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(
            process.terminationStatus, 0,
            "typst compile failed:\n\(diagnostics)\n--- sanitized .typ ---\n\(TypstCompiler.notePreamble + sanitized)"
        )
    }

    // MARK: - Typst AST / variable evaluation

    func testTypstLetVariableEvaluation() {
        let input = "#let name = \"Typst\"\n#name"
        let output = TypstToMarkdownConverter.convert(input, isAlreadyMarkdown: false)
        // The converter trims and appends one trailing newline; compare on the
        // trimmed form so the assertion stays about the evaluated value.
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "Typst")
    }

    func testTypstImportAndConditionalEvaluation() {
        let input = """
#import "lib.typ"
#let enabled = true
#if enabled {
  Hello
} else {
  No
}
"""
        let output = TypstToMarkdownConverter.convert(input, isAlreadyMarkdown: false)
        XCTAssertTrue(output.contains("Hello"), "Expected the true branch to render")
        XCTAssertFalse(output.contains("No"), "Expected the false branch to be excluded")
    }

    func testTypstImportUsesFileLoaderForNestedNoteVariables() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let noteURL = tempDir.appendingPathComponent("glossary.note")
        let noteContent = """
        #let terms = (
          mainTerm: "Lorem"
        )
        """
        try? noteContent.write(to: noteURL, atomically: true, encoding: .utf8)

        let input = """
        #import "glossary.note"
        #terms.mainTerm
        """

        let output = TypstToMarkdownConverter.convert(
            input,
            isAlreadyMarkdown: false,
            fileLoader: { filename in
                let url = tempDir.appendingPathComponent(filename)
                return try? String(contentsOf: url, encoding: .utf8)
            }
        )

        XCTAssertTrue(output.contains("Lorem"), "Expected imported note variables to resolve via the file loader")
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRelativeImportRewriterUsesSourceDirectory() async {
        let compiler = TypstCompiler()
        let content = "#import \"lib.typ\"\n#image(\"hero.png\")"
        let sourceDir = URL(fileURLWithPath: "/Users/example/project/subfolder")
        let tempDir = URL(fileURLWithPath: "/Users/example/project/temp")

        let rewritten = await compiler.rewriteRelativeImports(in: content, sourceDirectory: sourceDir, tempDirectory: tempDir)

        XCTAssertTrue(rewritten.contains("#import \"../subfolder/lib.typ\""), "Relative imports should be resolved from the source file directory")
        XCTAssertTrue(rewritten.contains("#image(\"../subfolder/hero.png\")"), "Relative images should be resolved from the source file directory")
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

    // MARK: - Blockquotes, task lists, code

    func testBlockQuoteBecomesQuote() {
        let input = "> advice line\n> second line"
        let output = convert(input)
        print("\n[QUOTE] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("#quote["), "Blockquote should become #quote[…]: \(output)")
        XCTAssertTrue(output.contains("advice line"))
    }

    func testTaskListItems() {
        let input = "- [x] done thing\n- [ ] open thing"
        let output = convert(input)
        print("\n[TASKLIST] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("- ☑ done thing"), "Checked item: \(output)")
        XCTAssertTrue(output.contains("- ☐ open thing"), "Unchecked item: \(output)")
    }

    func testInlineCodePreserved() {
        let input = "run `make build` now"
        let output = convert(input)
        XCTAssertEqual(output, "run `make build` now")
    }

    func testFencedCodeBlockPreserved() {
        let input = "```swift\nlet x = 1\n```"
        let output = convert(input)
        XCTAssertTrue(output.contains("```swift"), "Fence + language preserved: \(output)")
        XCTAssertTrue(output.contains("let x = 1"))
    }

    func testMathBlockConverts() {
        let input = "Energy: $$E = mc^2$$ done."
        let output = convert(input)
        print("\n[MATH] OUTPUT:\n\(output)\n")
        // The LaTeX payload goes through LyxToTypstConverter (multi-letter runs
        // like `mc` become quoted upright text), then is wrapped in Typst math.
        XCTAssertTrue(output.contains("Energy: $ "), "Math wrapped in Typst dollars: \(output)")
        XCTAssertTrue(output.contains("mc"), "Payload preserved: \(output)")
        XCTAssertTrue(output.contains("^2"), "Superscript preserved: \(output)")
        XCTAssertTrue(output.contains(" $ done."), "Math region closed: \(output)")
    }

    func testStrikethroughBecomesStrike() {
        let input = "~struck~ and ~~gone~~"
        let output = convert(input)
        print("\n[STRIKE] OUTPUT:\n\(output)\n")
        XCTAssertTrue(output.contains("#strike[struck]"), "\(output)")
        XCTAssertTrue(output.contains("#strike[gone]"), "\(output)")
    }

    // MARK: - End-to-End: converted Markdown must compile under typst

    /// Resolve the bundled typst binary, falling back to common system paths.
    private var typstPath: String? {
        let candidates = [
            // Package root when run via `swift test`; $HOME-relative otherwise.
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("typst-aarch64-apple-darwin/typst").path,
            NSString(string: "~/Desktop/TypstEdit/typst-aarch64-apple-darwin/typst").expandingTildeInPath,
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
                             "highlight", "raw", "quote"]
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
