import Foundation

/// Converts Typst math (the text inside `$ … $`) into TI/Giac entry-line
/// syntax, so an equation from the editor can be loaded straight into the
/// Calculator panel ("Send to Calculator").
///
/// Deliberately token-level rather than a full Typst-math parser: it handles
/// the constructs the CAS renderer produces (see `CASTypstRenderer`) plus the
/// common hand-written ones — fractions, powers, subscripts, sqrt, trig and
/// inverse trig, abs, logs, integrals, sums, products, limits, derivatives,
/// matrices, and Greek/symbol names spelled out (`alpha`, `pi`, `oo`, `<=` …).
/// Anything it cannot translate faithfully raises a descriptive
/// `ConversionError` instead of producing a wrong expression.
enum TypstMathToTI {

    struct ConversionError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    // MARK: - Entry point

    /// Strips `$`/`$$` (and `\[ … \]`) delimiters from `raw`, then converts.
    static func convert(raw: String) throws -> String {
        let math = stripDelimiters(raw)
        guard !math.isEmpty else {
            throw ConversionError(reason: "The equation is empty.")
        }
        return try convert(math: math)
    }

    static func convert(math input: String) throws -> String {
        var text = input

        // 1. Structural constructs: argument order changes, so rewrite first.
        text = rewriteIntegral(text)
        text = rewriteBoundStatement(text, keyword: "sum", function: "sum")
        text = rewriteBoundStatement(text, keyword: "product", function: "product")
        text = rewriteLimit(text)
        text = rewriteDerivative(text)
        text = try rewriteMatrices(text)

        // 2. Function spellings. Trig co-functions have no single giac word;
        //    they are staged as fallback names and expanded to quotients after
        //    the word replacer ran (so `arccot(` → `acot(` still works).
        let directMap: [String: String] = [
            "arcsin": "asin", "arccos": "acos", "arctan": "atan",
            "arcsec": "asec", "arccsc": "acsc", "arccot": "acot",
            "arcsinh": "asinh", "arccosh": "acosh", "arctanh": "atanh",
            "binom": "comb", "lgamma": "gamma", "abs": "abs",
            "sqrt": "sqrt", "root": "root", "exp": "exp", "ln": "ln",
            "log": "log", "floor": "floor", "ceil": "ceil",
            "round": "round", "gcd": "gcd", "lcm": "lcm",
            "min": "min", "max": "max", "sign": "sign", "gamma": "gamma",
            "erf": "erf",
        ]
        text = replaceWordCalls(in: text, map: [
            "sec": "_secfn", "csc": "_cscfn", "cot": "_cotfn",
        ])
        text = replaceWordCalls(in: text, map: directMap)
        text = text.replacingOccurrences(of: "(?<![A-Za-z0-9_])_secfn\\(", with: "(1/cos)(", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?<![A-Za-z0-9_])_cscfn\\(", with: "(1/sin)(", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?<![A-Za-z0-9_])_cotfn\\(", with: "(1/tan)(", options: .regularExpression)

        // 3. Operator words and symbols.
        for (from, to) in [
            " times ": "*", " dot ": "*", " dot.op ": "*", "·": "*", "∙": "*",
            " div ": "/", "±": "+-", "≠": "!=", "≤": "<=", "≥": ">=",
            "→": "->", "∞": "infinity", " oo ": " infinity ",
        ] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        // `oo` as a bare word → infinity.
        text = text.replacingOccurrences(of: "(?<![A-Za-z0-9_])oo(?![A-Za-z0-9_])", with: "infinity", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?<![A-Za-z0-9_])deg(?![A-Za-z0-9_])", with: "°", options: .regularExpression)

        // 4. Typst-math grouping braces → parentheses.
        text = text.replacingOccurrences(of: "{", with: "(")
        text = text.replacingOccurrences(of: "}", with: ")")

        // 5. Collapse whitespace (giac treats `2 x` as `2*x`; newlines are not
        //    valid on an entry line).
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        // 6. Reject constructs we cannot translate faithfully.
        let unsupported: [(token: String, label: String)] = [
            ("&", "an alignment (&)"), ("cases(", "a cases(...) piecewise"),
            ("bold(", "a bold(...) span"), ("italic(", "an italic(...) span"),
            ("overline(", "an overline"), ("underline(", "an underline"),
            ("hat(", "a hat accent"), ("tilde(", "a tilde accent"),
            ("accent(", "an accent"), ("~", "a non-breaking space"),
            ("∑", "a unicode Σ (write sum instead)"),
            ("∏", "a unicode Π (write product instead)"),
            ("∫", "a unicode ∫ (write integral instead)"),
            ("\"", "a quoted string"),
        ]
        for (token, label) in unsupported where text.contains(token) {
            throw ConversionError(reason: "the equation uses \(label)")
        }
        if text.contains(";") && !text.contains("[") {
            throw ConversionError(reason: "the equation contains a semicolon")
        }

        // 7. Balance check — giac's parser gives poor messages for this.
        let open = text.filter { "([{".contains($0) }.count
        let close = text.filter { ")]}".contains($0) }.count
        guard open == close else {
            throw ConversionError(reason: "the equation has unbalanced brackets")
        }

        return text
    }

    // MARK: - Delimiters

    static func stripDelimiters(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\\[") && text.hasSuffix("\\]") {
            text = String(text.dropFirst(2).dropLast(2))
        } else if text.hasPrefix("\\(") && text.hasSuffix("\\)") {
            text = String(text.dropFirst(2).dropLast(2))
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "$"))
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Structural rewrites

