import XCTest
@testable import TypstEdit

/// Opt-in size limit for Markdown / `.note` coloring.
///
/// The limit is a battery saver, not a responsiveness fix: tree-sitter now parses on a background thread
/// against a text snapshot, so typing is responsive at any size. What the hybrid grammar still costs is CPU
/// (measured at 1.6 MB while typing: ~82% of one core, against ~9% for plain text), so the default keeps full
/// coloring and the limit, when chosen, falls back to plain text.
///
/// These tests pin that the default never downgrades anything, that the fallback is plain text, and that the
/// decision is *latched per document* rather than recomputed from live text length.
@MainActor
final class LargeDocumentHighlightTests: XCTestCase {

    private func makeController(extension ext: String) -> EditorController {
        let controller = EditorController()
        controller.currentFileURL = URL(fileURLWithPath: "/tmp/document.\(ext)")
        return controller
    }

    private func setLimit(_ kilochars: Int) {
        GeneralSettingsManager.shared.markdownHighlightLimitKilochars = kilochars
    }

    override func setUp() {
        super.setUp()
        GeneralSettingsManager.shared.markdownHighlightLimitKilochars = 500
    }

    override func tearDown() {
        // Restore the documented default so other tests are not affected.
        UserDefaults.standard.removeObject(forKey: "markdownHighlightLimitKilochars")
        super.tearDown()
    }

    func testShippedDefaultIsNever() {
        // `@AppStorage` caches its value, so the default is pinned through its named constant.
        XCTAssertEqual(GeneralSettingsManager.defaultMarkdownHighlightLimitKilochars, 0)
    }

    func testDefaultNeverDowngradesColoring() {
        GeneralSettingsManager.shared.markdownHighlightLimitKilochars =
            GeneralSettingsManager.defaultMarkdownHighlightLimitKilochars
        let controller = makeController(extension: "note")
        controller.updateLargeDocumentHighlighting(for: 50_000_000)
        XCTAssertEqual(controller.highlightLanguage.id, .note, "the default must keep full coloring at any size")
    }

    func testSmallNoteKeepsHybridGrammar() {
        let controller = makeController(extension: "note")
        controller.updateLargeDocumentHighlighting(for: 10_000)
        XCTAssertEqual(controller.highlightLanguage.id, .note)
    }

    func testNoteAtTheLimitKeepsHybridGrammar() {
        let controller = makeController(extension: "note")
        controller.updateLargeDocumentHighlighting(for: 500_000)
        XCTAssertEqual(controller.highlightLanguage.id, .note, "the limit is exclusive")
    }

    func testNoteAboveTheLimitFallsBackToPlainText() {
        // Plain text, not the Typst grammar: measured, the Typst fallback still used ~52% of a core while
        // typing at 1.6 MB and left the document miscolored, for little saving over the hybrid grammar.
        for length in [500_001, 700_000, 1_600_000] {
            let controller = makeController(extension: "note")
            controller.updateLargeDocumentHighlighting(for: length)
            XCTAssertEqual(controller.highlightLanguage.id, .plainText, "length \(length)")
        }
    }

    func testMarkdownAboveTheLimitFallsBackToPlainText() {
        let controller = makeController(extension: "md")
        controller.updateLargeDocumentHighlighting(for: 700_000)
        XCTAssertEqual(controller.highlightLanguage.id, .plainText)
    }

    func testZeroDisablesTheLimit() {
        setLimit(0)
        let controller = makeController(extension: "note")
        controller.updateLargeDocumentHighlighting(for: 10_000_000)
        XCTAssertEqual(controller.highlightLanguage.id, .note)
    }

    func testTypstFileIsNeverAffected() {
        // Real Typst documents stay incremental, so size is not a reason to downgrade them.
        let controller = makeController(extension: "typ")
        controller.updateLargeDocumentHighlighting(for: 5_000_000)
        XCTAssertEqual(controller.highlightLanguage.id, .typst)
    }

    func testThresholdIsLatchedNotRecomputedPerKeystroke() {
        // The latch prevents a full re-highlight every time an edit straddles the limit. Growing the text
        // without a document load must not change the grammar.
        let controller = makeController(extension: "note")
        controller.updateLargeDocumentHighlighting(for: 10_000)
        XCTAssertEqual(controller.highlightLanguage.id, .note)
        controller.sourceCode = String(repeating: "x", count: 900_000)
        XCTAssertEqual(controller.highlightLanguage.id, .note,
                       "highlight grammar must change on a document load, never on a text edit")
    }

    func testReloadingASmallerDocumentClearsTheLatch() {
        let controller = makeController(extension: "note")
        controller.updateLargeDocumentHighlighting(for: 700_000)
        XCTAssertEqual(controller.highlightLanguage.id, .plainText)
        controller.updateLargeDocumentHighlighting(for: 20_000)
        XCTAssertEqual(controller.highlightLanguage.id, .note)
    }

    func testClosingDocumentClearsTheLatch() {
        let controller = makeController(extension: "note")
        controller.updateLargeDocumentHighlighting(for: 700_000)
        controller.closeDocument()
        XCTAssertFalse(controller.largeDocumentHighlighting)
    }
}
