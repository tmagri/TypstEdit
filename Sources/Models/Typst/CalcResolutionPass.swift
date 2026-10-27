import Foundation

/// Settings the resolution pass uses for CAS evaluations. Read from the
/// calculator's stored defaults (the same values the Calculator panel starts
/// with) so a document's `#calc` calls agree with what the user sees on the
/// home screen.
struct CalcResolutionSettings: Equatable, Sendable {
    var angle: CASAngleMode
    var exactMode: CASExactMode
    var digits: Int
    var timeout: TimeInterval

    @MainActor
    static func fromDefaults() -> CalcResolutionSettings {
        let manager = GeneralSettingsManager.shared
        return CalcResolutionSettings(
            angle: manager.calcAngleMode,
            exactMode: manager.calcExactMode,
            digits: manager.calcDisplayDigits,
            timeout: manager.calcTimeout)
    }
}

/// One resolved call site: what was replaced, and where the replacement came
/// from (for the document-parameter round-trip).
struct CalcResolutionOutcome {
    /// Source with every `#calc(…)` / `#calc-table(…)` call replaced by its
    /// value. Within-line replacements only, so shadow↔source line mapping is
    /// unaffected.
    var output: String
    /// Advisory warnings for calls the CAS could not evaluate (the document
    /// still compiles — the failing call is left in place and renders as text).
    var diagnostics: [TypstError]
    /// Document parameters found in `#let name = calc-param(expr)` lines,
    /// with their CAS-evaluated default values. Empty when the engine has no
    /// parameters to sync.
    var parameters: [CalculatorStoredVariable]
}

/// Resolves TypstEdit calculator calls in a document source:
///
///   #calc("2^10")                                  → 1024
///   #calc("BesselJ(2, 5)")                         → 0.04659…
///   #let a = calc-param(2.5)                       → parameter, stored in the
///                                                    CAS context as `a`
///   #calc-table("a*sin(x)", x, 0, 6.28, 40)        → ((0, 0), (0.157, 0.157), …)
///
/// One-shot only: calls are resolved *before* compilation, so they can NOT sit
/// inside Typst loops/`#for` bodies — those freeze at the first compile. Use
/// the preamble's pure-Typst functions (`BesselJ` …) inside loops instead.
///
/// `calc-param(…)` itself is never rewritten: the preamble defines it as the
/// identity function, so the compiled document uses the same default the CAS
/// sees, and both stay in sync with the one source line.
enum CalcResolutionPass {

    // MARK: - Call syntax

