import XCTest
@testable import TypstEdit

/// The batch patch format: parsing the model's text into operations, and
/// applying hunks without touching a file when anything fails to match.
final class BatchPatchTests: XCTestCase {

    // MARK: - Parsing

    func testParsesAddUpdateAndDelete() throws {
        let patch = """
        *** Begin Patch
        *** Add File: chapters/new.typ
        += New chapter
        +Body text.
        *** Update File: main.typ
        @@ = Contents
         = Contents
        -old line
        +new line
        *** Delete File: obsolete.typ
        *** End Patch
        """
        let operations = try BatchPatch.parse(patch)
        XCTAssertEqual(operations.count, 3)
        XCTAssertEqual(operations[0], .add(path: "chapters/new.typ", content: "= New chapter\nBody text."))
        XCTAssertEqual(operations[1].path, "main.typ")
        XCTAssertEqual(operations[2], .delete(path: "obsolete.typ"))
    }

    func testParsesMoveTo() throws {
        let patch = """
        *** Begin Patch
        *** Update File: old-name.typ
        *** Move to: new-name.typ
         kept
        -gone
        +added
        *** End Patch
        """
        let operations = try BatchPatch.parse(patch)
        guard case .update(let path, let moveTo, let hunks) = operations[0] else {
            return XCTFail("expected an update, got \(operations[0])")
        }
        XCTAssertEqual(path, "old-name.typ")
        XCTAssertEqual(moveTo, "new-name.typ")
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].oldLines, ["kept", "gone"])
        XCTAssertEqual(hunks[0].newLines, ["kept", "added"])
    }

    func testMultipleHunksInOneFile() throws {
        let patch = """
        *** Begin Patch
        *** Update File: doc.typ
        @@ first
         a
        -b
        +B
        @@ second
         c
        -d
        +D
        *** End Patch
        """
        let operations = try BatchPatch.parse(patch)
        guard case .update(_, _, let hunks) = operations[0] else {
            return XCTFail("expected an update")
        }
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].context, "first")
        XCTAssertEqual(hunks[1].context, "second")
    }

    func testPreambleBeforeBeginIsTolerated() throws {
        // Models often add a sentence of explanation before the patch.
        let patch = """
        Here is the restructure you asked for:
        *** Begin Patch
        *** Delete File: x.typ
        *** End Patch
        """
        XCTAssertEqual(try BatchPatch.parse(patch).count, 1)
    }

    func testMissingBeginOrEndIsAnError() {
        XCTAssertThrowsError(try BatchPatch.parse("*** Delete File: x.typ\n*** End Patch")) { error in
            XCTAssertEqual(error as? BatchPatch.PatchError, .missingBegin)
        }
        XCTAssertThrowsError(try BatchPatch.parse("*** Begin Patch\n*** Delete File: x.typ")) { error in
            XCTAssertEqual(error as? BatchPatch.PatchError, .missingEnd)
        }
    }

    func testEmptyPatchIsAnError() {
        XCTAssertThrowsError(try BatchPatch.parse("*** Begin Patch\n*** End Patch")) { error in
            XCTAssertEqual(error as? BatchPatch.PatchError, .empty)
        }
    }

    func testAddWithoutContentIsRefused() {
        let patch = """
        *** Begin Patch
        *** Add File: empty.typ
        *** End Patch
        """
        XCTAssertThrowsError(try BatchPatch.parse(patch)) { error in
            XCTAssertEqual(error as? BatchPatch.PatchError, .addWithoutContent("empty.typ"))
        }
    }

    func testUpdateWithoutHunksIsRefused() {
        let patch = """
        *** Begin Patch
        *** Update File: doc.typ
        *** End Patch
        """
        XCTAssertThrowsError(try BatchPatch.parse(patch)) { error in
            XCTAssertEqual(error as? BatchPatch.PatchError, .updateWithoutHunks("doc.typ"))
        }
    }

    func testDuplicatePathsAreRefused() {
        // Two blocks for one file would apply in an order the model probably
        // did not intend, so it is refused rather than guessed at.
        let patch = """
        *** Begin Patch
        *** Update File: doc.typ
         a
        -b
        +c
        *** Update File: doc.typ
         x
        -y
        +z
        *** End Patch
        """
        XCTAssertThrowsError(try BatchPatch.parse(patch)) { error in
            XCTAssertEqual(error as? BatchPatch.PatchError, .duplicatePath("doc.typ"))
        }
    }

    func testContentOutsideAFileBlockIsRefused() {
        let patch = """
        *** Begin Patch
        this line belongs to nothing
        *** End Patch
        """
        XCTAssertThrowsError(try BatchPatch.parse(patch))
    }

    func testCRLFPatchParsesTheSameWay() throws {
        let patch = "*** Begin Patch\r\n*** Delete File: x.typ\r\n*** End Patch\r\n"
        XCTAssertEqual(try BatchPatch.parse(patch), [.delete(path: "x.typ")])
    }

    // MARK: - Applying

    private func hunk(_ lines: [BatchPatch.Line]) -> BatchPatch.Hunk {
        BatchPatch.Hunk(context: nil, lines: lines)
    }

    func testAppliesASimpleReplacement() throws {
        let content = "one\ntwo\nthree\n"
        let patch = hunk([
            .init(kind: .context, text: "one"),
            .init(kind: .removed, text: "two"),
            .init(kind: .added, text: "TWO"),
        ])
        XCTAssertEqual(try BatchPatch.apply(hunks: [patch], to: content, path: "doc.typ"), "one\nTWO\nthree\n")
    }

    func testPreservesTrailingNewlineState() throws {
        let patch = hunk([
            .init(kind: .removed, text: "a"),
            .init(kind: .added, text: "b"),
        ])
        // With a trailing newline.
        XCTAssertEqual(try BatchPatch.apply(hunks: [patch], to: "a\n", path: "d"), "b\n")
        // Without one.
        XCTAssertEqual(try BatchPatch.apply(hunks: [patch], to: "a", path: "d"), "b")
    }

    func testRefusesAHunkThatMatchesNothing() {
        let patch = hunk([
            .init(kind: .context, text: "not present"),
            .init(kind: .added, text: "x"),
        ])
        XCTAssertThrowsError(try BatchPatch.apply(hunks: [patch], to: "one\ntwo\n", path: "doc.typ"))
    }

    func testRefusesAnAmbiguousHunk() {
        // Patching the wrong one of two identical paragraphs is worse than
        // asking for more context.
        let patch = hunk([
            .init(kind: .context, text: "same"),
            .init(kind: .added, text: "x"),
        ])
        XCTAssertThrowsError(
            try BatchPatch.apply(hunks: [patch], to: "same\nmiddle\nsame\n", path: "doc.typ")
        ) { error in
            guard case .ambiguous(_, _, let count)? = error as? BatchPatch.PatchError else {
                return XCTFail("expected .ambiguous, got \(error)")
            }
            XCTAssertEqual(count, 2)
        }
    }

    func testRefusesAHunkWithNoContextLines() {
        let patch = hunk([.init(kind: .added, text: "x")])
        XCTAssertThrowsError(try BatchPatch.apply(hunks: [patch], to: "one\n", path: "doc.typ")) { error in
            XCTAssertEqual(error as? BatchPatch.PatchError, .unanchoredHunk("doc.typ"))
        }
    }

    func testMatchingIgnoresTrailingWhitespaceAndTypographicVariants() throws {
        // The model copied a line out of rendered text: curly dash, extra
        // trailing space.
        let content = "the editor said \"no\" - clearly  \nsecond\n"
        let patch = hunk([
            .init(kind: .context, text: "the editor said \u{201C}no\u{201D} \u{2014} clearly"),
            .init(kind: .added, text: "inserted"),
        ])
        XCTAssertEqual(
            try BatchPatch.apply(hunks: [patch], to: content, path: "doc.typ"),
            "the editor said \u{201C}no\u{201D} \u{2014} clearly\ninserted\nsecond\n"
        )
    }

    func testSecondHunkAppliesAfterTheFirstChangesLineCount() throws {
        // Applying to a stale line list would shift the second hunk's target.
        let content = "a\nb\nc\nd\n"
        let first = hunk([
            .init(kind: .context, text: "a"),
            .init(kind: .added, text: "inserted"),
        ])
        let second = hunk([
            .init(kind: .context, text: "c"),
            .init(kind: .removed, text: "d"),
            .init(kind: .added, text: "D"),
        ])
        XCTAssertEqual(
            try BatchPatch.apply(hunks: [first, second], to: content, path: "doc.typ"),
            "a\ninserted\nb\nc\nD\n"
        )
    }

    func testAppliedHunksAreCheckedAgainstTheRunningText() {
        // The first hunk removes the only match for the second, so the second
        // must be reported as not found rather than silently skipped.
        let content = "keep\ndrop\n"
        let first = hunk([
            .init(kind: .removed, text: "drop"),
        ])
        let second = hunk([
            .init(kind: .context, text: "drop"),
            .init(kind: .added, text: "x"),
        ])
        XCTAssertThrowsError(try BatchPatch.apply(hunks: [first, second], to: content, path: "doc.typ"))
    }

    // MARK: - Result text

    func testResultTextListsEachFileWithItsLetter() {
        let text = BatchPatch.resultText([
            PatchChange(path: "added.typ", oldContent: "", newContent: "x", kind: .added),
            PatchChange(path: "changed.typ", oldContent: "a", newContent: "b", kind: .modified),
            PatchChange(path: "gone.typ", oldContent: "a", newContent: "", kind: .deleted),
            PatchChange(path: "moved.typ", oldContent: "a", newContent: "b", kind: .moved, fromPath: "old.typ"),
        ])
        XCTAssertTrue(text.contains("A added.typ"), text)
        XCTAssertTrue(text.contains("M changed.typ"), text)
        XCTAssertTrue(text.contains("D gone.typ"), text)
        XCTAssertTrue(text.contains("M moved.typ"), text)
    }
}
