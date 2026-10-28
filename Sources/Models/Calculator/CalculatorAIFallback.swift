import Foundation

/// Wolfram|Alpha-style fallback for the calculator: when the CAS fails — or
/// merely echoes the entry back as a quoted string — and the entry reads like
/// a natural-language question, the configured chat model is asked to
/// interpret it. Computable questions become a TI-syntax expression that is
/// evaluated locally by the CAS, so the number comes from Giac, not from the
/// model (which matters for small local models); knowledge and counting
/// questions get a prose answer.
///
/// Deliberately conservative about what it routes:
/// - Only fires after the CAS failed or returned a string echo, so real math
///   never costs a request.
/// - Formula-shaped input (a bare function call like `sovle(x^2-4=0,x)`, or
///   operator-heavy input like `solve x^2 - 4 = 0 for x`) is never routed —
///   the CAS error must stay visible so the typo can be fixed. Prose that
///   embeds math notation ("…velocity of 6 m/s, using g = 9.8 m/s^2, how
///   many seconds…?") does route: it is a question with units, not a formula.
/// - Double opt-in: AI Chat must be enabled AND this feature switched on
///   (Settings → General → Calculator → AI Fallback).
@MainActor
enum CalculatorAIFallback {

    /// The model's reading of one question.
    struct Interpretation: Sendable {
        /// A TI-syntax expression to evaluate locally, when the question is
        /// computable; `nil` for knowledge and counting questions.
        var expression: String?
        /// The model's short prose answer (or interpretation note).
        var answer: String
    }

    /// Openers that make an entry a question. Generous on purpose: this only
    /// runs after a CAS failure, so a false positive costs one small request
    /// while a false negative just shows the CAS error.
    private nonisolated static let questionStarters: Set<String> = [
        "what", "whats", "how", "why", "who", "whos", "whom", "when", "where", "which",
        "is", "are", "was", "were", "does", "do", "did", "can", "could", "should",
        "would", "will", "define", "explain", "convert", "calculate", "compute",
        "count", "list", "name", "tell", "compare", "spell", "translate", "write", "give",
    ]

    /// Phrasings that mark a question wherever they appear. These catch word
    /// problems that open with an article ("A boy throws a ball … how many
    /// seconds does it take …?") and embed math notation ("g = 9.8 m/s^2").
    private nonisolated static let questionPhrases: [String] = [
        "how many", "how much", "how long", "how far", "how fast", "how old",
        "how big", "how tall", "how high", "how heavy", "what is", "what's",
        "calculate", "determine", "find the", "find out", "give just",
    ]

    /// True when the user has opted in twice (AI Chat + this toggle) and a
    /// usable model is configured — a cloud provider needs its API key.
    static func isAvailable() -> Bool {
        let settings = AISettingsManager.shared
        guard settings.chatEnabled, settings.calcAIFallbackEnabled else { return false }
        let context = settings.modelContext(for: .generation)
        return context.isLocal || !context.apiKey.isEmpty
    }

    /// Heuristic for "this entry is a question, not a broken formula".
    /// `nonisolated` so tests can call it without hopping to the main actor.
    nonisolated static func looksLikeNaturalLanguage(_ raw: String) -> Bool {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...500).contains(input.count) else { return false }

        // A bare function call is a formula attempt however it is spelled
        // ("sovle(x^2-4=0,x)"): the user needs the CAS error to fix the typo.
        if input.range(of: #"^[A-Za-z_]\w*\("#, options: .regularExpression) != nil {
            return false
        }

        let words = input.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard words.count >= 3 else { return false }

        let lowered = input.lowercased()

