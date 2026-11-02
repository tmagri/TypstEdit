import Foundation

/// Uses the user's configured AI model for the parts of a PDF that geometry
/// alone cannot recover: display formulas (image → LaTeX → Typst) and
/// irregular tables (image → TSV).
///
/// Each request sends one cropped PNG. A model without image input simply
/// fails the request, and the item keeps its image fallback, so enabling
/// this never makes an import worse. Nothing is sent unless the user ticks
/// the option in the import panel.
enum PDFImportAI {

    /// A ready-to-send request target, captured on the main actor so the
    /// network calls can run concurrently off it.
    struct Target: Sendable {
        enum Style: Sendable { case openAI, anthropic, gemini }
        var url: URL
        var headers: [String: String]
        var model: String
        var style: Style
        var timeout: TimeInterval
        var maxTokens: Int
        /// A model on this Mac or network (LM Studio, Ollama, llama.cpp).
        /// Such servers often run one request at a time, so the import sends
        /// one at a time and first waits for the server to be free.
        var isLocal = false
        /// How long to wait for a busy local server before giving up on an
        /// item, and the pause before retrying a 503/429 "no free slot".
        var idleWait: TimeInterval = 30
        var busyRetryDelay: TimeInterval = 5

        /// "localhost:1234", for messages.
        var serverLabel: String { ModelServerActivity.serverKey(for: url) }
    }

    /// Why a transcription was not attempted or not answered. Either one
    /// means further requests in this import would only queue, so the
    /// importer stops sending and keeps the remaining items as images.
    enum ServerError: LocalizedError {
        case busy(server: String, waited: Int)
        case noAnswer(server: String, seconds: Int)

        var errorDescription: String? {
            switch self {
            case .busy(let server, let waited):
                return "The model at \(server) was still busy with another request after \(waited) s."
            case .noAnswer(let server, let seconds):
                return "The model at \(server) did not answer within \(seconds) s."
            }
        }
    }

    /// The Chat & Actions model, when AI is switched on and usable.
    @MainActor
    static func target() -> Target? {
        let settings = AISettingsManager.shared
        guard settings.chatEnabled else { return nil }
        let context = settings.modelContext(for: .generation)
        guard context.isLocal || !context.apiKey.isEmpty,
              !context.model.trimmingCharacters(in: .whitespaces).isEmpty || context.isLocal,
              let url = URL(string: context.chatEndpoint) else { return nil }
        let style: Target.Style = context.isGemini ? .gemini : (context.isAnthropic ? .anthropic : .openAI)
        return Target(url: url, headers: context.authHeaders, model: context.model, style: style,
                      timeout: max(settings.timeoutSeconds, 30),
                      maxTokens: 2_000 + context.reasoningEffort.thinkingTokenBudget,
                      isLocal: context.isLocal)
    }

    @MainActor
    static var modelDisplayName: String { AISettingsManager.shared.defaultModelDisplayName }

    // MARK: - Formulas

    static let formulaPrompt = """
    The image shows one mathematical formula cropped from a PDF page. Transcribe it into LaTeX math.
    Reply with only the LaTeX, with no $ or \\[ \\] delimiters, no equation environment, no code fence and no explanation.
    Leave out any equation number such as (3) at the right edge.
    """

    /// LaTeX for the formula, or `nil` when the reply is unusable.
    static func transcribeFormula(_ png: Data, hint: String, target: Target) async throws -> String? {
        var prompt = formulaPrompt
        if !hint.isEmpty {
            prompt += "\nThe PDF text layer reads (may be garbled): \(hint.prefix(400))"
        }
        let reply = try await send(prompt: prompt, png: png, target: target)
        return cleanLatex(reply)
    }