    /// `integral_(a)^(b) body dif x` (and the unbracketed forms
    /// `integral_a^b body dif x`) → `integrate(body, x, a, b)`.
    private static func rewriteIntegral(_ text: String) -> String {
        let pattern = #"(?<![A-Za-z0-9_])integral_\(?([^\s)^_]+)\)?\s*\^\(?([^\s)_]+)\)?\s+(.+?)\s+dif\s+([A-Za-z](?:_\d)?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return replacingMatches(of: regex, in: text) { groups in
            let lower = groups[0], upper = groups[1], body = groups[2], variable = groups[3]
            return "integrate(\(body), \(variable), \(lower), \(upper))"
        }
    }

    /// `sum_(k=a)^b body` / `product_(k=a)^b body` → `sum(body, k, a, b)`.
    private static func rewriteBoundStatement(_ text: String, keyword: String, function: String) -> String {
        let pattern = #"(?<![A-Za-z0-9_])\#(keyword)_?\(?([A-Za-z](?:_\d)?)\)?\s*=\s*\(?([^\s)^]+)\)?\s*\^\(?([^\s_]+)\)?\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return text }
        return replacingMatches(of: regex, in: text) { groups in
            let variable = groups[0], lower = groups[1], upper = groups[2], body = groups[3]
            return "\(function)(\(body), \(variable), \(lower), \(upper))"
        }
    }

    /// `lim_(x -> a) body` → `limit(body, x, a)`.
    private static func rewriteLimit(_ text: String) -> String {
        let pattern = #"(?<![A-Za-z0-9_])lim_\(?([A-Za-z](?:_\d)?)\s*(?:->|→)\s*([^\s)]+)\)?\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return text }
        return replacingMatches(of: regex, in: text) { groups in
            let variable = groups[0], target = groups[1], body = groups[2]
            return "limit(\(body), \(variable), \(target))"
        }
    }

    /// `(dif f)/(dif x)` → `diff(f, x)`. Bare `dif` products are left alone.
    private static func rewriteDerivative(_ text: String) -> String {
        let pattern = #"\(\s*dif\s+([^)]+?)\s*\)\s*/\s*\(\s*dif\s+([A-Za-z](?:_\d)?)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return replacingMatches(of: regex, in: text) { groups in
            let body = groups[0], variable = groups[1]
            return "diff(\(body), \(variable))"
        }
    }

    /// `mat(a, b; c, d)` → `[[a,b],[c,d]]` (giac matrix literal).
    private static func rewriteMatrices(_ text: String) throws -> String {
        guard let matCall = balancedCallText(in: text, name: "mat") else {
            if text.contains("mat(") {
                throw ConversionError(reason: "an unbalanced mat(...) call")
            }
            return text
        }
        // matCall is "mat(<inner>)" — peel the wrapper.
        guard matCall.hasPrefix("mat("), matCall.hasSuffix(")") else { return text }
        let inner = matCall.dropFirst("mat(".count).dropLast()
        let rows = inner.split(whereSeparator: { $0 == ";" }).map { row in
            "[" + row.split(whereSeparator: { $0 == "," })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: ",") + "]"
        }
        let replacement = "[" + rows.joined(separator: ",") + "]"
        guard let range = text.range(of: matCall, options: .literal) else { return text }
        return text.replacingCharacters(in: range, with: replacement)
    }

    // MARK: - Scanning helpers

    /// Applies `transform` to every match (first match first, so earlier
    /// matches keep valid ranges — replacements come back with their own
    /// balanced text and ranges are recomputed by scanning the updated string
    /// until stable, bounded by the original match count).
    private static func replacingMatches(
        of regex: NSRegularExpression, in input: String,
        transform: ([String]) -> String
    ) -> String {
        var result = input
        var iterations = 0
        while iterations < 32 {
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            guard let first = matches.first else { break }
            let groups = (1..<first.numberOfRanges).map { ns.substring(with: first.range(at: $0)) }
            let replacement = transform(groups)
            guard let range = Range(first.range, in: result) else { break }
            result.replaceSubrange(range, with: replacement)
            iterations += 1
        }
        return result
    }

    /// Finds `name(...)` with balanced parentheses and returns the full call
    /// text, or nil when absent/unbalanced.
    private static func balancedCallText(in text: String, name: String) -> String? {
        guard let nameRange = text.range(of: "(?<![A-Za-z0-9_])" + name + "\\(", options: .regularExpression) else {
            return nil
        }
        var depth = 0
        var index = nameRange.upperBound
        index = text.index(before: index) // the '(' character
        while index < text.endIndex {
            let character = text[index]
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 {
                    return String(text[nameRange.lowerBound...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Replaces `name(` occurrences (word-bounded, longest name first) using
    /// `map`.
    private static func replaceWordCalls(in text: String, map: [String: String]) -> String {
        var result = text
        for (from, to) in map.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: from) + "\\("
            result = result.replacingOccurrences(
                of: pattern,
                with: "\(to)(",
                options: .regularExpression)
        }
        return result
    }
}
