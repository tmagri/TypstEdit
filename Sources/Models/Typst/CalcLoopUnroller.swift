import Foundation

/// Specialises calculator calls inside *statically bounded* Typst loops.
///
/// ```typ
/// #for n in range(3) [ Order #n: #calc("BesselJ(n, 6)") ]
/// ```
///
/// cannot be resolved as written: the CAS never sees `n`. This pass rewrites
/// the loop into one copy of its body per iteration:
///
/// ```typ
/// #{ let n = 0; [ Order #n: #calc("BesselJ(0, 6)") ] }#{ let n = 1; … }…
/// ```
///
/// Each copy re-binds the loop variable, so everything Typst evaluates
/// (`#n`, `#(n * 2)`, nested code) behaves exactly as in the loop, and copies
/// are concatenated without separators, which is how `for` joins its results.
/// Only the calculator strings get the literal value, so the resolution pass
/// can evaluate each copy with the real CAS.
///
/// Scope is deliberately narrow and fail-safe:
/// - the loop variable is a plain identifier (no destructuring);
/// - the iterable is `range(<int literals>)` or a tuple of number literals;
/// - the body contains a calculator call (otherwise the loop is left alone);
/// - at most `maxIterations` iterations;
/// - anything else is left byte-identical and reported as a warning.
enum CalcLoopUnroller {

    struct Warning: Equatable {
        let line: Int
        let message: String
    }

    struct Result {
        var output: String
        /// Warnings for loops that call the calculator but cannot be
        /// specialised. Line numbers refer to the *original* source.
        var warnings: [Warning] = []
    }

    static func unroll(_ source: String, maxIterations: Int = 200, maxDepth: Int = 4) -> Result {
        var warnings: [Warning] = []
        var text = unrollOnce(source, maxIterations: maxIterations, warnings: &warnings)
        // Warnings come from the first sweep only, so their line numbers match
        // the user's source. Later sweeps expand loops that were nested inside
        // already-expanded bodies.
        var discarded: [Warning] = []
        for _ in 1..<maxDepth {
            let next = unrollOnce(text, maxIterations: maxIterations, warnings: &discarded)
            if next == text { break }
            text = next
        }
        return Result(output: text, warnings: warnings)
    }

    // MARK: - One sweep

