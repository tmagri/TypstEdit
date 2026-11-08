import XCTest
@testable import TypstEdit
import CodeEditSourceEditor
import CodeEditLanguages
import AppKit

/// End-to-end check that a code file really gets colored text in the editor,
/// and that a plain-text file stays editable without a grammar.
///
/// The earlier unit tests prove the grammar and query exist; this one drives
/// the same `TextViewController` the window uses, so a color found here is a
/// color the user actually sees.
final class CodeHighlightingTests: XCTestCase {

    @MainActor
    private func makeController(for controller: EditorController) -> (TextViewController, EditorTheme) {
        let theme = controller.customTheme
        let tvc = TextViewController(
            string: "",
            language: controller.highlightLanguage,
            configuration: controller.editorConfiguration,
            cursorPositions: [],
            highlightProviders: [TreeSitterClient()]
        )
        tvc.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = tvc.view
        tvc.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        tvc.view.layoutSubtreeIfNeeded()
        return (tvc, theme)
    }

    /// Sets the text and pumps the run loop until the asynchronous tree-sitter
    /// query has painted at least one run in something other than the theme's
    /// base text color.
    @MainActor
    private func settle(_ tvc: TextViewController, _ text: String, theme: EditorTheme) {
        tvc.setText(text)
        tvc.textView.layoutManager.layoutLines()

        let base = theme.text.color
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            tvc.textView.layoutManager.layoutLines()
            if hasRunDiffering(from: base, in: tvc) { break }
        }
    }

    @MainActor
    private func hasRunDiffering(from base: NSColor, in tvc: TextViewController) -> Bool {
        guard let storage = tvc.textView.textStorage, storage.length > 0 else { return false }
        var found = false
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if let color = value as? NSColor, color != base {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    @MainActor
    private func color(at index: Int, in tvc: TextViewController) -> NSColor? {
        guard let storage = tvc.textView.textStorage, index < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    @MainActor
    func testPythonGetsSyntaxColors() throws {
        let controller = EditorController()
        controller.currentFileURL = URL(fileURLWithPath: "/tmp/project/main.py")
        XCTAssertEqual(controller.highlightLanguage.id, .python)

        let (tvc, theme) = makeController(for: controller)
        let source = """
        # a comment
        def greet(name):
            return f"hello {name}" if name else None
        """
        settle(tvc, source, theme: theme)

        let ns = source as NSString
        let commentIndex = ns.range(of: "# a comment").location
        let defIndex = ns.range(of: "def").location
        let commentColor = try XCTUnwrap(color(at: commentIndex, in: tvc))
        let keywordColor = try XCTUnwrap(color(at: defIndex, in: tvc))
        XCTAssertNotEqual(commentColor, keywordColor, "comment and keyword should not share a color")
        XCTAssertNotEqual(commentColor, theme.text.color)
        XCTAssertEqual(keywordColor, theme.keywords.color, "a `def` keyword uses the keyword color")
    }

    @MainActor
    func testJSONKeysAndValuesDiffer() throws {
        let controller = EditorController()
        controller.currentFileURL = URL(fileURLWithPath: "/tmp/project/data.json")
        XCTAssertEqual(controller.highlightLanguage.id, .json)

        let (tvc, theme) = makeController(for: controller)
        let source = "{\n  \"name\": \"value\",\n  \"count\": 42\n}"
        settle(tvc, source, theme: theme)

        let ns = source as NSString
        let keyColor = try XCTUnwrap(color(at: ns.range(of: "\"name\"").location + 1, in: tvc))
        let stringValueColor = try XCTUnwrap(color(at: ns.range(of: "\"value\"").location + 1, in: tvc))
        let numberColor = try XCTUnwrap(color(at: ns.range(of: "42").location, in: tvc))

        XCTAssertEqual(stringValueColor, theme.strings.color, "a JSON string value uses the string color")
        XCTAssertEqual(keyColor, theme.attributes.color, "a JSON key uses the attribute color")
        XCTAssertEqual(numberColor, theme.numbers.color)
        XCTAssertNotEqual(keyColor, stringValueColor, "a JSON key should not look like its string value")
    }

    @MainActor
    func testXMLAttributesAreColored() throws {
        let controller = EditorController()
        controller.currentFileURL = URL(fileURLWithPath: "/tmp/project/feed.xml")
        XCTAssertEqual(controller.currentSyntaxName, "XML")

        let (tvc, theme) = makeController(for: controller)
        let source = "<root attr=\"value\"><child/></root>"
        settle(tvc, source, theme: theme)

        let ns = source as NSString
        let tagColor = try XCTUnwrap(color(at: ns.range(of: "root").location, in: tvc))
        let attrColor = try XCTUnwrap(color(at: ns.range(of: "attr").location, in: tvc))
        XCTAssertEqual(tagColor, theme.keywords.color, "an XML tag uses the keyword color")
        XCTAssertEqual(attrColor, theme.attributes.color, "an XML attribute uses the attribute color")
        XCTAssertNotEqual(tagColor, attrColor, "XML tag and attribute should not share a color")
    }

    @MainActor
    func testPlainTextOpensWithoutGrammar() throws {
        let controller = EditorController()
        controller.currentFileURL = URL(fileURLWithPath: "/tmp/project/notes.txt")
        XCTAssertEqual(controller.currentFileType, .text)
        XCTAssertEqual(controller.currentSyntaxName, "Plain Text")
        XCTAssertEqual(controller.highlightLanguage.id, .plainText)

        // Must not crash and must remain editable.
        let (tvc, _) = makeController(for: controller)
        tvc.setText("just some words\n")
        XCTAssertEqual(tvc.textView.string, "just some words\n")
    }

    @MainActor
    func testCommentToggleUsesLanguagePrefix() throws {
        let controller = EditorController()
        controller.currentFileURL = URL(fileURLWithPath: "/tmp/project/main.py")
        controller.sourceCode = "print('hi')"
        controller.editorState.cursorPositions = [.init(range: NSRange(location: 0, length: 0))]
        controller.toggleLineComment()
        XCTAssertEqual(controller.sourceCode, "# print('hi')")

        controller.toggleLineComment()
        XCTAssertEqual(controller.sourceCode, "print('hi')")
    }

    @MainActor
    func testRibbonIsProseOnly() throws {
        let controller = EditorController()
        controller.currentFileURL = URL(fileURLWithPath: "/tmp/project/main.py")
        XCTAssertFalse(controller.isProseFile)
        XCTAssertTrue(controller.currentFileType.isTextual)

        controller.currentFileURL = URL(fileURLWithPath: "/tmp/project/doc.typ")
        XCTAssertTrue(controller.isProseFile)
    }
}
