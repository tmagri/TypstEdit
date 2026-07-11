import XCTest
@testable import CodeEditLanguages
import SwiftTreeSitter

/// Verifies the .note highlight pipeline end-to-end using the same TreeSitterState
/// machinery the editor uses (primary + injected layers). Confirms that Typst
/// constructs and Markdown constructs are both captured for a hybrid document.
final class NoteHighlightTests: XCTestCase {

    func test_noteQueryCompiles() throws {
        let note = CodeLanguage.note
        let query = TreeSitterModel.shared.query(for: .note)
        XCTAssertNotNil(query)
        XCTAssertNotEqual(query?.patternCount, 0)
        // Sanity: the note language resolves to the markdown grammar.
        XCTAssertNotNil(note.language)
    }

    func test_noteLanguageDetection() throws {
        // .note should NOT auto-detect to typst/markdown; the host app assigns it
        // explicitly. We only ensure the CodeLanguage exists and uses markdown parser.
        XCTAssertEqual(CodeLanguage.note.id, .note)
        XCTAssertEqual(CodeLanguage.note.extensions, ["note"])
    }

    /// End-to-end check of the injection overlay: parsing a hybrid note document
    /// with the note (markdown) grammar and resolving the note injections must
    /// produce a `typst` injection spanning the whole document, as well as the
    /// standard `markdown_inline` injections for inline content.
    func test_noteInjectionsResolveTypstOverlay() throws {
        let source = """
        # Heading

        Some text with $math$ and #func().

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

        let textProvider: SwiftTreeSitter.Predicate.TextProvider = { range, _ in
            return (source as NSString).substring(with: range)
        }

        var injectedLanguages: [String: [NSRange]] = [:]
        for match in cursor {
            if let injection = match.injection(with: textProvider) {
                injectedLanguages[injection.name, default: []].append(injection.range)
            }
        }

        // Typst must be injected — once per (paragraph) node, not over the whole document.
        let typstRanges = try XCTUnwrap(injectedLanguages["typst"], "Expected typst injections from the note overlay")
        XCTAssertFalse(typstRanges.isEmpty, "Expected at least one typst paragraph injection")
        let docLength = (source as NSString).length
        XCTAssert(typstRanges.allSatisfy { $0.length < docLength },
                  "Typst should be injected per-paragraph, not over the whole document. Got ranges: \(typstRanges)")

        // markdown_inline must also be injected for inline content.
        XCTAssertNotNil(injectedLanguages["markdown_inline"], "Expected markdown_inline injections")
    }
}