    static func cleanLatex(_ reply: String) -> String? {
        var text = stripFences(stripThinking(reply))
        let wrappers: [(String, String)] = [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]
        for (open, close) in wrappers where text.hasPrefix(open) && text.hasSuffix(close) && text.count > open.count + close.count {
            text = String(text.dropFirst(open.count).dropLast(close.count))
            break
        }
        text = text.replacingOccurrences(of: #"\\begin\{(equation|align|gather|displaymath)\*?\}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\end\{(equation|align|gather|displaymath)\*?\}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\(tag|label)\{[^}]*\}"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 4_000, isBalanced(text) else { return nil }
        // Refusals and prose are not math.
        if text.split(separator: " ").count > 12 && !text.contains("\\") && !text.contains("=") { return nil }
        return text
    }

    // MARK: - Tables

    static let tablePrompt = """
    The image shows one table cropped from a PDF page. Transcribe it as tab-separated values:
    one table row per line, cells separated by a single TAB character, header row first.
    When a cell spans several columns or rows, put its text in the first cell it covers and leave the others empty, so every row has the same number of cells.
    Copy numbers, units and symbols exactly. Reply with only the TSV, with no code fence and no explanation.
    """

    static func transcribeTable(_ png: Data, hint: [[String]], target: Target) async throws -> [[String]]? {
        var prompt = tablePrompt
        let hintText = hint.prefix(40).map { $0.joined(separator: " | ") }.joined(separator: "\n")
        if !hintText.isEmpty {
            prompt += "\nText found in the region, row by row, for reference (cell grouping may be wrong):\n\(hintText.prefix(3_000))"
        }
        let reply = try await send(prompt: prompt, png: png, target: target)
        return parseTable(reply)
    }

    /// Accepts TSV as asked, and the Markdown pipe tables models often send
    /// instead.
    static func parseTable(_ reply: String) -> [[String]]? {
        let text = stripFences(stripThinking(reply))
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var rows: [[String]]
        if lines.contains(where: { $0.contains("\t") }) {
            rows = lines.filter { $0.contains("\t") }.map { $0.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) } }
        } else if lines.filter({ $0.hasPrefix("|") }).count >= 2 {
            lines = lines.filter { $0.hasPrefix("|") && $0.range(of: #"^\|[\s:\-|]+\|?$"#, options: .regularExpression) == nil }
            rows = lines.map { line in
                var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first == "" { cells.removeFirst() }
                if cells.last == "" { cells.removeLast() }
                return cells
            }
        } else {
            return nil
        }
        let width = rows.map(\.count).max() ?? 0
        guard rows.count >= 2, width >= 2 else { return nil }
        rows = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        return rows
    }

    // MARK: - Transport

    static func send(prompt: String, png: Data, target: Target) async throws -> String {
        var request = URLRequest(url: target.url)
        request.httpMethod = "POST"
        request.timeoutInterval = target.timeout
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in target.headers { request.addValue(value, forHTTPHeaderField: field) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body(prompt: prompt, png: png, target: target))

        // A local server busy with the chat (or anything else) would queue
        // this request silently: wait for it to be free, or give up.
        if target.isLocal, !(await ModelServerActivity.shared.waitUntilIdle(target.url, timeout: target.idleWait)) {
            try Task.checkCancellation()
            throw ServerError.busy(server: target.serverLabel, waited: Int(target.idleWait.rounded()))
        }

        var attempt = 0
        while true {
            let activity = ModelServerActivity.shared.begin(target.url)
            let data: Data, response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
                ModelServerActivity.shared.end(activity)
            } catch let error as URLError where error.code == .timedOut {
                ModelServerActivity.shared.end(activity)
                throw ServerError.noAnswer(server: target.serverLabel, seconds: Int(target.timeout))
            } catch {
                ModelServerActivity.shared.end(activity)
                throw error
            }
            guard let http = response as? HTTPURLResponse else { throw AIError.noData }
            // llama.cpp answers 503 with no free slot; others may send 429.
            if target.isLocal, http.statusCode == 503 || http.statusCode == 429 {
                attempt += 1
                guard attempt <= 2 else {
                    throw ServerError.busy(server: target.serverLabel, waited: Int((Double(attempt - 1) * target.busyRetryDelay).rounded()))
                }
                try await Task.sleep(nanoseconds: UInt64(target.busyRetryDelay * 1_000_000_000))
                continue
            }
            return try decodeReply(data, http: http, style: target.style)
        }
    }

    private static func decodeReply(_ data: Data, http: HTTPURLResponse, style: Target.Style) throws -> String {
        guard http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                ?? String(data: data.prefix(300), encoding: .utf8) ?? "Unknown error"
            throw AIError.apiError("API Error (\(http.statusCode)): \(message)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.parsingError("Invalid JSON returned by provider.")
        }
        return extractText(json, style: style)
    }

    static let systemPrompt = "You transcribe cropped images of PDF content exactly, in the format requested, with no commentary."

    static func body(prompt: String, png: Data, target: Target) -> [String: Any] {
        let base64 = png.base64EncodedString()
        switch target.style {
        case .openAI:
            return [
                "model": target.model,
                "max_tokens": target.maxTokens,
                "temperature": 0,
                "stream": false,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(base64)"]],
                    ]],
                ],
            ]
        case .anthropic:
            return [
                "model": target.model,
                "max_tokens": target.maxTokens,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": [
                        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": base64]],
                        ["type": "text", "text": prompt],
                    ]],
                ],
            ]
        case .gemini:
            return [
                "contents": [[
                    "parts": [
                        ["text": systemPrompt + "\n\n" + prompt],
                        ["inline_data": ["mime_type": "image/png", "data": base64]],
                    ],
                ]],
                "generationConfig": ["maxOutputTokens": target.maxTokens, "temperature": 0],
            ]
        }
    }

    static func extractText(_ json: [String: Any], style: Target.Style) -> String {
        switch style {
        case .openAI:
            let message = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
            if let content = message?["content"] as? String { return content }
            if let parts = message?["content"] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }.joined()
            }
            return ""
        case .anthropic:
            return (json["content"] as? [[String: Any]] ?? [])
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }.joined()
        case .gemini:
            let parts = (((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            return parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        }
    }

    // MARK: - Reply Clean-up

    static func stripThinking(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            result = result.replacingOccurrences(of: #"^```[A-Za-z]*\s*\n?"#, with: "", options: .regularExpression)
            result = result.replacingOccurrences(of: #"\n?```\s*$"#, with: "", options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isBalanced(_ text: String) -> Bool {
        var stack: [Character] = []
        var escaped = false
        for character in text {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            switch character {
            case "{", "(", "[": stack.append(character)
            case "}": guard stack.popLast() == "{" else { return false }
            case ")": if stack.last == "(" { stack.removeLast() }   // LaTeX allows "(a, b]"
            case "]": if stack.last == "[" { stack.removeLast() }
            default: break
            }
        }
        return !stack.contains("{")
    }
}
