import XCTest
@testable import TypstEdit

@MainActor
final class SkillInstallerTests: XCTestCase {
    func testParsesRepositoryAndTreeLinks() throws {
        let repository = try SkillInstaller.parseSource("owner/repo")
        XCTAssertEqual(repository.repository, "owner/repo")
        XCTAssertNil(repository.subpath)

        let tree = try SkillInstaller.parseSource(
            "https://github.com/owner/repo/tree/main/skills/example"
        )
        XCTAssertEqual(tree.repository, "owner/repo")
        XCTAssertEqual(tree.branch, "main")
        XCTAssertEqual(tree.subpath, "skills/example")
    }

    func testParsesNpxCommandAndSkillFilter() throws {
        let source = try SkillInstaller.parseSource(
            "npx -y skills add owner/repo --skill example"
        )
        XCTAssertEqual(source.repository, "owner/repo")
        XCTAssertEqual(source.skillName, "example")
    }

    func testParsesGitHubArchiveZipWithoutFollowingItsCrossHostRedirect() throws {
        let source = try SkillInstaller.parseSource(
            "https://github.com/owner/repo/archive/refs/heads/main.zip"
        )
        XCTAssertEqual(
            source.archiveURL?.absoluteString,
            "https://codeload.github.com/owner/repo/zip/refs/heads/main"
        )
    }

    func testRejectsUnsupportedRemoteHostAndMalformedInput() {
        XCTAssertThrowsError(try SkillInstaller.parseSource("https://example.com/owner/repo"))
        XCTAssertThrowsError(try SkillInstaller.parseSource(""))
        XCTAssertThrowsError(try SkillInstaller.parseSource("not a source"))
    }

    func testDiscoversSkillAndFiltersByNameAndSubpath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typstedit-skills-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("skills/example", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try """
        ---
        name: 'Example'
        description: |
          A test skill
          with multiline description
        ---
        Instructions.
        """.write(
            to: skill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Reference".write(
            to: skill.appendingPathComponent("reference.md"),
            atomically: true,
            encoding: .utf8
        )

        let found = try SkillInstaller.discoverSkills(in: root, subpath: "skills", skillName: "Example")
        XCTAssertEqual(found.map(\.name), ["Example"])
        XCTAssertEqual(found.first?.description, "A test skill\nwith multiline description")
        XCTAssertEqual(found.first?.attachmentCount, 1)
    }

    func testInstallsLocalSkillIntoProjectScope() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typstedit-skill-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/my-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try """
        ---
        name: "My Skill"
        description: "Installed locally"
        ---
        Use this style.
        """.write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "Reference text".write(
            to: source.appendingPathComponent("reference.md"),
            atomically: true,
            encoding: .utf8
        )

        let manager = SkillsManager()
        manager.setProjectRoot(root)
        let installed = try await SkillInstaller.install(
            from: source.deletingLastPathComponent().path,
            scope: .project,
            projectRoot: root,
            manager: manager,
            progress: { _ in }
        )

        XCTAssertEqual(installed.map(\.name), ["My Skill"])
        XCTAssertEqual(manager.projectSkills.map(\.name), ["My Skill"])
        XCTAssertTrue(manager.projectSkills[0].attachments.contains("reference.md"))
    }
}
