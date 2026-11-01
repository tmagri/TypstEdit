import XCTest
@testable import TypstEdit

/// Per-model request tuning: the short per-family style note added to the
/// system prompt, and the terser-answer hint sent only to models that accept
/// it.
final class ModelPromptStyleTests: XCTestCase {

    // MARK: - Family detection

    func testDetectsTheGPTFamily() {
        XCTAssertEqual(ModelPromptStyle.detect(model: "gpt-5"), .gpt)
        XCTAssertEqual(ModelPromptStyle.detect(model: "gpt-4o"), .gpt)
        XCTAssertEqual(ModelPromptStyle.detect(model: "openai/gpt-5-mini"), .gpt)
        XCTAssertEqual(ModelPromptStyle.detect(model: "o3"), .gpt)
        XCTAssertEqual(ModelPromptStyle.detect(model: "o4-mini"), .gpt)
    }

    func testDetectsClaude() {
        XCTAssertEqual(ModelPromptStyle.detect(model: "claude-sonnet-4-5"), .claude)
        XCTAssertEqual(ModelPromptStyle.detect(model: "anthropic/claude-opus-4-1"), .claude)
    }

    func testDetectsKimi() {
        XCTAssertEqual(ModelPromptStyle.detect(model: "kimi-k2"), .kimi)
        XCTAssertEqual(ModelPromptStyle.detect(model: "moonshot/kimi-k2"), .kimi)
    }

    func testFallsBackToGeneric() {
        XCTAssertEqual(ModelPromptStyle.detect(model: "qwen3-coder"), .generic)
        XCTAssertEqual(ModelPromptStyle.detect(model: "llama-3.3-70b"), .generic)
        XCTAssertEqual(ModelPromptStyle.detect(model: ""), .generic)
    }

    // MARK: - Guidance

    func testEveryFamilyExceptGenericHasAGuidanceNote() {
        XCTAssertNotNil(ModelPromptStyle.gpt.guidance)
        XCTAssertNotNil(ModelPromptStyle.claude.guidance)
        XCTAssertNotNil(ModelPromptStyle.kimi.guidance)
        // Generic models get the base prompt unchanged.
        XCTAssertNil(ModelPromptStyle.generic.guidance)
    }

    func testGuidanceIsShortEnoughToBeWorthItsTokens() {
        // The point of a note rather than a whole second prompt: it must stay
        // small next to the base instructions.
        for style in [ModelPromptStyle.gpt, .claude, .kimi] {
            let note = try? XCTUnwrap(style.guidance)
            XCTAssertLessThan(note?.count ?? 0, 600, "\(style) guidance is too long")
        }
    }

    // MARK: - Verbosity support

    func testVerbosityIsSentOnlyToSupportingModels() {
        XCTAssertTrue(ModelVerbosity.supports(model: "gpt-5"))
        XCTAssertTrue(ModelVerbosity.supports(model: "gpt-5-mini"))
        XCTAssertTrue(ModelVerbosity.supports(model: "gpt-5.2"))
        XCTAssertTrue(ModelVerbosity.supports(model: "gpt-6"))
        // Unknown minor versions are left out until they are known to work.
        XCTAssertFalse(ModelVerbosity.supports(model: "gpt-4o"))
        XCTAssertFalse(ModelVerbosity.supports(model: "gpt-5-chat"))
        XCTAssertFalse(ModelVerbosity.supports(model: "claude-sonnet-4-5"))
    }

    func testVisitorOnlySourcesForwardTheHint() {
        // Direct OpenAI and the gateways pass it through; a local server need
        // not, and a rejected unknown field costs far more than it saves.
        XCTAssertEqual(ModelVerbosity.value(model: "gpt-5", source: .openAI, enabled: true), "low")
        XCTAssertEqual(ModelVerbosity.value(model: "gpt-5", source: .openRouter, enabled: true), "low")
        XCTAssertEqual(ModelVerbosity.value(model: "gpt-5", source: .portkey, enabled: true), "low")
        XCTAssertNil(ModelVerbosity.value(model: "gpt-5", source: .local, enabled: true))
        XCTAssertNil(ModelVerbosity.value(model: "gpt-5", source: .anthropic, enabled: true))
        XCTAssertNil(ModelVerbosity.value(model: "gpt-5", source: .gemini, enabled: true))
    }

    func testDisabledSettingSendsNothing() {
        XCTAssertNil(ModelVerbosity.value(model: "gpt-5", source: .openAI, enabled: false))
    }
}
