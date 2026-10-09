import XCTest
@testable import TypstEdit

final class HTMLToMarkdownConversionTests: XCTestCase {

    private func convert(_ html: String) -> String {
        HTMLToMarkdownConverter.convert(html)
    }

    func testHeadings() {
        let out = convert("<h1>Title</h1><h2>Sub</h2><h3>Deeper</h3>")
        XCTAssertEqual(out, "# Title\n\n## Sub\n\n### Deeper\n")
    }

    func testParagraphWithInlineFormatting() {
        let out = convert("<p>Hello <strong>world</strong> and <em>you</em>.</p>")
        XCTAssertEqual(out, "Hello **world** and *you*.\n")
    }

    func testBoldAndItalicAliases() {
        let out = convert("<p><b>b</b> <i>i</i></p>")
        XCTAssertEqual(out, "**b** *i*\n")
    }

    func testLink() {
        let out = convert(#"<p>See <a href="https://example.com">Example</a>.</p>"#)
        XCTAssertEqual(out, "See [Example](https://example.com).\n")
    }

    func testLinkWithoutTextUsesHref() {
        let out = convert(#"<a href="https://example.com"></a>"#)
        XCTAssertEqual(out, "[https://example.com](https://example.com)\n")
    }

    func testImage() {
        let out = convert(#"<p><img src="pic.png" alt="A pic"></p>"#)
        XCTAssertEqual(out, "![A pic](pic.png)\n")
    }

    func testImageWrappedInLink() {
        let out = convert(#"<a href="https://example.com"><img src="pic.png" alt="A pic"></a>"#)
        XCTAssertEqual(out, "[![A pic](pic.png)](https://example.com)\n")
    }

    func testUnorderedList() {
        let out = convert("<ul><li>One</li><li>Two</li></ul>")
        XCTAssertEqual(out, "- One\n- Two\n")
    }

    func testOrderedList() {
        let out = convert("<ol><li>First</li><li>Second</li></ol>")
        XCTAssertEqual(out, "1. First\n2. Second\n")
    }

    func testNestedListIndentation() {
        let out = convert("<ul><li>One<ul><li>Sub</li></ul></li><li>Two</li></ul>")
        XCTAssertEqual(out, "- One\n  - Sub\n- Two\n")
    }

    func testBlockquote() {
        let out = convert("<blockquote><p>Quoted</p></blockquote>")
        XCTAssertEqual(out, "> Quoted\n")
    }

    func testFencedCodeBlockWithLanguage() {
        let out = convert(#"<pre><code class="language-swift">let x = 1</code></pre>"#)
        XCTAssertEqual(out, "```swift\nlet x = 1\n```\n")
    }

    func testFencedCodeBlockWithoutLanguage() {
        let out = convert("<pre>plain\ncode</pre>")
        XCTAssertEqual(out, "```\nplain\ncode\n```\n")
    }

    func testInlineCode() {
        let out = convert("<p>Use <code>foo()</code> here.</p>")
        XCTAssertEqual(out, "Use `foo()` here.\n")
    }

    func testHorizontalRule() {
        let out = convert("<p>a</p><hr><p>b</p>")
        XCTAssertEqual(out, "a\n\n---\n\nb\n")
    }

    func testLineBreak() {
        let out = convert("<p>one<br>two</p>")
        XCTAssertEqual(out, "one\\\ntwo\n")
    }

    func testTable() {
        let html = "<table><thead><tr><th>A</th><th>B</th></tr></thead>"
            + "<tbody><tr><td>1</td><td>2</td></tr></tbody></table>"
        let out = convert(html)
        XCTAssertEqual(out, "| A | B |\n| --- | --- |\n| 1 | 2 |\n")
    }

    func testTablePadsRaggedRowsAndEscapesPipes() {
        let html = "<table><tr><td>a|b</td><td>c</td></tr><tr><td>only</td></tr></table>"
        let out = convert(html)
        XCTAssertEqual(out, "| a\\|b | c |\n| --- | --- |\n| only |  |\n")
    }

    func testDefinitionList() {
        let out = convert("<dl><dt>Term</dt><dd>Definition</dd></dl>")
        XCTAssertEqual(out, "Term\n: Definition\n")
    }

    func testEntitiesAreDecoded() {
        let out = convert("<p>AT&amp;T &lt;3 &#169; &#x2192;</p>")
        XCTAssertEqual(out, "AT&T \\<3 © →\n")
    }

    func testNonBreakingSpaceBecomesSpace() {
        let out = convert("<p>a&nbsp;b</p>")
        XCTAssertEqual(out, "a b\n")
    }

    func testScriptAndStyleAreStripped() {
        let out = convert("<p>Hi</p><script>var x = 1 < 2;</script><style>p{color:red}</style>")
        XCTAssertEqual(out, "Hi\n")
    }

    func testHeadIsDropped() {
        let html = "<html><head><title>T</title></head><body><p>Body</p></body></html>"
        XCTAssertEqual(convert(html), "Body\n")
    }

    func testCommentsAreStripped() {
        let out = convert("<p>a<!-- hidden -->b</p>")
        XCTAssertEqual(out, "ab\n")
    }

    func testMarkdownMetacharactersAreEscaped() {
        let out = convert("<p>a*b_c [d] ~e~</p>")
        XCTAssertEqual(out, "a\\*b\\_c \\[d\\] \\~e\\~\n")
    }

    func testLeadingHashIsEscaped() {
        let out = convert("<p># not a heading</p>")
        XCTAssertEqual(out, "\\# not a heading\n")
    }

    func testUnderlineAndSuperscriptPreservedAsHTML() {
        let out = convert("<p><u>under</u> x<sup>2</sup></p>")
        XCTAssertEqual(out, "<u>under</u> x<sup>2</sup>\n")
    }

    func testStrikethrough() {
        let out = convert("<p><del>gone</del></p>")
        XCTAssertEqual(out, "~~gone~~\n")
    }

    func testDivContainerFlattensToParagraphs() {
        let out = convert("<div><p>One</p><p>Two</p></div>")
        XCTAssertEqual(out, "One\n\nTwo\n")
    }

    func testWhitespaceIsCollapsed() {
        let out = convert("<p>a\n   b\t\tc</p>")
        XCTAssertEqual(out, "a b c\n")
    }

    func testEmptyInput() {
        XCTAssertEqual(convert(""), "")
    }

    func testMalformedMarkupDoesNotCrash() {
        let out = convert("<p>unclosed <strong>bold")
        XCTAssertEqual(out, "unclosed **bold**\n")
    }

    func testLooksLikeHTML() {
        XCTAssertTrue(HTMLToMarkdownConverter.looksLikeHTML("<p>hi</p>"))
        XCTAssertTrue(HTMLToMarkdownConverter.looksLikeHTML("text <br> more"))
        XCTAssertFalse(HTMLToMarkdownConverter.looksLikeHTML("just plain text"))
        XCTAssertFalse(HTMLToMarkdownConverter.looksLikeHTML("a < b and c > d"))
        XCTAssertFalse(HTMLToMarkdownConverter.looksLikeHTML(""))
    }
}

/// Verifies the full paste pipeline used for `.typ` and `.note` documents:
/// HTML → Markdown → Typst. `.typ` uses the pure sanitizer, `.note` the hybrid one.
@MainActor
final class HTMLToTypstPipelineTests: XCTestCase {

    private func pipeline(_ html: String, isHybrid: Bool) -> String {
        let markdown = HTMLToMarkdownConverter.convert(html)
        return AICompletionService.shared.sanitizeMarkdownToTypst(markdown, isHybrid: isHybrid)
    }

    func testHeadingsAndEmphasisConvertToTypst() {
        let typst = pipeline("<h1>Title</h1><p>Hello <strong>world</strong> and <em>you</em>.</p>", isHybrid: false)
        XCTAssertTrue(typst.contains("= Title"), typst)
        XCTAssertTrue(typst.contains("*world*"), typst)
        XCTAssertTrue(typst.contains("_you_"), typst)
    }

    func testListsConvertToTypst() {
        let typst = pipeline("<ul><li>One</li><li>Two</li></ul>", isHybrid: false)
        XCTAssertTrue(typst.contains("- One"), typst)
        XCTAssertTrue(typst.contains("- Two"), typst)
    }

    func testLinkConvertsToTypstLink() {
        let typst = pipeline(#"<p>See <a href="https://example.com">Example</a></p>"#, isHybrid: false)
        XCTAssertTrue(typst.contains("#link(\"https://example.com\")"), typst)
    }

    func testNoteHybridPipelineProducesTypst() {
        let typst = pipeline("<h2>Notes</h2><ul><li>One</li></ul>", isHybrid: true)
        XCTAssertTrue(typst.contains("== Notes"), typst)
        XCTAssertTrue(typst.contains("- One"), typst)
    }
}
