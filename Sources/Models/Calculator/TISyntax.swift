import Foundation

/// Converts TI-89 style input into what giac's TI compatibility mode expects.
/// Most TI-89 syntax (`solve`, `factor`, `d(`, `∫(`, `|`, `[a,b;c,d]`) is
/// already understood by giac when running in TI mode (`xcas_mode == 3`);
/// this layer covers the rest. Pure functions only — unit tested.
enum TISyntax {

    /// Preprocesses one entry line.
    static func preprocess(_ input: String) -> String {
        var text = input

        // Store arrow: `5->a` and `5→a` both mean the TI's `5►a`.
        // giac's `->` means a lambda/map arrow, so retarget it first.
        text = text.replacingOccurrences(of: "->", with: "►")
        text = text.replacingOccurrences(of: "→", with: "►")

        // Unicode function templates the keyboard shortcut bar inserts.
        text = text.replacingOccurrences(of: "Σ(", with: "sum(")
        text = text.replacingOccurrences(of: "Π(", with: "product(")
        text = text.replacingOccurrences(of: "∞", with: "infinity")
        text = text.replacingOccurrences(of: "≥", with: ">=")
        text = text.replacingOccurrences(of: "≤", with: "<=")
        text = text.replacingOccurrences(of: "≠", with: "!=")

        // TI spellings giac does not carry under the same case or name.
        text = replaceWordCalls(in: text, map: [
            "cSolve": "csolve",
            "cSOLVE": "csolve",
            "propFrac": "propfrac",
            "comDenom": "normal",
            "nSolve": "fsolve",
            "delVar": "purge",
        ])

        // `d(f,x)` — giac spells the derivative `diff`, and `d(` must not be
        // confused with a variable named d.
        text = text.replacingOccurrences(of: "(?<![A-Za-z0-9_])d\\(", with: "diff(", options: .regularExpression)

        // TI `Define f(x)=x^2` → giac `f(x):=x^2`.
        text = defineStatementToAssignment(text)

        return text
    }

    /// Replaces `name(` calls where giac uses a different command name.
    private static func replaceWordCalls(in text: String, map: [String: String]) -> String {
        var result = text
        for (from, to) in map {
            let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: from) + "\\("
            result = result.replacingOccurrences(
                of: pattern,
                with: "\(to)(",
                options: .regularExpression
            )
        }
        return result
    }

    /// `define f(x)=x^2` / `Define g(a,b)=a*b` → `f(x):=x^2`.
    private static func defineStatementToAssignment(_ text: String) -> String {
        guard let range = text.range(of: "^\\s*define\\s+", options: [.regularExpression, .caseInsensitive]) else {
            return text
        }
        var result = String(text[range.upperBound...])
        // Turn the remaining first `=` into `:=` (the TI-89 input line has no
        // `==` here to worry about).
        if let eq = result.range(of: "=") {
            result.replaceSubrange(eq.lowerBound..<eq.upperBound, with: ":=")
        }
        return result
    }

    // MARK: - ans / entry recall

    /// Substitutes TI recall variables before evaluation:
    /// `ans` → last result, `ans(n)` → nth result, `entry(n)` → nth input.
    /// The bare-`ans` rule runs first, so text brought in by `entry(n)`
    /// (which may itself contain `ans`) stays verbatim, like the TI-89.
    static func substituteRecalls(
        in input: String,
        history: [CalculatorEntry]
    ) throws -> String {
        var text = input

        // Bare `ans` → the most recent result.
        if text.range(of: "(?<![A-Za-z0-9_])ans(?![0-9]*\\()", options: .regularExpression) != nil {
            guard let last = history.last(where: { !$0.isError && !$0.resultPlain.isEmpty }) else {
                throw CalculatorInputError.noPreviousResult("ans")
            }
            text = text.replacingOccurrences(
                of: "(?<![A-Za-z0-9_])ans",
                with: last.resultPlain,
                options: .regularExpression
            )
        }

        // ans(n) / entry(n), n counts from 1 (TI-89 numbering: 1 is the most
        // recent). Applied last-match-first so earlier ranges stay valid.
        let numbered = try matchNumberedRecalls(in: text, history: history)
        for recall in numbered.reversed() {
            text.replaceSubrange(recall.range, with: recall.replacement)
        }
        return text
    }

    private struct NumberedRecall {
        let range: Range<String.Index>
        let replacement: String
    }

    private static func matchNumberedRecalls(
        in text: String,
        history: [CalculatorEntry]
    ) throws -> [NumberedRecall] {
        var found: [NumberedRecall] = []
        guard let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])(ans|entry)\\(([0-9]+)\\)") else {
            return found
        }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: match.range(at: 1))
            guard let valueRange = Range(match.range(at: 2), in: text),
                  let n = Int(text[valueRange]), n >= 1 else { continue }
            let usable = history.filter { !$0.isError }
            let isEntry = kind == "entry"
            let source = isEntry ? usable.map(\.input) : usable.map(\.resultPlain)
            guard n <= source.count else {
                throw CalculatorInputError.noHistoryEntry(kind, n)
            }
            let replacement = source[source.count - n]
            if let swiftRange = Range(match.range, in: text) {
                found.append(NumberedRecall(range: swiftRange, replacement: replacement))
            }
        }
        return found
    }
}

/// Errors raised while turning a raw entry line into engine input.
enum CalculatorInputError: LocalizedError {
    case noPreviousResult(String)
    case noHistoryEntry(String, Int)

    var errorDescription: String? {
        switch self {
        case let .noPreviousResult(name):
            return "\(name) has no value yet — evaluate something first."
        case let .noHistoryEntry(name, n):
            return "There is no \(name)(\(n)) — the history is shorter than that."
        }
    }
}
