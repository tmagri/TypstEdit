import XCTest
@testable import TypstEdit

/// Unit tests for the styled-span pipeline (2026-11-27 P0 work):
/// span building from runs, the dash-separator rule, span rendering and
/// margin-furniture capture. Pure functions — no PDFKit, no fixtures.
final class PDFImportStyleTests: XCTestCase {

    // MARK: Helpers

    private func run(_ text: String, x: CGFloat = 0, size: CGFloat = 11,
                     bold: Bool = false, italic: Bool = false,
                     mono: Bool = false, script: PDFSpanScript = .none,
                     color: String? = nil, link: String? = nil) -> PDFTextRun {
        var r = PDFTextRun(text: text, rect: CGRect(x: x, y: 100, width: CGFloat(text.count) * 5, height: size * 1.2), fontSize: size)
        r.isBold = bold
        r.isItalic = italic
        r.isMonospace = mono
        r.script = script
        r.color = color
        r.link = link
        return r
    }

    private func line(_ runs: [PDFTextRun], text: String? = nil) -> PDFLayoutAnalyzer.Line {
        let joined = text ?? runs.map(\.text).joined(separator: " ")
        let rect = runs.reduce(CGRect.null) { $0.union($1.rect) }
        return PDFLayoutAnalyzer.Line(text: joined, rect: rect, fontSize: 11, isBold: false,
                                      mathScore: 0, isTitle: false, runs: runs)
    }

    // MARK: Span building

    func testPlainRunsProduceNilSpans() {
        let lines = [line([run("Plain"), run("text", x: 30)])]
        XCTAssertNil(PDFLayoutAnalyzer.styledSpans(from: lines))
    }

    func testBoldRunProducesSpan() {
        let lines = [line([run("Plain "), run("bold", x: 40, bold: true), run(" rest", x: 70)])]
        let spans = PDFLayoutAnalyzer.styledSpans(from: lines)
        XCTAssertNotNil(spans)
        XCTAssertEqual(spans?.map(\.text).joined(), "Plain bold rest")
        XCTAssertEqual(spans?.filter(\.isBold).map(\.text), [" bold"])
    }

    func testColorAndLinkCarryThrough() {
        let lines = [line([run("red", color: "#AA0000"), run(" link", x: 30, link: "https://example.com")])]
        let spans = PDFLayoutAnalyzer.styledSpans(from: lines)
        XCTAssertEqual(spans?.first?.color, "#AA0000")
        XCTAssertEqual(spans?.last?.link, "https://example.com")
    }

    func testIncompleteSpansDropToNil() {
        // A run whose text is not in the line text: completeness check must fail.
        var bogus = line([run("visible")])
        bogus.text = "different text entirely"
        XCTAssertNil(PDFLayoutAnalyzer.styledSpans(from: [bogus]))
    }

    func testSuperscriptRunSurvivesAsScriptSpan() {
        let small = run("2", x: 20, size: 8, script: .raised)
        let spans = PDFLayoutAnalyzer.styledSpans(from: [line([run("E = mc"), small])])
        // The space before a styled run rides on the new span, mirroring
        // joinLines' word joining.
        XCTAssertEqual(spans?.filter { $0.script == .raised }.map(\.text), [" 2"])
    }

    // MARK: Dash separator (the em-dash bug)

    func testDashSeparatorIsNotABullet() {
        XCTAssertNil(PDFLayoutAnalyzer.listMarker(in: "— End of page one content —"))
        XCTAssertNil(PDFLayoutAnalyzer.listMarker(in: "- section break -"))
    }

    func testRealBulletsStillMatch() {
        XCTAssertNotNil(PDFLayoutAnalyzer.listMarker(in: "- First bullet item"))
        XCTAssertNotNil(PDFLayoutAnalyzer.listMarker(in: "• Second bullet"))
        XCTAssertNotNil(PDFLayoutAnalyzer.listMarker(in: "— A dash bullet that keeps going and eventually ends with a full stop."))
    }

    // MARK: Rendering

    func testRenderSpansFallbackToPlain() {
        let out = PDFImportEmitter.renderSpans(nil, plain: "a *b* c", atLineStart: false)
        XCTAssertEqual(out, "a \\*b\\* c")
    }

