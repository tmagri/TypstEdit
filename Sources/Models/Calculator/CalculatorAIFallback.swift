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
        /// A Typst math expression for the main formula, equation, or series
        /// result when the question asks for a mathematical form (e.g. Fourier
        /// series, identity, solved formula); `nil` for non-mathematical answers.
        var typstMath: String?
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
        let context = settings.modelContext(for: .calculator)
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
    /// Each line is either part of the parse contract (the labels, the
    /// `none` escape hatch) or CAS dialect the model would otherwise get
    /// wrong (function names and arities that are not standard notation).
    /// The examples anchor the reply shapes; keep it that lean.
    private static let instructions = """
    You are the interpreter for a calculator app (TI-89 style syntax). Its math engine could not evaluate the entry below, so you interpret it.

    If the entry has a computable numeric answer, EXPR is a calculator expression that computes it:
    - Allowed: numbers, + - * / ^, parentheses, pi, e, sqrt, sin, cos, tan, log, ln, abs, root(x,n), d(f,x), integrate(f,x,a,b), taylor(f,x,order) around 0 (shift the variable for another point: f(x+a)), solve(equation,x).
    - Substitute the entry's numbers and convert units so the answer comes out in the unit asked for; keep x only when the entry asks for an expression, like a derivative or a series.
    Otherwise (definitions, general knowledge, counting letters), EXPR is: none

    If the entry asks for an equation, formula, series expansion, or mathematical expression that is not directly computable by the TI engine above, TYPST is the typeset equation in Typst math syntax (without outer $ delimiters).
    Otherwise, TYPST is: none

    Reply with EXACTLY these three lines and nothing else:
    EXPR: <expression or none>
    TYPST: <typst math expression or none>
    ANSWER: <one short sentence answering the entry; format any math expressions or variables with $...$ delimiters>

    Examples:
    Question: What is the area of a circle if the diameter is 1 cm?
    EXPR: pi*(1/2)^2
    TYPST: A = pi / 4
    ANSWER: The area is $pi/4$, about 0.785 square centimeters.

    Question: Find the Fourier series expansion of f(x) = x^2 on (-pi, pi)
    EXPR: none
    TYPST: x^2 = pi^2/3 + 4 sum_(n=1)^oo (-1)^n/n^2 cos(n x)
    ANSWER: The Fourier series of $f(x)=x^2$ on $(-pi, pi)$ is $x^2 = pi^2/3 + 4 sum_(n=1)^oo (-1)^n/n^2 cos(n x)$.

    Question: How many r's are in strawberry?
    EXPR: none
    TYPST: none
    ANSWER: 3 — s-t-r-a-w-b-e-r-r-y has an r at positions 3, 8 and 9.
    """

    /// Asks the user's configured chat model to interpret the entry. Throws
    /// so the caller can fall back to the CAS error entry on failure.
    static func interpret(_ question: String) async throws -> Interpretation {
        let settings = AISettingsManager.shared
        let ctx = settings.modelContext(for: .calculator)
        // When the model is configured with an active reasoning effort
        // (low/medium/high/xhigh), thinking tokens count against max_tokens on
        // most providers (local Ollama/llama.cpp models, OpenAI reasoning,
        // OpenRouter, etc.). A fixed ceiling causes the model to exhaust all
        // tokens on its reasoning chain, leaving nothing for the EXPR/ANSWER.
        // We therefore allocate:
        //   answerBase   = user-configurable ceiling for the answer itself
        //   thinkingBudget = generic per-effort estimate of thinking consumption
        //   maxTokens    = answerBase + thinkingBudget
        // Anthropic is the one provider that keeps thinking tokens in a
        // separate pool; `applyReasoningEffort(toAnthropic:)` already raises
        // `max_tokens` for that path, so the addition is harmless there too.
        let answerBase = settings.calcAIFallbackMaxTokens
        let thinkingBudget = ctx.reasoningEffort.thinkingTokenBudget
        let maxTokens = answerBase + thinkingBudget
        let raw = try await AICompletionService.shared.fetchCompletion(
            prompt: """
            \(instructions)

            Question: \(question)
            """,
            systemPrompt: "You interpret questions for a calculator app and always reply in the exact three-line EXPR/TYPST/ANSWER format. Reason carefully and count precisely before writing the ANSWER line.",
            // answerBase tokens for the EXPR/ANSWER reply, plus thinkingBudget
            // when the model has an active reasoning effort (see above).
            maxTokens: maxTokens,
            purpose: .chat,
            // Use the model picked for the calculator (Settings → General →
            // Calculator → AI Fallback), falling back to Chat & Actions.
            model: ctx,
            sanitize: false)
        return parseInterpretation(raw)
    }

    /// Parses the EXPR/TYPST/ANSWER reply, tolerating the variations small models
    /// produce: markdown-wrapped labels (`**EXPR:**`), various label spellings,
    /// missing lines, and formatless prose.
    /// `nonisolated` so tests can call it without hopping to the main actor.
    nonisolated static func parseInterpretation(_ raw: String) -> Interpretation {
        var expression: String?
        var typstMath: String?
        var sawExpressionLabel = false
        var sawTypstLabel = false
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
            } else if lower.hasPrefix("typst:"), cleaned.count > "typst:".count {
                typstMath = interpretationTypstMath(String(cleaned.dropFirst("typst:".count)))
                sawTypstLabel = true
                collectingAnswer = false
            } else if lower.hasPrefix("math:"), cleaned.count > "math:".count {
                typstMath = interpretationTypstMath(String(cleaned.dropFirst("math:".count)))
                sawTypstLabel = true
                collectingAnswer = false
            } else if lower.hasPrefix("equation:"), cleaned.count > "equation:".count {
                typstMath = interpretationTypstMath(String(cleaned.dropFirst("equation:".count)))
                sawTypstLabel = true
                collectingAnswer = false
            } else if lower.hasPrefix("formula:"), cleaned.count > "formula:".count {
                typstMath = interpretationTypstMath(String(cleaned.dropFirst("formula:".count)))
                sawTypstLabel = true
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

        // If no explicit TYPST formula was given, check whether the answer contains a primary equation
        if typstMath == nil && !answer.isEmpty {
            if let extracted = extractPrimaryEquation(from: answer) {
                typstMath = interpretationTypstMath(extracted)
            }
        }

        if sawExpressionLabel || sawTypstLabel {
            if !answer.isEmpty {
                return Interpretation(expression: expression,
                                      typstMath: typstMath,
                                      answer: normalizeAnswerMath(answer))
            }
            if let expression {
                return Interpretation(expression: expression,
                                      typstMath: typstMath,
                                      answer: "Interpreted as \(expression).")
            }
            if let typstMath {
                return Interpretation(expression: nil,
                                      typstMath: typstMath,
                                      answer: "$\(typstMath)$")
            }
            return Interpretation(expression: nil,
                                  typstMath: nil,
                                  answer: "The model could not interpret this entry.")
        }

        // No recognized labels: the whole reply is the answer (covers models that
        // ignore the format and just answer in prose).
        let rawAnswer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if typstMath == nil {
            if let extracted = extractPrimaryEquation(from: rawAnswer) {
                typstMath = interpretationTypstMath(extracted)
            }
        }
        return Interpretation(expression: nil,
                              typstMath: typstMath,
                              answer: normalizeAnswerMath(rawAnswer))
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

    /// Cleans and normalizes a Typst math value: strips markdown leftovers,
    /// removes outer math delimiters, converts LaTeX/Unicode forms to Typst math.
    nonisolated static func interpretationTypstMath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "*_` \t\r\n"))
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return nil }
        let normalized = normalizeToTypstMath(trimmed)
        return normalized.isEmpty ? nil : normalized
    }

    /// Converts math written with LaTeX markup or unicode characters into valid Typst math syntax.
    nonisolated static func normalizeToTypstMath(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip outer delimiters if present
        if text.hasPrefix("$$") && text.hasSuffix("$$") && text.count >= 4 {
            text = String(text.dropFirst(2).dropLast(2))
        } else if text.hasPrefix("$") && text.hasSuffix("$") && text.count >= 2 {
            text = String(text.dropFirst(1).dropLast(1))
        } else if text.hasPrefix("\\[") && text.hasSuffix("\\]") && text.count >= 4 {
            text = String(text.dropFirst(2).dropLast(2))
        } else if text.hasPrefix("\\(") && text.hasSuffix("\\)") && text.count >= 4 {
            text = String(text.dropFirst(2).dropLast(2))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Convert LaTeX spacing and symbols
        text = text.replacingOccurrences(of: "\\quad", with: " ")
        text = text.replacingOccurrences(of: "\\qquad", with: " ")
        text = text.replacingOccurrences(of: "\\cdot", with: " dot ")
        text = text.replacingOccurrences(of: "\\times", with: " times ")
        text = text.replacingOccurrences(of: "\\infty", with: " oo ")
        text = text.replacingOccurrences(of: "\\pi", with: " pi ")
        text = text.replacingOccurrences(of: "\\alpha", with: " alpha ")
        text = text.replacingOccurrences(of: "\\beta", with: " beta ")
        text = text.replacingOccurrences(of: "\\gamma", with: " gamma ")
        text = text.replacingOccurrences(of: "\\delta", with: " delta ")
        text = text.replacingOccurrences(of: "\\theta", with: " theta ")
        text = text.replacingOccurrences(of: "\\lambda", with: " lambda ")
        text = text.replacingOccurrences(of: "\\mu", with: " mu ")
        text = text.replacingOccurrences(of: "\\sigma", with: " sigma ")
        text = text.replacingOccurrences(of: "\\omega", with: " omega ")
        text = text.replacingOccurrences(of: "\\sum", with: " sum ")
        text = text.replacingOccurrences(of: "\\int", with: " integral ")
        text = text.replacingOccurrences(of: "\\prod", with: " product ")
        text = text.replacingOccurrences(of: "\\cos", with: " cos ")
        text = text.replacingOccurrences(of: "\\sin", with: " sin ")
        text = text.replacingOccurrences(of: "\\tan", with: " tan ")
        text = text.replacingOccurrences(of: "\\ln", with: " ln ")
        text = text.replacingOccurrences(of: "\\log", with: " log ")
        text = text.replacingOccurrences(of: "\\sqrt", with: " sqrt ")
        text = text.replacingOccurrences(of: "\\partial", with: " diff ")
        text = text.replacingOccurrences(of: "\\le", with: " <= ")
        text = text.replacingOccurrences(of: "\\ge", with: " >= ")
        text = text.replacingOccurrences(of: "\\neq", with: " != ")
        text = text.replacingOccurrences(of: "\\pm", with: " plus.minus ")
        text = text.replacingOccurrences(of: "\\left", with: "")
        text = text.replacingOccurrences(of: "\\right", with: "")

        // Handle LaTeX fractions \frac{a}{b} -> ((a)/(b))
        while let range = text.range(of: "\\frac") {
            let after = text[range.upperBound...]
            guard let open1 = after.firstIndex(of: "{") else { break }
            var depth = 1
            var idx = after.index(after: open1)
            let aStart = idx
            while idx < after.endIndex && depth > 0 {
                if after[idx] == "{" { depth += 1 }
                else if after[idx] == "}" { depth -= 1 }
                if depth > 0 { idx = after.index(after: idx) }
            }
            guard depth == 0 else { break }
            let a = String(after[aStart..<idx])
            let rest = after[after.index(after: idx)...]
            guard let open2 = rest.firstIndex(of: "{") else { break }
            depth = 1
            idx = rest.index(after: open2)
            let bStart = idx
            while idx < rest.endIndex && depth > 0 {
                if rest[idx] == "{" { depth += 1 }
                else if rest[idx] == "}" { depth -= 1 }
                if depth > 0 { idx = rest.index(after: idx) }
            }
            guard depth == 0 else { break }
            let b = String(rest[bStart..<idx])
            let replaceRange = range.lowerBound...idx
            text.replaceSubrange(replaceRange, with: "(\(a))/(\(b))")
        }

        // Unicode subscripts & superscripts
        let supers: [String: String] = [
            "⁰": "^0", "¹": "^1", "²": "^2", "³": "^3", "⁴": "^4",
            "⁵": "^5", "⁶": "^6", "⁷": "^7", "⁸": "^8", "⁹": "^9",
            "ⁿ": "^n", "ˣ": "^x", "ʸ": "^y", "⁺": "^+", "⁻": "^-"
        ]
        let subs: [String: String] = [
            "₀": "_0", "₁": "_1", "₂": "_2", "₃": "_3", "₄": "_4",
            "₅": "_5", "₆": "_6", "₇": "_7", "₈": "_8", "₉": "_9",
            "ₙ": "_n", "ₘ": "_m", "ᵢ": "_i", "ⱼ": "_j", "ₖ": "_k"
        ]
        text = text.replacingOccurrences(of: "ₙ₌₁", with: "_(n=1)")
        text = text.replacingOccurrences(of: "ₙ₌₀", with: "_(n=0)")
        text = text.replacingOccurrences(of: "ₖ₌₁", with: "_(k=1)")
        text = text.replacingOccurrences(of: "ₖ₌₀", with: "_(k=0)")
        for (k, v) in supers { text = text.replacingOccurrences(of: k, with: v) }
        for (k, v) in subs { text = text.replacingOccurrences(of: k, with: v) }

        // Unicode math symbols
        text = text.replacingOccurrences(of: "∑", with: " sum ")
        text = text.replacingOccurrences(of: "∏", with: " product ")
        text = text.replacingOccurrences(of: "∫", with: " integral ")
        text = text.replacingOccurrences(of: "√", with: " sqrt ")
        text = text.replacingOccurrences(of: "π", with: " pi ")
        text = text.replacingOccurrences(of: "·", with: " dot ")
        text = text.replacingOccurrences(of: "×", with: " * ")
        text = text.replacingOccurrences(of: "÷", with: " / ")
        text = text.replacingOccurrences(of: "∞", with: " oo ")
        text = text.replacingOccurrences(of: "≠", with: " != ")
        text = text.replacingOccurrences(of: "≤", with: " <= ")
        text = text.replacingOccurrences(of: "≥", with: " >= ")
        text = text.replacingOccurrences(of: "±", with: " plus.minus ")
        text = text.replacingOccurrences(of: "≈", with: " approx ")

        // LaTeX brace subscripts and superscripts: _{n=1} -> _(n=1), ^{2} -> ^2 or ^(2)
        text = text.replacingOccurrences(of: "_{", with: "_(")
        text = text.replacingOccurrences(of: "^{", with: "^(")
        text = text.replacingOccurrences(of: "}", with: ")")

        // Ensure spacing between digits/letters and Typst math identifiers
        text = text.replacingOccurrences(
            of: #"(?<=[0-9A-Za-z])(?=sum|product|integral|sqrt|pi|cos|sin|tan)"#,
            with: " ",
            options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?<=sum|product|integral|sqrt|pi|cos|sin|tan)(?<=[A-Za-z])(?=[0-9A-Za-z])"#,
            with: " ",
            options: .regularExpression)

        text = text.replacingOccurrences(of: "\\", with: "")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts a primary equation from a prose answer if present.
    nonisolated static func extractPrimaryEquation(from text: String) -> String? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // 1. Explicit display math \[ ... \] or $$ ... $$ containing '='
        if let blockRegex = try? NSRegularExpression(pattern: #"(?:\\\[|\$\$)(.*?)(?:\\\]|\$\$)"#) {
            for m in blockRegex.matches(in: text, range: fullRange) {
                let snippet = nsText.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if snippet.contains("=") {
                    return snippet
                }
            }
        }

        // 2. Inline math \( ... \) or $ ... $ containing '='
        var inlineCandidates: [String] = []
        if let inlineRegex = try? NSRegularExpression(pattern: #"(?:\$|\\\()(.*?)(?:\$|\\\))"#) {
            for m in inlineRegex.matches(in: text, range: fullRange) {
                let snippet = nsText.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if snippet.contains("=") {
                    inlineCandidates.append(snippet)
                }
            }
        }
        if let best = inlineCandidates.max(by: { $0.count < $1.count }) {
            return best
        }

        // 3. Look for unicode math equation patterns, e.g. "x² = ..." or "f(x) = ..."
        var eqCandidates: [String] = []
        if let eqRegex = try? NSRegularExpression(pattern: #"(?:[A-Za-z0-9_\(\)]+(?:\^[0-9A-Za-z]+|[²³ⁿ])?\s*=\s*[^,\.;]+)"#) {
            for m in eqRegex.matches(in: text, range: fullRange) {
                let snippet = nsText.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines)
                if snippet.contains("+") || snippet.contains("-") || snippet.contains("/")
                    || snippet.contains("sum") || snippet.contains("∑")
                    || snippet.contains("pi") || snippet.contains("π")
                    || snippet.contains("^") || snippet.contains("²") {
                    eqCandidates.append(snippet)
                }
            }
        }
        return eqCandidates.max(by: { $0.count < $1.count })
    }

    /// Normalizes any inline math within a prose answer into Typst $...$ notation.
    nonisolated static func normalizeAnswerMath(_ text: String) -> String {
        var result = text

        // Convert LaTeX \( ... \) and \[ ... \] to $ ... $
        if let inlineRegex = try? NSRegularExpression(pattern: #"\\\((.*?)\\\)"#) {
            let ns = NSMutableString(string: result)
            for m in inlineRegex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                let inner = ns.substring(with: m.range(at: 1))
                let norm = normalizeToTypstMath(inner)
                ns.replaceCharacters(in: m.range, with: "$ \(norm) $")
            }
            result = ns as String
        }

        if let blockRegex = try? NSRegularExpression(pattern: #"\\\[(.*?)\\\]"#) {
            let ns = NSMutableString(string: result)
            for m in blockRegex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                let inner = ns.substring(with: m.range(at: 1))
                let norm = normalizeToTypstMath(inner)
                ns.replaceCharacters(in: m.range, with: "$ \(norm) $")
            }
            result = ns as String
        }

        // If the text contains $ delimiters, normalize the contents inside $ ... $
        if result.contains("$") {
            if let mathRegex = try? NSRegularExpression(pattern: #"\$([^$]+)\$"#) {
                let ms = NSMutableString(string: result)
                for m in mathRegex.matches(in: result, range: NSRange(location: 0, length: ms.length)).reversed() {
                    let inner = ms.substring(with: m.range(at: 1))
                    let norm = normalizeToTypstMath(inner)
                    ms.replaceCharacters(in: m.range, with: "$\(norm)$")
                }
                result = ms as String
            }
        }

        return result
    }
}
