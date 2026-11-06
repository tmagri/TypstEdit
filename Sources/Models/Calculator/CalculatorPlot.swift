import Foundation

// MARK: - Plot model

/// One sampled point of a plotted curve. `NaN` in `y` marks a gap — a point
/// where the expression had no real value (like 1/x at 0). The chart skips
/// the gap and starts a new segment after it.
struct CalculatorPlotPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One plotted calculator entry: the expressions, their range, and the
/// points the CAS sampled. Cached in `.tcalc` files like every other
/// result, so reopening a saved session redraws the chart without
/// re-evaluating anything.
struct CalculatorPlotSpec: Codable, Hashable, Sendable {
    /// Curve expressions in TI/Giac syntax, exactly as sampled, e.g. `["sin(x)"]`.
    var expressions: [String]
    /// The free variable the expressions are plotted against, e.g. `x`.
    var variable: String
    var xMin: Double
    var xMax: Double
    /// One point list per expression, x ascending. `NaN` y marks a gap.
    var curves: [[CalculatorPlotPoint]]

    /// One-line summary for Copy-as-plain-text (and a harmless `ans` recall).
    var summary: String {
        let curves = expressions.count == 1 ? "1 curve" : "\(expressions.count) curves"
        return "\(expressions.joined(separator: ", ")) · \(variable) from \(TIPlot.format(xMin)) to \(TIPlot.format(xMax)) · \(curves)"
    }
}

/// The parsed form of a `plot(…)` entry line, before the bounds are turned
/// into numbers.
struct TIPlotCall: Equatable {
    /// Curve expressions in TI/Giac syntax (already preprocessed).
    var expressions: [String]
    var variable: String
    /// The bound texts as typed; may be plain numbers or expressions (`-pi`).
    var xMinText: String
    var xMaxText: String
}

/// A plot-shaped input that could not be used.
struct TIPlotError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The calculator's plotting language: `plot(expr, …, var, x-min, x-max)`
/// draws one to four curves in the history, sampled by the CAS itself
/// (`seq((expr | var = …), …)`), and offers the result to the editor as
/// document `#plot(…)` code, as exact sampled points, or as an image.
///
/// Parsing and code generation are pure; sampling needs the CAS engine.
enum TIPlot {

    /// Curves allowed on one entry line.
    static let maxCurves = 4
    /// Points per curve — the same default the document `plot()` uses.
    static let sampleCount = 160

    // MARK: - Parsing

    /// Parses one entry line. Returns `nil` when the line is not a plot call
    /// at all; throws `TIPlotError` when it is one but cannot be used.
    static func parse(_ input: String) throws -> TIPlotCall? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\s*plot\s*\("#,
                            options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        guard trimmed.hasSuffix(")") else {
            throw TIPlotError("plot: the call is missing its closing parenthesis")
        }
        guard let open = trimmed.firstIndex(of: "(") else { return nil }
        let inner = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        let arguments = splitArguments(inner)
        guard arguments.count >= 4 else {
            throw TIPlotError("plot(expression, …, var, x-min, x-max) — give 1–\(maxCurves) expressions, the variable and the two bounds")
        }
        guard arguments.count <= maxCurves + 3 else {
            throw TIPlotError("plot: at most \(maxCurves) curves fit on one line")
        }
        let variable = arguments[arguments.count - 3]
        guard variable.range(of: #"^[\p{L}_][\p{L}\p{N}_]*$"#, options: .regularExpression) != nil else {
            throw TIPlotError("plot: “\(variable)” is not a variable name")
        }
        let xMinText = arguments[arguments.count - 2]
        let xMaxText = arguments[arguments.count - 1]
        let expressions = Array(arguments[0..<(arguments.count - 3)])
        for expression in expressions where expression.isEmpty {
            throw TIPlotError("plot: one of the expressions is empty")
        }
        for expression in expressions where expression.contains("=") {
            throw TIPlotError("plot: “\(expression)” is not an expression — equations belong to solve(, and the calculator draws expressions")
        }
        for expression in expressions where expression.range(of: #"^\s*plot\s*\("#,
                                                              options: [.regularExpression, .caseInsensitive]) != nil {
            throw TIPlotError("plot: a plot cannot be an argument of another plot")
        }
        return TIPlotCall(expressions: expressions,
                          variable: variable,
                          xMinText: xMinText,
                          xMaxText: xMaxText)
    }

