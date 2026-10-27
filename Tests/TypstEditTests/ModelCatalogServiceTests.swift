import XCTest
@testable import TypstEdit

/// The model-list lookups behind the "browse models" button in Settings:
/// per-provider URLs/headers, response parsing and paging, and filtering out
/// models that can't do the job.
@MainActor
final class ModelCatalogServiceTests: XCTestCase {

    private func json(_ string: String) -> Data { Data(string.utf8) }

    // MARK: - URLs

    func testModelsURLFromLocalEndpoints() {
        XCTAssertEqual(ModelCatalogService.modelsURL(fromEndpoint: "http://localhost:11434/v1/chat/completions"), "http://localhost:11434/v1/models")
        XCTAssertEqual(ModelCatalogService.modelsURL(fromEndpoint: "http://localhost:11434/v1/embeddings"), "http://localhost:11434/v1/models")
        XCTAssertEqual(ModelCatalogService.modelsURL(fromEndpoint: "http://localhost:1234/v1/"), "http://localhost:1234/v1/models")
        XCTAssertEqual(ModelCatalogService.modelsURL(fromEndpoint: "http://localhost:11434"), "http://localhost:11434/v1/models")
        XCTAssertEqual(ModelCatalogService.modelsURL(fromEndpoint: "https://api.portkey.ai/v1"), "https://api.portkey.ai/v1/models")
    }

