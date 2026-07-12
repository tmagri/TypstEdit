import XCTest
@testable import CodeEditLanguages
import SwiftTreeSitter

/// Verifies fenced code blocks produce a text.literal capture for their content.
final class FencedCodeBlockProbeTests: XCTestCase {

    func test_fencedCodeBlockContentGetsHighlighted() throws {
        let source = """
        Some text.

        ```
        /ai/robot/
        ```
        """

        var note = CodeLanguage.note
        note.resourceURL = Bundle.module.resourceURL
        let language = try XCTUnwrap(note.language)
        let parser = Parser()
        try parser.setLanguage(language)
        parser.timeout = 0
        let tree = try XCTUnwrap(parser.parse(source))
        let rootNode = try XCTUnwrap(tree.rootNode)

        // Run the note highlights query and collect captures.
        let query = try XCTUnwrap(TreeSitterModel.shared.query(for: .note))
        let cursor = query.execute(node: rootNode, in: tree)

        let textProvider: SwiftTreeSitter.Predicate.TextProvider = { range, _ in
            return (source as NSString).substring(with: range)
        }

        var captures: [(name: String, text: String, range: NSRange)] = []
        for match in cursor {
            for capture in match.captures {
                let text = capture.range.length > 0
                    ? (source as NSString).substring(with: capture.range)
                    : ""
                captures.append((capture.name ?? "", text, capture.range))
            }
        }

        // Filter to valid highlight captures (drop injection.* captures).
        let highlightCaptures = captures.filter {
            $0.name != "injection.content" && $0.name != "injection.language" && $0.name != "none"
        }

        // The code block content "/ai/robot/" must appear in a text.literal capture.
        let literalTexts = highlightCaptures
            .filter { $0.name == "text.literal" }
            .map { $0.text }

        XCTAssertTrue(
            literalTexts.contains(where: { $0.contains("/ai/robot/") }),
            "Expected /ai/robot/ in a text.literal capture. Got: \(literalTexts)"
        )
    }

    func test_fencedCodeBlockWithLanguage() throws {
        let source = """
        ```python
        x = 1
        ```
        """

        var note = CodeLanguage.note
        note.resourceURL = Bundle.module.resourceURL
        let language = try XCTUnwrap(note.language)
        let parser = Parser()
        try parser.setLanguage(language)
        parser.timeout = 0
        let tree = try XCTUnwrap(parser.parse(source))
        let rootNode = try XCTUnwrap(tree.rootNode)

        let query = try XCTUnwrap(TreeSitterModel.shared.query(for: .note))
        let cursor = query.execute(node: rootNode, in: tree)

        var captures: [(name: String, text: String)] = []
        for match in cursor {
            for capture in match.captures {
                let text = capture.range.length > 0
                    ? (source as NSString).substring(with: capture.range)
                    : ""
                captures.append((capture.name ?? "", text))
            }
        }

        let highlightCaptures = captures.filter {
            $0.name != "injection.content" && $0.name != "injection.language" && $0.name != "none"
        }

        // Even with a language tag, the content should appear in some capture.
        let joined = highlightCaptures.map { "\($0.name)→'\($0.text)'" }.joined(separator: ", ")
        XCTAssertTrue(
            highlightCaptures.contains(where: { $0.text.contains("x = 1") }),
            "Expected code content in captures. Got: \(joined)"
        )
    }
}
