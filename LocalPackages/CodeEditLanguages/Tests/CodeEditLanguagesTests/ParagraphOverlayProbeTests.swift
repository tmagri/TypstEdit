import XCTest
@testable import CodeEditLanguages
import SwiftTreeSitter

final class ParagraphOverlayProbeTests: XCTestCase {
    /// Confirms that injecting Typst over (paragraph) nodes — instead of (document) —
    /// still captures all the Typst constructs we care about, while leaving block-level
    /// Markdown structure (headings, lists, code blocks) to the Markdown primary layer.
    func test_typstParagraphOverlayCaptures() throws {
        // A representative .note document.
        let source = """
        # ATX Heading

        = Typst Heading

        #let x = 10
        #myfunc(arg)

        Text with *bold*, _italic_, $math$, and [a link](http://x.com).

        - list item
        - another

        ```python
        print("hi")
        ```
        """

        // Parse as Markdown (the note primary grammar) and find paragraph ranges.
        var note = CodeLanguage.note
        note.resourceURL = Bundle.module.resourceURL
        let mdLanguage = try XCTUnwrap(note.language)
        let mdParser = Parser()
        try mdParser.setLanguage(mdLanguage)
        mdParser.timeout = 0
        let mdTree = try XCTUnwrap(mdParser.parse(source))
        let mdRoot = try XCTUnwrap(mdTree.rootNode)

        // Collect (paragraph) node ranges.
        let paragraphRanges = collectNamedRanges(root: mdRoot, name: "paragraph", source: source)
        XCTAssertFalse(paragraphRanges.isEmpty, "Expected paragraph nodes in the markdown parse")

        // For each paragraph range, parse with Typst + Typst highlights query and collect captures.
        var typst = CodeLanguage.typst
        typst.resourceURL = Bundle.module.resourceURL
        let tsLanguage = try XCTUnwrap(typst.language)
        let tsParser = Parser()
        try tsParser.setLanguage(tsLanguage)
        tsParser.timeout = 0
        let query = try XCTUnwrap(TreeSitterModel.shared.query(for: .typst))

        var allCaptureTexts: [String] = []
        for pr in paragraphRanges {
            // Parse the paragraph fragment with Typst.
            let frag = (source as NSString).substring(with: pr)
            let tsTree = try XCTUnwrap(tsParser.parse(frag))
            let cursor = query.execute(node: try XCTUnwrap(tsTree.rootNode), in: tsTree)
            for match in cursor {
                for capture in match.captures {
                    let r = capture.range
                    let text = r.length > 0 ? (frag as NSString).substring(with: r) : ""
                    allCaptureTexts.append(text)
                }
            }
        }

        let joined = allCaptureTexts.joined(separator: " | ")
        // Typst constructs that MUST be captured within paragraphs.
        XCTAssertTrue(joined.contains("= Typst Heading"), "Typst heading missing. Captures: \(joined)")
        XCTAssertTrue(joined.contains("#let") || joined.contains("let"), "Typst let missing. Captures: \(joined)")
        XCTAssertTrue(joined.contains("myfunc"), "Typst function call missing. Captures: \(joined)")
        XCTAssertTrue(joined.contains("$"), "Typst math missing. Captures: \(joined)")
        XCTAssertTrue(joined.contains("*bold*"), "Typst strong missing. Captures: \(joined)")
        XCTAssertTrue(joined.contains("_italic_"), "Typst emph missing. Captures: \(joined)")

        // The ATX heading line ("# ATX Heading") is NOT a paragraph in markdown, so it should
        // not appear in any Typst paragraph capture — it's handled by Markdown.
        XCTAssertFalse(joined.contains("ATX Heading"), "ATX heading should be handled by Markdown, not Typst. Captures: \(joined)")
    }

    private func collectNamedRanges(root: Node, name: String, source: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            if node.nodeType == name {
                ranges.append(NSRange(location: node.range.lowerBound, length: node.range.length))
            }
            for i in 0..<node.childCount {
                if let child = node.child(at: i) { stack.append(child) }
            }
        }
        return ranges
    }
}