    /// `#for` in markup, or `for` in code mode (e.g. `..for n in (1, 2) { … }`
    /// inside a table's arguments).
    private static let loopHead = try! NSRegularExpression(
        pattern: #"(#?)(?<![A-Za-z0-9_-])for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+"#)
    private static let numberLiteral = try! NSRegularExpression(
        pattern: #"^-?\d+(\.\d+)?$"#)

    private static func unrollOnce(
        _ source: String, maxIterations: Int, warnings: inout [Warning]
    ) -> String {
        let ns = source as NSString
        let full = NSRange(location: 0, length: ns.length)
        var edits: [(range: NSRange, replacement: String)] = []
        var claimedEnd = 0 // end of the last scheduled edit: nested loops wait a sweep

        for match in loopHead.matches(in: source, options: [], range: full) {
            let variable = ns.substring(with: match.range(at: 2))
            let markup = match.range(at: 1).length > 0
            // A loop inside an already-scheduled one is judged next sweep,
            // after the outer value has been substituted into its head.
            guard match.range.location >= claimedEnd else { continue }
            guard let construct = parseLoop(ns, headEnd: match.range.upperBound) else { continue }
            let body = ns.substring(with: construct.bodyRange)
            guard containsCalculatorCall(body) else { continue }

            guard let values = iterationValues(construct.iterable) else {
                warnings.append(Warning(
                    line: line(of: match.range.location, in: ns),
                    message: "This loop cannot be specialised, so #calc(…) inside it has no value for ‘\(variable)’. Use literal bounds (range(3), (1, 2, 3)) or the compiled functions (BesselJ, calc-call) instead."))
                continue
            }
            guard values.count <= maxIterations else {
                warnings.append(Warning(
                    line: line(of: match.range.location, in: ns),
                    message: "This loop has \(values.count) iterations; specialising it is limited to \(maxIterations). Use the compiled functions (BesselJ, calc-call) for large loops."))
                continue
            }

            let isContentBody = body.hasPrefix("[")
            var replacement = markup ? "" : "{ "
            for value in values {
                let specialised = specialise(body, variable: variable, value: value)
                let inner = isContentBody ? specialised : String(specialised.dropFirst().dropLast())
                // Markup joins `#{…}#{…}`; in code mode a block joins the values
                // of its inner blocks — the same joining `for` performs.
                replacement += (markup ? "#" : "") + "{ let \(variable) = \(value); \(inner) }"
                if !markup { replacement += "; " } /* code blocks separate expressions */
            }
            if !markup { replacement += "}" }
            let end = construct.bodyRange.location + construct.bodyRange.length
            edits.append((NSRange(location: match.range.location, length: end - match.range.location), replacement))
            claimedEnd = end
        }

        var text = source
        for edit in edits.reversed() {
            if let range = Range(edit.range, in: text) {
                text.replaceSubrange(range, with: edit.replacement)
            }
        }
        return text
    }

    private static func containsCalculatorCall(_ body: String) -> Bool {
        body.range(of: #"(?<![A-Za-z0-9_.-])#?calc(-table)?\s*\(\s*""#, options: .regularExpression) != nil
    }

    // MARK: - Parsing

    private struct LoopConstruct {
        let iterable: String
        let bodyRange: NSRange
    }

    /// Parses `<iterable> <body>` right after `#for <var> in `. The iterable
    /// runs to the first `{` or `[` outside parentheses and strings.
    private static func parseLoop(_ ns: NSString, headEnd: Int) -> LoopConstruct? {
        var depth = 0
        var index = headEnd
        while index < ns.length {
            let character = ns.character(at: index)
            if character == 0x22 { index = skipString(ns, from: index); continue }
            if character == 0x0A && depth == 0 { return nil } // the head must be on one line
            if character == 0x28 { depth += 1 }
            if character == 0x29 { depth -= 1; if depth < 0 { return nil } }
            if depth == 0, character == 0x7B || character == 0x5B {
                guard let body = balancedRange(in: ns, from: index) else { return nil }
                let iterable = ns.substring(with: NSRange(location: headEnd, length: index - headEnd))
                    .trimmingCharacters(in: .whitespaces)
                return LoopConstruct(iterable: iterable, bodyRange: body)
            }
            index += 1
        }
        return nil
    }

    /// Index just past the string literal starting at `start` (a `"`).
    private static func skipString(_ ns: NSString, from start: Int) -> Int {
        var index = start + 1
        while index < ns.length {
            let character = ns.character(at: index)
            if character == 0x5C { index += 2; continue }
            index += 1
            if character == 0x22 { break }
        }
        return index
    }

    /// Range of the balanced bracket pair opening at `start` (`{`, `[` or `(`).
    private static func balancedRange(in ns: NSString, from start: Int) -> NSRange? {
        let open = ns.character(at: start)
        let close: unichar = open == 0x7B ? 0x7D : (open == 0x5B ? 0x5D : 0x29)
        var depth = 0
        var index = start
        while index < ns.length {
            let character = ns.character(at: index)
            if character == 0x22 { index = skipString(ns, from: index); continue }
            if character == open { depth += 1 }
            if character == close {
                depth -= 1
                if depth == 0 { return NSRange(location: start, length: index - start + 1) }
            }
            index += 1
        }
        return nil
    }

    /// `range(n)`, `range(a, b)`, `range(a, b, step)` with integer literals,
    /// or a tuple of number literals `(1, 2.5, -3)`.
    static func iterationValues(_ iterable: String) -> [String]? {
        let trimmed = iterable.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("range(") && trimmed.hasSuffix(")") {
            let parts = trimmed.dropFirst("range(".count).dropLast()
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let numbers = parts.compactMap { Int($0) }
            guard !numbers.isEmpty, numbers.count == parts.count, numbers.count <= 3 else { return nil }
            let start = numbers.count == 1 ? 0 : numbers[0]
            let end = numbers.count == 1 ? numbers[0] : numbers[1]
            let step = numbers.count == 3 ? numbers[2] : 1
            guard step != 0 else { return nil }
            var values: [String] = []
            var value = start
            while (step > 0 ? value < end : value > end) && values.count <= 100_000 {
                values.append(String(value))
                value += step
            }
            return values
        }
        if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") {
            let parts = trimmed.dropFirst().dropLast()
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            for part in parts {
                let range = NSRange(location: 0, length: (part as NSString).length)
                guard numberLiteral.firstMatch(in: part, options: [], range: range) != nil else { return nil }
            }
            return parts
        }
        return nil
    }

    // MARK: - Substitution

    private static let calculatorCall = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.-])#?calc(?:-table)?\s*\((?=\s*")"#)
    private static let nestedRangeHead = try! NSRegularExpression(
        pattern: #"#?for\s+[A-Za-z_][A-Za-z0-9_]*\s+in\s+range\([^()\n]*\)"#)

    /// Substitutes `value` for `variable` inside every `#calc(…)` /
    /// `#calc-table(…)` call (the whole balanced call, so table bounds work)
    /// and inside nested `range(…)` heads, leaving all other text untouched.
    static func specialise(_ body: String, variable: String, value: String) -> String {
        // Negative values are parenthesised so `n^2` becomes `(-1)^2`, not `-1^2`.
        let literal = value.hasPrefix("-") ? "(\(value))" : value
        let word = "(?<![A-Za-z0-9_.])" + NSRegularExpression.escapedPattern(for: variable) + "(?![A-Za-z0-9_])"
        let template = NSRegularExpression.escapedTemplate(for: literal)

        var ranges: [NSRange] = []
        let ns = body as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in calculatorCall.matches(in: body, options: [], range: full) {
            if let call = balancedRange(in: ns, from: match.range.upperBound - 1) {
                ranges.append(NSRange(location: match.range.location,
                                      length: call.location + call.length - match.range.location))
            }
        }
        for match in nestedRangeHead.matches(in: body, options: [], range: full) {
            ranges.append(match.range)
        }
        ranges.sort { $0.location < $1.location }

        var result = ""
        var cursor = 0
        for range in ranges where range.location >= cursor {
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let segment = ns.substring(with: range)
            result += segment.replacingOccurrences(of: word, with: template, options: .regularExpression)
            cursor = range.location + range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func line(of location: Int, in ns: NSString) -> Int {
        var line = 1
        var index = 0
        while index < min(location, ns.length) {
            if ns.character(at: index) == 0x0A { line += 1 }
            index += 1
        }
        return line
    }
}
