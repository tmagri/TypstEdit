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
            settings.setModelProfileID(profile.id, for: .calculator)
            XCTAssertEqual(settings.modelProfileID(for: .chat), profile.id)
            XCTAssertEqual(settings.modelProfileID(for: .calculator), profile.id)

            settings.removeModelProfile(id: profile.id)

            XCTAssertTrue(settings.modelProfiles.isEmpty)
            XCTAssertNil(settings.modelProfileID(for: .chat))
            XCTAssertNil(settings.modelProfileID(for: .refine))
            XCTAssertNil(settings.modelProfileID(for: .calculator))
        }
    }

    /// The calculator's AI fallback has its own model choice, independent of
    /// the chat model.
    func testCalculatorFallbackUsesItsOwnModel() {
        withCleanProfiles { settings in
            var profile = settings.addModelProfile()
            profile.source = .openAI
            profile.model = "calculator-test"
            settings.updateModelProfile(profile)

            // With no choice it follows the default Chat & Actions model.
            XCTAssertNil(settings.modelProfileID(for: .calculator))
            XCTAssertEqual(settings.modelContext(for: .calculator).model,
                           settings.modelContext(for: .generation).model)

            settings.setModelProfileID(profile.id, for: .calculator)
            XCTAssertEqual(settings.modelContext(for: .calculator).model, "calculator-test")
            XCTAssertEqual(settings.activeModelShortName(for: .calculator), "calculator-test")

            // Picking one for the calculator leaves chat alone.
            XCTAssertNil(settings.modelProfileID(for: .chat))
            XCTAssertEqual(settings.modelContext(for: .chat).model,
                           settings.modelContext(for: .generation).model)
        }
    }

    // MARK: - Per-model compaction

    func testAutomaticCompactionPicksBySource() {
        XCTAssertEqual(ChatCompressionMethod.automatic.resolved(isLocal: false), .llmSummary, "paid/cloud models summarize well")
        XCTAssertEqual(ChatCompressionMethod.automatic.resolved(isLocal: true), .llmlingua2, "local models get verbatim filtering")
        for method in [ChatCompressionMethod.llmSummary, .tokenFilter, .llmlingua2] {
            XCTAssertEqual(method.resolved(isLocal: true), method)
            XCTAssertEqual(method.resolved(isLocal: false), method)
        }
    }

    func testOlderSavedModelsWithoutCompactionFollowTheGlobalSetting() {
        let raw = """
        [{"id":"\(UUID().uuidString)","name":"","source":"OpenAI","model":"gpt-4o","endpoint":"","reasoningEffort":"auto"}]
        """
        XCTAssertNil(AISettingsManager.decodeProfiles(raw).first?.compressionMethod)
    }

    func testCompactionOverrideSurvivesEncoding() {
        let profile = AIModelProfile(source: .local, model: "llama3", compressionMethod: .tokenFilter)
        let decoded = AISettingsManager.decodeProfiles(AISettingsManager.encodeProfiles([profile]))
        XCTAssertEqual(decoded.first?.compressionMethod, .tokenFilter)
    }

    func testEffectiveCompressionMethodForModels() {
        let settings = AISettingsManager.shared
        let original = settings.chatCompressionMethod
        defer { settings.chatCompressionMethod = original }

        let cloud = AIModelProfile(source: .anthropic, model: "claude")
        let local = AIModelProfile(source: .local, model: "llama3")
        let pinned = AIModelProfile(source: .openAI, model: "gpt-4o-mini", compressionMethod: .tokenFilter)
        let pinnedAuto = AIModelProfile(source: .local, model: "qwen", compressionMethod: .automatic)

        settings.chatCompressionMethod = .automatic
        XCTAssertEqual(settings.effectiveCompressionMethod(for: settings.modelContext(for: cloud)), .llmSummary)
        XCTAssertEqual(settings.effectiveCompressionMethod(for: settings.modelContext(for: local)), .llmlingua2)
        XCTAssertEqual(settings.effectiveCompressionMethod(for: settings.modelContext(for: pinned)), .tokenFilter, "a saved-model override wins")

        settings.chatCompressionMethod = .llmSummary
        XCTAssertEqual(settings.effectiveCompressionMethod(for: settings.modelContext(for: local)), .llmSummary, "no override → global setting")
        XCTAssertEqual(settings.effectiveCompressionMethod(for: settings.modelContext(for: pinnedAuto)), .llmlingua2, "a per-model Automatic resolves by source")

        let portkey = AIModelProfile(source: .portkey, model: "@openai-prod/gpt-4o", compressionMethod: .tokenFilter)
        XCTAssertEqual(settings.effectiveCompressionMethod(for: settings.modelContext(for: portkey)), .tokenFilter, "Portkey models keep their override")
    }

    func testStaleChoiceResolvesToDefault() {
        withCleanProfiles { settings in
            settings.setModelProfileID(UUID(), for: .chat)
            XCTAssertNil(settings.modelProfileID(for: .chat))
            XCTAssertNil(settings.modelProfile(for: .chat))
        }
    }

    // MARK: - Per-model API keys

    func testSavedModelFallsBackToTheSharedProviderKey() {
        let settings = AISettingsManager.shared
        let saved = (settings.customApiKey, settings.openAIApiKey)
        defer {
            settings.customApiKey = saved.0
            settings.openAIApiKey = saved.1
        }
        settings.customApiKey = "shared-local"
        settings.openAIApiKey = "shared-openai"

        let local = AIModelProfile(source: .local, model: "llama3", endpoint: "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(settings.modelContext(for: local).apiKey, "shared-local")

        let cloud = AIModelProfile(source: .openAI, model: "gpt-4o-mini")
        XCTAssertEqual(settings.modelContext(for: cloud).apiKey, "shared-openai")
    }

    /// Two local servers behind the same `.local` source can each need their
    /// own token; the saved model's key must win over the shared one.
    func testSavedModelOwnKeyWins() {
        let settings = AISettingsManager.shared
        let saved = settings.customApiKey
        defer { settings.customApiKey = saved }
        settings.customApiKey = "shared-local"

        let profile = AIModelProfile(
            source: .local,
            model: "llama3",
            endpoint: "http://localhost:1234/v1/chat/completions",
            apiKey: " second-server "
        )
        let ctx = settings.modelContext(for: profile)
        XCTAssertEqual(ctx.apiKey, "second-server")
        XCTAssertEqual(ctx.authHeaders["Authorization"], "Bearer second-server")
        XCTAssertEqual(ctx.chatEndpoint, "http://localhost:1234/v1/chat/completions")
    }

    func testFeatureUsesItsSavedModelKey() {
        withCleanProfiles { settings in
            var profile = settings.addModelProfile()
            profile.source = .local
            profile.model = "llama3"
            profile.endpoint = "http://localhost:1234/v1/chat/completions"
            profile.apiKey = "chat-only-key"
            settings.updateModelProfile(profile)
            settings.setModelProfileID(profile.id, for: .chat)

            XCTAssertEqual(settings.modelContext(for: .chat).apiKey, "chat-only-key")
        }
    }

    func testOlderSavedModelsWithoutAKeyUseTheSharedKey() {
        let raw = """
        [{"id":"\(UUID().uuidString)","name":"","source":"Local (Ollama/LMStudio)","model":"llama3","endpoint":"http://localhost:11434/v1/chat/completions","reasoningEffort":"auto"}]
        """
        let decoded = AISettingsManager.decodeProfiles(raw)
        XCTAssertEqual(decoded.first?.apiKey, "")
    }

    func testModelKeySurvivesEncoding() {
        let profile = AIModelProfile(
            source: .local,
            model: "llama3",
            endpoint: "http://localhost:1234/v1/chat/completions",
            apiKey: "secret"
        )
        let decoded = AISettingsManager.decodeProfiles(AISettingsManager.encodeProfiles([profile]))
        XCTAssertEqual(decoded.first?.apiKey, "secret")
    }

    // MARK: - Per-task local API keys

    /// Autocomplete and embeddings often run on different local servers than
    /// chat, so each task can override the shared Local Server key.
    func testCompletionAndEmbeddingLocalKeysOverrideTheSharedKey() {
        let settings = AISettingsManager.shared
        let saved = (
            settings.customApiKey,
            settings.completionApiKey,
            settings.embeddingApiKey,
            settings.source(for: .generation),
            settings.source(for: .completion),
            settings.source(for: .embedding),
            settings.completionModel
        )
        defer {
            settings.customApiKey = saved.0
            settings.completionApiKey = saved.1
            settings.embeddingApiKey = saved.2
            settings.setSource(saved.3, for: .generation)
            settings.setSource(saved.4, for: .completion)
            settings.setSource(saved.5, for: .embedding)
            settings.completionModel = saved.6
        }

        settings.customApiKey = "shared-local"
        settings.completionApiKey = ""
        settings.embeddingApiKey = ""
        settings.setSource(.local, for: .generation)
        settings.setSource(.local, for: .completion)
        settings.setSource(.local, for: .embedding)
        settings.completionModel = "qwen"

        XCTAssertEqual(settings.modelContext(for: .generation).apiKey, "shared-local")
        XCTAssertEqual(settings.modelContext(for: .completion).apiKey, "shared-local")
        XCTAssertEqual(settings.modelContext(for: .embedding).apiKey, "shared-local")

        settings.completionApiKey = " completion-key "
        settings.embeddingApiKey = "embedding-key"

        XCTAssertEqual(settings.modelContext(for: .completion).apiKey, "completion-key")
        XCTAssertEqual(settings.modelContext(for: .embedding).apiKey, "embedding-key")
        XCTAssertEqual(settings.modelContext(for: .generation).apiKey, "shared-local", "chat keeps the shared key")
    }

    // MARK: - Per-model context budget

    func testOlderSavedModelsWithoutContextBudgetFollowTheGlobalSetting() {
        let raw = """
        [{"id":"\(UUID().uuidString)","name":"","source":"OpenAI","model":"gpt-4o","endpoint":"","reasoningEffort":"auto"}]
        """
        XCTAssertNil(AISettingsManager.decodeProfiles(raw).first?.contextBudgetTokens)
    }

    func testContextBudgetOverrideSurvivesEncoding() {
        let profile = AIModelProfile(source: .anthropic, model: "claude", contextBudgetTokens: 200_000)
        let decoded = AISettingsManager.decodeProfiles(AISettingsManager.encodeProfiles([profile]))
        XCTAssertEqual(decoded.first?.contextBudgetTokens, 200_000)
    }

    func testEffectiveContextBudgetTokensForModels() {
        let settings = AISettingsManager.shared
        let original = settings.chatContextBudgetTokens
        defer { settings.chatContextBudgetTokens = original }

        settings.chatContextBudgetTokens = 16_000

        let inherited = AIModelProfile(source: .openAI, model: "gpt-4o-mini")
        let longContext = AIModelProfile(source: .anthropic, model: "claude", contextBudgetTokens: 200_000)
        let tooSmall = AIModelProfile(source: .local, model: "tiny", contextBudgetTokens: 10)
        let portkey = AIModelProfile(source: .portkey, model: "@openai-prod/gpt-4o", contextBudgetTokens: 128_000)

        XCTAssertEqual(settings.effectiveContextBudgetTokens(for: settings.modelContext(for: inherited)), 16_000, "no override → global setting")
        XCTAssertEqual(settings.effectiveContextBudgetTokens(for: settings.modelContext(for: longContext)), 200_000, "a paid long-context model can use its real window")
        XCTAssertEqual(settings.effectiveContextBudgetTokens(for: settings.modelContext(for: tooSmall)), 2_000, "tiny overrides are clamped up so compaction still works")
        XCTAssertEqual(settings.effectiveContextBudgetTokens(for: settings.modelContext(for: portkey)), 128_000, "Portkey models keep their override")
    }
}
