import XCTest
import PDFKit
import CoreText
@testable import TypstEdit

/// PDF import: layout rules on synthetic runs, ruled tables from synthetic
/// rules, the outline, the emitters, AI reply parsing, and one end-to-end
/// import of a PDF drawn by the test.
final class PDFImportTests: XCTestCase {

    private func run(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat? = nil, size: CGFloat = 10, bold: Bool = false) -> PDFTextRun {
        PDFTextRun(text: text, rect: CGRect(x: x, y: y, width: width ?? CGFloat(text.count) * size * 0.5, height: size * 1.2),
                   fontSize: size, isBold: bold)
    }

    // MARK: - Line joining

    func testSoftHyphenJoinsWithoutSpace() {
        XCTAssertEqual(PDFLayoutAnalyzer.joinLines(["requires atten\u{00AD}", "tion to order"]), "requires attention to order")
    }

    func testVisibleHyphenJoinsOnlyBeforeLowercase() {
        XCTAssertEqual(PDFLayoutAnalyzer.joinLines(["incomprehen-", "sibilities"]), "incomprehensibilities")
        XCTAssertEqual(PDFLayoutAnalyzer.joinLines(["well-", "Known"]), "well- Known")
    }

    func testRangeBrokenAfterDashKeepsDash() {
        XCTAssertEqual(PDFLayoutAnalyzer.joinLines(["Prophet (1:1-", "4:1a)."]), "Prophet (1:1-4:1a).")
    }

    // MARK: - Markers and headings

    func testListMarkers() {
        XCTAssertEqual(PDFLayoutAnalyzer.listMarker(in: "• Item")?.ordered, false)
        XCTAssertEqual(PDFLayoutAnalyzer.listMarker(in: "3. Item")?.number, 3)
        XCTAssertEqual(PDFLayoutAnalyzer.listMarker(in: "(IV) Outline")?.ordered, true)
        XCTAssertNil(PDFLayoutAnalyzer.listMarker(in: "Plain text"))
        XCTAssertTrue(PDFLayoutAnalyzer.isBareMarker("(ii)"))
        XCTAssertTrue(PDFLayoutAnalyzer.isBareMarker("•"))
        XCTAssertFalse(PDFLayoutAnalyzer.isBareMarker("Total"))
    }

    func testCapitalsHeadingRejectsKeyValuePairs() {
        XCTAssertTrue(PDFLayoutAnalyzer.isCapitalsHeading("BIBLIOGRAPHY"))
        XCTAssertFalse(PDFLayoutAnalyzer.isCapitalsHeading("HOST: 10.10.10.10:1010"))
        XCTAssertFalse(PDFLayoutAnalyzer.isCapitalsHeading("Introduction"))
    }

    // MARK: - Reading order

    func testTwoColumnsReadLeftColumnFirst() {
        let rects = [
            CGRect(x: 100, y: 760, width: 400, height: 20),   // full-width title
            CGRect(x: 50, y: 700, width: 240, height: 12),    // left 1
            CGRect(x: 320, y: 700, width: 240, height: 12),   // right 1
            CGRect(x: 50, y: 685, width: 240, height: 12),    // left 2
            CGRect(x: 320, y: 685, width: 240, height: 12),   // right 2
        ]
        XCTAssertEqual(PDFLayoutAnalyzer.readingOrder(rects, minGutter: 6), [0, 1, 3, 2, 4])
    }

    func testCentredAuthorLineIsNotSplitBetweenColumns() {
        let rects = [
            CGRect(x: 250, y: 740, width: 45, height: 11),    // "Jane Doe"  (left of gutter)
            CGRect(x: 318, y: 740, width: 50, height: 11),    // "John Smith" (right of gutter)
            CGRect(x: 50, y: 700, width: 250, height: 12),
            CGRect(x: 316, y: 700, width: 250, height: 12),
            CGRect(x: 50, y: 685, width: 250, height: 12),
            CGRect(x: 316, y: 685, width: 250, height: 12),
        ]
        let order = PDFLayoutAnalyzer.readingOrder(rects, minGutter: 6)
        XCTAssertEqual(Array(order.prefix(2)), [0, 1])
    }

    // MARK: - Tables from text alignment

    func testAlignedShortCellsFormATable() {
        var runs: [PDFTextRun] = []
        for (r, row) in [["Method", "Precision", "Recall"], ["Baseline", "0.71", "0.64"],
                         ["Ours", "0.93", "0.91"], ["Oracle", "0.99", "0.98"]].enumerated() {
            for (c, text) in row.enumerated() {
                runs.append(run(text, x: 100 + CGFloat(c) * 80, y: 500 - CGFloat(r) * 16, width: 40))
            }
        }
        let detection = PDFLayoutAnalyzer.detectTables(in: runs, pageSize: CGSize(width: 612, height: 792))
        guard case .table(let table)? = detection.regions.first?.kind else { return XCTFail("no table") }
        XCTAssertEqual(table.rows.count, 4)
        XCTAssertEqual(table.rows[2], ["Ours", "0.93", "0.91"])
        XCTAssertFalse(table.isComplex)
    }

