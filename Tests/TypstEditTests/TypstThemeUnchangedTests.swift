import XCTest
@testable import TypstEdit
import CodeEditLanguages

/// The code palette must not leak into Typst or Markdown documents. These
/// assert the exact relationships the old theme had, so the editor's
/// established look is preserved while code files get their own colors.
final class TypstThemeUnchangedTests: XCTestCase {

    @MainActor
    private func controller(for name: String) -> EditorController {
        let controller = EditorController()
        controller.currentFileURL = URL(fileURLWithPath: "/tmp/project/\(name)")
        return controller
    }

    @MainActor
    func testTypstPaletteIsPurpleForward() {
        let theme = controller(for: "doc.typ").customTheme
        // Typst keywords were purple, types blue, variables purple, and
        // functions matched variables (no separate function color).
        XCTAssertEqual(theme.keywords.color, theme.variables.color)
        XCTAssertEqual(theme.functions.color, theme.variables.color)
        XCTAssertNotEqual(theme.types.color, theme.keywords.color)
    }

    @MainActor
    func testMarkdownPaletteIsUnchanged() {
        let theme = controller(for: "README.md").customTheme
        // Markdown keywords were blue, types orange, variables yellow, and
        // functions still read like variables.
        XCTAssertEqual(theme.functions.color, theme.variables.color)
        XCTAssertNotEqual(theme.keywords.color, theme.variables.color)
    }

    @MainActor
    func testCodePaletteSeparatesFunctionsFromVariables() {
        let theme = controller(for: "main.py").customTheme
        XCTAssertNotEqual(
            theme.functions.color,
            theme.variables.color,
            "in code, a function call should stand out from surrounding variables"
        )
    }
}
