import XCTest
@testable import TypstEdit

/// Portkey AI Gateway as a model source: endpoint normalization, auth and
/// routing headers, and context resolution from settings / saved models.
@MainActor
final class PortkeyProviderTests: XCTestCase {

    // MARK: - Endpoint (pure)

    func testChatEndpointFromBaseURL() {
        let expected = "https://api.portkey.ai/v1/chat/completions"
        XCTAssertEqual(PortkeyGateway.chatEndpoint(fromBaseURL: "https://api.portkey.ai/v1"), expected)
        XCTAssertEqual(PortkeyGateway.chatEndpoint(fromBaseURL: " https://api.portkey.ai/v1/ "), expected)
        XCTAssertEqual(PortkeyGateway.chatEndpoint(fromBaseURL: expected), expected)
        XCTAssertEqual(PortkeyGateway.chatEndpoint(fromBaseURL: ""), expected, "empty falls back to the hosted gateway")
        XCTAssertEqual(
            PortkeyGateway.chatEndpoint(fromBaseURL: "http://localhost:8787/v1"),
            "http://localhost:8787/v1/chat/completions",
            "self-hosted gateways keep their own URL"
        )
    }

    func testRoutingHeadersOmitEmptyValues() {
        XCTAssertEqual(PortkeyGateway.routingHeaders(provider: "", config: "  "), [:])
        XCTAssertEqual(
            PortkeyGateway.routingHeaders(provider: " @openai-prod ", config: "pc-abc"),
            ["x-portkey-provider": "@openai-prod", "x-portkey-config": "pc-abc"]
        )
    }

    // MARK: - Headers (pure)

    func testPortkeyAuthHeadersUsePortkeyKeyAndNoBearer() {
        let ctx = ModelContext(
            task: .generation, source: .portkey, model: "@openai-prod/gpt-4o",
            endpoint: PortkeyGateway.defaultBaseURL, apiKey: "pk-test", reasoningEffort: .auto,
            extraHeaders: ["x-portkey-provider": "@openai-prod"]
        )
        XCTAssertEqual(ctx.chatEndpoint, "https://api.portkey.ai/v1/chat/completions")
        XCTAssertEqual(ctx.authHeaders, [
            "x-portkey-api-key": "pk-test",
            "x-portkey-provider": "@openai-prod",
        ])
    }

    func testOtherProvidersKeepTheirHeaders() {
        func headers(_ source: ModelSource) -> [String: String] {
            ModelContext(task: .generation, source: source, model: "m", endpoint: "", apiKey: "k", reasoningEffort: .auto).authHeaders
        }
        XCTAssertEqual(headers(.openAI), ["Authorization": "Bearer k"])
        XCTAssertEqual(headers(.local), ["Authorization": "Bearer k"])
        XCTAssertEqual(headers(.anthropic), ["x-api-key": "k", "anthropic-version": "2023-06-01"])
        XCTAssertEqual(headers(.openRouter), ["Authorization": "Bearer k", "HTTP-Referer": "TypstEdit", "X-Title": "TypstEdit"])
        XCTAssertEqual(headers(.gemini), [:])
    }

    // MARK: - Settings resolution

    func testSavedPortkeyModelResolvesToGatewayContext() {
        let settings = AISettingsManager.shared
        let saved = (settings.portkeyApiKey, settings.portkeyBaseURL, settings.portkeyProvider, settings.portkeyConfig)
        defer {
            settings.portkeyApiKey = saved.0
            settings.portkeyBaseURL = saved.1
            settings.portkeyProvider = saved.2
            settings.portkeyConfig = saved.3
        }
        settings.portkeyApiKey = "pk-123"
        settings.portkeyBaseURL = "https://gateway.example.com/v1/"
        settings.portkeyProvider = ""
        settings.portkeyConfig = "pc-fallback"

        let profile = AIModelProfile(source: .portkey, model: " @anthropic/claude-sonnet ", reasoningEffort: .medium)
        let ctx = settings.modelContext(for: profile)

        XCTAssertEqual(ctx.source, .portkey)
        XCTAssertEqual(ctx.model, "@anthropic/claude-sonnet")
        XCTAssertEqual(ctx.apiKey, "pk-123")
        XCTAssertEqual(ctx.reasoningEffort, .medium)
        XCTAssertEqual(ctx.chatEndpoint, "https://gateway.example.com/v1/chat/completions")
        XCTAssertEqual(ctx.authHeaders, ["x-portkey-api-key": "pk-123", "x-portkey-config": "pc-fallback"])
    }

    func testPortkeyProfileSurvivesEncoding() {
        let profile = AIModelProfile(name: "Gateway", source: .portkey, model: "@openai-prod/gpt-4o")
        let decoded = AISettingsManager.decodeProfiles(AISettingsManager.encodeProfiles([profile]))
        XCTAssertEqual(decoded, [profile])
    }
}
