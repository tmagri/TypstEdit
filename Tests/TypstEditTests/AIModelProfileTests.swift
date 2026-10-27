import XCTest
@testable import TypstEdit

/// Saved models (Settings → AI Assistant → Chat & Actions → Saved Models) and
/// the per-feature model choice used by AI Chat, AI Prompt, and Refine.
@MainActor
final class AIModelProfileTests: XCTestCase {

    // MARK: - Encoding (pure)

    func testProfilesRoundTrip() {
        let profiles = [
            AIModelProfile(name: "Fast", source: .openAI, model: "gpt-4o-mini", reasoningEffort: .low),
            AIModelProfile(source: .local, model: "llama3", endpoint: "http://localhost:1234/v1/chat/completions"),
        ]
        let raw = AISettingsManager.encodeProfiles(profiles)
        XCTAssertEqual(AISettingsManager.decodeProfiles(raw), profiles)
    }

    func testEmptyRawDecodesToEmptyList() {
        XCTAssertEqual(AISettingsManager.decodeProfiles(""), [])
        XCTAssertEqual(AISettingsManager.encodeProfiles([]), "")
    }

    func testUnknownSourceAndEffortFallBackInsteadOfDroppingTheList() {
        let id = UUID()
        let raw = """
        [{"id":"\(id.uuidString)","name":"x","source":"Some Future Provider","model":"m","endpoint":"e","reasoningEffort":"ultra"}]
        """
        let decoded = AISettingsManager.decodeProfiles(raw)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.id, id)
        XCTAssertEqual(decoded.first?.source, .openAI)
        XCTAssertEqual(decoded.first?.reasoningEffort, .auto)
        XCTAssertEqual(decoded.first?.model, "m")
    }

    func testDisplayNamePrefersFriendlyName() {
        XCTAssertEqual(AIModelProfile(name: "  Drafts ", model: "gpt-4o").displayName, "Drafts")
        XCTAssertEqual(AIModelProfile(name: "", model: " gpt-4o ").displayName, "gpt-4o")
        XCTAssertEqual(AIModelProfile().displayName, "Untitled model")
    }

    // MARK: - Settings resolution

    private func withCleanProfiles(_ body: (AISettingsManager) -> Void) {
        let settings = AISettingsManager.shared
        let originalProfiles = settings.modelProfiles
        let originalChoices = AIFeature.allCases.map { settings.modelProfileID(for: $0) }
        defer {
            settings.modelProfiles = originalProfiles
            for (feature, id) in zip(AIFeature.allCases, originalChoices) {
                settings.setModelProfileID(id, for: feature)
            }
        }
        settings.modelProfiles = []
        for feature in AIFeature.allCases { settings.setModelProfileID(nil, for: feature) }
        body(settings)
    }

    func testFeatureUsesDefaultModelWithoutAChoice() {
        withCleanProfiles { settings in
            let ctx = settings.modelContext(for: .chat)
            let defaultCtx = settings.modelContext(for: .generation)
            XCTAssertEqual(ctx.model, defaultCtx.model)
            XCTAssertEqual(ctx.source, defaultCtx.source)
        }
    }

    func testFeatureUsesChosenProfile() {
        withCleanProfiles { settings in
            var profile = settings.addModelProfile()
            profile.source = .anthropic
            profile.model = " claude-test "
            profile.reasoningEffort = .high
            settings.updateModelProfile(profile)

            settings.setModelProfileID(profile.id, for: .prompt)

            let ctx = settings.modelContext(for: .prompt)
            XCTAssertEqual(ctx.source, .anthropic)
            XCTAssertEqual(ctx.model, "claude-test")
            XCTAssertEqual(ctx.reasoningEffort, .high)
            XCTAssertEqual(ctx.apiKey, settings.apiKey(for: .anthropic))

            // Other features are untouched.
            XCTAssertNil(settings.modelProfileID(for: .chat))
            XCTAssertEqual(settings.modelContext(for: .chat).model, settings.modelContext(for: .generation).model)
        }
    }

    func testRemovingAProfileResetsFeaturesToDefault() {
        withCleanProfiles { settings in
            let profile = settings.addModelProfile()
            settings.setModelProfileID(profile.id, for: .chat)
            settings.setModelProfileID(profile.id, for: .refine)
            XCTAssertEqual(settings.modelProfileID(for: .chat), profile.id)

            settings.removeModelProfile(id: profile.id)

            XCTAssertTrue(settings.modelProfiles.isEmpty)
            XCTAssertNil(settings.modelProfileID(for: .chat))
            XCTAssertNil(settings.modelProfileID(for: .refine))
        }
    }

    func testStaleChoiceResolvesToDefault() {
        withCleanProfiles { settings in
            settings.setModelProfileID(UUID(), for: .chat)
            XCTAssertNil(settings.modelProfileID(for: .chat))
            XCTAssertNil(settings.modelProfile(for: .chat))
        }
    }
}