    /// Splits on commas that sit outside every bracket and string.
    static func splitArguments(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quoted = false
        var escaped = false
        for character in text {
            if quoted {
                current.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
                continue
            }
            switch character {
            case "\"": quoted = true; current.append(character)
            case "(", "[", "{": depth += 1; current.append(character)
            case ")", "]", "}": depth -= 1; current.append(character)
            case ",":
                if depth == 0 { parts.append(current); current = "" }
                else { current.append(character) }
            default: current.append(character)
            }
        }
        if !parts.isEmpty || !current.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(current)
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Sampling

    struct ResolvedBounds: Equatable {
        let xMin: Double
        let xMax: Double
    }

    /// Samples every curve and checks the result is honest, then returns the
    /// spec the history entry keeps (including its points, for `.tcalc`
    /// caching). Each curve costs one CAS call for the samples plus three
    /// single-point probes that catch symbolic residue.
    static func sample(_ call: TIPlotCall,
                       engine: CASEngine = .shared,
                       angle: CASAngleMode = .radians,
                       digits: Int = 12,
                       timeout: TimeInterval = 10) async throws -> CalculatorPlotSpec {
        let bounds = try await resolveBounds(call, engine: engine, angle: angle, digits: digits, timeout: timeout)
        var curves: [[CalculatorPlotPoint]] = []
        for expression in call.expressions {
            let input = casInput(expression: expression,
                                 variable: call.variable,
                                 xMin: bounds.xMin,
                                 xMax: bounds.xMax)
            let result = await engine.eval(input: input, approx: true,
                                           angle: angle, digits: digits, timeout: timeout)
            guard result.ok else {
                throw TIPlotError("plot: the CAS could not sample “\(expression)” — \(result.errorMessage)")
            }
            let values = sampledValues(from: result)
            guard values.count == sampleCount else {
                throw TIPlotError("plot: the CAS returned \(values.count) of \(sampleCount) samples for “\(expression)”")
            }
            let points = zip(sampleXs(xMin: bounds.xMin, xMax: bounds.xMax), values)
                .map { CalculatorPlotPoint(x: $0, y: $1 ?? Double.nan) }
            guard points.contains(where: { !$0.y.isNaN }) else {
                throw TIPlotError("plot: “\(expression)” produced no numbers over this range — check that every name in it has a stored value, and that it is an expression, not an equation")
            }
            try await rejectSymbolicResidue(expression, call, bounds,
                                            engine: engine, angle: angle,
                                            digits: digits, timeout: timeout)
            curves.append(points)
        }
        return CalculatorPlotSpec(expressions: call.expressions,
                                  variable: call.variable,
                                  xMin: bounds.xMin,
                                  xMax: bounds.xMax,
                                  curves: curves)
    }

    /// A curve whose samples are mostly numbers can still be nonsense: with
    /// an unknown name in the expression, the sample at x = 0 is genuinely
    /// `0` (the CAS multiplies the free name away), and the rest are gaps.
    /// Probing three interior points separates that case from an honest
    /// pole: a residue that still contains a free symbol fails the plot;
    /// `infinity` or a complex value passes (the chart draws those as gaps).
    private static func rejectSymbolicResidue(_ expression: String,
                                              _ call: TIPlotCall,
                                              _ bounds: ResolvedBounds,
                                              engine: CASEngine,
                                              angle: CASAngleMode,
                                              digits: Int,
                                              timeout: TimeInterval) async throws {
        let span = bounds.xMax - bounds.xMin
        let probeShares = [0.25, 0.5, 0.75]
        var symbolicProbes = 0
        for share in probeShares {
            let probeValue = bounds.xMin + span * share
            let input = substitutionInput(expression: expression,
                                          variable: call.variable,
                                          value: probeValue)
            let probe = await engine.eval(input: input, approx: true,
                                          angle: angle, digits: digits, timeout: timeout)
            guard probe.ok, let tree = probe.resultTree else { continue }
            if containsFreeSymbol(tree) {
                symbolicProbes += 1
            } else {
                return // at least one real value — the curve is computable
            }
        }
        if symbolicProbes == probeShares.count {
            throw TIPlotError("plot: “\(expression)” does not evaluate to numbers — check that every name in it has a stored value (delVar a name first if it shadows the plot variable)")
        }
    }

    /// The one-point form of the sampling substitution: `expr | var = value`.
    static func substitutionInput(expression: String, variable: String, value: Double) -> String {
        "(\(expression) | \(variable) = \(format(value, precision: 12)))"
    }

    /// The one-line CAS input that evaluates a whole curve at once:
    /// `seq((expr | var = xmin + LV*(xmax-xmin)/(n-1)), LV, 0, n-1)`.
    /// The TI `with` operator substitutes even when the plot variable has a
    /// stored value (the parentheses keep `seq` from rejecting it), so the
    /// chart is the curve over the range — never the stored value.
    static func casInput(expression: String, variable: String, xMin: Double, xMax: Double) -> String {
        let loop = loopVariable(for: expression, plotVariable: variable)
        let last = sampleCount - 1
        let rhs = "\(format(xMin, precision: 12)) + \(loop)*(\(format(xMax - xMin, precision: 12)))/\(last)"
        let substitution = "\(expression) | \(variable) = \(rhs)"
        return "seq((\(substitution)),\(loop),0,\(last))"
    }

    /// A loop name that does not appear in the expression, so a stored value
    /// of the same name is never shadowed by the sampler.
    static func loopVariable(for expression: String, plotVariable: String) -> String {
        for candidate in ["k", "_plot_j", "_plot_m"] {
            if candidate == plotVariable { continue }
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: candidate)
                + "(?![\\p{L}\\p{N}_])"
            if expression.range(of: pattern, options: .regularExpression) == nil {
                return candidate
            }
        }
        return "_plot_z"
    }

