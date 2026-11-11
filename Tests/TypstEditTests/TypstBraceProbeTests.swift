import XCTest
import SwiftTreeSitter
import CodeEditLanguages
@testable import TypstEdit

/// Regression tests for Typst code-block highlighting: every token of a
/// `#show … : it => { … }` rule must carry a capture — braces, brackets,
/// the lambda arrow, assignment `=`, and plain identifiers. Previously the
/// packaged query captured none of these, so braces rendered as plain text
/// and a code block looked like it never closed.
final class TypstBraceProbeTests: XCTestCase {

    /// Runs the language's packaged highlights query and returns
    /// (captureName, capturedText) pairs, first-wins order preserved.
    private func captures(language: CodeLanguage, source: String) throws -> [(String, String)] {
        let sourceNS = source as NSString
        let parser = Parser()
        let lang = try XCTUnwrap(language.language, "no language for \(language.id)")
        try parser.setLanguage(lang)
        let tree = try XCTUnwrap(parser.parse(source), "parse failed")
        let root = try XCTUnwrap(tree.rootNode, "parse failed")
        // The query must compile and the source must parse cleanly: a broken
        // tree is a separate bug from a missing capture.
        XCTAssertFalse(root.hasError, "source failed to parse for \(language.id)")

        let queryURL = try XCTUnwrap(language.queryURL, "no highlights query for \(language.id)")
        let data = try XCTUnwrap(FileManager.default.contents(atPath: queryURL.path), "no query data at \(queryURL.path)")
        let query = try Query(language: lang, data: data)
        let cursor = query.execute(node: root, in: tree)
        cursor.setRange(NSRange(location: 0, length: sourceNS.length))
        let context = SwiftTreeSitter.Predicate.Context(textProvider: { nsRange, _ in
            sourceNS.substring(with: nsRange)
        })
        // First-wins resolution, mirroring StyledRangeContainer.applyHighlightResult:
        // the earliest capture (query order) for overlapping ranges is what renders.
        var seen: [(String, String)] = []
        var covered: [NSRange] = []
        for match in cursor.resolve(with: context) {
            for cap in match.captures {
                let range = cap.range
                // Skip captures that start inside an already-styled range.
                if covered.contains(where: { range.location >= $0.location && range.location < ($0.location + $0.length) }) {
                    continue
                }
                covered.append(range)
                seen.append((cap.name ?? "?", sourceNS.substring(with: range)))
            }
        }
        return seen
    }

    private func capture(for text: String, in captures: [(String, String)]) -> String? {
        captures.first(where: { $0.1 == text })?.0
    }

    /// The exact construct from the bug report: show rules with `{ }` blocks.
    func testShowRuleBraceBlocksAreFullyCaptured() throws {
        let source = """
        #show figure.where(kind: "verse"): it => {
          let parts = str(it.label).split("-")
          super(parts.at(2)) + h(0.15em) + it.body + [
          ]
        }
        """
        let caps = try captures(language: .typst, source: source)

        // Braces of the code block: punctuation, not plain text.
        XCTAssertEqual(capture(for: "{", in: caps), "punctuation.bracket", "{ must be captured")
        XCTAssertEqual(capture(for: "}", in: caps), "punctuation.bracket", "} must be captured")
        // Content block delimiters.
        XCTAssertEqual(capture(for: "[", in: caps), "punctuation.bracket")
        XCTAssertEqual(capture(for: "]", in: caps), "punctuation.bracket")
        // Paren group.
        XCTAssertEqual(capture(for: "(", in: caps), "punctuation.bracket")
        XCTAssertEqual(capture(for: ")", in: caps), "punctuation.bracket")
        // Lambda arrow and let-binding assignment.
        XCTAssertEqual(capture(for: "=>", in: caps), "operator")
        XCTAssertEqual(capture(for: "=", in: caps), "operator")
        // Plain identifiers stay unstyled (default text color) by design;
        // call names still read as functions.
        XCTAssertNil(capture(for: "parts", in: caps), "plain idents must stay unstyled")
        XCTAssertNil(capture(for: "it", in: caps), "plain idents must stay unstyled")
        XCTAssertEqual(capture(for: "str", in: caps), "function")
        XCTAssertEqual(capture(for: "super", in: caps), "function")
        // Delimiters: the tagged-argument colon and the field-access dot.
        XCTAssertEqual(capture(for: ":", in: caps), "punctuation.delimiter")
        XCTAssertEqual(capture(for: ".", in: caps), "punctuation.delimiter")
    }

    /// A plain `#{ … }` code block and an `#let` with a lambda body block.
    func testStandaloneBraceBlocks() throws {
        let caps = try captures(language: .typst, source: "#{\n  let a = 1\n  a\n}\n")
        XCTAssertEqual(capture(for: "{", in: caps), "punctuation.bracket")
        XCTAssertEqual(capture(for: "}", in: caps), "punctuation.bracket")
        XCTAssertEqual(capture(for: "=", in: caps), "operator")

        let lambdaCaps = try captures(language: .typst, source: "#let f = x => {\n  x + 1\n}\n")
        XCTAssertEqual(capture(for: "{", in: lambdaCaps), "punctuation.bracket")
        XCTAssertEqual(capture(for: "}", in: lambdaCaps), "punctuation.bracket")
        XCTAssertEqual(capture(for: "=>", in: lambdaCaps), "operator")
        XCTAssertEqual(capture(for: "+", in: lambdaCaps), "operator")
    }

    /// Math must keep its yellow styling: the parent `(math)` capture covers
    /// the whole `$…$` span, so inner punctuation rules must not break out.
    func testMathStaysCoveredByNumberCapture() throws {
        let caps = try captures(language: .typst, source: "$x^2 + 1$\n")
        // With first-wins resolution the whole span must read as one number run.
        XCTAssertTrue(caps.contains(where: { $0.0 == "number" && $0.1.contains("x^2 + 1") }),
                      "math span must be captured as number, got: \(caps)")
    }
}