    func testTwoColumnProseIsNotATable() {
        let line = "Portable documents are designed for printing rather than for reuse"
        let runs = (0..<8).flatMap { i in
            [run(line, x: 50, y: 700 - CGFloat(i) * 14, width: 240), run(line, x: 320, y: 700 - CGFloat(i) * 14, width: 240)]
        }
        XCTAssertTrue(PDFLayoutAnalyzer.detectTables(in: runs, pageSize: CGSize(width: 612, height: 792)).regions.isEmpty)
    }

    func testTermDescriptionTable() {
        var runs = [run("Site", x: 60, y: 600, width: 25), run("Importance", x: 160, y: 600, width: 60)]
        for (i, site) in ["Acco", "Arad", "Ashdod"].enumerated() {
            let y = 580 - CGFloat(i) * 30
            runs.append(run(site, x: 60, y: y, width: 30))
            runs.append(run("Important commercial centre and port city", x: 160, y: y, width: 220))
            runs.append(run("occupied from the Bronze Age onwards.", x: 160, y: y - 13, width: 200))
        }
        let detection = PDFLayoutAnalyzer.detectTables(in: runs, pageSize: CGSize(width: 612, height: 792))
        guard case .table(let table)? = detection.regions.first?.kind else { return XCTFail("no table") }
        XCTAssertEqual(table.rows.first, ["Site", "Importance"])
        XCTAssertEqual(table.rows[1], ["Acco", "Important commercial centre and port city occupied from the Bronze Age onwards."])
    }

    // MARK: - Running heads

    func testRepeatedRunningHeadIsRemoved() {
        let size = CGSize(width: 600, height: 800)
        let pages = (1...4).map { n in
            [run("Journal of Testing · Vol. \(n)", x: 50, y: 780), run("Body text on page \(n) that stays.", x: 50, y: 400),
             run("\(n)", x: 300, y: 20)]
        }
        let cleaned = PDFLayoutAnalyzer.removeRunningHeaders(pages: pages, pageSizes: Array(repeating: size, count: 4))
        XCTAssertTrue(cleaned.allSatisfy { $0.count == 1 && $0[0].text.hasPrefix("Body text") })
    }

    // MARK: - Ruled tables

    func testLatticeBuildsMergedCells() {
        typealias Line = PDFLatticeTables.Line
        // Two rows; the top row is one cell spanning both columns.
        let rulings = PDFLatticeTables.Rulings(
            horizontal: [Line(position: 700, start: 100, end: 300), Line(position: 680, start: 100, end: 300),
                         Line(position: 660, start: 100, end: 300)],
            vertical: [Line(position: 100, start: 660, end: 700), Line(position: 300, start: 660, end: 700),
                       Line(position: 200, start: 660, end: 680)])
        let runs = [run("Request", x: 180, y: 685, width: 40), run("Path", x: 110, y: 665, width: 25),
                    run("/api/task", x: 210, y: 665, width: 50)]
        let detection = PDFLatticeTables.tables(from: rulings, runs: runs)
        guard case .table(let table)? = detection.regions.first?.kind else { return XCTFail("no table") }
        XCTAssertEqual(table.rows, [["Request", ""], ["Path", "/api/task"]])
        XCTAssertEqual(table.spans, [PDFCellSpan(row: 0, column: 0, rowSpan: 1, columnSpan: 2)])
        XCTAssertTrue(PDFImportEmitter.typstTable(table, rect: .zero, contentWidth: 400).contains("table.cell(colspan: 2)[Request]"))
    }

    func testFramedCodeKeepsIndentation() {
        typealias Line = PDFLatticeTables.Line
        let rulings = PDFLatticeTables.Rulings(
            horizontal: [Line(position: 700, start: 50, end: 400), Line(position: 600, start: 50, end: 400)],
            vertical: [Line(position: 50, start: 600, end: 700), Line(position: 400, start: 600, end: 700)])
        let runs = [run("{", x: 60, y: 680), run("\"code\": \"A2\",", x: 80, y: 666), run("}", x: 60, y: 652)]
        let detection = PDFLatticeTables.tables(from: rulings, runs: runs)
        guard case .block(let block)? = detection.regions.first?.kind, case .text(let text) = block.content else {
            return XCTFail("no code block")
        }
        XCTAssertEqual(block.kind, .code(language: "json"))
        XCTAssertEqual(text, "{\n    \"code\": \"A2\",\n}")
    }