    /// Turns the two bound texts into numbers: plain decimals directly,
    /// anything else through the CAS in approximate mode (so `-pi` works).
    static func resolveBounds(_ call: TIPlotCall,
                              engine: CASEngine = .shared,
                              angle: CASAngleMode = .radians,
                              digits: Int = 12,
                              timeout: TimeInterval = 10) async throws -> ResolvedBounds {
        let xMin = try await bound(call.xMinText, engine: engine, angle: angle, digits: digits, timeout: timeout)
        let xMax = try await bound(call.xMaxText, engine: engine, angle: angle, digits: digits, timeout: timeout)
        return try checkedBounds(xMin: xMin, xMax: xMax)
    }

    static func checkedBounds(xMin: Double, xMax: Double) throws -> ResolvedBounds {
        guard xMin.isFinite, xMax.isFinite else {
            throw TIPlotError("plot: the bounds must be numbers")
        }
        guard xMin < xMax else {
            throw TIPlotError("plot: x-min (\(format(xMin))) must be less than x-max (\(format(xMax)))")
        }
        return ResolvedBounds(xMin: xMin, xMax: xMax)
    }

    private static func bound(_ text: String,
                              engine: CASEngine,
                              angle: CASAngleMode,
                              digits: Int,
                              timeout: TimeInterval) async throws -> Double {
        if let direct = double(text) { return direct }
        let result = await engine.eval(input: text, approx: true, angle: angle, digits: digits, timeout: timeout)
        guard result.ok, let tree = result.resultTree, let value = numericValue(tree) else {
            throw TIPlotError("plot: the bound “\(text)” is not a number")
        }
        return value
    }

    /// The x values that belong to the CAS's sample list.
    static func sampleXs(xMin: Double, xMax: Double) -> [Double] {
        guard sampleCount > 1 else { return [xMin] }
        let last = sampleCount - 1
        return (0...last).map { xMin + (xMax - xMin) * Double($0) / Double(last) }
    }

    /// Reads the sample list the CAS answered with. Anything that is not a
    /// plain real number (a complex value, `infinity`, an unevaluated call)
    /// becomes `nil`, which draws as a gap.
    static func sampledValues(from result: CASEvalResult) -> [Double?] {
        guard let tree = result.resultTree else { return [] }
        switch tree {
        case .vector(let items): return items.map { numericValue($0) }
        default: return [numericValue(tree)]
        }
    }

    static func numericValue(_ node: CASExpression) -> Double? {
        switch node {
        case .number(let value, let approx): return double(approx ?? value)
        default: return nil
        }
    }