    /// `#calc("…")` in markup or `calc("…")` in code mode. Requiring a string
    /// as the first argument keeps it disjoint from Typst's own `calc.pow(…)`
    /// module calls (and from `my-calc(…)`).
    private static let callStart = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_.-])#?(calc|calc-table)\s*(\()(?=\s*")"#)
    private static let parameterDecl = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*#let[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*calc-param\s*\("#)
    /// Standalone identifier used when substituting the table variable.
    private static let wordBoundary = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])x(?![A-Za-z0-9_])"#)

    /// Matches a plain number (what we can substitute bare into any context).
    private static let plainNumber = try! NSRegularExpression(
        pattern: #"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$"#)

    /// Doubles that came back from the CAS as clean decimals.
    private static let giacNumber = try! NSRegularExpression(
        pattern: #"^[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?$"#)

    // MARK: - Entry point

    /// Resolves every call in `source`. Never throws; per-call failures become
    /// advisory diagnostics and leave the original text untouched.
    ///
    /// - Parameters:
    ///   - cache: memo of `callText|paramsKey` → replacement, owned by the
    ///     compiler so debounced recompiles skip CAS round-trips. Passed in by
    ///     value (this call is async and must not hold `inout` access across
    ///     suspension); the updated cache comes back in the result.
    ///   - storedParameters: last-known parameter set; when it changes the
    ///     engine variables are (re)stored before resolution.
    /// - Returns: the resolved outcome plus the new cache/parameter state for
    ///   the caller to keep for the next run.
    static func resolve(
        _ source: String,
        fileExtension: String,
        settings: CalcResolutionSettings,
        cache: [String: String],
        storedParameters: [CalculatorStoredVariable]
    ) async -> (outcome: CalcResolutionOutcome, cache: [String: String], storedParameters: [CalculatorStoredVariable]) {
        // Statically bounded loops that call the calculator are specialised
        // first: one body copy per iteration, with the loop value substituted
        // into the calculator string, so the CAS can evaluate each copy.
        let unrolled = CalcLoopUnroller.unroll(source)
        var output = unrolled.output
        var diagnostics: [TypstError] = []
        for warning in unrolled.warnings {
            diagnostics.append(makeDiagnostic(line: warning.line, message: warning.message))
        }
        var parameters = extractParameters(from: output)
        var cache = cache
        var storedParameters = storedParameters

        // Sync parameters into the CAS context only when they actually
        // changed (or the engine lost them), so typing elsewhere in the
        // document does not replay stores on every keystroke. Stale
        // variables from a previous document are purged so `#calc("a")`
        // in a parameter-less document can't pick up a leftover value.
        if parameters != storedParameters {
            let staleNames = Set(storedParameters.map(\.name)).subtracting(parameters.map(\.name))
            for name in staleNames {
                _ = await CASEngine.shared.eval(
                    input: "purge(\(name))",
                    approx: true,
                    angle: settings.angle,
                    digits: settings.digits,
                    timeout: 5)
            }
            for parameter in parameters {
                let prepared = TISyntax.preprocess("\(parameter.value)►\(parameter.name)")
                let result = await CASEngine.shared.eval(
                    input: prepared,
                    approx: true,
                    angle: settings.angle,
                    digits: settings.digits,
                    timeout: settings.timeout)
                if !result.ok {
                    diagnostics.append(makeDiagnostic(
                        line: parameterLine(name: parameter.name, in: source),
                        message: "Parameter \(parameter.name) = \(parameter.value) could not be evaluated: \(result.errorMessage)"))
                    parameters.removeAll { $0.name == parameter.name }
                }
            }
            storedParameters = parameters
            cache.removeAll()
        }

        guard needsResolution(output) else {
            return (CalcResolutionOutcome(output: output, diagnostics: diagnostics, parameters: parameters), cache, storedParameters)
        }

        let paramsKey = parameters.map { "\($0.name)=\($0.value)" }.joined(separator: ";")

        // Collect call ranges first (they don't overlap), then replace from
        // the end so earlier ranges stay valid.
        var sites: [(range: NSRange, text: String, kind: String, line: Int)] = []
        let ns = output as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in callStart.matches(in: output, options: [], range: full) {
            guard let call = balancedCall(in: output, openingBracketUTF16At: match.range(at: 2).location) else {
                sites.append((match.range, "", "unbalanced", line(of: match.range.location, in: output as NSString)))
                continue
            }
            let line = line(of: match.range.location, in: output as NSString)
            // Replace the whole call (`#calc(…)`), not just the parenthesized
            // part: the balanced range starts at the opening bracket.
            let whole = NSRange(location: match.range.location,
                                length: call.range.upperBound - match.range.location)
            sites.append((whole, call.text, ns.substring(with: match.range(at: 1)), line))
        }

        for site in sites.reversed() {
            if site.kind == "unbalanced" {
                diagnostics.append(makeDiagnostic(
                    line: site.line,
                    message: "This #calc call has unbalanced parentheses and could not be evaluated."))
                continue
            }

            let cacheKey = "\(paramsKey)|\(site.kind)|\(site.text)"
            if let cached = cache[cacheKey] {
                output = replace(site.range, with: cached, in: output)
                continue
            }

            let evaluated: String?
            switch site.kind {
            case "calc":
                evaluated = await resolveCalcCall(site.text, settings: settings, line: site.line, diagnostics: &diagnostics)
            case "calc-table":
                evaluated = await resolveTableCall(site.text, settings: settings, line: site.line, diagnostics: &diagnostics)
            default:
                evaluated = nil
            }

            if let evaluated {
                cache[cacheKey] = evaluated
                output = replace(site.range, with: evaluated, in: output)
            }
            // On failure the original call text stays: it compiles as literal
            // text (or raises a normal Typst diagnostic), and the advisory
            // warning explains why it never got substituted.
        }

        return (CalcResolutionOutcome(output: output, diagnostics: diagnostics, parameters: parameters), cache, storedParameters)
    }

    /// Cheap pre-check so documents without calls skip all regex work beyond
    /// the scan the compiler already ran.
    static func needsResolution(_ source: String) -> Bool {
        source.contains("calc(") || source.contains("calc-table(") || source.contains("calc-param(")
    }

    // MARK: - Parameters

    /// Finds `#let name = calc-param(expr)` declarations. `expr` is the text
    /// up to the matching closing parenthesis.
    static func extractParameters(from source: String) -> [CalculatorStoredVariable] {
        let ns = source as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [CalculatorStoredVariable] = []
        var seen = Set<String>()
        for match in parameterDecl.matches(in: source, options: [], range: full) {
            let name = ns.substring(with: match.range(at: 1))
            guard let call = balancedCall(in: source, openingBracketUTF16At: match.range.upperBound - 1),
                  let openQuote = call.text.firstIndex(of: "(") else { continue }
            let expr = String(call.text[call.text.index(after: openQuote)...]
                .dropLast())
            guard isValidParameterName(name), !seen.contains(name) else { continue }
            seen.insert(name)
            found.append(CalculatorStoredVariable(name: name, value: expr))
        }
        return found
    }

    private static func isValidParameterName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    private static func parameterLine(name: String, in source: String) -> Int? {
        // The declaration line `#let <name> = calc-param(...)` is what the
        // diagnostic should point at; fall back to the first calc-param line.
        let ns = source as NSString
        let full = NSRange(location: 0, length: ns.length)
        let pattern = try! NSRegularExpression(pattern: "#let[ \\t]+\(NSRegularExpression.escapedPattern(for: name))[ \\t]*=")
        if let match = pattern.firstMatch(in: source, options: [], range: full) {
            return line(of: match.range.location, in: ns)
        }
        if let range = source.range(of: "calc-param", options: .literal) {
            return line(of: range.lowerBound.utf16Offset(in: source), in: ns)
        }
        return nil
    }

    // MARK: - #calc("expr")

    private static func resolveCalcCall(
        _ call: String, settings: CalcResolutionSettings, line: Int,
        diagnostics: inout [TypstError]
    ) async -> String? {
        guard let argument = firstQuotedArgument(call) else {
            diagnostics.append(makeDiagnostic(
                line: line,
                message: "#calc needs a quoted expression, e.g. #calc(\"2^10\")."))
            return nil
        }
        let prepared = TISyntax.preprocess(argument)
        let result = await CASEngine.shared.eval(
            input: prepared,
            approx: true,
            angle: settings.angle,
            digits: settings.digits,
            timeout: settings.timeout)

        guard result.ok, !result.resultText.isEmpty else {
            diagnostics.append(makeDiagnostic(
                line: line,
                message: "Calculator could not evaluate #calc(\(argument)): \(result.errorMessage.isEmpty ? "no result" : result.errorMessage)"))
            return nil
        }

        let text = result.resultText
        // giac answers `undef` (not an error) for input it cannot make sense of.
        if text == "undef" || result.resultTree == .undefined {
            diagnostics.append(makeDiagnostic(
                line: line,
                message: "Calculator could not evaluate #calc(\(argument)) — the result is undefined."))
            return nil
        }

        // Numeric results substitute bare (valid in markup and code); symbolic
        // ones become a math span so operators like `+`/`/` render correctly.
        if plainNumber.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) != nil {
            return text
        }
        if !result.resultTypst.isEmpty {
            return "$ \(result.resultTypst) $"
        }
        diagnostics.append(makeDiagnostic(
            line: line,
            message: "#calc(\(argument)) produced a non-numeric result (\(text)) that cannot be placed in the document."))
        return nil
    }

    // MARK: - #calc-table("expr", x, x0, x1, n)

    private static func resolveTableCall(
        _ call: String, settings: CalcResolutionSettings, line: Int,
        diagnostics: inout [TypstError]
    ) async -> String? {
        guard let arguments = splitArguments(call) else {
            diagnostics.append(makeDiagnostic(line: line, message: "#calc-table arguments could not be parsed."))
            return nil
        }
        guard arguments.count >= 1, let expression = quoted(arguments[0]) else {
            diagnostics.append(makeDiagnostic(
                line: line,
                message: "#calc-table needs a quoted expression, e.g. #calc-table(\"sin(x)\", x, 0, 6.28, 40)."))
            return nil
        }
        guard arguments.count == 5 else {
            diagnostics.append(makeDiagnostic(
                line: line,
                message: "#calc-table needs five arguments: expression, variable, x-min, x-max, samples."))
            return nil
        }
        let variable = arguments[1]
        guard isValidParameterName(variable) else {
            diagnostics.append(makeDiagnostic(line: line, message: "#calc-table variable name must be a plain identifier."))
            return nil
        }
        let numbers = arguments[2...].compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 3, numbers[0] < numbers[1] else {
            diagnostics.append(makeDiagnostic(
                line: line,
                message: "#calc-table needs numeric x-min < x-max and a whole-number sample count."))
            return nil
        }
        let lower = numbers[0]
        let upper = numbers[1]
        let samples = max(1, min(Int(numbers[2]), 400))

        var points: [String] = []
        for index in 0...samples {
            let xv = lower + (upper - lower) * Double(index) / Double(samples)
            let xText = formatNumber(xv)
            let substituted = wordBoundary.stringByReplacingMatches(
                in: expression,
                options: [],
                range: NSRange(location: 0, length: (expression as NSString).length),
                withTemplate: "(\(xText))")
            let prepared = TISyntax.preprocess(substituted)
            let result = await CASEngine.shared.eval(
                input: prepared,
                approx: true,
                angle: settings.angle,
                digits: settings.digits,
                timeout: settings.timeout)
            guard result.ok else {
                diagnostics.append(makeDiagnostic(
                    line: line,
                    message: "#calc-table could not evaluate \(expression) at x=\(xText): \(result.errorMessage)"))
                return nil
            }
            let yText = result.resultText.trimmingCharacters(in: .whitespaces)
            guard giacNumber.firstMatch(in: yText, options: [], range: NSRange(location: 0, length: (yText as NSString).length)) != nil else {
                diagnostics.append(makeDiagnostic(
                    line: line,
                    message: "#calc-table needs numeric results; \(expression) at x=\(xText) returned \(yText)."))
                return nil
            }
            points.append("(\(xText), \(yText))")
        }
        return "(" + points.joined(separator: ", ") + ")"
    }

    // MARK: - Text plumbing

    private static func quoted(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func firstQuotedArgument(_ call: String) -> String? {
        guard let arguments = splitArguments(call) else { return nil }
        return quoted(arguments[0])
    }

    /// Splits the inside of the call's parentheses on top-level commas,
    /// returning trimmed argument text (quotes kept).
    private static func splitArguments(_ call: String) -> [String]? {
        guard let open = call.firstIndex(of: "(") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var arguments: [String] = []
        var current = ""
        var index = call.index(after: open)
        while index < call.endIndex {
            let character = call[index]
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && inString {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                inString.toggle()
                current.append(character)
            } else if inString {
                current.append(character)
            } else if character == "(" || character == "[" {
                depth += 1
                current.append(character)
            } else if character == ")" || character == "]" {
                if depth == 0 {
                    arguments.append(current.trimmingCharacters(in: .whitespaces))
                    return arguments
                }
                depth -= 1
                current.append(character)
            } else if character == "," && depth == 0 {
                arguments.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            index = call.index(after: index)
        }
        return nil
    }

    /// Returns the balanced `(...)` call text starting at the given UTF-16
    /// offset (the position of the opening bracket).
    /// Tolerates Typst's named arguments, nested strings and nested calls.
    private static func balancedCall(in text: String, openingBracketUTF16At offset: Int) -> (range: NSRange, text: String)? {
        guard let bracketRange = Range(NSRange(location: offset, length: 0), in: text) else { return nil }
        return balancedCall(in: text, openingBracketAt: bracketRange.lowerBound)
    }

    /// Returns the balanced `(...)` call text starting at `openingBracketAt`.
    private static func balancedCall(in text: String, openingBracketAt: String.Index) -> (range: NSRange, text: String)? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = openingBracketAt
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        let callText = String(text[openingBracketAt...index])
                        let utf16Start = openingBracketAt.utf16Offset(in: text)
                        return (NSRange(location: utf16Start, length: callText.utf16.count), callText)
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func replace(_ range: NSRange, with replacement: String, in source: String) -> String {
        guard let swiftRange = Range(range, in: source) else { return source }
        return source.replacingCharacters(in: swiftRange, with: replacement)
    }

    private static func line(of location: Int, in ns: NSString) -> Int {
        var line = 1
        var i = 0
        let capped = min(location, ns.length)
        while i < capped {
            if ns.character(at: i) == 0x0A { line += 1 }
            i += 1
        }
        return line
    }

    private static func formatNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%d", Int(value))
        }
        return String(format: "%.10g", value)
    }

    private static func makeDiagnostic(line: Int?, message: String) -> TypstError {
        var issue = TypstError(line: line, message: message, severity: .warning)
        issue.hints = [
            "The call was left in place; the document still compiles.",
            "#calc calls resolve once per compile — they cannot sit inside Typst loops. Use the preamble's pure-Typst functions (BesselJ, …) there.",
        ]
        return issue
    }
}
