import Foundation

// MARK: - Precompiled Regexes

enum AICompletionRegex {
    static let thinkTag = try! NSRegularExpression(pattern: "<think>[\\s\\S]*?<\\/think>", options: [.caseInsensitive])
    static let thoughtTag = try! NSRegularExpression(pattern: "<thought>[\\s\\S]*?<\\/thought>", options: [.caseInsensitive])
    static let extractCode = try! NSRegularExpression(pattern: "```(?:[a-zA-Z]*\\n)?([\\s\\S]*?)```")
    
    // Masking
    static let codeBlock = try! NSRegularExpression(pattern: "(?s)(`+).*?(?<!`)\\1(?!`)")
    static let mathBlock = try! NSRegularExpression(pattern: "(?s)\\$\\$.+?\\$\\$|(?<!\\\\)\\$(?!\\s)[^\\$\\n]+?(?<!\\s)(?<!\\\\)\\$|(?s)\\\\\\[.+?\\\\\\]|(?s)\\\\\\([^\\n]+?\\\\\\)")
    
    // Autolinks & HTML tags
    static let autolink = try! NSRegularExpression(pattern: "<(https?://[^>\\s]+)>")
    static let htmlPAlign = try! NSRegularExpression(pattern: "(?is)\\s*<p\\s+align=[\"']([^\"']+)[\"']>\\s*(.*?)\\s*</p>\\s*")
    static let htmlP = try! NSRegularExpression(pattern: "(?is)\\s*<p>\\s*(.*?)\\s*</p>\\s*")
    static let htmlDt = try! NSRegularExpression(pattern: "(?is)\\s*<dt>(.*?)</dt>\\s*")
    static let htmlDd = try! NSRegularExpression(pattern: "(?is)\\s*<dd>(.*?)</dd>\\s*")
    static let htmlDl = try! NSRegularExpression(pattern: "(?i)\\s*</?dl>\\s*")
    static let htmlStrong = try! NSRegularExpression(pattern: "(?is)<(strong|b)>(.*?)</\\1>")
    static let htmlEm = try! NSRegularExpression(pattern: "(?is)<(em|i)>(.*?)</\\1>")
    static let htmlDel = try! NSRegularExpression(pattern: "(?is)<del>(.*?)</del>")
    static let htmlSup = try! NSRegularExpression(pattern: "(?is)<sup>(.*?)</sup>")
    static let htmlSub = try! NSRegularExpression(pattern: "(?is)<sub>(.*?)</sub>")
    static let htmlU = try! NSRegularExpression(pattern: "(?is)<u>(.*?)</u>")
    static let htmlMark = try! NSRegularExpression(pattern: "(?is)<mark>(.*?)</mark>")
    static let htmlBr = try! NSRegularExpression(pattern: "(?i)<br\\s*/?>")
    static let htmlLink = try! NSRegularExpression(pattern: "(?is)<a\\s+(?:[^>]*?\\s+)?href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>")
    static let htmlImg = try! NSRegularExpression(pattern: "(?i)<img\\s+([^>]+)>")
    static let imgSrc = try! NSRegularExpression(pattern: "(?i)src=[\"']([^\"']+)[\"']")
    static let imgAlt = try! NSRegularExpression(pattern: "(?i)alt=[\"']([^\"']*)[\"']")
    static let imgWidth = try! NSRegularExpression(pattern: "(?i)width=[\"']([^\"']+)[\"']")
    static let imgHeight = try! NSRegularExpression(pattern: "(?i)height=[\"']([^\"']+)[\"']")
    static let escapeHtmlTags = try! NSRegularExpression(pattern: "(?i)\\\\?<(?!(?:[a-z0-9_-]+)>)(/?[a-z][a-z0-9]*\\b[^>]*)>")
    
    // Footnotes & Headings & Lists
    static let fnDef = try! NSRegularExpression(pattern: "(?m)^\\[\\^([^\\]]+)\\]:[ \\t]*(.*?)(?=\\n\\[\\^|\n\\z|\\z)", options: [.dotMatchesLineSeparators])
    static let fnRef = try! NSRegularExpression(pattern: "\\[\\^([^\\]]+)\\]")
    static let fnInline = try! NSRegularExpression(pattern: "(?<!!)\\^\\[([^\\]]+)\\]")
    static let heading = try! NSRegularExpression(pattern: "(?m)^([ \\t]*(?:>[ \\t]*)?)(#+)[ \\t]+")
    static let docDot = try! NSRegularExpression(pattern: "(?m)^([ \\t]*)[⋅·]+")
    static let taskListChecked = try! NSRegularExpression(pattern: "(?m)^([ \\t]*(?:>[ \\t]*)?)[-*+][ \\t]+\\[[xX]\\][ \\t]+")
    static let taskListUnchecked = try! NSRegularExpression(pattern: "(?m)^([ \\t]*(?:>[ \\t]*)?)[-*+][ \\t]+\\[ \\][ \\t]+")
    static let unorderedList = try! NSRegularExpression(pattern: "(?m)^([ \\t]*(?:>[ \\t]*)?)[*+][ \\t]+")
    static let orderedList = try! NSRegularExpression(pattern: "(?m)^([ \\t]*(?:>[ \\t]*)?)\\d+\\.[ \\t]+")
    