    func testRenderBoldItalicMono() {
        let spans = [
            PDFStyledSpan(text: "plain ", isBold: false),
            PDFStyledSpan(text: "bold", isBold: true),
            PDFStyledSpan(text: " it", isItalic: true),
            PDFStyledSpan(text: " raw", isMonospace: true),
        ]
        let out = PDFImportEmitter.renderSpans(spans, plain: "plain bold it raw", atLineStart: false)
        // Whitespace rides outside the markers: Typst reads `* text*` as
        // literal asterisks, and a glued marker would merge with the
        // previous word ("word.* text").
        XCTAssertEqual(out, "plain *bold* _it_ `raw`")
    }

    func testRenderLinkColorScript() {
        let spans = [
            PDFStyledSpan(text: "x", script: .raised),
            PDFStyledSpan(text: " red", color: "#AA0000"),
            PDFStyledSpan(text: " link", link: "https://e.com"),
        ]
        let out = PDFImportEmitter.renderSpans(spans, plain: "x red link", atLineStart: false)
        XCTAssertEqual(out, "#super[x]#text(fill: rgb(\"#AA0000\"))[ red]#link(\"https://e.com\")[ link]")
    }

    func testLineStartEscapeAppliesToStyledOutput() {
        let spans = [PDFStyledSpan(text: "= not a heading", isBold: true)]
        let out = PDFImportEmitter.renderSpans(spans, plain: "= not a heading", atLineStart: true)
        // The escape lands inside the styling, where Typst still reads it.
        XCTAssertTrue(out.contains("\\="), out)
    }

    // MARK: Furniture

    func testFurnitureCapturesRepeatingHeader() {
        func pageRuns(_ header: String, _ page: Int) -> [PDFTextRun] {
            var head = PDFTextRun(text: header, rect: CGRect(x: 60, y: 790, width: 120, height: 12), fontSize: 10)
            head.isBold = true
            let body = PDFTextRun(text: "Body text of page \(page).", rect: CGRect(x: 60, y: 400, width: 300, height: 12), fontSize: 11)
            return [head, body]
        }
        let pages = (0..<4).map { pageRuns("Running Header", $0) }
        let sizes = Array(repeating: CGSize(width: 612, height: 792), count: 4)
        let furniture = PDFLayoutAnalyzer.pageFurniture(pages: pages, pageSizes: sizes)
        XCTAssertEqual(furniture.header?.text, "Running Header")
        XCTAssertEqual(furniture.footer, nil)
        XCTAssertFalse(furniture.pageNumbers)
    }

    func testFurnitureDetectsPageNumbersOnly() {
        func pageRuns(_ n: Int) -> [PDFTextRun] {
            let num = PDFTextRun(text: "\(n)", rect: CGRect(x: 300, y: 20, width: 12, height: 12), fontSize: 10)
            let body = PDFTextRun(text: "Body.", rect: CGRect(x: 60, y: 400, width: 300, height: 12), fontSize: 11)
            return [num, body]
        }
        let pages = (1...4).map(pageRuns)
        let sizes = Array(repeating: CGSize(width: 612, height: 792), count: 4)
        let furniture = PDFLayoutAnalyzer.pageFurniture(pages: pages, pageSizes: sizes)
        XCTAssertNil(furniture.header)
        XCTAssertNil(furniture.footer)
        XCTAssertTrue(furniture.pageNumbers)
    }

    func testFurnitureIgnoresOneOffText() {
        let pages: [[PDFTextRun]] = [
            [PDFTextRun(text: "Chapter 1", rect: CGRect(x: 60, y: 790, width: 90, height: 12), fontSize: 10)],
            [PDFTextRun(text: "Chapter 2", rect: CGRect(x: 60, y: 790, width: 90, height: 12), fontSize: 10)],
            [PDFTextRun(text: "Chapter 3", rect: CGRect(x: 60, y: 790, width: 90, height: 12), fontSize: 10)],
        ]
        let sizes = Array(repeating: CGSize(width: 612, height: 792), count: 3)
        let furniture = PDFLayoutAnalyzer.pageFurniture(pages: pages, pageSizes: sizes)
        XCTAssertNil(furniture.header)
    }
}