    func testTableContinuedOnNextPageWithoutLeadingColumn() {
        var first = PDFTableData(rows: [["Body", "groupCode", "String"]], headerRows: 0)
        first.columnEdges = [50, 150, 250, 350]
        var second = PDFTableData(rows: [["strategy", "String"]], headerRows: 0)
        second.columnEdges = [150, 250, 350]
        var document = PDFImportedDocument(pages: [
            PDFImportedPage(index: 0, size: .zero, blocks: [PDFImportedBlock(kind: .table, rect: .zero, content: .table(first))]),
            PDFImportedPage(index: 1, size: .zero, blocks: [PDFImportedBlock(kind: .table, rect: .zero, content: .table(second))]),
        ])
        PDFLayoutAnalyzer.mergeContinuedTables(&document)
        guard case .table(let merged) = document.pages[0].blocks[0].content else { return XCTFail() }
        XCTAssertEqual(merged.rows, [["Body", "groupCode", "String"], ["", "strategy", "String"]])
        XCTAssertEqual(merged.spans, [PDFCellSpan(row: 0, column: 0, rowSpan: 2, columnSpan: 1)])
        XCTAssertTrue(document.pages[1].blocks.isEmpty)
    }

    // MARK: - Outline

    func testOutlineMakesHeadingsAndSplitsMergedText() {
        var document = PDFImportedDocument(pages: [PDFImportedPage(index: 0, size: CGSize(width: 600, height: 800), blocks: [
            PDFImportedBlock(kind: .paragraph, rect: CGRect(x: 50, y: 700, width: 300, height: 12),
                             content: .text("CTU Task – Buffer Rack Inbound The rack is filled first.")),
        ])])
        PDFOutlineHeadings.apply([.init(title: "3.7  CTU Task – Buffer Rack Inbound", level: 2, pageIndex: 0, point: CGPoint(x: 50, y: 712))],
                                 to: &document)
        let blocks = document.pages[0].blocks
        XCTAssertEqual(blocks[0].kind, .heading(level: 2))
        XCTAssertEqual(blocks[0].content, .text("3.7 CTU Task – Buffer Rack Inbound"))
        XCTAssertEqual(blocks[1].content, .text("The rack is filled first."))
    }

    // MARK: - Emitters

    func testMarkupEscaping() {
        XCTAssertEqual(PDFImportEmitter.escapeMarkup("- 5 *bold* #x $y @ref"), "\\- 5 \\*bold\\* \\#x \\$y \\@ref")
        XCTAssertEqual(PDFImportEmitter.escapeMarkup("1. not a list"), "1\\. not a list")
        XCTAssertEqual(PDFImportEmitter.escapeMarkup("see https://a.b/c_d"), "see https://a.b/c_d")
    }

    func testListLabelsAreKept() {
        let items = [
            PDFImportedBlock(kind: .listItem(depth: 0, ordered: true), rect: .zero, content: .text("(IV) Outline")),
            PDFImportedBlock(kind: .listItem(depth: 1, ordered: true), rect: .zero, content: .text("(a) Birth of Samuel")),
        ]
        let typst = PDFImportEmitter.typstList(items[...])
        XCTAssertTrue(typst.contains("#set list(marker: [])"))
        XCTAssertTrue(typst.contains("- (IV) Outline"))
        XCTAssertTrue(typst.contains("  - (a) Birth of Samuel"))
        let numbered = PDFImportEmitter.typstList([PDFImportedBlock(kind: .listItem(depth: 0, ordered: true), rect: .zero, content: .text("3. Third"))][...])
        XCTAssertEqual(numbered, "3. Third")
    }

    func testFenceOutgrowsBackticksInside() {
        XCTAssertEqual(PDFImportEmitter.fenced("a ```b```", language: nil), "````\na ```b```\n````")
    }

    // MARK: - AI replies

    func testAITableRepliesInTSVOrMarkdown() {
        XCTAssertEqual(PDFImportAI.parseTable("A\tB\n1\t2"), [["A", "B"], ["1", "2"]])
        XCTAssertEqual(PDFImportAI.parseTable("```\n| A | B |\n|---|---|\n| 1 | 2 |\n```"), [["A", "B"], ["1", "2"]])
        XCTAssertNil(PDFImportAI.parseTable("I cannot read this image."))
    }

    func testAIFormulaReplyIsUnwrapped() {
        XCTAssertEqual(PDFImportAI.cleanLatex("$$E = mc^2$$"), "E = mc^2")
        XCTAssertEqual(PDFImportAI.cleanLatex("\\begin{equation}a+b\\label{x}\\end{equation}"), "a+b")
        XCTAssertNil(PDFImportAI.cleanLatex("\\frac{a}{b"))
    }

    // MARK: - Scripts

