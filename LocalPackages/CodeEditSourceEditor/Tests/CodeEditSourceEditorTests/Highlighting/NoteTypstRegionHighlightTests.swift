import XCTest
import CodeEditTextView
import CodeEditLanguages
@testable import CodeEditSourceEditor

/// In `.note` files Typst is overlaid per Markdown paragraph. A Typst code
/// construct containing a blank line used to be split apart: the indented
/// `grid(` after the blank line became a green Markdown indented-code block,
/// and `text(size: a * 1em, it)` was parsed as markup with an unclosed `*bold`.
final class NoteTypstRegionHighlightTests: XCTestCase {
    final class NoAttributes: ThemeAttributesProviding {
        func attributesFor(_ capture: CaptureName?) -> [NSAttributedString.Key: Any] { [:] }
    }

    private let footerSource = """
    Some intro text.

    #set page(
      footer: context {
        let display-date = datetime.today().display("[month repr:long] [day], [year]")

        grid(
          columns: (1fr, 1fr, 1fr),
          align(left)[Page #current of #total],
        )
      }
    )
    #counter(page).update(1)
    """

    private let showSource = """
    #show outline.entry.where(level: 2): it => {
      set text(weight: "medium", style: "italic")
      it
    }

    #show outline.entry: it => {
      // Use calc.max to force any level below 3 to evaluate 2
      let exponent = calc.max(0, it.level - 2)
      let scale-factor = calc.pow(0.9, exponent)

      text(size: scale-factor * 1em, it)
    }

    After the rule *bold* text.
    """

    // MARK: - Region scanning

    func test_regionSpansBlankLines() {
        let regions = NoteTypstRegions.regions(in: footerSource)
        let ns = footerSource as NSString
        let texts = regions.map { ns.substring(with: $0) }
        XCTAssertEqual(texts.count, 2, "\(texts)")
        XCTAssertTrue(texts[0].hasPrefix("#set page("))
        XCTAssertTrue(texts[0].hasSuffix("  }\n)"), texts[0])
        XCTAssertEqual(texts[1], "#counter(page).update(1)")
    }

    func test_regionOpenerRules() {
        XCTAssertTrue(NoteTypstRegions.isRegionOpener("#show heading: it => it"))
        XCTAssertTrue(NoteTypstRegions.isRegionOpener("  #{ 1 }"))
        XCTAssertFalse(NoteTypstRegions.isRegionOpener("# ATX heading"))
        XCTAssertFalse(NoteTypstRegions.isRegionOpener("## h2"))
        XCTAssertFalse(NoteTypstRegions.isRegionOpener("#hashtag, text"))
    }

    func test_regionsSkipFencesAndUrlComments() {
        let source = """
        ```
        #set page(
        ```
        #link("https://x.com")[a]
        after
        """
        let ns = source as NSString
        let texts = NoteTypstRegions.regions(in: source).map { ns.substring(with: $0) }
        XCTAssertEqual(texts, ["#link(\"https://x.com\")[a]"])
    }

    func test_mergeWidensOnlyOverlappingParagraphs() {
        let merged = NoteTypstRegions.merge(
            paragraphs: [NSRange(location: 0, length: 5), NSRange(location: 10, length: 5), NSRange(location: 30, length: 5)],
            regions: [NSRange(location: 12, length: 10)]
        )
        XCTAssertEqual(merged, [NSRange(location: 0, length: 5), NSRange(location: 10, length: 12), NSRange(location: 30, length: 5)])
    }

    // MARK: - End-to-end highlighting

    @MainActor
    private func highlights(for source: String) -> [HighlightRange] {
        let textView = Mock.textView()
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textView.setText(source)
        let provider = TreeSitterClient()
        provider.forceSyncOperation = true
        let highlighter = Mock.highlighter(
            textView: textView,
            highlightProviders: [provider],
            attributeProvider: NoAttributes()
        )
        textView.addStorageDelegate(highlighter)
        highlighter.setLanguage(language: .note)
        highlighter.invalidate()

        var received: [HighlightRange] = []
        provider.queryHighlightsFor(textView: textView, range: textView.documentRange) { result in
            if case .success(let ranges) = result { received = ranges }
        }
        return received
    }

    private func captures(_ highlights: [HighlightRange], covering needle: String, in source: String) -> [CaptureName] {
        let range = (source as NSString).range(of: needle)
        precondition(range.location != NSNotFound, "missing \(needle)")
        return highlights.filter { $0.range.intersection(range) != nil }.compactMap { $0.capture }
    }

    @MainActor
    func test_gridAfterBlankLineIsTypstNotIndentedCode() {
        let result = highlights(for: footerSource)
        let gridCaptures = captures(result, covering: "grid", in: footerSource)
        XCTAssertFalse(gridCaptures.contains(.textLiteral), "grid( must not be a Markdown code block: \(gridCaptures)")
        XCTAssertTrue(gridCaptures.contains(.function), "grid( should be a Typst call: \(gridCaptures)")
        XCTAssertTrue(captures(result, covering: "1fr", in: footerSource).contains(.number))
    }

    @MainActor
    func test_methodCallsAreFunctions() {
        let source = """
        #let total = counter(page).final().first()
        #let d = datetime.today().display("[year]")
        #let m = calc.max(0, 2)

        Math stays math: $arrow.r(x) + f(y) + x^arrow.l(y)$
        """
        let result = highlights(for: source)
        let ns = source as NSString
        func shown(_ word: String, after anchor: String = "") -> CaptureName? {
            let from = anchor.isEmpty ? 0 : ns.range(of: anchor).location
            let range = ns.range(of: word, range: NSRange(location: from, length: ns.length - from))
            return renderedCapture(result, at: range.location)
        }
        for method in ["final", "first", "today", "display", "max"] {
            XCTAssertEqual(shown(method), .function, "\(method) should render as a function")
        }
        // The receiver object is not a function.
        XCTAssertNotEqual(shown("datetime"), .function)
        XCTAssertNotEqual(shown("calc"), .function)
        // Inside math, method-style calls keep the math colour.
        XCTAssertEqual(shown("r(x)", after: "$arrow"), .number)
        XCTAssertEqual(shown("l(y)", after: "x^arrow"), .number)
    }

    /// The capture the editor actually draws at `location`, mirroring
    /// `StyledRangeContainer.applyHighlightResult`: highlights are applied in
    /// order and any highlight starting inside an already-applied one is skipped.
    private func renderedCapture(_ highlights: [HighlightRange], at location: Int) -> CaptureName? {
        var lastIndex = 0
        var drawn: CaptureName?
        for highlight in highlights {
            guard highlight.range.location >= lastIndex else { continue }
            if NSLocationInRange(location, highlight.range) { drawn = highlight.capture }
            lastIndex = highlight.range.upperBound
        }
        return drawn
    }

    @MainActor
    func test_codeAfterBlankLineInShowRuleIsNotMarkup() {
        let result = highlights(for: showSource)
        let starLine = captures(result, covering: "* 1em, it)", in: showSource)
        XCTAssertFalse(starLine.contains(.textStrong), "`*` in code is multiplication, not bold: \(starLine)")
        XCTAssertTrue(captures(result, covering: "text(size", in: showSource).contains(.function))
        let showKeywords = result.filter {
            (showSource as NSString).substring(with: $0.range) == "show" && $0.capture == .keyword
        }
        XCTAssertEqual(showKeywords.count, 2, "both #show rules should highlight `show`")
        // Markup after the region is still Typst markup.
        XCTAssertTrue(captures(result, covering: "*bold*", in: showSource).contains(.textStrong))
    }
}