        // Strong prose signals. A question mark never appears in valid CAS
        // syntax, so it is decisive even when the entry embeds math notation.
        if input.contains("?") { return true }
        let first = words[0]
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\"“”‘’(?"))
            .lowercased()
        if questionStarters.contains(first) { return true }
        if questionPhrases.contains(where: { lowered.contains($0) }) { return true }

        // Otherwise judge by shape: prose is mostly letter-bearing words,
        // formulas are mostly operators and figures. The 60% floor keeps
        // units inside word problems ("velocity of 6 m/s, using g = 9.8")
        // routing, while operator-heavy input ("solve x^2 - 4 = 0 for x")
        // stays with the CAS.
        let letterWords = words.filter { $0.contains(where: { $0.isLetter }) }
        return letterWords.count >= 4
            && Double(letterWords.count) >= 0.6 * Double(words.count)
    }

    /// True when the CAS reported success but the whole "result" is just the
    /// input echoed back — what the helper does with prose it cannot evaluate
    /// ("Area of a circle…" → `"Area of a circle…"`). For routing purposes
    /// that counts as a failure: the question deserves the AI.
    /// `nonisolated` so tests can call it without hopping to the main actor.
    nonisolated static func isStringEcho(_ result: CASEvalResult, input: String) -> Bool {
        if let tree = result.resultTree, case .string = tree {
            return true
        }
        let text = result.resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return false }
        let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        return inner == input.trimmingCharacters(in: .whitespaces)
    }

    /// True when the CAS reported success but the result is not usable as an
    /// answer: a string echo of the input, or `undef` (Giac's answer for text
    /// it cannot make sense of — the same rule the document calculator uses).
    /// `nonisolated` so tests can call it without hopping to the main actor.
    nonisolated static func isUnhelpfulResult(_ result: CASEvalResult, input: String) -> Bool {
        isStringEcho(result, input: input) || isUndefined(result)
    }

    /// Giac answers `undef` instead of an error for text it cannot interpret
    /// ("the derivative of x^2" → `undef`), sometimes embedded in a mangled
    /// expression ("… at x = 0" → `undef = 0`), so any `undef` token counts.
    /// `nonisolated` so tests can call it without hopping to the main actor.
    nonisolated static func isUndefined(_ result: CASEvalResult) -> Bool {
        if let tree = result.resultTree, containsUndefined(tree) { return true }
        return result.resultText.range(
            of: #"\bundef(ined)?\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Walks the expression graph for an `undef` node.
    /// `nonisolated` so tests can call it without hopping to the main actor.
    nonisolated static func containsUndefined(_ expression: CASExpression) -> Bool {
        switch expression {
        case .undefined:
            return true
        case .symbol(let name):
            let lowered = name.lowercased()
            return lowered == "undef" || lowered == "undefined"
        case .operation(_, let args), .function(_, let args),
             .sequence(let args), .vector(let args), .list(let args):
            return args.contains(where: containsUndefined)
        case .number, .constant, .string:
            return false
        }
    }

    /// Interpreter instructions: a small language spec, not a chat prompt.
    /// Each line is either part of the parse contract (the two labels, the
    /// `none` escape hatch) or CAS dialect the model would otherwise get
    /// wrong (function names and arities that are not standard notation).
    /// The two examples anchor the two reply shapes; keep it that lean.
    private static let instructions = """
    You are the interpreter for a calculator app (TI-89 style syntax). Its math engine could not evaluate the entry below, so you interpret it.

    If the entry has a computable numeric answer, EXPR is a calculator expression that computes it:
    - Allowed: numbers, + - * / ^, parentheses, pi, e, sqrt, sin, cos, tan, log, ln, abs, root(x,n), d(f,x), integrate(f,x,a,b), taylor(f,x,order) around 0 (shift the variable for another point: f(x+a)), solve(equation,x).
    - Substitute the entry's numbers and convert units so the answer comes out in the unit asked for; keep x only when the entry asks for an expression, like a derivative or a series.
    Otherwise (definitions, general knowledge, counting letters), EXPR is: none

    Reply with EXACTLY these two lines and nothing else:
    EXPR: <expression or none>
    ANSWER: <one short sentence answering the entry>

    Examples:
    Question: What is the area of a circle if the diameter is 1 cm?
    EXPR: pi*(1/2)^2
    ANSWER: The area is pi/4, about 0.785 square centimeters.
    Question: How many r's are in strawberry?
    EXPR: none
    ANSWER: 3 — s-t-r-a-w-b-e-r-r-y has an r at positions 3, 8 and 9.
    """

    /// Asks the user's configured chat model to interpret the entry. Throws
    /// so the caller can fall back to the CAS error entry on failure.
    static func interpret(_ question: String) async throws -> Interpretation {
        let raw = try await AICompletionService.shared.fetchCompletion(
            prompt: """
            \(instructions)

            Question: \(question)
            """,
            systemPrompt: "You interpret questions for a calculator app and always reply in the exact two-line EXPR/ANSWER format. Reason carefully and count precisely before writing the ANSWER line.",
            // Enough headroom that the ANSWER line is never cut off when the
            // model writes a longer formula; the ceiling does not cost
            // anything by itself.
            maxTokens: 800,
            purpose: .chat,
            sanitize: false)
        return parseInterpretation(raw)
    }

    /// Parses the EXPR/ANSWER reply, tolerating the variations small models
    /// produce: markdown-wrapped labels (`**EXPR:**`), both label spellings,
    /// missing lines, and formatless prose.
    /// `nonisolated` so tests can call it without hopping to the main actor.
    nonisolated static func parseInterpretation(_ raw: String) -> Interpretation {
        var expression: String?
        var sawExpressionLabel = false
        var answerLines: [String] = []
        var collectingAnswer = false

        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Strip the markdown wrappers models like to add around labels.
            let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "*_`#> "))
            let lower = cleaned.lowercased()

            if lower.hasPrefix("expression:"), cleaned.count > "expression:".count {
                expression = interpretationExpression(String(cleaned.dropFirst("expression:".count)))
                sawExpressionLabel = true
                collectingAnswer = false
            } else if lower.hasPrefix("expr:"), cleaned.count > "expr:".count {
                expression = interpretationExpression(String(cleaned.dropFirst("expr:".count)))
                sawExpressionLabel = true
                collectingAnswer = false
            } else if lower.hasPrefix("answer:"), cleaned.count > "answer:".count {
                let value = String(cleaned.dropFirst("answer:".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*_` "))
                if !value.isEmpty { answerLines.append(value) }
                collectingAnswer = true
            } else if collectingAnswer {
                answerLines.append(trimmed)
            }
        }

        let answer = answerLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        // The model followed the format (an EXPR label appeared): use the
        // parsed pieces. Note `expression` is nil both for EXPR: none and
        // for no answer at all, so the label flag is what tells them apart.
        if sawExpressionLabel {
            if let expression {
                return Interpretation(expression: expression,
                                      answer: answer.isEmpty ? "Interpreted as \(expression)." : answer)
            }
            if !answer.isEmpty {
                return Interpretation(expression: nil, answer: answer)
            }
            return Interpretation(expression: nil,
                                  answer: "The model could not interpret this entry.")
        }
        // No EXPR label: the whole reply is the answer (covers models that
        // ignore the format and just answer in prose).
        return Interpretation(expression: nil,
                              answer: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Cleans one EXPR value: strips markdown leftovers, maps typographic
    /// math to ASCII, drops a sentence-ending period. Returns nil for empty
    /// values and explicit "none".
    nonisolated static func interpretationExpression(_ raw: String) -> String? {
        let mapped = raw
            .replacingOccurrences(of: "π", with: "pi")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "²", with: "^2")
            .replacingOccurrences(of: "³", with: "^3")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "$", with: "")
        var text = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "*_ \t"))
        if text.hasSuffix("."), text.count > 1 {
            let before = text[text.index(before: text.index(before: text.endIndex))]
            if before.isNumber || before == ")" { text.removeLast() }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.lowercased() == "none" { return nil }
        return text
    }
}
