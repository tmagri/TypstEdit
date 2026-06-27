import Foundation

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

@MainActor
class AICompletionService: ObservableObject {
    static let shared = AICompletionService()
    
    @Published var isFetching: Bool = false
    
    private init() {}
    
    func fetchCompletion(prompt: String, systemPrompt: String = "You are a precise code completion engine. Output only the code to insert at the cursor.", maxTokens: Int = 128) async throws -> String {
        isFetching = true
        defer { isFetching = false }
        
        let settings = AISettingsManager.shared
        
        // Only require API key for non-custom providers, or if custom provider is not localhost
        if settings.provider != .custom && settings.apiKey.isEmpty {
            throw AIError.apiError("API Key is missing for \(settings.provider.rawValue)")
        }
        
        let endpoint: String
        let isGemini = settings.provider == .gemini
        
        switch settings.provider {
        case .openAI: endpoint = "https://api.openai.com/v1/chat/completions"
        case .openRouter: endpoint = "https://openrouter.ai/api/v1/chat/completions"
        case .gemini: endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(settings.model):generateContent?key=\(settings.apiKey)"
        case .custom: endpoint = settings.customEndpoint
        }
        
        guard let url = URL(string: endpoint) else {
            throw AIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeoutSeconds
        // Gemini API key is in URL query parameter, not header
        if !isGemini {
            request.addValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // OpenRouter specific headers
        if settings.provider == .openRouter {
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
                    "maxOutputTokens": maxTokens,
                    "temperature": 0.2
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
                "model": settings.model,
                "messages": messages,
                "max_tokens": maxTokens,
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
        if settings.forceCodeOutput {
            let extracted = extractCode(from: rawResult)
            // Fallback to the raw text if the AI didn't format it as a code block
            finalResult = extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rawResult : extracted
        }
        
        let sanitizedResult = sanitizeMarkdownToTypst(finalResult)
        
        print("RAW AI RESULT: '\(rawResult)'")
        print("SANITIZED RESULT: '\(sanitizedResult)'")

        // Trap completely empty responses so the UI doesn't silently reset
        if sanitizedResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIError.apiError("The AI processed the request but returned an empty response. Try rephrasing your prompt.")
        }
        
        return sanitizedResult
    }
    
    private func extractCode(from text: String) -> String {
        // Look for content between ``` and ```
        let pattern = "```(?:[a-zA-Z]*\\n)?([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: nsRange),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return text
    }
    
    /// Verifies the connection to the AI provider by sending a minimal prompt.
    func testConnection() async throws -> String {
        return try await fetchCompletion(prompt: "Hello. Respond with exactly the word 'OK'.")
    }

    func sanitizeMarkdownToTypst(_ text: String) -> String {
        let processed = NSMutableString(string: text.replacingOccurrences(of: "\r\n", with: "\n"))
        
        // --- 1. MASK CODE BLOCKS ---
        // Temporarily hide inline and fenced code blocks so they aren't mangled by formatting regexes
        var codeBlocks: [String] = []
        do {
            // Matches any number of opening backticks, lazy content, and the exact same number of closing backticks.
            let codeRegex = try NSRegularExpression(pattern: "(?s)(`+).*?(?<!`)\\1(?!`)", options: [])
            let matches = codeRegex.matches(in: processed as String, options: [], range: NSRange(location: 0, length: processed.length))
            for match in matches { codeBlocks.append(processed.substring(with: match.range)) }
            for (i, match) in matches.enumerated().reversed() {
                // Changed from @@@ to purely alphanumeric tokens to prevent regex escaping collision
                processed.replaceCharacters(in: match.range, with: "MASKEDCODEBLOCK\(i)ENDMASK")
            }
        } catch { print("Code block mask regex failed: \(error)") }
        
        // --- 2. MASK MATH BLOCKS ---
        // Protect real equations so we can safely escape currency dollars later
        var mathBlocks: [String] = []
        do {
            // Strict matching: $$...$$ | $...$ (no newlines) | \[...\] | \(...\)
            let mathPattern = "(?s)\\$\\$.+?\\$\\$|(?<!\\\\)\\$(?!\\s)[^\\$\\n]+?(?<!\\s)(?<!\\\\)\\$|(?s)\\\\\\[.+?\\\\\\]|(?s)\\\\\\([^\\n]+?\\\\\\)"
            let mathRegex = try NSRegularExpression(pattern: mathPattern, options: [])
            let matches = mathRegex.matches(in: processed as String, options: [], range: NSRange(location: 0, length: processed.length))
            for match in matches { mathBlocks.append(processed.substring(with: match.range)) }
            for (i, match) in matches.enumerated().reversed() {
                // Changed from @@@ to purely alphanumeric tokens to prevent regex escaping collision
                processed.replaceCharacters(in: match.range, with: "MASKEDMATHBLOCK\(i)ENDMASK")
            }
        } catch { print("Math block mask regex failed: \(error)") }
        
        // Helper to safely apply regex replacements so one failure doesn't crash the pipeline
        func applyRegex(_ pattern: String, template: String) {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [])
                regex.replaceMatches(in: processed, options: [], range: NSRange(location: 0, length: processed.length), withTemplate: template)
            } catch { print("Regex failed: \(pattern) - \(error)") }
        }
        
        // 3. Autolinks (Process before HTML tags to prevent crossfire)
        applyRegex("<(https?://[^>\\s]+)>", template: "#link(\"$1\")")
        
        // 3.5 Common HTML tags to Typst
        applyRegex("(?is)\\s*<p\\s+align=[\"']([^\"']+)[\"']>\\s*(.*?)\\s*</p>\\s*", template: "\n#align($1)[\n$2\n]\n")
        applyRegex("(?is)\\s*<p>\\s*(.*?)\\s*</p>\\s*", template: "\n$1\n")
        applyRegex("(?is)\\s*<dt>(.*?)</dt>\\s*", template: "\n/ $1: ")
        applyRegex("(?is)\\s*<dd>(.*?)</dd>\\s*", template: " $1\n")
        applyRegex("(?i)\\s*</?dl>\\s*", template: "\n")
        applyRegex("(?is)<(strong|b)>(.*?)</\\1>", template: "*$2*")
        applyRegex("(?is)<(em|i)>(.*?)</\\1>", template: "_$2_")
        applyRegex("(?is)<del>(.*?)</del>", template: "#strike[$1]")
        applyRegex("(?i)<br\\s*/?>", template: "\\\\")
        
        // 3.6 HTML Links and Images
        applyRegex("(?is)<a\\s+(?:[^>]*?\\s+)?href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", template: "#link(\"$1\")[$2]")
        if let htmlImgRegex = try? NSRegularExpression(pattern: "(?i)<img\\s+([^>]+)>", options: []) {
            let matches = htmlImgRegex.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
            for match in matches.reversed() {
                let attributes = processed.substring(with: match.range(at: 1))
                var src = ""
                var alt = ""
                var width = ""
                var height = ""
                
                if let srcMatch = try? NSRegularExpression(pattern: "(?i)src=[\"']([^\"']+)[\"']").firstMatch(in: attributes, options: [], range: NSRange(0..<attributes.utf16.count)) {
                    src = (attributes as NSString).substring(with: srcMatch.range(at: 1))
                }
                if let altMatch = try? NSRegularExpression(pattern: "(?i)alt=[\"']([^\"']*)[\"']").firstMatch(in: attributes, options: [], range: NSRange(0..<attributes.utf16.count)) {
                    alt = (attributes as NSString).substring(with: altMatch.range(at: 1))
                }
                if let widthMatch = try? NSRegularExpression(pattern: "(?i)width=[\"']([^\"']+)[\"']").firstMatch(in: attributes, options: [], range: NSRange(0..<attributes.utf16.count)) {
                    width = (attributes as NSString).substring(with: widthMatch.range(at: 1))
                }
                if let heightMatch = try? NSRegularExpression(pattern: "(?i)height=[\"']([^\"']+)[\"']").firstMatch(in: attributes, options: [], range: NSRange(0..<attributes.utf16.count)) {
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
        }

        // 4. Escape remaining HTML tags to prevent Typst label parsing crashes
        // Swallow optional preceding backslash to prevent double-escaping into an unclosed label
        applyRegex("(?i)\\\\?<(/?[a-z][a-z0-9]*\\b[^>]*)>", template: "\\\\<$1\\\\>")
        
        // 5. Escape Markdown footnotes to prevent Typst math errors
        applyRegex("\\[\\^([^\\]]+)\\]", template: "\\\\[\\\\^$1\\\\]")
        
        // 6. Headings (H1 - H6) -> Typst (=)
        if let headingRegex = try? NSRegularExpression(pattern: "(?m)^([ \\t]*(?:>[ \\t]*)?)(#+)[ \\t]+", options: []) {
            let headingMatches = headingRegex.matches(in: processed as String, options: [], range: NSRange(location: 0, length: processed.length))
            for match in headingMatches.reversed() {
                let prefix = processed.substring(with: match.range(at: 1))
                let hashCount = match.range(at: 2).length
                let equals = String(repeating: "=", count: hashCount)
                processed.replaceCharacters(in: match.range, with: "\(prefix)\(equals) ")
            }
        }
        
        // 6.5 Translate literal documentation space characters (⋅ or ·) to actual spaces
        if let dotRegex = try? NSRegularExpression(pattern: "(?m)^([ \\t]*)[⋅·]+", options: []) {
            while let match = dotRegex.firstMatch(in: processed as String, options: [], range: NSRange(location: 0, length: processed.length)) {
                let matchedString = processed.substring(with: match.range)
                let replaced = matchedString.replacingOccurrences(of: "⋅", with: " ").replacingOccurrences(of: "·", with: " ")
                processed.replaceCharacters(in: match.range, with: replaced)
            }
        }
        
        // 7. Task Lists -> Typst native Checkboxes
        applyRegex("(?m)^([ \\t]*(?:>[ \\t]*)?)[-*+][ \\t]+\\[[xX]\\][ \\t]+", template: "$1- ☑ ")
        applyRegex("(?m)^([ \\t]*(?:>[ \\t]*)?)[-*+][ \\t]+\\[ \\][ \\t]+", template: "$1- ☐ ")
        
        // 8. Unordered Lists -> Typst (-)
        applyRegex("(?m)^([ \\t]*(?:>[ \\t]*)?)[*+][ \\t]+", template: "$1- ")
        
        // 9. Ordered Lists `1. ` -> Typst auto-numbering (`+ `)
        applyRegex("(?m)^([ \\t]*(?:>[ \\t]*)?)\\d+\\.[ \\t]+", template: "$1+ ")

        // 9.5 Tables
        processed.setString(convertMarkdownTablesToTypst(processed as String))

        // 10. Strikethrough -> #strike[text]
        applyRegex("~~(.+?)~~", template: "#strike[$1]")
        
        // 10.4 Bold-Italic (Markdown *** or ___) -> Typst _*
        applyRegex("\\*\\*\\*(.+?)\\*\\*\\*", template: "_*$1*_")
        applyRegex("___(.+?)___", template: "_*$1*_")
        
        // 10.5 Fix asymmetrical bold markers
        applyRegex("(?<!\\*)\\*\\*\\*([^*\\n]+)\\*\\*(?!\\*)", template: "**$1**")
        applyRegex("(?<!\\*)\\*\\*([^*\\n]+)\\*\\*\\*(?!\\*)", template: "**$1**")
        
        // 10.6 Escape underscores in technical terms/filenames
        applyRegex("(?<=[a-zA-Z0-9])_(?=[a-zA-Z0-9])", template: "\\\\_")
        applyRegex("_(?=\\\\?\\*(?!\\*))", template: "\\\\_")
        
        // 11. Bold (Markdown ** or __) -> Typst *
        applyRegex("\\*\\*(.+?)\\*\\*", template: "*$1*")
        applyRegex("__(.+?)__", template: "*$1*")
        
        // 12. Reference-Style Links & Images (Pass 1: Extract Definitions)
        var referenceLinks: [String: String] = [:]
        if let refDefRegex = try? NSRegularExpression(pattern: "(?m)^[ \\t]*\\[([^\\]]+)\\]:[ \\t]+([^ \\t\\n]+)(?:[ \\t]+[\"'(].*?[\"')])?[ \\t]*$", options: []) {
            let matches = refDefRegex.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
            for match in matches.reversed() {
                let id = processed.substring(with: match.range(at: 1)).lowercased()
                let url = processed.substring(with: match.range(at: 2))
                referenceLinks[id] = url
                processed.replaceCharacters(in: match.range, with: "")
            }
        }
        
        // 12.5 Reference-Style Images (Pass 2)
        if let refImgRegex = try? NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\[([^\\]]*)\\]", options: []) {
            let matches = refImgRegex.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
            for match in matches.reversed() {
                let alt = processed.substring(with: match.range(at: 1))
                var id = processed.substring(with: match.range(at: 2)).lowercased()
                if id.isEmpty { id = alt.lowercased() }
                
                if let url = referenceLinks[id] {
                    let formattedUrl = url.lowercased().hasPrefix("http") || url.hasPrefix("/") || url.hasPrefix("data:") ? url : "/\(url)"
                    let replacement = "#image(\"\(formattedUrl)\", alt: \"\(alt)\")"
                    processed.replaceCharacters(in: match.range, with: replacement)
                }
            }
        }
        
        // 12.6 Reference-Style Links (Pass 2)
        if let refLinkRegex = try? NSRegularExpression(pattern: "(?<!!)\\[([^\\]]+)\\]\\[([^\\]]*)\\]", options: []) {
            let matches = refLinkRegex.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
            for match in matches.reversed() {
                let text = processed.substring(with: match.range(at: 1))
                var id = processed.substring(with: match.range(at: 2)).lowercased()
                if id.isEmpty { id = text.lowercased() }
                
                if let url = referenceLinks[id] {
                    processed.replaceCharacters(in: match.range, with: "#link(\"\(url)\")[\(text)]")
                }
            }
        }

        // 13. Inline Images
        if let imgRegex = try? NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\(\\s*([^)\\s]+)(?:\\s+\"[^\"]*\")?\\s*\\)", options: []) {
            let matches = imgRegex.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
            for match in matches.reversed() {
                let altText = processed.substring(with: match.range(at: 1))
                let urlText = processed.substring(with: match.range(at: 2))
                
                let formattedUrl = urlText.lowercased().hasPrefix("http") || urlText.hasPrefix("/") || urlText.hasPrefix("data:") ? urlText : "/\(urlText)"
                let replacement = "#image(\"\(formattedUrl)\", alt: \"\(altText)\")"
                processed.replaceCharacters(in: match.range, with: replacement)
            }
        }
        
        // 13.1 Inline Links
        applyRegex("(?<!!)\\[([^\\]]+)\\]\\(\\s*([^)\\s]+)(?:\\s+\"[^\"]*\")?\\s*\\)", template: "#link(\"$2\")[$1]")
        
        // 13.5 Escape Markdown abbreviation definitions
        applyRegex("(?m)^\\*\\[([^\\]]+)\\]:", template: "\\\\*[$1]:")
        
        // 14. Horizontal Rules (---, ***, ___) -> #line(length: 100%)
        applyRegex("(?m)^[-*_]{3,}[ \\t]*$", template: "#line(length: 100%)")
        
        // 14. Escape Literal Dollars (Currency)
        applyRegex("(?<!\\\\)\\$", template: "\\\\$")
        
        // 14b. Common HTML Entities
        applyRegex("(?i)&rarr;", template: "->")
        applyRegex("(?i)&larr;", template: "<-")
                
        // 14c. Escape Literal Hash
        applyRegex("(?<!\\\\)#(?!link\\(|image\\(|strike\\[|line\\(|table\\(|figure\\(|align\\(|kbd\\[)", template: "\\\\#")
        
        // 14e. Escape Stray Backticks
        applyRegex("(?<!\\\\)`", template: "\\\\`")
        
        // 14g. Escape Literal At-Signs (@)
        applyRegex("(?<!\\\\)@", template: "\\\\@")

        // 14f. Un-escape characters inside Typst string parameters
        if let stringRegex = try? NSRegularExpression(pattern: "\"[^\"]*\"", options: []) {
            let matches = stringRegex.matches(in: processed as String, options: [], range: NSRange(0..<processed.length))
            for match in matches.reversed() {
                let matchedString = processed.substring(with: match.range)
                let unescaped = matchedString.replacingOccurrences(of: "\\_", with: "_")
                                             .replacingOccurrences(of: "\\*", with: "*")
                                             .replacingOccurrences(of: "\\#", with: "#")
                                             .replacingOccurrences(of: "\\`", with: "`")
                processed.replaceCharacters(in: match.range, with: unescaped)
            }
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
    private func convertMarkdownTablesToTypst(_ text: String) -> String {
        // Matches a table block including potential hard-wrapped lines (matches until a blank line)
        let pattern = "(?m)^[ \\t]*\\|[^\\n]*\\n[ \\t]*\\|[-:| \\t]*\\|[^\\n]*(?:\\n(?![ \\t]*$)[^\\n]*)*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        
        let matches = regex.matches(in: text, options: [], range: NSRange(0..<text.utf16.count))
        let processed = NSMutableString(string: text)
        
        for match in matches.reversed() {
            let tableText = processed.substring(with: match.range)
            let typstTable = parseSingleMarkdownTable(tableText)
            processed.replaceCharacters(in: match.range, with: typstTable + "\n")
        }
        
        return processed as String
    }
    
    private func parseSingleMarkdownTable(_ markdown: String) -> String {
        let rawLines = markdown.components(separatedBy: .newlines)
        var lines: [String] = []
        
        // Safely re-join hard-wrapped lines that belong to the same row
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            
            if trimmed.hasPrefix("|") {
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
                } else {
                    currentCell.append(char)
                }
            }
            
            if isEscaped { currentCell.append("\\") }
            cells.append(currentCell.trimmingCharacters(in: .whitespaces))
            
            return cells
        }
        
        let headerCells = extractCells(from: lines[0])
        let separatorLine = lines[1].replacingOccurrences(of: "-", with: "")
                                    .replacingOccurrences(of: "|", with: "")
                                    .replacingOccurrences(of: ":", with: "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard separatorLine.isEmpty else { return markdown }
        
        let columnsCount = headerCells.count
        var typst = "#table(\n"
        typst += "  columns: \(columnsCount),\n"
        
        // Headers
        typst += "  table.header(\n"
        for cell in headerCells {
            typst += "    [\(cell)],\n"
        }
        typst += "  ),\n"
        
        // Body rows
        for i in 2..<lines.count {
            var cells = extractCells(from: lines[i])
            
            while cells.count < columnsCount { cells.append("") }
            cells = Array(cells.prefix(columnsCount))
            
            for cell in cells {
                typst += "  [\(cell)],\n"
            }
        }
        
        typst += ")"
        return typst
    }
}
