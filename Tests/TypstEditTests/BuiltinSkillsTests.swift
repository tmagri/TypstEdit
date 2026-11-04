import XCTest
@testable import TypstEdit

/// The typst-reference skill ships inside the app bundle and must be
/// discoverable, readable (SKILL.md + attachments), and read-only.
@MainActor
final class BuiltinSkillsTests: XCTestCase {

    func testTypstReferenceSkillIsBundledAndDiscoverable() {
        guard SkillsManager.builtinSkillsDirectory != nil else {
            XCTFail("builtinSkillsDirectory not found in this environment")
            return
        }
        let skill = ProjectContext.detached.skills.builtinSkills.first { $0.folderName == "typst-reference" }
        XCTAssertNotNil(skill, "the typst-reference skill must ship in the bundle")
        XCTAssertEqual(skill?.scope, .builtin)
        XCTAssertEqual(skill?.id, "builtin:typst-reference")
        XCTAssertEqual(skill?.name, "Typst Reference")
        XCTAssertFalse(skill?.body.isEmpty ?? true, "SKILL.md body must be non-empty")
        XCTAssertFalse(skill?.description.isEmpty ?? true, "frontmatter description must be set")
    }

    func testTypstReferenceAttachmentsAreReadable() throws {
        let skill = try XCTUnwrap(
            ProjectContext.detached.skills.builtinSkills.first { $0.folderName == "typst-reference" },
            "typst-reference skill not bundled")
        XCTAssertTrue(skill.attachments.contains("cheatsheet.md"))
        XCTAssertTrue(skill.attachments.contains("function-catalog.md"))
        XCTAssertTrue(skill.attachments.contains("styling-recipes.md"))
        // read_skill_file reads through this folder; both attachments must be
        // readable and non-trivial.
        for name in skill.attachments {
            let url = skill.folderURL.appendingPathComponent(name)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertGreaterThan(text.count, 1_000, "\(name) looks truncated")
        }
        // The catalog index must mention the calc module (sanity check that
        // the extraction actually produced content, not an empty shell).
        let catalog = try String(
            contentsOf: skill.folderURL.appendingPathComponent("function-catalog.md"),
            encoding: .utf8)
        XCTAssertTrue(catalog.contains("calc.abs"))
    }

    func testBuiltinSkillsAreNotUserManageable() throws {
        let skill = try XCTUnwrap(
            ProjectContext.detached.skills.builtinSkills.first { $0.folderName == "typst-reference" })
        XCTAssertFalse(skill.scope.isUserManageable)
        // CRUD calls on a built-in skill must be no-ops: the bundled folder
        // must still exist with its SKILL.md after every mutation attempt.
        ProjectContext.detached.skills.deleteSkill(skill)
        ProjectContext.detached.skills.updateSkill(skill, name: "x", description: "y", body: "z")
        ProjectContext.detached.skills.removeAttachment("cheatsheet.md", from: skill)
        ProjectContext.detached.skills.addAttachment(to: skill, from: skill.folderURL.appendingPathComponent("SKILL.md"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: skill.folderURL.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(skill.attachments.contains("cheatsheet.md"))
        XCTAssertEqual(ProjectContext.detached.skills.allSkills.filter { $0.scope == .builtin }.count,
                       ProjectContext.detached.skills.builtinSkills.count)
    }

    func testCreateSkillRejectsBuiltinScope() {
        let created = ProjectContext.detached.skills.createSkill(
            name: "should-not-exist", description: "", body: "",
            scope: .builtin, projectRoot: nil)
        XCTAssertNil(created, "creating a skill in the builtin scope must fail")
        XCTAssertFalse(
            ProjectContext.detached.skills.allSkills.contains { $0.name == "should-not-exist" })
    }
}
