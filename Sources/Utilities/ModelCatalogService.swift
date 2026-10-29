import Foundation

/// One model a provider reports as available, for the model picker in
/// Settings.
struct AvailableModel: Identifiable, Hashable {
    /// The exact string to send as `model` in requests.
    let id: String
    /// Human-friendly name, when the provider returns one.
    var name: String? = nil
    /// Short extra info (context size, owner), when available.
    var detail: String? = nil
}

/// What the model is going to be used for — filters out models that can't do
/// the job (e.g. TTS or embedding models in a chat picker).
enum ModelListKind: String {
    case chat
    case embedding
}

/// One page of a provider's model list plus the query items that fetch the
/// next page (`nil` = last page).
struct ModelListPage {
    var models: [AvailableModel]
    var nextPageQuery: [URLQueryItem]?
}

/// Fetches the list of models each provider offers, so Settings can offer a
/// searchable picker instead of making users type model names by hand.
/// Results are cached in memory per provider/endpoint/key until refreshed.
@MainActor
final class ModelCatalogService {
    static let shared = ModelCatalogService()

    private var cache: [String: [AvailableModel]] = [:]
    /// Safety bound on paged providers (Anthropic, Gemini, Portkey).
    private static let maxPages = 10

    private init() {}

    /// The models available for `source`. `localEndpoint` is only used for
    /// `.local` (the chat or embeddings URL configured for that model).
    /// `apiKeyOverride` lets a saved model browse with its own key instead of
    /// the shared per-provider key (two local servers, different tokens).
    func models(
        for source: ModelSource,
        localEndpoint: String = "",
        apiKeyOverride: String = "",
        kind: ModelListKind = .chat,
        forceRefresh: Bool = false
    ) async throws -> [AvailableModel] {
        let settings = AISettingsManager.shared
        let override = apiKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = override.isEmpty ? settings.apiKey(for: source) : override
        let endpoint = source == .portkey ? settings.portkeyBaseURL : localEndpoint
        let extraHeaders: [String: String] = source == .portkey
            ? PortkeyGateway.routingHeaders(provider: settings.portkeyProvider, config: settings.portkeyConfig)
            : [:]

        let cacheKey = [source.rawValue, endpoint, kind.rawValue, String(apiKey.hashValue), extraHeaders.description].joined(separator: "|")
        if !forceRefresh, let cached = cache[cacheKey] {
            return cached
        }

        if !source.isLocal && source != .openRouter && apiKey.isEmpty {
            throw AIError.apiError("Add your \(source.rawValue) API key first (API Keys & Limits tab).")
        }

        var all: [AvailableModel] = []
        var pageQuery: [URLQueryItem] = []
        for _ in 0..<Self.maxPages {
            guard let url = Self.listURL(source: source, endpoint: endpoint, apiKey: apiKey, pageQuery: pageQuery) else {
                throw AIError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            for (field, value) in Self.listHeaders(source: source, apiKey: apiKey, extraHeaders: extraHeaders) {
                request.setValue(value, forHTTPHeaderField: field)
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIError.noData }
            guard http.statusCode == 200 else {
                throw AIError.apiError("Couldn't list models (\(http.statusCode)): \(Self.errorMessage(from: data))")
            }

            let page = try Self.parse(source: source, data: data, currentQuery: pageQuery)
            all.append(contentsOf: page.models)
            guard let next = page.nextPageQuery else { break }
            pageQuery = next
        }

        let result = Self.finalize(all, source: source, kind: kind)
        cache[cacheKey] = result
        return result
    }

    // MARK: - Request Building (pure, testable)

    /// The models-list URL for a provider, including paging/auth query items.
    static func listURL(source: ModelSource, endpoint: String, apiKey: String, pageQuery: [URLQueryItem] = []) -> URL? {
        let base: String
        var query: [URLQueryItem] = []
        switch source {
        case .openAI:
            base = "https://api.openai.com/v1/models"
        case .openRouter:
            base = "https://openrouter.ai/api/v1/models"
        case .anthropic:
            base = "https://api.anthropic.com/v1/models"
            query.append(URLQueryItem(name: "limit", value: "1000"))
        case .gemini:
            base = "https://generativelanguage.googleapis.com/v1beta/models"
            query.append(URLQueryItem(name: "pageSize", value: "1000"))
            query.append(URLQueryItem(name: "key", value: apiKey))
        case .portkey:
            base = modelsURL(fromEndpoint: endpoint.isEmpty ? PortkeyGateway.defaultBaseURL : endpoint)
        case .local:
            base = modelsURL(fromEndpoint: endpoint)
        }
        guard var components = URLComponents(string: base) else { return nil }
        let combined = (components.queryItems ?? []) + query + pageQuery
        components.queryItems = combined.isEmpty ? nil : combined
        return components.url
    }

    /// Derives an OpenAI-compatible `/models` URL from a configured chat or
    /// embeddings URL (`…/v1/chat/completions` → `…/v1/models`). A bare host
    /// (`http://localhost:11434`) gets `/v1/models`.
    static func modelsURL(fromEndpoint endpoint: String) -> String {
        var trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        for suffix in ["/chat/completions", "/completions", "/embeddings", "/models"] where trimmed.hasSuffix(suffix) {
            trimmed.removeLast(suffix.count)
            break
        }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        let path = URLComponents(string: trimmed)?.path ?? ""
        if path.isEmpty {
            return trimmed + "/v1/models"
        }
        return trimmed + "/models"
    }

    static func listHeaders(source: ModelSource, apiKey: String, extraHeaders: [String: String] = [:]) -> [String: String] {
        let ctx = ModelContext(
            task: .generation, source: source, model: "", endpoint: "",
            apiKey: apiKey, reasoningEffort: .auto, extraHeaders: extraHeaders
        )
        var headers = ctx.authHeaders
        switch source {
        case .local, .openRouter:
            // Optional keys: don't send an empty "Bearer " header.
            if apiKey.isEmpty { headers["Authorization"] = nil }
        case .portkey:
            // Return the workspace's Model Catalog (`@slug/model` ids, ready to
            // use as-is) even when a default provider/config is set.
            headers["x-portkey-fetch-integrated-models"] = "true"
        default:
            break
        }
        return headers
    }

    // MARK: - Parsing (pure, testable)

    static func parse(source: ModelSource, data: Data, currentQuery: [URLQueryItem] = []) throws -> ModelListPage {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.parsingError("Unexpected model list format.")
        }

        switch source {
        case .gemini:
            let items = json["models"] as? [[String: Any]] ?? []
            let models: [AvailableModel] = items.compactMap { item in
                guard let rawName = item["name"] as? String else { return nil }
                let id = rawName.hasPrefix("models/") ? String(rawName.dropFirst("models/".count)) : rawName
                let methods = item["supportedGenerationMethods"] as? [String] ?? []
                var detail: [String] = []
                if let limit = item["inputTokenLimit"] as? Int { detail.append(contextLabel(limit)) }
                if methods.contains("embedContent") && !methods.contains("generateContent") { detail.append("embedding") }
                return AvailableModel(id: id, name: item["displayName"] as? String, detail: detail.isEmpty ? nil : detail.joined(separator: " · "))
            }
            let next = (json["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : [URLQueryItem(name: "pageToken", value: $0)] }
            return ModelListPage(models: models, nextPageQuery: next)

        case .anthropic:
            let items = json["data"] as? [[String: Any]] ?? []
            let models = items.compactMap { item -> AvailableModel? in
                guard let id = item["id"] as? String else { return nil }
                return AvailableModel(id: id, name: item["display_name"] as? String)
            }
            var next: [URLQueryItem]?
            if (json["has_more"] as? Bool) == true, let lastID = json["last_id"] as? String {
                next = [URLQueryItem(name: "after_id", value: lastID)]
            }
            return ModelListPage(models: models, nextPageQuery: next)

        case .openRouter:
            let items = json["data"] as? [[String: Any]] ?? []
            let models = items.compactMap { item -> AvailableModel? in
                guard let id = item["id"] as? String else { return nil }
                let context = (item["context_length"] as? Int).map(contextLabel)
                return AvailableModel(id: id, name: item["name"] as? String, detail: context)
            }
            return ModelListPage(models: models, nextPageQuery: nil)

        case .portkey:
            let items = json["data"] as? [[String: Any]] ?? []
            let models = items.compactMap { item -> AvailableModel? in
                guard let id = item["id"] as? String else { return nil }
                return AvailableModel(id: id, detail: item["owned_by"] as? String)
            }
            // Offset paging when the gateway reports a total.
            var next: [URLQueryItem]?
            let offset = currentQuery.first { $0.name == "offset" }.flatMap { $0.value.flatMap(Int.init) } ?? 0
            if let total = json["total"] as? Int, !items.isEmpty, offset + items.count < total {
                next = [URLQueryItem(name: "offset", value: String(offset + items.count))]
            }
            return ModelListPage(models: models, nextPageQuery: next)

        case .openAI, .local:
            let items = json["data"] as? [[String: Any]] ?? []
            var models = items.compactMap { item -> AvailableModel? in
                guard let id = item["id"] as? String else { return nil }
                return AvailableModel(id: id, detail: item["owned_by"] as? String)
            }
            // Ollama's native /api/tags shape, in case a server answers with it.
            if models.isEmpty, let tags = json["models"] as? [[String: Any]] {
                models = tags.compactMap { ($0["name"] as? String).map { AvailableModel(id: $0) } }
            }
            return ModelListPage(models: models, nextPageQuery: nil)
        }
    }

    /// Dedupes, filters to models usable for `kind`, and sorts. Anthropic and
    /// Gemini keep the provider's order (newest/most relevant first).
    static func finalize(_ models: [AvailableModel], source: ModelSource, kind: ModelListKind) -> [AvailableModel] {
        var seen = Set<String>()
        var unique = models.filter { seen.insert($0.id).inserted }

        unique = unique.filter { isUsable($0, source: source, kind: kind) }

        switch source {
        case .anthropic, .gemini:
            return unique
        default:
            return unique.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        }
    }

    /// Name-based filtering for providers whose list mixes every model type.
    static func isUsable(_ model: AvailableModel, source: ModelSource, kind: ModelListKind) -> Bool {
        let id = model.id.lowercased()
        let looksLikeEmbedding = id.contains("embed")

        switch kind {
        case .embedding:
            // Local servers name embedding models freely (bge-m3, …) — show all.
            return source.isLocal || looksLikeEmbedding
        case .chat:
            if looksLikeEmbedding { return false }
            if source == .gemini {
                return model.detail?.contains("embedding") != true && !id.contains("aqa")
            }
            if source == .openAI {
                let nonChat = ["tts", "whisper", "dall-e", "moderation", "davinci", "babbage", "transcribe", "gpt-image", "sora", "-realtime", "-audio", "-search"]
                return !nonChat.contains { id.contains($0) }
            }
            return true
        }
    }

    private static func contextLabel(_ tokens: Int) -> String {
        tokens >= 1_000_000
            ? String(format: "%.1fM context", Double(tokens) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
            : "\(tokens / 1_000)k context"
    }

    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = json["error"] as? String { return message }
            if let message = json["message"] as? String { return message }
        }
        let text = String(data: data, encoding: .utf8) ?? "Unknown error"
        return String(text.prefix(300))
    }
}
