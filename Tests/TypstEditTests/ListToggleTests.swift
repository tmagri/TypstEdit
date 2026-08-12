import XCTest
@testable import TypstEdit

final class ListToggleTests: XCTestCase {

    // MARK: - Add bullet to plain lines

    func testAddBulletToSingleLine() {
        let result = EditorController.transformListToggle(
            text: "Hello world\n",
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "- Hello world\n")
    }

    func testAddBulletToMultipleLines() {
        let input = "First line\nSecond line\nThird line\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "- First line\n- Second line\n- Third line\n")
    }

    // MARK: - Toggle off (remove prefix when all lines have it)

    func testRemoveBulletWhenAllHaveIt() {
        let input = "- First\n- Second\n- Third\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "First\nSecond\nThird\n")
    }

    // MARK: - Convert between list types

    func testConvertNumberToBullet() {
        let input = "+ First\n+ Second\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "- First\n- Second\n")
    }

    func testConvertBulletToNumber() {
        let input = "- First\n- Second\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .number,
            isMarkdown: false
        )
        XCTAssertEqual(result, "+ First\n+ Second\n")
    }

    func testConvertDescriptionToBullet() {
        let input = "/ First\n/ Second\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "- First\n- Second\n")
    }

    func testConvertBulletToDescription() {
        let input = "- First\n- Second\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .description,
            isMarkdown: false
        )
        XCTAssertEqual(result, "/ First\n/ Second\n")
    }

    // MARK: - Mixed lines (some with target, some without)

    func testMixedBulletAndPlainAddsBulletToAll() {
        let input = "- First\nSecond line\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "- First\n- Second line\n")
    }

    func testMixedNumberAndBulletConvertsAllToBullet() {
        let input = "+ First\n- Second\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "- First\n- Second\n")
    }

    func testMixedNumberBulletAndPlainConvertsAllToDescription() {
        let input = "+ First\n- Second\nPlain text\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .description,
            isMarkdown: false
        )
        XCTAssertEqual(result, "/ First\n/ Second\n/ Plain text\n")
    }

    // MARK: - Markdown syntax

    func testMarkdownBulletUsesDash() {
        let result = EditorController.transformListToggle(
            text: "Hello\n",
            type: .bullet,
            isMarkdown: true
        )
        XCTAssertEqual(result, "- Hello\n")
    }

    func testMarkdownNumberUsesOneDot() {
        let result = EditorController.transformListToggle(
            text: "Hello\n",
            type: .number,
            isMarkdown: true
        )
        XCTAssertEqual(result, "1. Hello\n")
    }

    func testMarkdownConvertBulletToNumber() {
        let input = "- First\n- Second\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .number,
            isMarkdown: true
        )
        XCTAssertEqual(result, "1. First\n1. Second\n")
    }

    func testMarkdownConvertNumberToBullet() {
        let input = "1. First\n2. Second\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: true
        )
        XCTAssertEqual(result, "- First\n- Second\n")
    }

    // MARK: - Indented lines (preserve leading whitespace)

    func testAddBulletToIndentedLine() {
        let result = EditorController.transformListToggle(
            text: "  Indented item\n",
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "  - Indented item\n")
    }

    func testConvertIndentedNumberToBullet() {
        let input = "  + Item one\n  + Item two\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "  - Item one\n  - Item two\n")
    }

    func testRemoveBulletFromIndentedLine() {
        let input = "  - Indented item\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "  Indented item\n")
    }

    func testMixedIndentedAndNonIndentedLines() {
        let input = "Top level\n  Indented\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "- Top level\n  - Indented\n")
    }

    // MARK: - Blank lines

    func testBlankLinesBetweenItemsPreserved() {
        let input = "- First\n\n- Second\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .number,
            isMarkdown: false
        )
        XCTAssertEqual(result, "+ First\n\n+ Second\n")
    }

    func testBlankListItemsConvertedDuringTypeChange() {
        let input = "- First\n- \n- Second\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .number,
            isMarkdown: false
        )
        XCTAssertEqual(result, "+ First\n+ \n+ Second\n")
    }

    func testBlankListItemsRemovedOnToggleOff() {
        let input = "- First\n- \n- Second\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "First\n\nSecond\n")
    }

    // MARK: - Heading prefix preservation

    func testHeadingPrefixPreservedWhenAddingBullet() {
        let input = "== Heading\nPlain text\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "== - Heading\n- Plain text\n")
    }

    // MARK: - Asterisk as bullet

    func testAsteriskBulletTreatedAsBulletToggleOff() {
        // * matches the bullet target pattern [-*], so toggling bullet on all-* lines
        // treats them as already having the target prefix → toggle off (remove prefix).
        let input = "* First\n* Second\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "First\nSecond\n")
    }

    func testAsteriskBulletConvertedWhenMixedWithPlain() {
        // When not all lines have the target prefix, the prefix is applied to all lines.
        let input = "* First\nPlain text\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "- First\n- Plain text\n")
    }

    // MARK: - Edge cases

    func testAllBlankLinesReturnsOriginal() {
        let input = "\n\n\n"
        let result = EditorController.transformListToggle(
            text: input,
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, input)
    }

    func testNoTrailingNewline() {
        let result = EditorController.transformListToggle(
            text: "Hello world",
            type: .bullet,
            isMarkdown: false
        )
        XCTAssertEqual(result, "- Hello world")
    }
}