    func testRightToLeftLinesAreDetected() {
        XCTAssertTrue(TextScript.isRightToLeftLine("هذا نص عربي للاختبار"))
        XCTAssertTrue(TextScript.isRightToLeftLine("זהו טקסט בעברית"))
        XCTAssertFalse(TextScript.isRightToLeftLine("This is English text"))
        XCTAssertFalse(TextScript.isRightToLeftLine("Αυτό είναι ελληνικά"))
        // Mixed text is judged by its majority.
        XCTAssertTrue(TextScript.isRightToLeftLine("كتاب book"))
        XCTAssertFalse(TextScript.isRightToLeftLine("The word for book is كتاب كتاب x"))
    }

    func testRightToLeftWordsAreReadInLogicalOrder() {
        // A PDF draws an Arabic line from its right edge, so extraction
        // delivers the words reversed.
        let drawn = ["اليسار.", "إلى", "اليمين", "من", "صحيح", "بترتيب"]
        XCTAssertEqual(PDFPageExtractor.readingOrderedWords(drawn).joined(separator: " "),
                       "بترتيب صحيح من اليمين إلى اليسار.")
        XCTAssertEqual(PDFPageExtractor.readingOrderedWords(["Hello", "world"]), ["Hello", "world"])
    }

    func testCJKLineBreakAddsNoSpace() {
        // The sentence is one run of characters; the printed line break in
        // the middle of it must not become a space.
        XCTAssertEqual(PDFLayoutAnalyzer.joinLines(["这是一段用于测试的中文文本，用来检查提取", "出来。"]),
                       "这是一段用于测试的中文文本，用来检查提取出来。")
        XCTAssertEqual(PDFLayoutAnalyzer.joinLines(["日本語の文章を", "確認します。"]),
                       "日本語の文章を確認します。")
        // A Latin word next to CJK keeps its space.
        XCTAssertEqual(PDFLayoutAnalyzer.joinLines(["The book is 书", "and it is good"]),
                       "The book is 书 and it is good")
    }

    func testGreekIsNotMathematics() {
        // Greek prose was read as display math (Greek letters counted as math
        // symbols) and turned into an image.
        XCTAssertLessThan(PDFLayoutAnalyzer.mathSymbolFraction("Αυτό είναι ένα κείμενο στα ελληνικά"), 0.2)
        XCTAssertLessThan(PDFLayoutAnalyzer.mathSymbolFraction("Это текст на русском"), 0.2)
        // Real math is still recognised (4 of the 7 visible characters here).
        XCTAssertGreaterThan(PDFLayoutAnalyzer.mathSymbolFraction("E = m c ∑ ∫ ∞"), 0.5)
    }

    func testRightToLeftParagraphKeepsRightAlignedWrap() {
        // A Hebrew paragraph: the first line is full, the second is short and
        // ends at the right edge (RTL alignment), which must not be read as a
        // new, indented paragraph.
        var lines: [PDFLayoutAnalyzer.Line] = []
        for (index, text) in ["זהו טקסט בעברית לבדיקה. הוא כולל מספר מילים", "לשמאל."].enumerated() {
            let width: CGFloat = index == 0 ? 400 : 60
            lines.append(.init(text: text,
                               rect: CGRect(x: 500 - width, y: 600 - CGFloat(index) * 15,
                                            width: width, height: 11),
                               fontSize: 11, isBold: false, mathScore: 0, isTitle: false))
        }
        let blocks = PDFLayoutAnalyzer.textBlocks(from: lines, bodyFontSize: 11)
        XCTAssertEqual(blocks.count, 1, "\(blocks)")
        XCTAssertEqual(blocks.first?.content, .text("זהו טקסט בעברית לבדיקה. הוא כולל מספר מילים לשמאל."))
    }

    // MARK: - End to end

    /// Draws a small PDF (title, two paragraphs, a ruled table with a merged
    /// header) and imports it.
    func testImportOfDrawnPDF() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PDFImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("drawn.pdf")
        try PDFTestFixtures.draw(to: url)

        let result = try await PDFImporter(sourceURL: url, outputDirectory: folder, baseName: "drawn").run()
        let blocks = result.document.blocks
        XCTAssertEqual(blocks.first?.kind.isHeading, true, result.typst)
        XCTAssertEqual(blocks.first?.content, .text("Quarterly Report"))
        XCTAssertTrue(blocks.contains { $0.content == .text("Revenue grew in every region this quarter.") }, result.typst)
        guard let table = blocks.compactMap({ block -> PDFTableData? in
            if case .table(let t) = block.content { return t } else { return nil }
        }).first else { return XCTFail("no table: \(result.typst)") }
        XCTAssertEqual(table.rows.count, 3, result.typst)
        XCTAssertEqual(table.rows[1], ["North", "120"], result.typst)
        XCTAssertEqual(table.spans.first?.columnSpan, 2, result.typst)
    }

}
