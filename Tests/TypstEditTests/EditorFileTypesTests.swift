import XCTest
@testable import TypstEdit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftTreeSitter

/// Verifies the file-type table and the grammar selection behind syntax
/// highlighting. These are the two places that decide whether a file colors
/// at all; a wrong answer here is what left `.py` and `.xml` files plain.
final class EditorFileTypesTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/project/\(name)")
    }

    // MARK: - Classification

    func testTypstFamily() {
        XCTAssertTrue(EditorFileTypes.isTypstFamily(url("doc.typ")))
        XCTAssertTrue(EditorFileTypes.isTypstFamily(url("page.note")))
        XCTAssertFalse(EditorFileTypes.isTypstFamily(url("main.py")))
    }

    func testMarkdownDetection() {
        XCTAssertTrue(EditorFileTypes.isMarkdownFile(url("README.md")))
        XCTAssertTrue(EditorFileTypes.isMarkdownFile(url("doc.markdown")))
        XCTAssertFalse(EditorFileTypes.isMarkdownFile(url("main.typ")))
    }

    func testCodeAndPlainTextAreEditable() {
        let editable = [
            "main.py", "data.json", "feed.xml", "config.yml", "Cargo.toml",
            "style.css", "index.html", "app.js", "app.tsx", "main.c", "lib.rs",
            "notes.txt", ".gitignore", "Dockerfile", "schema.xsd", "notebook.ipynb",
        ]
        for name in editable {
            XCTAssertTrue(
                EditorFileTypes.isEditableTextFile(url(name)),
                "\(name) should open in the text editor"
            )
        }
    }

    func testBinaryFilesAreNotEditable() {
        for name in ["photo.png", "manual.pdf", "archive.zip", "font.ttf"] {
            XCTAssertFalse(
                EditorFileTypes.isEditableTextFile(url(name)),
                "\(name) should not open in the text editor"
            )
        }
    }

    // MARK: - Grammar selection

    func testGrammarsAreResolved() {
        let expected: [String: TreeSitterLanguage] = [
            "main.py": .python,
            "data.json": .json,
            "feed.xml": .html,        // HTML grammar doubles for XML
            "config.yml": .yaml,
            "Cargo.toml": .toml,
            "style.css": .css,
            "index.html": .html,
            "app.js": .javascript,
            "app.tsx": .tsx,
            "main.c": .c,
            "lib.rs": .rust,
            "run.sh": .bash,
            "query.sql": .sql,
        ]
        for (name, language) in expected {
            XCTAssertEqual(
                EditorFileTypes.syntax(for: url(name))?.language.id,
                language,
                "\(name) should resolve to \(language.rawValue)"
            )
        }
    }

    func testPlainTextHasNoGrammar() {
        XCTAssertNil(EditorFileTypes.syntax(for: url("notes.txt")))
        XCTAssertNil(EditorFileTypes.syntax(for: url("data.csv")))
    }

    func testDisplayNames() {
        XCTAssertEqual(EditorFileTypes.displayName(for: url("main.py")), "Python")
        XCTAssertEqual(EditorFileTypes.displayName(for: url("data.json")), "JSON")
        XCTAssertEqual(EditorFileTypes.displayName(for: url("feed.xml")), "XML")
        XCTAssertEqual(EditorFileTypes.displayName(for: url("README.md")), "Markdown")
        XCTAssertEqual(EditorFileTypes.displayName(for: url("notes.txt")), "Plain Text")
        XCTAssertEqual(EditorFileTypes.displayName(for: url("doc.typ")), "Typst")
    }

    /// The grammar must actually produce a query and parse, or the file loads
    /// with a language but still renders unstyled.
    func testGrammarQueriesLoadAndCapture() throws {
        let cases: [(name: String, source: String, expected: CaptureName)] = [
            ("main.py", "def greet(name):\n    return f\"hi {name}\"\n", .keyword),
            // JSON has no keywords: strings, numbers, and true/false/null
            // (which the grammar captures as constant.builtin).
            ("data.json", "{\"key\": [1, 2, true, null]}\n", .constant),
            ("feed.xml", "<root attr=\"value\"><child/></root>\n", .tag),
        ]

        for testCase in cases {
            let syntax = try XCTUnwrap(
                EditorFileTypes.syntax(for: url(testCase.name)),
                "no grammar for \(testCase.name)"
            )
            let language = try XCTUnwrap(syntax.language.language, "no TS language")
            let query = try XCTUnwrap(
                TreeSitterModel.shared.query(for: syntax.language.id),
                "no highlight query for \(testCase.name)"
            )
            let parser = Parser()
            try parser.setLanguage(language)
            let tree = try XCTUnwrap(parser.parse(testCase.source), "parse failed")

            let cursor = query.execute(in: tree)
            let captures = cursor.resolve(with: .init(
                textProvider: { range, _ in
                    let ns = testCase.source as NSString
                    guard range.location + range.length <= ns.length else { return nil }
                    return ns.substring(with: range)
                }
            )).flatMap { $0.captures }

            let names = captures.compactMap { CaptureName.fromString($0.name) }
            XCTAssertFalse(names.isEmpty, "\(testCase.name) produced no highlights")
            XCTAssertTrue(
                names.contains(testCase.expected),
                "\(testCase.name) should capture \(testCase.expected.debugDescription), got \(names.map(\.debugDescription))"
            )
        }
    }

    // MARK: - Comment syntax

    func testLineCommentPrefixes() {
        XCTAssertEqual(EditorFileTypes.lineCommentPrefix(for: url("main.py")), "#")
        XCTAssertEqual(EditorFileTypes.lineCommentPrefix(for: url("main.typ")), "//")
        XCTAssertEqual(EditorFileTypes.lineCommentPrefix(for: url("query.sql")), "--")
        XCTAssertNil(EditorFileTypes.lineCommentPrefix(for: url("index.html")))
        XCTAssertNil(EditorFileTypes.lineCommentPrefix(for: url("README.md")))
    }

    func testBlockCommentDelimiters() {
        XCTAssertEqual(EditorFileTypes.blockCommentDelimiters(for: url("index.html"))?.open, "<!--")
        XCTAssertEqual(EditorFileTypes.blockCommentDelimiters(for: url("main.c"))?.open, "/*")
        XCTAssertNil(EditorFileTypes.blockCommentDelimiters(for: url("main.py")))
    }
}
