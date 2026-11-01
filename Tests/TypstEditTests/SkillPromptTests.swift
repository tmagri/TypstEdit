import XCTest
@testable import TypstEdit

/// Deciding how much of each enabled skill goes into the system prompt: a
/// short skill is inlined, a large reference pack is listed and loaded through
/// `read_skill` on demand.
final class SkillPromptTests: XCTestCase {

    // MARK: - The split

    func testShortSkillIsInlined() {
        let split = SkillPrompt.split([(id: "global:house-style", body: "Use sentence case.")])
        XCTAssertEqual(split.inlined, ["global:house-style"])
        XCTAssertTrue(split.deferred.isEmpty)
    }

    func testLongSkillIsDeferred() {
        // The bundled typst-reference body is a few KB; a reference pack of
        // this size must not be written into every prompt.
        let body = String(repeating: "x", count: SkillPrompt.inlineBodyLimit + 1)
        let split = SkillPrompt.split([(id: "builtin:typst-reference", body: body)])
        XCTAssertTrue(split.inlined.isEmpty)
        XCTAssertEqual(split.deferred, ["builtin:typst-reference"])
    }

    func testTheBoundaryItselfIsInlined() {
        // Exactly at the limit still goes in: the test is "no larger than".
        let body = String(repeating: "x", count: SkillPrompt.inlineBodyLimit)
        let split = SkillPrompt.split([(id: "a", body: body)])
        XCTAssertEqual(split.inlined, ["a"])
    }

    func testASetOfSkillsIsSplitBothWays() {
        let split = SkillPrompt.split([
            (id: "small", body: "short"),
            (id: "big", body: String(repeating: "y", count: SkillPrompt.inlineBodyLimit + 10))
        ])
        XCTAssertEqual(split.inlined, ["small"])
        XCTAssertEqual(split.deferred, ["big"])
    }

    func testNoSkillsProducesAnEmptySplit() {
        XCTAssertTrue(SkillPrompt.split([]).isEmpty)
    }

    // MARK: - Rendering the block

    func testInlinedSkillCarriesItsIdAndBody() {
        let skill = makeSkill(id: "global:style", name: "House Style", body: "Use sentence case.")
        let block = SkillPrompt.block(skills: [skill], readable: true)
        XCTAssertEqual(block?.contains("global:style"), true)
        XCTAssertEqual(block?.contains("Use sentence case."), true)
        XCTAssertEqual(block?.contains("House Style"), true)
    }

    func testDeferredSkillIsListedWithoutItsBody() {
        let body = "SECRET BODY " + String(repeating: "z", count: SkillPrompt.inlineBodyLimit + 10)
        let skill = makeSkill(id: "builtin:typst-reference", name: "Typst Reference", body: body)
        let block = try? XCTUnwrap(SkillPrompt.block(skills: [skill], readable: true))

        XCTAssertEqual(block?.contains("SECRET BODY"), false, "a deferred body must not be inlined")
        XCTAssertEqual(block?.contains("builtin:typst-reference"), true)
        XCTAssertEqual(block?.contains("Typst Reference"), true)
        XCTAssertEqual(block?.contains("read_skill"), true)
    }

    func testDeferredListingSaysWhenItCannotBeLoaded() {
        // Without the read_skill tool the listing must not promise it.
        let body = String(repeating: "z", count: SkillPrompt.inlineBodyLimit + 10)
        let skill = makeSkill(id: "builtin:x", name: "X", body: body)
        let block = SkillPrompt.block(skills: [skill], readable: false)
        XCTAssertEqual(block?.contains("cannot be loaded"), true)
        XCTAssertEqual(block?.contains("Call read_skill"), false)
    }

    func testAttachmentFilesAreNamedSoTheyCanBeRead() {
        let skill = makeSkill(id: "builtin:x", name: "X", body: "short")
        let block = SkillPrompt.block(
            skills: [skill],
            readable: true,
            attachmentFiles: ["builtin:x": ["cheatsheet.md", "recipes.md"]]
        )
        XCTAssertEqual(block?.contains("cheatsheet.md"), true)
        XCTAssertEqual(block?.contains("read_skill_file"), true)
    }

    func testNoSkillsRendersNothing() {
        XCTAssertNil(SkillPrompt.block(skills: [], readable: true))
    }

    // MARK: - The loaded body

    func testLoadedBodyIsWrappedWithItsBaseDirectory() {
        let text = SkillPrompt.loadedBody(
            name: "Typst Reference",
            id: "builtin:typst-reference",
            body: "Use `#set page(..)`.",
            directory: URL(fileURLWithPath: "/skills/typst-reference"),
            files: ["cheatsheet.md"]
        )
        XCTAssertTrue(text.contains("<skill_content"), text)
        XCTAssertTrue(text.contains("builtin:typst-reference"), text)
        XCTAssertTrue(text.contains("Use `#set page(..)`."), text)
        // Relative paths in a skill only resolve against its own folder, so
        // the folder has to be stated.
        XCTAssertTrue(text.contains("/skills/typst-reference"), text)
        XCTAssertTrue(text.contains("<file>cheatsheet.md</file>"), text)
    }

    func testLoadedBodySamplesAtMostTenFiles() {
        let files = (1...25).map { "file\($0).md" }
        let text = SkillPrompt.loadedBody(
            name: "X", id: "x", body: "b",
            directory: URL(fileURLWithPath: "/skills/x"),
            files: files
        )
        XCTAssertTrue(text.contains("file10.md"))
        XCTAssertFalse(text.contains("file11.md"))
    }

    // MARK: - Helpers

    /// Builds a skill whose `id` matches `id` exactly — the prefix selects the
    /// scope, since `AISkill.id` is `"<scope>:<folderName>"`.
    private func makeSkill(id: String, name: String, body: String) -> AISkill {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        let scope = ConfigScope(rawValue: parts.first ?? "global") ?? .global
        let folderName = parts.count > 1 ? parts[1] : id
        return AISkill(
            folderName: folderName,
            name: name,
            description: "desc",
            body: body,
            scope: scope,
            folderURL: URL(fileURLWithPath: "/skills/\(name)")
        )
    }
}
