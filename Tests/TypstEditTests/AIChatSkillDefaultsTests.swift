import XCTest
@testable import TypstEdit

/// Per-skill "on by default" settings: new AI chat sessions start with the
/// skills the user ticked in Settings → AI Assistant → Skills, and stale IDs
/// (deleted skills) are dropped at seed time rather than at write time.
@MainActor
final class AIChatSkillDefaultsTests: XCTestCase {

    // MARK: - filteredDefaultSkillIDs (pure)

    private func makeSkill(_ folderName: String, scope: ConfigScope) -> AISkill {
        AISkill(
            folderName: folderName,
            name: folderName,
            description: "",
            body: "",
            scope: scope,
            // Never read: `id` only needs scope + folderName.
            folderURL: URL(fileURLWithPath: "/nonexistent/\(scope.rawValue)/\(folderName)")
        )
    }

    func testFilteredDefaultsEmptyWhenNoDefaults() {
        let available = [makeSkill("a", scope: .global), makeSkill("b", scope: .builtin)]
        XCTAssertEqual(AIChatManager.filteredDefaultSkillIDs([], available: available), [])
    }

    func testFilteredDefaultsKeepOnlyAvailableSkills() {
        let available = [
            makeSkill("resume", scope: .global),
            makeSkill("typst-reference", scope: .builtin),
        ]
        let defaults = ["global:resume", "global:deleted-skill", "builtin:typst-reference", "project:gone"]
        XCTAssertEqual(
            AIChatManager.filteredDefaultSkillIDs(defaults, available: available),
            ["global:resume", "builtin:typst-reference"]
        )
    }

    func testFilteredDefaultsDeduplicate() {
        let available = [makeSkill("resume", scope: .global)]
        XCTAssertEqual(
            AIChatManager.filteredDefaultSkillIDs(["global:resume", "global:resume"], available: available),
            ["global:resume"]
        )
    }

    func testFilteredDefaultsEmptyWhenNoSkillsAvailable() {
        XCTAssertEqual(
            AIChatManager.filteredDefaultSkillIDs(["global:resume"], available: []),
            []
        )
    }

    // MARK: - Settings persistence

    func testChatDefaultSkillIDsRoundTrip() {
        let settings = AISettingsManager.shared
        let original = settings.chatDefaultSkillIDs
        defer { settings.chatDefaultSkillIDs = original }

        settings.chatDefaultSkillIDs = []
        XCTAssertEqual(settings.chatDefaultSkillIDs, [])

        // Order is the user's tick order and must survive the round trip.
        settings.chatDefaultSkillIDs = ["global:resume", "project:notes", "builtin:typst-reference"]
        XCTAssertEqual(
            settings.chatDefaultSkillIDs,
            ["global:resume", "project:notes", "builtin:typst-reference"]
        )
    }

    // MARK: - Seeding against the live skill list

    func testDefaultSkillIDsIntersectsAvailableSkills() {
        let settings = AISettingsManager.shared
        let original = settings.chatDefaultSkillIDs
        defer { settings.chatDefaultSkillIDs = original }

        let liveIDs = Set(SkillsManager.shared.allSkills.map(\.id))
        // A stale ID no skill has (UUID makes collision impossible).
        let staleID = "global:deleted-skill-\(UUID().uuidString)"
        settings.chatDefaultSkillIDs = Array(liveIDs) + [staleID]

        XCTAssertEqual(
            AIChatManager.shared.defaultSkillIDs(),
            liveIDs,
            "every currently available skill must be kept and the stale ID dropped"
        )
    }
}