    // Formatting
    static let strike = try! NSRegularExpression(pattern: "(?s)~~(.+?)~~")
    static let boldItalicAsterisk = try! NSRegularExpression(pattern: "\\*\\*\\*(.+?)\\*\\*\\*")
    static let boldItalicUnderscore = try! NSRegularExpression(pattern: "___(.+?)___")
    static let boldAsymmetric1 = try! NSRegularExpression(pattern: "(?<!\\*)\\*\\*\\*([^*\\n]+)\\*\\*(?!\\*)")
    static let boldAsymmetric2 = try! NSRegularExpression(pattern: "(?<!\\*)\\*\\*([^*\\n]+)\\*\\*\\*(?!\\*)")
    static let technicalUnderscore = try! NSRegularExpression(pattern: "(?<=[a-zA-Z0-9])_(?=[a-zA-Z0-9])")
    static let underscoreBeforeAsterisk = try! NSRegularExpression(pattern: "_(?=\\\\?\\*(?!\\*))")
    static let boldAsterisk = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
    static let boldUnderscore = try! NSRegularExpression(pattern: "__(.+?)__")
    
    // Links and Images
    static let refDef = try! NSRegularExpression(pattern: "(?m)^[ \\t]*\\[([^\\]]+)\\]:[ \\t]+([^ \\t\\n]+)(?:[ \\t]+[\"'(].*?[\"')])?[ \\t]*$")
    static let refImg = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\[([^\\]]*)\\]")
    static let refLink = try! NSRegularExpression(pattern: "(?<!!)\\[([^\\]]+)\\]\\[([^\\]]*)\\]")
    static let inlineImg = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\(\\s*([^)\\s]+)(?:\\s+\"[^\"]*\")?\\s*\\)")
    static let inlineLink = try! NSRegularExpression(pattern: "(?<!!)\\[([^\\]]+)\\]\\(\\s*([^)\\s]+)(?:\\s+\"[^\"]*\")?\\s*\\)")
    static let bareVideo = try! NSRegularExpression(pattern: #"(?m)^[ \t]*(https?://(?:www\.|m\.)?(?:youtube\.com/(?:watch|embed|v|shorts|live)|youtu\.be/|vimeo\.com/)[^\s]+)[ \t]*$"#, options: [.caseInsensitive])
    
    // Typst and Cleanups
    static let markdownAbbr = try! NSRegularExpression(pattern: "(?m)^\\*\\[([^\\]]+)\\]:")
    static let horizontalRule = try! NSRegularExpression(pattern: "(?m)^[-*_]{3,}[ \\t]*$")
    static let entityRarr = try! NSRegularExpression(pattern: "(?i)&rarr;")
    static let entityLarr = try! NSRegularExpression(pattern: "(?i)&larr;")
    static let strayBacktick = try! NSRegularExpression(pattern: "(?<!\\\\)`")
    static let literalDollar = try! NSRegularExpression(pattern: "(?<!\\\\)\\$")
    static let literalHash = try! NSRegularExpression(pattern: "(?<!\\\\)#(?!link\\(|image\\(|strike\\[|line\\(|table\\(|figure\\(|align\\(|kbd\\[|super\\[|sub\\[|underline\\[|highlight\\[|footnote\\[)")
    static let literalAt = try! NSRegularExpression(pattern: "(?<!\\\\)@")
    static let hybridDollarDigit = try! NSRegularExpression(pattern: "(?<!\\\\)\\$(?=\\d)")
    static let hybridAt = try! NSRegularExpression(pattern: "(?<!\\\\)(?<=[a-zA-Z0-9])@|(?<!\\\\)@(?=\\s)")
    static let hybridHash = try! NSRegularExpression(pattern: "(?<!\\\\)#(?!import\\b|include\\b|let\\b|set\\b|show\\b|return\\b|if\\b|else\\b|for\\b|while\\b|context\\b)([A-Za-z][A-Za-z0-9_]*)(?=[,!?;:]|\\.\\s|\\.$)")
    static let stringLiteral = try! NSRegularExpression(pattern: "\"[^\"]*\"")
    
    // Markdown table & video IDs
    static let markdownTable = try! NSRegularExpression(pattern: "(?m)^[ \\t]*(?:\\|?[^\\n|]+\\|[^\\n]+|[^\\n|]+\\|[^\\n]*)\\n[ \\t]*\\|?[ \\t]*:?-+:?[ \\t]*(?:\\|[ \\t]*:?-+:?[ \\t]*)*\\|?[ \\t]*\\n(?:[ \\t]*(?:\\|?[^\\n|]+\\|[^\\n]+|[^\\n|]+\\|[^\\n]*)\\n?)*")
    static let youtubeID = try! NSRegularExpression(pattern: #"(?:youtube\.com/(?:watch\?(?:.*&)?v=|embed/|v/|shorts/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})"#, options: [.caseInsensitive])
    static let vimeoID = try! NSRegularExpression(pattern: #"(?:player\.)?vimeo\.com/(?:video/)?(\d{6,})"#, options: [.caseInsensitive])
}

enum AIError: LocalizedError {
    case invalidURL
    case noData
    case parsingError(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL configuration."
        case .noData: return "No data received from the AI provider."
        case .parsingError(let details): return "Parsing Error: \(details)"
        case .apiError(let msg): return msg
        }
    }
}

/// Distinguishes between chat-based requests (AI Prompt, Refine, test connection)
/// and inline completion requests (autocomplete). Maps to the corresponding
/// ModelTask so each purpose can use its own model source and configuration.
enum AIRequestPurpose {
    case chat
    case completion

    var modelTask: ModelTask {
        switch self {
        case .chat: return .generation
        case .completion: return .completion
        }
    }
}

@MainActor
class AICompletionService: ObservableObject {
    static let shared = AICompletionService()

    @Published var isFetching: Bool = false

    private init() {}

    private func stripThinkingTags(from text: String) -> String {
        var cleanText = text
        let regexes = [AICompletionRegex.thinkTag, AICompletionRegex.thoughtTag]

        for regex in regexes {
            let range = NSRange(cleanText.startIndex..<cleanText.endIndex, in: cleanText)
            cleanText = regex.stringByReplacingMatches(in: cleanText, options: [], range: range, withTemplate: "")
        }

        return cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fetchCompletion(prompt: String, systemPrompt: String = "You are a precise code completion engine. Output ONLY the code to insert at the cursor. Do NOT output any thinking, reasoning, explanations, or XML tags.", maxTokens: Int? = nil, purpose: AIRequestPurpose = .chat) async throws -> String {
        isFetching = true
        defer { isFetching = false }

        let settings = AISettingsManager.shared

        // Determine appropriate token ceiling: autocomplete only needs a few tokens
        let effectiveMaxTokens: Int
        if let explicitTokens = maxTokens {
            effectiveMaxTokens = explicitTokens
        } else if purpose == .completion {
            effectiveMaxTokens = settings.completionMaxTokens
        } else {
            effectiveMaxTokens = 128
        }

        // Resolve the full model context for this task (source, model, endpoint, key).
        let ctx = settings.modelContext(for: purpose.modelTask)

        // Only require API key for cloud providers
        if !ctx.isLocal && ctx.apiKey.isEmpty {
            throw AIError.apiError("API Key is missing for \(ctx.source.rawValue)")
        }

        let endpoint = ctx.chatEndpoint
        let isGemini = ctx.isGemini

        guard let url = URL(string: endpoint) else {
            throw AIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeoutSeconds
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Provider-specific auth headers
        if ctx.isAnthropic {
            request.addValue(ctx.apiKey, forHTTPHeaderField: "x-api-key")
            request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !isGemini {
            request.addValue("Bearer \(ctx.apiKey)", forHTTPHeaderField: "Authorization")
        }

        // OpenRouter specific headers
        if ctx.source == .openRouter {
            request.addValue("TypstEdit", forHTTPHeaderField: "HTTP-Referer")
            request.addValue("TypstEdit", forHTTPHeaderField: "X-Title")
        }

        // Gemini Body Format
        if isGemini {
            let body: [String: Any] = [
                "contents": [
                    [
                        "parts": [
                            ["text": systemPrompt + "\n\n" + prompt]
                        ]
                    ]
                ],
                "generationConfig": [
                    "maxOutputTokens": effectiveMaxTokens,
                    "temperature": 0.2
                ]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // Anthropic Messages API Format
        else if ctx.isAnthropic {
            let body: [String: Any] = [
                "model": ctx.model,
                "max_tokens": effectiveMaxTokens,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": prompt]
                ]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // OpenAI / Standard Format
        else {
            let messages: [[String: String]] = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ]

            let body: [String: Any] = [
                "model": ctx.model,
                "messages": messages,
                "max_tokens": effectiveMaxTokens,
                "temperature": 0.2, // Deterministic
                "stream": false
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.noData
        }

        guard httpResponse.statusCode == 200 else {
            var parsedErrorMsg = String(data: data, encoding: .utf8) ?? "Unknown Error"

            // Attempt to extract a clean error message from the standard AI API formats
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                    parsedErrorMsg = msg
                } else if let errorArray = json["error"] as? [[String: Any]], let first = errorArray.first, let msg = first["message"] as? String {
                    parsedErrorMsg = msg
                }
            }

            throw AIError.apiError("API Error (\(httpResponse.statusCode)): \(parsedErrorMsg)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.parsingError("Invalid JSON structure returned by provider.")
        }

        let rawResult: String

        // Parse Gemini Response
        if isGemini {
            if let candidates = json["candidates"] as? [[String: Any]],
               let firstCandidate = candidates.first,
               let contentObj = firstCandidate["content"] as? [String: Any],
               let parts = contentObj["parts"] as? [[String: Any]],
               let firstPart = parts.first,
               let text = firstPart["text"] as? String {
                rawResult = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let promptFeedback = json["promptFeedback"] as? [String: Any],
                      let blockReason = promptFeedback["blockReason"] as? String {
                throw AIError.apiError("Request blocked by safety filters. Reason: \(blockReason)")
            } else {
                throw AIError.parsingError("Gemini response missing text. Keys returned: \(json.keys.joined(separator: ", "))")
            }
        }
        // Parse Anthropic Response
        else if ctx.isAnthropic {
            if let contentArray = json["content"] as? [[String: Any]],
               let textBlock = contentArray.first(where: { ($0["type"] as? String) == "text" }),
               let text = textBlock["text"] as? String {
                rawResult = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                throw AIError.apiError("API Error: \(msg)")
            } else {
                throw AIError.parsingError("Anthropic response missing text. Keys returned: \(json.keys.joined(separator: ", "))")
            }
        }
        // Parse OpenAI / OpenRouter Response
        else {
            if let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let message = firstChoice["message"] as? [String: Any],
               let content = message["content"] as? String {
                rawResult = content.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                throw AIError.apiError("API Error: \(msg)")
            } else {
                throw AIError.parsingError("OpenAI response missing text. Keys returned: \(json.keys.joined(separator: ", "))")
            }
        }

        var finalResult = rawResult

        // Strip out any <think> tags that models might output
        finalResult = stripThinkingTags(from: finalResult)

        if settings.forceCodeOutput {
            let extracted = extractCode(from: finalResult)
            // Fallback to the raw text if the AI didn't format it as a code block
            finalResult = extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? finalResult : extracted
        }

        // Completion requests return code to insert at the caret, not markdown
        // prose — running the Markdown→Typst sanitizer over it mangles the very
        // syntax it should insert (e.g. `#page` becomes `\#page`).
        let sanitizedResult = purpose == .completion ? finalResult : sanitizeMarkdownToTypst(finalResult)

        print("RAW AI RESULT: '\(rawResult)'")
        print("SANITIZED RESULT: '\(sanitizedResult)'")

        // Trap completely empty responses so the UI doesn't silently reset
        if sanitizedResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIError.apiError("The AI processed the request but returned an empty response. Try rephrasing your prompt.")
        }

        return sanitizedResult
    }

    private func extractCode(from text: String) -> String {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = AICompletionRegex.extractCode.firstMatch(in: text, options: [], range: nsRange),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text
    }

    /// Verifies the connection to the AI provider by sending a minimal prompt.
    func testConnection() async throws -> String {
        return try await fetchCompletion(prompt: "Hello. Respond with exactly the word 'OK'.")
    }

    nonisolated func sanitizeMarkdownToTypst(_ text: String, isHybrid: Bool = false) -> String {
        let processed = NSMutableString(string: text.replacingOccurrences(of: "\r\n", with: "\n"))

        // --- 1. MASK CODE BLOCKS ---
        // Temporarily hide inline and fenced code blocks so they aren't mangled by formatting regexes
        var codeBlocks: [String] = []
        let codeMatches = AICompletionRegex.codeBlock.matches(in: processed as String, options: [], range: NSRange(location: 0, length: processed.length))
        for match in codeMatches { codeBlocks.append(processed.substring(with: match.range)) }
        for (i, match) in codeMatches.enumerated().reversed() {
            // Changed from @@@ to purely alphanumeric tokens to prevent regex escaping collision
            processed.replaceCharacters(in: match.range, with: "MASKEDCODEBLOCK\(i)ENDMASK")
        }

        // --- 2. MASK MATH BLOCKS ---
        // Protect real equations so we can safely escape currency dollars later
        var mathBlocks: [String] = []
        let mathMatches = AICompletionRegex.mathBlock.matches(in: processed as String, options: [], range: NSRange(location: 0, length: processed.length))
        for match in mathMatches { mathBlocks.append(processed.substring(with: match.range)) }
        for (i, match) in mathMatches.enumerated().reversed() {
            // Changed from @@@ to purely alphanumeric tokens to prevent regex escaping collision
            processed.replaceCharacters(in: match.range, with: "MASKEDMATHBLOCK\(i)ENDMASK")
        }

        // Helper to safely apply precompiled regex replacements
        func applyRegex(_ regex: NSRegularExpression, template: String) {
            regex.replaceMatches(in: processed, options: [], range: NSRange(location: 0, length: processed.length), withTemplate: template)
        }

        // 3. Autolinks (Process before HTML tags to prevent crossfire).
        // Angle-bracket autolinks to known video hosts become clickable thumbnail embeds.
        let autoMatches = AICompletionRegex.autolink.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
        for match in autoMatches.reversed() {
            let url = processed.substring(with: match.range(at: 1))
            let host = url.lowercased()
            let replacement: String
            if host.contains("youtube.com") || host.contains("youtu.be") {
                replacement = Self.videoEmbed(for: url, alt: "YouTube video")
            } else if host.contains("vimeo.com") {
                replacement = Self.videoEmbed(for: url, alt: "Vimeo video")
            } else {
                replacement = "#link(\"\(url)\")"
            }
            processed.replaceCharacters(in: match.range, with: replacement)
        }

        // 3.5 Common HTML tags to Typst
        applyRegex(AICompletionRegex.htmlPAlign, template: "\n#align($1)[\n$2\n]\n")
        applyRegex(AICompletionRegex.htmlP, template: "\n$1\n")
        applyRegex(AICompletionRegex.htmlDt, template: "\n/ $1: ")
        applyRegex(AICompletionRegex.htmlDd, template: " $1\n")
        applyRegex(AICompletionRegex.htmlDl, template: "\n")
        applyRegex(AICompletionRegex.htmlStrong, template: "*$2*")
        applyRegex(AICompletionRegex.htmlEm, template: "_$2_")
        applyRegex(AICompletionRegex.htmlDel, template: "#strike[$1]")
        applyRegex(AICompletionRegex.htmlSup, template: "#super[$1]")
        applyRegex(AICompletionRegex.htmlSub, template: "#sub[$1]")
        applyRegex(AICompletionRegex.htmlU, template: "#underline[$1]")
        applyRegex(AICompletionRegex.htmlMark, template: "#highlight[$1]")
        applyRegex(AICompletionRegex.htmlBr, template: "\\\\")

        // 3.6 HTML Links and Images
        applyRegex(AICompletionRegex.htmlLink, template: "#link(\"$1\")[$2]")
        let htmlImgMatches = AICompletionRegex.htmlImg.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
        for match in htmlImgMatches.reversed() {
            let attributes = processed.substring(with: match.range(at: 1))
            var src = ""
            var alt = ""
            var width = ""
            var height = ""

            let attrRange = NSRange(0..<attributes.utf16.count)
            if let srcMatch = AICompletionRegex.imgSrc.firstMatch(in: attributes, options: [], range: attrRange) {
                src = (attributes as NSString).substring(with: srcMatch.range(at: 1))
            }
            if let altMatch = AICompletionRegex.imgAlt.firstMatch(in: attributes, options: [], range: attrRange) {
                alt = (attributes as NSString).substring(with: altMatch.range(at: 1))
            }
            if let widthMatch = AICompletionRegex.imgWidth.firstMatch(in: attributes, options: [], range: attrRange) {
                width = (attributes as NSString).substring(with: widthMatch.range(at: 1))
            }
            if let heightMatch = AICompletionRegex.imgHeight.firstMatch(in: attributes, options: [], range: attrRange) {
                height = (attributes as NSString).substring(with: heightMatch.range(at: 1))
            }

            if !src.isEmpty {
                let formattedSrc = src.lowercased().hasPrefix("http") || src.hasPrefix("/") || src.hasPrefix("data:") ? src : "/\(src)"
                var params: [String] = ["\"\(formattedSrc)\""]
                if !alt.isEmpty { params.append("alt: \"\(alt)\"") }

                // HTML width and height are typically in pixels. In Typst, we can append 'pt' if they are pure numbers.
                if !width.isEmpty {
                    if width.allSatisfy({ $0.isNumber }) {
                        params.append("width: \(width)pt")
                    } else {
                        params.append("width: \(width)")
                    }
                }
                if !height.isEmpty {
                    if height.allSatisfy({ $0.isNumber }) {
                        params.append("height: \(height)pt")
                    } else {
                        params.append("height: \(height)")
                    }
                }

                let ext = (src as NSString).pathExtension.lowercased()
                let isWeb = src.lowercased().hasPrefix("http")
                let supportedExts = ["png", "jpg", "jpeg", "gif", "svg"]

                let replacement: String
                if !isWeb && !ext.isEmpty && !supportedExts.contains(ext) {
                    // Fallback to a link if format is entirely unsupported by Typst (like .icns)
                    let displayAlt = alt.trimmingCharacters(in: .whitespaces).isEmpty ? "Image" : alt
                    replacement = "#link(\"\(src)\")[🖼️ \(displayAlt)]"
                } else {
                    replacement = "#image(\(params.joined(separator: ", ")))"
                }
                processed.replaceCharacters(in: match.range, with: replacement)
            }
        }

        // 4. Escape remaining HTML tags to prevent Typst label parsing crashes
        // Swallow optional preceding backslash to prevent double-escaping into an unclosed label
        // We use a negative lookahead `(?!(?:[a-z0-9_-]+)>)` to ensure we do NOT escape valid Typst labels `<label>`.
        applyRegex(AICompletionRegex.escapeHtmlTags, template: "\\\\<$1\\\\>")

        // 5. Markdown Footnotes -> Typst #footnote[]
        var footnotes: [String: String] = [:]
        // Extract reference footnote definitions: [^id]: text
        // This regex matches `[^id]:` at the start of a line, then lazily captures text until it sees
        // either the next `\n[^something]:` or the end of the string.
        let fnDefMatches = AICompletionRegex.fnDef.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
        for match in fnDefMatches.reversed() {
            let id = processed.substring(with: match.range(at: 1))
            let text = processed.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            footnotes[id] = text
            processed.replaceCharacters(in: match.range, with: "")
        }

        // Replace footnote references: [^id]
        let fnRefMatches = AICompletionRegex.fnRef.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
        for match in fnRefMatches.reversed() {
            let id = processed.substring(with: match.range(at: 1))
            if let text = footnotes[id] {
                processed.replaceCharacters(in: match.range, with: "#footnote[\(text)]")
            } else {
                // Escape it if no definition found so it doesn't break Typst math
                processed.replaceCharacters(in: match.range, with: "\\\\[\\\\^\(id)\\\\]")
            }
        }

        // Inline footnotes: ^[text]
        applyRegex(AICompletionRegex.fnInline, template: "#footnote[$1]")

        // 6. Headings (H1 - H6) -> Typst (=)
        let headingMatches = AICompletionRegex.heading.matches(in: processed as String, options: [], range: NSRange(location: 0, length: processed.length))
        for match in headingMatches.reversed() {
            let prefix = processed.substring(with: match.range(at: 1))
            let hashCount = match.range(at: 2).length
            let equals = String(repeating: "=", count: hashCount)
            processed.replaceCharacters(in: match.range, with: "\(prefix)\(equals) ")
        }

        // 6.5 Translate literal documentation space characters (⋅ or ·) to actual spaces
        while let match = AICompletionRegex.docDot.firstMatch(in: processed as String, options: [], range: NSRange(location: 0, length: processed.length)) {
            let matchedString = processed.substring(with: match.range)
            let replaced = matchedString.replacingOccurrences(of: "⋅", with: " ").replacingOccurrences(of: "·", with: " ")
            processed.replaceCharacters(in: match.range, with: replaced)
        }

        // 7. Task Lists -> Typst native Checkboxes
        applyRegex(AICompletionRegex.taskListChecked, template: "$1- ☑ ")
        applyRegex(AICompletionRegex.taskListUnchecked, template: "$1- ☐ ")

        // 8. Unordered Lists -> Typst (-)
        applyRegex(AICompletionRegex.unorderedList, template: "$1- ")

        // 9. Ordered Lists `1. ` -> Typst auto-numbering (`+ `)
        applyRegex(AICompletionRegex.orderedList, template: "$1+ ")

        // (Tables are converted AFTER inline formatting — see step 13.3 below — so that
        // links, bold, etc. inside cells are converted to Typst before the cell delimiters
        // are wrapped around them. Otherwise the link regex mistakes the cell `[...]` for
        // Markdown link syntax.)

        // 10. Strikethrough -> #strike[text]
        applyRegex(AICompletionRegex.strike, template: "#strike[$1]")

        // 10.4 Bold-Italic (Markdown *** or ___) -> Typst _*
        applyRegex(AICompletionRegex.boldItalicAsterisk, template: "_*$1*_")
        applyRegex(AICompletionRegex.boldItalicUnderscore, template: "_*$1*_")

        // 10.5 Fix asymmetrical bold markers
        applyRegex(AICompletionRegex.boldAsymmetric1, template: "**$1**")
        applyRegex(AICompletionRegex.boldAsymmetric2, template: "**$1**")

        // 10.6 Escape underscores in technical terms/filenames
        // In Hybrid mode (.note), Typst handles my_variable perfectly natively, and `_underscores_` is native italic.
        // If we escape underscores, we break valid Typst syntax.
        if !isHybrid {
            applyRegex(AICompletionRegex.technicalUnderscore, template: "\\\\_")
            applyRegex(AICompletionRegex.underscoreBeforeAsterisk, template: "\\\\_")
        }

        // 11. Bold (Markdown ** or __) -> Typst *
        applyRegex(AICompletionRegex.boldAsterisk, template: "*$1*")
        applyRegex(AICompletionRegex.boldUnderscore, template: "*$1*")

        // 12. Reference-Style Links & Images (Pass 1: Extract Definitions)
        var referenceLinks: [String: String] = [:]
        let refDefMatches = AICompletionRegex.refDef.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
        for match in refDefMatches.reversed() {
            let id = processed.substring(with: match.range(at: 1)).lowercased()
            let url = processed.substring(with: match.range(at: 2))
            referenceLinks[id] = url
            processed.replaceCharacters(in: match.range, with: "")
        }

        // 12.5 Reference-Style Images (Pass 2)
        let refImgMatches = AICompletionRegex.refImg.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
        for match in refImgMatches.reversed() {
            let alt = processed.substring(with: match.range(at: 1))
            var id = processed.substring(with: match.range(at: 2)).lowercased()
            if id.isEmpty { id = alt.lowercased() }

            if let url = referenceLinks[id] {
                let formattedUrl = url.lowercased().hasPrefix("http") || url.hasPrefix("/") || url.hasPrefix("data:") ? url : "/\(url)"
                let replacement = "#image(\"\(formattedUrl)\", alt: \"\(alt)\")"
                processed.replaceCharacters(in: match.range, with: replacement)
            }
        }

        // 12.6 Reference-Style Links (Pass 2)
        let refLinkMatches = AICompletionRegex.refLink.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
        for match in refLinkMatches.reversed() {
            let text = processed.substring(with: match.range(at: 1))
            var id = processed.substring(with: match.range(at: 2)).lowercased()
            if id.isEmpty { id = text.lowercased() }

            if let url = referenceLinks[id] {
                processed.replaceCharacters(in: match.range, with: "#link(\"\(url)\")[\(text)]")
            }
        }

        // 13. Inline Images
        let imgMatches = AICompletionRegex.inlineImg.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
        for match in imgMatches.reversed() {
            let altText = processed.substring(with: match.range(at: 1))
            let urlText = processed.substring(with: match.range(at: 2))

            let formattedUrl = urlText.lowercased().hasPrefix("http") || urlText.hasPrefix("/") || urlText.hasPrefix("data:") ? urlText : "/\(urlText)"
            let replacement = "#image(\"\(formattedUrl)\", alt: \"\(altText)\")"
            processed.replaceCharacters(in: match.range, with: replacement)
        }

        // 13.1 Inline Links (with special handling for video URLs)
        // For links pointing to known video hosts (YouTube, Vimeo, etc.), auto-embed the
        // thumbnail image as a clickable link to the video, so a single Markdown link like
        // `[Title](https://youtube.com/watch?v=...)` produces a full embed preview.
        let linkMatches = AICompletionRegex.inlineLink.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
        for match in linkMatches.reversed() {
            let linkText = processed.substring(with: match.range(at: 1))
            let rawUrl  = processed.substring(with: match.range(at: 2))

            let replacement: String
            if let ytID = Self.extractYouTubeID(from: rawUrl) {
                // If the link body is already an image (e.g. `[![alt](thumb)](url)` was
                // converted in step 13), keep that image as the clickable thumbnail and
                // don't try to inject a second one.
                if linkText.contains("#image(") {
                    replacement = "#link(\"\(rawUrl)\")[\(linkText)]"
                } else {
                    let thumb = "https://img.youtube.com/vi/\(ytID)/hqdefault.jpg"
                    let alt = Self.escapeTypstString(linkText)
                    replacement = "#link(\"\(rawUrl)\")[#image(\"\(thumb)\", alt: \"\(alt)\")]"
                }
            } else {
                replacement = "#link(\"\(rawUrl)\")[\(linkText)]"
            }
            processed.replaceCharacters(in: match.range, with: replacement)
        }

        // 13.2 Bare video URLs on their own line become clickable thumbnail embeds too,
        // so pasting a YouTube/Vimeo URL in body text is enough to render a preview.
        // (Angle-bracket autolinks are already handled in step 3 above.)
        let bareMatches = AICompletionRegex.bareVideo.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
        for match in bareMatches.reversed() {
            let url = processed.substring(with: match.range(at: 1))
            let alt = url.lowercased().contains("vimeo") ? "Vimeo video" : "YouTube video"
            processed.replaceCharacters(in: match.range, with: Self.videoEmbed(for: url, alt: alt))
        }

        // 13.3 Tables — converted AFTER inline formatting so cells already contain Typst
        // syntax (`#link(...)`, `*bold*`, etc.) by the time they're wrapped in `[...]`.
        // This prevents the inline regexes from matching the cell delimiters themselves.
        processed.setString(convertMarkdownTablesToTypst(processed as String))

        // 13.5 Escape Markdown abbreviation definitions
        applyRegex(AICompletionRegex.markdownAbbr, template: "\\\\*[$1]:")

        // 14. Horizontal Rules (---, ***, ___) -> #line(length: 100%)
        applyRegex(AICompletionRegex.horizontalRule, template: "#line(length: 100%)")

        // 14b. Common HTML Entities
        applyRegex(AICompletionRegex.entityRarr, template: "->")
        applyRegex(AICompletionRegex.entityLarr, template: "<-")

        // 14e. Escape Stray Backticks (Always)
        // A stray backtick ALWAYS crashes Typst as an unclosed raw block.
        // Valid code blocks are already masked, so any remaining backticks are stray.
        applyRegex(AICompletionRegex.strayBacktick, template: "\\\\`")

        // In pure Markdown mode (e.g. AI completions or .md files), we escape Typst's special characters
        // so they render as literal text. In hybrid mode (.note), we apply smart escaping to prevent
        // common Markdown patterns (like $1600 or user@email.com) from crashing the compiler, while
        // leaving native Typst functions (e.g. #title, $math$, @ref) alone.
        if !isHybrid {
            // 14. Escape Literal Dollars (Currency)
            applyRegex(AICompletionRegex.literalDollar, template: "\\\\$")

            // 14c. Escape Literal Hash
            applyRegex(AICompletionRegex.literalHash, template: "\\\\#")

            // 14g. Escape Literal At-Signs (@)
            applyRegex(AICompletionRegex.literalAt, template: "\\\\@")
        } else {
            // HYBRID MODE SMART ESCAPING
            // Escape dollars if followed by a digit (e.g. $1600) to prevent unclosed math block errors,
            // but leave other dollars alone so Typst math ($E=mc^2$) still works.
            applyRegex(AICompletionRegex.hybridDollarDigit, template: "\\\\$")

            // Escape @ if it's preceded by a letter/number (e.g. email addresses like user@email.com)
            // or followed by a space. Typst references (like @fig1) usually have a space before them and letters after.
            // The `(?<!\\)` guards keep this idempotent with `TypstCompiler.delimitImproperOperators`,
            // which already backslash-escapes these same cases (and warns the user) for `.note` files.
            applyRegex(AICompletionRegex.hybridAt, template: "\\\\@")

            // Smart `#` escaping: in `.note` files we leave most `#`-prefixed Typst alone
            // (so `#let`, `#score(...)`, `#emph[...]` all work). But pasted Markdown often
            // contains `#word` followed by sentence punctuation — e.g. "#refs," in
            // "@mentions, #refs, [links]()". That's not a Typst call (no `(` / `[` / `.`),
            // so escape the `#` to render it as literal text instead of erroring on an
            // unknown variable. Real Typst continuations (`#word(`, `#word[`, `#word.`)
            // are explicitly preserved by the negative lookahead.
            applyRegex(AICompletionRegex.hybridHash, template: "\\\\#$1")
        }

        // 14f. Un-escape characters inside Typst string parameters
        let strMatches = AICompletionRegex.stringLiteral.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
        for match in strMatches.reversed() {
            let matchedString = processed.substring(with: match.range)
            let unescaped = matchedString.replacingOccurrences(of: "\\_", with: "_")
                                         .replacingOccurrences(of: "\\*", with: "*")
                                         .replacingOccurrences(of: "\\#", with: "#")
                                         .replacingOccurrences(of: "\\`", with: "`")
            processed.replaceCharacters(in: match.range, with: unescaped)
        }

        var resultString = processed as String

        // 16. UNMASK AND CONVERT MATH BLOCKS
        for (i, block) in mathBlocks.enumerated() {
            var latexMath = ""
            if block.hasPrefix("$$") && block.hasSuffix("$$") {
                latexMath = String(block.dropFirst(2).dropLast(2))
            } else if block.hasPrefix("$") && block.hasSuffix("$") {
                latexMath = String(block.dropFirst(1).dropLast(1))
            } else if block.hasPrefix("\\[") && block.hasSuffix("\\]") {
                latexMath = String(block.dropFirst(2).dropLast(2))
            } else if block.hasPrefix("\\(") && block.hasSuffix("\\)") {
                latexMath = String(block.dropFirst(2).dropLast(2))
            } else {
                latexMath = block
            }
            let typstMath = LyxToTypstConverter.convertLatexMathToTypst(latexMath)
            resultString = resultString.replacingOccurrences(of: "MASKEDMATHBLOCK\(i)ENDMASK", with: "$ \(typstMath) $")
        }

        // 17. UNMASK CODE BLOCKS
        for (i, block) in codeBlocks.enumerated() {
            resultString = resultString.replacingOccurrences(of: "MASKEDCODEBLOCK\(i)ENDMASK", with: block)
        }

        return resultString
    }
    nonisolated private func convertMarkdownTablesToTypst(_ text: String) -> String {
        // Matches a table block including potential hard-wrapped lines (matches until a blank line).
        // Supports tables both with and without outer pipes.
        let matches = AICompletionRegex.markdownTable.matches(in: text, options: [], range: NSRange(0..<text.utf16.count))
        let processed = NSMutableString(string: text)

        for match in matches.reversed() {
            let tableText = processed.substring(with: match.range)
            let typstTable = parseSingleMarkdownTable(tableText)
            processed.replaceCharacters(in: match.range, with: typstTable + "\n")
        }

        return processed as String
    }

    nonisolated private func parseSingleMarkdownTable(_ markdown: String) -> String {
        let rawLines = markdown.components(separatedBy: .newlines)
        var lines: [String] = []

        // Safely re-join hard-wrapped lines that belong to the same row.
        // A line is treated as the START of a new row when it contains a `|` (the universal
        // Markdown table delimiter). Lines without a pipe are continuations of the previous
        // row — this lets tables work whether or not they use outer pipes (`| … |`) and
        // also gracefully joins soft-wrapped rows.
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.contains("|") {
                lines.append(trimmed)
            } else if !lines.isEmpty {
                lines[lines.count - 1] += " " + trimmed
            } else {
                lines.append(trimmed)
            }
        }

        guard lines.count >= 2 else { return markdown }

        func extractCells(from row: String) -> [String] {
            var rowText = row.trimmingCharacters(in: .whitespaces)
            if rowText.hasPrefix("|") { rowText.removeFirst() }
            if rowText.hasSuffix("|") { rowText.removeLast() }

            var cells: [String] = []
            var currentCell = ""
            var isEscaped = false

            for char in rowText {
                if isEscaped {
                    if char == "|" {
                        currentCell.append(char) // Keep pipe, drop backslash
                    } else {
                        currentCell.append("\\")
                        currentCell.append(char)
                    }
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "|" {
                    cells.append(currentCell.trimmingCharacters(in: .whitespaces))
                    currentCell = ""
                } else if char == "`" {
                    // Escape stray backticks (since valid code blocks are already masked)
                    currentCell.append("\\")
                    currentCell.append(char)
                } else {
                    currentCell.append(char)
                }
            }

            if isEscaped { currentCell.append("\\") }
            cells.append(currentCell.trimmingCharacters(in: .whitespaces))

            return cells
        }

        /// Parse a column-alignment marker (`:---`, `---:`, `:---:`, `---`) and return
        /// one of "left", "center", "right", or nil for default alignment.
        func alignment(for cell: String) -> String? {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("-") else { return nil }
            let leadingColon = trimmed.hasPrefix(":")
            let trailingColon = trimmed.hasSuffix(":")
            if leadingColon && trailingColon { return "center" }
            if leadingColon { return "left" }
            if trailingColon { return "right" }
            return nil  // plain `---` — leave default
        }

        let headerCells = extractCells(from: lines[0])
        let separatorCells = extractCells(from: lines[1])

        // Validate the separator: every cell must be a dash-alignment marker (or empty).
        let separatorIsValid = separatorCells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: "-", with: "")
                               .replacingOccurrences(of: ":", with: "")
                               .trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty && cell.contains("-")
        }
        guard separatorIsValid else { return markdown }

        let columnsCount = headerCells.count

        // Compute per-column alignments, if any non-default markers were specified.
        let columnAlignments: [String?] = (0..<columnsCount).map { idx in
            idx < separatorCells.count ? alignment(for: separatorCells[idx]) : nil
        }
        let hasAnyAlignment = columnAlignments.contains { $0 != nil }

        var typst = "#table(\n"
        typst += "  columns: \(columnsCount),\n"
        if hasAnyAlignment {
            // `align: (x, y, z, ...)` accepts `left`, `center`, `right`, or `auto` per column.
            let aligns = columnAlignments.map { $0 ?? "auto" }.joined(separator: ", ")
            typst += "  align: (\(aligns)),\n"
        }

        // Headers
        typst += "  table.header(\n"
        for cell in headerCells {
            typst += "    [\(escapeTableCell(cell))],\n"
        }
        typst += "  ),\n"

        // Body rows
        for i in 2..<lines.count {
            var cells = extractCells(from: lines[i])

            while cells.count < columnsCount { cells.append("") }
            cells = Array(cells.prefix(columnsCount))

            for cell in cells {
                typst += "  [\(escapeTableCell(cell))],\n"
            }
        }

        typst += ")"
        return typst
    }

    /// Lightly escapes characters in a table cell that would otherwise confuse Typst.
    ///
    /// Note: Typst tracks `[...]` depth, so nested literal brackets (`[link]`) inside a
    /// content-block cell render correctly without escaping — we therefore leave them
    /// alone so legitimate inline Typst syntax (`#link(...)[$1]`, `*bold*`) keeps working.
    /// We only neutralise dangling backslashes at the very end of a cell, since those
    /// would otherwise escape the closing `]` and break the cell.
    nonisolated private func escapeTableCell(_ cell: String) -> String {
        var result = cell
        // A trailing backslash would escape the cell's closing `]`; double it so it
        // becomes a literal backslash followed by the closing bracket.
        while result.hasSuffix("\\") && !result.hasSuffix("\\\\") {
            result += "\\"
        }
        return result
    }

    // MARK: - Video Link Helpers

    /// Extracts the 11-character video ID from any common YouTube URL shape:
    /// `youtube.com/watch?v=ID`, `youtu.be/ID`, `youtube.com/embed/ID`,
    /// `youtube.com/shorts/ID`, `m.youtube.com/...`, etc.
    /// Returns nil if `url` doesn't look like a YouTube link.
    nonisolated static func extractYouTubeID(from url: String) -> String? {
        // Normalise HTML entities so `&amp;v=` works the same as `&v=`.
        let cleaned = url.replacingOccurrences(of: "&amp;", with: "&")
        let nsText = cleaned as NSString
        guard let match = AICompletionRegex.youtubeID.firstMatch(in: cleaned, options: [], range: NSRange(0..<nsText.length)) else { return nil }
        return nsText.substring(with: match.range(at: 1))
    }

    /// Extracts the numeric video ID from a Vimeo URL (`vimeo.com/123456`,
    /// `player.vimeo.com/video/123456`). Returns nil otherwise.
    nonisolated static func extractVimeoID(from url: String) -> String? {
        let nsText = url as NSString
        guard let match = AICompletionRegex.vimeoID.firstMatch(in: url, options: [], range: NSRange(0..<nsText.length)) else { return nil }
        return nsText.substring(with: match.range(at: 1))
    }

    /// Escapes a string for safe inclusion inside a Typst string literal `"..."`.
    nonisolated static func escapeTypstString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Wraps a video URL in a Typst clickable thumbnail embed.
    /// For YouTube we can derive a free thumbnail from `img.youtube.com`; for other hosts
    /// we just produce a styled text link with a play marker so the link is still obvious.
    nonisolated static func videoEmbed(for url: String, alt: String) -> String {
        let escapedAlt = escapeTypstString(alt)
        if let ytID = extractYouTubeID(from: url) {
            let thumb = "https://img.youtube.com/vi/\(ytID)/hqdefault.jpg"
            return "#link(\"\(url)\")[#image(\"\(thumb)\", alt: \"\(escapedAlt)\")]"
        }
        // Vimeo doesn't expose a free public thumbnail URL, so render a clearly-clickable
        // text link instead. The user can swap in their own image if desired.
        return "#link(\"\(url)\")[▶ \(alt)]"
    }
}