    func testProviderListURLs() {
        XCTAssertEqual(ModelCatalogService.listURL(source: .openAI, endpoint: "", apiKey: "k")?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(ModelCatalogService.listURL(source: .openRouter, endpoint: "", apiKey: "")?.absoluteString, "https://openrouter.ai/api/v1/models")
        XCTAssertEqual(ModelCatalogService.listURL(source: .anthropic, endpoint: "", apiKey: "k")?.absoluteString, "https://api.anthropic.com/v1/models?limit=1000")
        XCTAssertEqual(
            ModelCatalogService.listURL(source: .gemini, endpoint: "", apiKey: "AIza", pageQuery: [URLQueryItem(name: "pageToken", value: "p2")])?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000&key=AIza&pageToken=p2"
        )
        XCTAssertEqual(ModelCatalogService.listURL(source: .portkey, endpoint: "", apiKey: "pk")?.absoluteString, "https://api.portkey.ai/v1/models")
        XCTAssertEqual(
            ModelCatalogService.listURL(source: .local, endpoint: "http://localhost:11434/v1/chat/completions", apiKey: "")?.absoluteString,
            "http://localhost:11434/v1/models"
        )
    }

    func testListHeaders() {
        XCTAssertEqual(ModelCatalogService.listHeaders(source: .openAI, apiKey: "sk"), ["Authorization": "Bearer sk"])
        XCTAssertEqual(ModelCatalogService.listHeaders(source: .local, apiKey: ""), [:], "no empty Bearer header for keyless local servers")
        XCTAssertEqual(ModelCatalogService.listHeaders(source: .anthropic, apiKey: "a"), ["x-api-key": "a", "anthropic-version": "2023-06-01"])
        XCTAssertEqual(ModelCatalogService.listHeaders(source: .gemini, apiKey: "g"), [:], "Gemini authenticates via the URL")
        XCTAssertEqual(
            ModelCatalogService.listHeaders(source: .portkey, apiKey: "pk", extraHeaders: ["x-portkey-provider": "@openai-prod"]),
            ["x-portkey-api-key": "pk", "x-portkey-provider": "@openai-prod", "x-portkey-fetch-integrated-models": "true"]
        )
    }

    // MARK: - Parsing

    func testParseOpenAIStyle() throws {
        let page = try ModelCatalogService.parse(source: .openAI, data: json("""
        {"object":"list","data":[{"id":"gpt-4o","owned_by":"openai"},{"id":"text-embedding-3-small","owned_by":"openai"}]}
        """))
        XCTAssertEqual(page.models.map(\.id), ["gpt-4o", "text-embedding-3-small"])
        XCTAssertNil(page.nextPageQuery)
    }

    func testParseOllamaNativeTagsFallback() throws {
        let page = try ModelCatalogService.parse(source: .local, data: json("""
        {"models":[{"name":"llama3:latest"},{"name":"nomic-embed-text:latest"}]}
        """))
        XCTAssertEqual(page.models.map(\.id), ["llama3:latest", "nomic-embed-text:latest"])
    }

    func testParseAnthropicPaging() throws {
        let page = try ModelCatalogService.parse(source: .anthropic, data: json("""
        {"data":[{"id":"claude-sonnet-4-5","display_name":"Claude Sonnet 4.5"}],"has_more":true,"last_id":"claude-sonnet-4-5"}
        """))
        XCTAssertEqual(page.models, [AvailableModel(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5")])
        XCTAssertEqual(page.nextPageQuery, [URLQueryItem(name: "after_id", value: "claude-sonnet-4-5")])
    }

    func testParseGeminiStripsPrefixAndPages() throws {
        let page = try ModelCatalogService.parse(source: .gemini, data: json("""
        {"models":[
          {"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","inputTokenLimit":1048576,"supportedGenerationMethods":["generateContent"]},
          {"name":"models/text-embedding-004","displayName":"Text Embedding 004","supportedGenerationMethods":["embedContent"]}
        ],"nextPageToken":"next"}
        """))
        XCTAssertEqual(page.models.map(\.id), ["gemini-2.5-flash", "text-embedding-004"])
        XCTAssertEqual(page.models.first?.detail, "1M context")
        XCTAssertEqual(page.nextPageQuery, [URLQueryItem(name: "pageToken", value: "next")])

        let chat = ModelCatalogService.finalize(page.models, source: .gemini, kind: .chat)
        XCTAssertEqual(chat.map(\.id), ["gemini-2.5-flash"])
    }

    func testParseOpenRouterIncludesNameAndContext() throws {
        let page = try ModelCatalogService.parse(source: .openRouter, data: json("""
        {"data":[{"id":"anthropic/claude-sonnet-4.5","name":"Anthropic: Claude Sonnet 4.5","context_length":200000}]}
        """))
        XCTAssertEqual(page.models.first, AvailableModel(id: "anthropic/claude-sonnet-4.5", name: "Anthropic: Claude Sonnet 4.5", detail: "200k context"))
    }

    func testParsePortkeyOffsetPaging() throws {
        let first = try ModelCatalogService.parse(source: .portkey, data: json("""
        {"object":"list","total":3,"data":[{"id":"@openai-prod/gpt-4o"},{"id":"@anthropic/claude-sonnet"}]}
        """))
        XCTAssertEqual(first.models.map(\.id), ["@openai-prod/gpt-4o", "@anthropic/claude-sonnet"])
        XCTAssertEqual(first.nextPageQuery, [URLQueryItem(name: "offset", value: "2")])

        let last = try ModelCatalogService.parse(source: .portkey, data: json("""
        {"object":"list","total":3,"data":[{"id":"@openai-prod/gpt-4o-mini"}]}
        """), currentQuery: [URLQueryItem(name: "offset", value: "2")])
        XCTAssertNil(last.nextPageQuery)
    }

    func testParseRejectsNonObject() {
        XCTAssertThrowsError(try ModelCatalogService.parse(source: .openAI, data: json("[1,2]")))
    }

    // MARK: - Filtering

    func testOpenAIChatFilterDropsNonChatModels() {
        let models = ["gpt-4o", "text-embedding-3-small", "tts-1", "whisper-1", "dall-e-3", "gpt-4o-mini", "omni-moderation-latest"]
            .map { AvailableModel(id: $0) }
        XCTAssertEqual(ModelCatalogService.finalize(models, source: .openAI, kind: .chat).map(\.id), ["gpt-4o", "gpt-4o-mini"])
        XCTAssertEqual(ModelCatalogService.finalize(models, source: .openAI, kind: .embedding).map(\.id), ["text-embedding-3-small"])
    }

    func testLocalEmbeddingListShowsEverythingAndDedupes() {
        let models = ["llama3", "bge-m3", "nomic-embed-text", "llama3"].map { AvailableModel(id: $0) }
        XCTAssertEqual(ModelCatalogService.finalize(models, source: .local, kind: .embedding).map(\.id), ["bge-m3", "llama3", "nomic-embed-text"])
        XCTAssertEqual(ModelCatalogService.finalize(models, source: .local, kind: .chat).map(\.id), ["bge-m3", "llama3"])
    }

    func testAnthropicKeepsProviderOrder() {
        let models = ["claude-sonnet-4-5", "claude-3-5-haiku"].map { AvailableModel(id: $0) }
        XCTAssertEqual(ModelCatalogService.finalize(models, source: .anthropic, kind: .chat).map(\.id), ["claude-sonnet-4-5", "claude-3-5-haiku"])
    }
}