    /// Whether a CAS node still carries a free name (a residue like
    /// `nosuchname*0.5`). Constants (`i`, `infinity`) and the names of
    /// unevaluated functions are not free symbols.
    static func containsFreeSymbol(_ node: CASExpression) -> Bool {
        switch node {
        case .symbol: return true
        case .number, .constant, .string, .undefined: return false
        case .operation(_, let args), .function(_, let args):
            return args.contains { containsFreeSymbol($0) }
        case .sequence(let items), .vector(let items), .list(let items):
            return items.contains { containsFreeSymbol($0) }
        }
    }

    /// Giac prints plain decimal numbers (including `1.06e+13`); a leading
    /// `.` would not survive Swift's `Double` init.
    static func double(_ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(".") { trimmed = "0" + trimmed }
        return Double(trimmed)
    }

    // MARK: - Typst code generation

    /// The `#plot(…)` call to drop into a document. This is the sampled
    /// points form on purpose: it draws the exact chart the calculator
    /// showed, and it cannot crash the document — a curve with a pole
    /// inside the range (say `sin(x)/x` over [-20, 20]) would make the
    /// callback form divide by zero while the document samples it.
    static func documentCall(for spec: CalculatorPlotSpec) -> String {
        documentCallPointsOnly(for: spec)
    }

    /// `#plot(x => calc.sin(x), -10, 10)` — or the `curves:` form for two or
    /// more translatable curves. `nil` when a curve uses something Typst
    /// cannot express, or the variable is not a Typst identifier.
    static func callbackCall(for spec: CalculatorPlotSpec) -> String? {
        guard isValidTypstIdentifier(spec.variable) else { return nil }
        let bodies = spec.expressions.map { typstCodeExpression($0, variable: spec.variable) }
        guard bodies.allSatisfy({ $0 != nil }) else { return nil }
        if spec.expressions.count == 1 {
            return "#plot(\(spec.variable) => \(bodies[0]!), \(format(spec.xMin, precision: 12)), \(format(spec.xMax, precision: 12)))"
        }
        let entries = zip(spec.expressions, bodies).map { expression, body in
            "  (fn: \(spec.variable) => \(body!), label: [\(mathLabel(expression))]),"
        }
        return """
        #plot(curves: (
        \(entries.joined(separator: "\n"))
        ), x-min: \(format(spec.xMin, precision: 12)), x-max: \(format(spec.xMax, precision: 12)))
        """
    }

    /// The points form unconditionally — one `#plot(points: …)` per curve —
    /// even when the callback form would translate. This is what "insert the
    /// sampled points" promises.
    static func documentCallPointsOnly(for spec: CalculatorPlotSpec) -> String {
        spec.curves
            .map { pointsCall(curve: $0, xMin: spec.xMin, xMax: spec.xMax) }
            .joined(separator: "\n\n")
    }

    /// `#plot(points: ((x, y), …), x-min: …, x-max: …)` — the exact sampled
    /// chart as data, downsampled to keep the snippet readable.
    static func pointsCall(curve: [CalculatorPlotPoint],
                           xMin: Double,
                           xMax: Double,
                           maxPoints: Int = 61) -> String {
        let finite = curve.filter { !$0.y.isNaN && $0.y.isFinite }
        let stride = max(1, (finite.count + maxPoints - 1) / maxPoints)
        var pairs: [String] = []
        for (index, point) in finite.enumerated() where index % stride == 0 {
            pairs.append("(\(format(point.x, precision: 6)), \(format(point.y, precision: 6)))")
        }
        if let last = finite.last, !pairs.contains(where: { $0.contains(format(last.x, precision: 6)) }) {
            pairs.append("(\(format(last.x, precision: 6)), \(format(last.y, precision: 6)))")
        }
        return """
        #plot(
          points: (\(pairs.joined(separator: ", "))),
          x-min: \(format(xMin, precision: 12)), x-max: \(format(xMax, precision: 12)),
        )
        """
    }

    /// Short number text for summaries and generated code.
    static func format(_ value: Double, precision: Int = 6) -> String {
        guard value.isFinite else { return String(value) }
        if value == value.rounded(), abs(value) < 1e12 {
            return String(Int(value))
        }
        return String(format: "%.\(precision)g", value)
    }

    /// Curve labels go into Typst markup, so escape the characters that
    /// would start code, math or formatting there.
    static func mathLabel(_ expression: String) -> String {
        expression
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func isValidTypstIdentifier(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    // MARK: - TI expression → Typst code

    /// Translates a TI/Giac expression onto a Typst code-mode expression
    /// (`sin(x)` → `calc.sin(x)`, `x^2` → `calc.pow(x, 2)`, registry
    /// functions → `calc-call("name", …)`). Returns `nil` when the
    /// expression uses something TypstEdit cannot map reliably, so callers
    /// can fall back to the sampled-points form.
    static func typstCodeExpression(_ ti: String, variable: String) -> String? {
        guard let tokens = tokenize(ti) else { return nil }
        let parser = CodeParser(tokens: tokens, variable: variable)
        return parser.parse()
    }

    private struct CodeToken {
        enum Kind { case number, name, symbol }
        let kind: Kind
        let text: String
    }

    private static func tokenize(_ input: String) -> [CodeToken]? {
        var tokens: [CodeToken] = []
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            if character.isWhitespace {
                index = input.index(after: index)
                continue
            }
            // Named glyphs the entry line uses.
            if character == "√" { tokens.append(CodeToken(kind: .name, text: "sqrt")); index = input.index(after: index); continue }
            if character == "π" { tokens.append(CodeToken(kind: .name, text: "pi")); index = input.index(after: index); continue }
            if character == "∞" { tokens.append(CodeToken(kind: .name, text: "infinity")); index = input.index(after: index); continue }

            if character.isNumber || character == "." {
                var text = ""
                var seenDot = false
                while index < input.endIndex {
                    let c = input[index]
                    if c.isNumber {
                        text.append(c)
                        index = input.index(after: index)
                    } else if c == ".", !seenDot {
                        seenDot = true
                        text.append(c)
                        index = input.index(after: index)
                    } else {
                        break
                    }
                }
                // Exponent notation: 1e+13, 2.5e-3 (but not the e in `exp`).
                if let (sign, digitsEnd) = Self.exponentStart(in: input, at: index) {
                    text.append("e")
                    index = input.index(after: index)
                    if let sign {
                        text.append(sign)
                        index = input.index(after: index)
                    }
                    index = digitsEnd
                    while index < input.endIndex, input[index].isNumber {
                        text.append(input[index])
                        index = input.index(after: index)
                    }
                }
                tokens.append(CodeToken(kind: .number, text: text))
                continue
            }

            if character.isLetter || character == "_" {
                var text = ""
                while index < input.endIndex,
                      input[index].isLetter || input[index].isNumber || input[index] == "_" {
                    text.append(input[index])
                    index = input.index(after: index)
                }
                tokens.append(CodeToken(kind: .name, text: text))
                continue
            }

            if "+-*/^(),!".contains(character) {
                tokens.append(CodeToken(kind: .symbol, text: String(character)))
                index = input.index(after: index)
                continue
            }
            return nil // unsupported character — fall back to the points form
        }
        return tokens
    }

    /// If `index` sits on an `e`/`E` that starts an exponent run inside a
    /// number, returns the optional sign and where the digits begin.
    private static func exponentStart(in input: String, at index: String.Index) -> (Character?, String.Index)? {
        guard index < input.endIndex, input[index] == "e" || input[index] == "E" else { return nil }
        let next = input.index(after: index)
        guard next < input.endIndex else { return nil }
        if input[next].isNumber { return (nil, next) }
        if input[next] == "+" || input[next] == "-" {
            let afterSign = input.index(after: next)
            if afterSign < input.endIndex, input[afterSign].isNumber {
                return (input[next], afterSign)
            }
        }
        return nil
    }

    /// Recursive descent over the token list, emitting Typst code directly.
    /// Precedence, tightest first: `!`, `^` (right-associative), unary minus,
    /// `*` `/` (and implicit multiplication like `2x`), `+` `-`.
    private final class CodeParser {
        private let tokens: [CodeToken]
        private let variable: String
        private var position = 0

        /// Typst's own `calc` functions, spelled the same as Giac's.
        private static let calcFunctions: Set<String> = [
            "abs", "ceil", "floor", "round", "trunc", "exp", "ln", "sqrt", "root",
            "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
            "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
            "min", "max", "norm", "odd", "even", "pow", "div", "rem", "quotient",
        ]

        /// Constants the entry line can use, with their Typst code names.
        private static let constants: [String: String] = [
            "pi": "calc.pi", "e": "calc.e", "tau": "calc.tau", "infinity": "calc.inf",
        ]

        init(tokens: [CodeToken], variable: String) {
            self.tokens = tokens
            self.variable = variable
        }

        func parse() -> String? {
            guard let expression = additive() else { return nil }
            guard position == tokens.count else { return nil }
            return expression
        }

        private func peek() -> CodeToken? { tokens[safe: position] }

        private func advance() { position += 1 }

        private func symbol() -> String? {
            guard let token = peek(), token.kind == .symbol else { return nil }
            return token.text
        }

        private func additive() -> String? {
            guard var left = multiplicative() else { return nil }
            while let op = symbol(), op == "+" || op == "-" {
                advance()
                guard let right = multiplicative() else { return nil }
                left = "\(left) \(op) \(right)"
            }
            return left
        }

        private func multiplicative() -> String? {
            guard var left = unary() else { return nil }
            while true {
                if let op = symbol(), op == "*" || op == "/" {
                    advance()
                    guard let right = unary() else { return nil }
                    left = "\(left) \(op) \(right)"
                } else if startsPrimary, let right = unary() {
                    // Implicit multiplication, like `2x` or `2(x + 1)`.
                    left = "\(left) * \(right)"
                } else {
                    break
                }
            }
            return left
        }

        private var startsPrimary: Bool {
            guard let token = peek() else { return false }
            if token.kind == .number || token.kind == .name { return true }
            return token.kind == .symbol && token.text == "("
        }

        private func unary() -> String? {
            if let op = symbol(), op == "-" {
                advance()
                guard let operand = unary() else { return nil }
                return "-\(operand)"
            }
            if let op = symbol(), op == "+" {
                advance()
                return unary()
            }
            return power()
        }

        private func power() -> String? {
            guard let base = postfix() else { return nil }
            if let op = symbol(), op == "^" {
                advance()
                guard let exponent = unary() else { return nil }
                return "calc.pow(\(base), \(exponent))"
            }
            return base
        }

        private func postfix() -> String? {
            guard var operand = primary() else { return nil }
            while let op = symbol(), op == "!" {
                advance()
                operand = "calc.factorial(\(operand))"
            }
            return operand
        }

        private func primary() -> String? {
            guard let token = peek() else { return nil }
            switch token.kind {
            case .number:
                advance()
                var text = token.text
                if text.hasPrefix(".") { text = "0" + text }
                return text
            case .symbol where token.text == "(":
                advance()
                guard let inner = additive() else { return nil }
                guard let close = symbol(), close == ")" else { return nil }
                advance()
                return "(\(inner))"
            case .name:
                advance()
                if let op = symbol(), op == "(" {
                    advance()
                    var arguments: [String] = []
                    if let first = symbol(), first == ")" {
                        advance()
                    } else {
                        guard let argument = additive() else { return nil }
                        arguments.append(argument)
                        while let comma = symbol(), comma == "," {
                            advance()
                            guard let next = additive() else { return nil }
                            arguments.append(next)
                        }
                        guard let close = symbol(), close == ")" else { return nil }
                        advance()
                    }
                    return call(named: token.text, arguments: arguments)
                }
                return plainName(token.text)
            default:
                return nil
            }
        }

        private func call(named name: String, arguments: [String]) -> String? {
            let joined = arguments.joined(separator: ", ")
            // Giac's `log` is the natural logarithm; Typst's `calc.log` is
            // base-10, so map to `calc.ln` to keep the chart honest.
            if name == "log" { return "calc.ln(\(joined))" }
            if Self.calcFunctions.contains(name) { return "calc.\(name)(\(joined))" }
            // Registry functions draw through the bridge's generic dispatcher.
            if let entry = CalcPlugin.registryFunctions.first(where: { $0.name == name }),
               entry.arity == arguments.count {
                return "calc-call(\"\(name)\", \(joined))"
            }
            return nil
        }

        private func plainName(_ name: String) -> String? {
            if name == variable { return name }
            return Self.constants[name]
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
