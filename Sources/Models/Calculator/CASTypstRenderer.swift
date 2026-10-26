import Foundation

/// Converts a `CASExpression` tree into Typst math markup, in the style the
/// TI-89 uses on its home screen: fractions, `sin⁻¹`, `e^x`, ∫ with bounds,
/// solution sets like `{x=-2, x=2}`.
///
/// Every function here is pure, so the whole renderer is covered by plain
/// unit tests without a running CAS.
enum CASTypstRenderer {

    /// Renders a Typst math string. The result is meant to be wrapped in
    /// `$ … $` by callers.
    static func typst(_ expression: CASExpression) -> String {
        render(expression)
    }

    /// Renders for display inside an existing math environment, where the
    /// top level gets no outer grouping.
    static func typstInline(_ expression: CASExpression) -> String {
        render(expression)
    }

    // MARK: - Dispatch

    private static func render(_ e: CASExpression) -> String {
        switch e {
        case let .number(value, approx):
            return renderNumber(value: value, approx: approx)
        case let .symbol(name):
            return renderSymbol(name)
        case let .constant(name):
            return renderConstant(name)
        case let .string(value):
            return quote(value)
        case let .operation(name, args):
            return renderOperation(name: name, args: args)
        case let .function(name, args):
            return renderFunction(name: name, args: args)
        case let .sequence(items):
            return items.map { render($0) }.joined(separator: ", ")
        case let .vector(items):
            return renderVector(items)
        case let .list(items):
            return "{" + items.map { render($0) }.joined(separator: ", ") + "}"
        case .undefined:
            return "undef"
        }
    }

    // MARK: - Atoms

    private static func renderNumber(value: String, approx: String?) -> String {
        var text = value
        // Giac reports booleans (isPrime, comparisons) as numeric leaves.
        // Typst math would read the bare words as unknown variables.
        if text == "true" || text == "false" || text == "undef" {
            return "\"\(text)\""
        }
        // Powers of ten like 1.5e-7 or 2E+12: Typst math would read `e` as
        // a variable, so typeset scientific notation explicitly.
        if let match = scientificRange(in: text) {
            let mantissa = String(text[match.mantissa])
            let exponent = String(text[match.exponent]).replacingOccurrences(of: "+", with: "")
            return "\(mantissa) times 10^(\(exponent))"
        }
        // Exact rationals print as a/b; make the fraction explicit so Typst's
        // slash grammar can't mis-group anything. Atomic pieces stay bare —
        // Typst reads `1/2` and `(-3)/4` correctly — while compound pieces
        // keep the grouping they already carry from `render`.
        if let slash = text.firstIndex(of: "/") {
            let numerator = String(text[text.startIndex..<slash])
            let denominator = String(text[text.index(after: slash)...])
            return "\(numerator)/\(denominator)"
        }
        if text.contains("*") {
            return text.replacingOccurrences(of: "*", with: " ")
        }
        _ = approx
        return text
    }

    private static func scientificRange(in text: String) -> (mantissa: Range<String.Index>, exponent: Range<String.Index>)? {
        guard let eIndex = text.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return nil }
        let mantissa = text.startIndex..<eIndex
        var cursor = text.index(after: eIndex)
        let exponentStart = cursor
        if cursor < text.endIndex && (text[cursor] == "+" || text[cursor] == "-") {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex, text[cursor].isNumber else { return nil }
        guard text[text.startIndex..<eIndex].allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return (mantissa, exponentStart..<text.endIndex)
    }

    /// Wraps a rendered piece in parentheses when it isn't a single atom.
    private static func parenthesize(_ s: String, atomic: Bool) -> String {
        atomic || s.hasPrefix("(") ? s : "(\(s))"
    }

    private static func renderSymbol(_ name: String) -> String {
        // Single letters and Greek names are fine as-is; anything containing
        // characters Typst's math grammar would misread is quoted.
        if name.count == 1 || isGreekName(name) || isTypstSafeWord(name) {
            return name
        }
        return quote(name)
    }

    private static func renderConstant(_ name: String) -> String {
        switch name {
        case "pi": return "pi"
        case "e": return "e"
        case "i": return "i"
        case "infinity", "inf", "+infinity": return "oo"
        case "-infinity": return "-oo"
        // Typst math has no boolean literals; show the words as text.
        case "true": return "\"true\""
        case "false": return "\"false\""
        case "undef": return "\"undef\""
        default: return renderSymbol(name)
        }
    }

    // MARK: - Operators

    private static func renderOperation(name: String, args: [CASExpression]) -> String {
        switch name {
        case "-", "+":
            if args.count == 1 {
                let operand = render(args[0])
                return name == "-" ? negated(operand) : "+ \(operand)"
            }
            if args.count >= 2 {
                let op = name == "+" ? " + " : " - "
                return args.map { operand($0, rightSide: false) }.joined(separator: op)
            }
        case "*":
            if args.count >= 2 {
                return args.map { render($0) }.joined(separator: " ")
            }
        case "/":
            if args.count == 2 {
                let num = render(args[0])
                let den = render(args[1])
                return "\(parenthesize(num, atomic: isAtomicOperand(args[0])))/\(parenthesize(den, atomic: isAtomicOperand(args[1])))"
            }
        case "^":
            if args.count == 2 {
                let base = parenthesize(render(args[0]), atomic: isAtomicOperand(args[0]) || isNamedFunction(args[0]))
                let exponent = render(args[1])
                // Parenthesize compound or negative exponents so the sign
                // and grouping can't be misread.
                let negative: Bool = {
                    if case let .number(value, _) = args[1] { return value.hasPrefix("-") }
                    if case let .operation("-", a) = args[1] { return a.count == 1 }
                    return false
                }()
                let needsParens = (!isAtomicOperand(args[1]) && !exponent.hasPrefix("(") && !exponent.hasPrefix("sqrt")) || negative
                return "\(base)^\(needsParens ? "(\(exponent))" : exponent)"
            }
        case "=":
            if args.count == 2 {
                return "\(render(args[0])) = \(render(args[1]))"
            }
        case ":=":
            if args.count == 2 {
                return "\(render(args[0])) \"\u{2254}\" \(render(args[1]))"
            }
        case "<", ">", "<=", ">=", "!=", "==":
            let typstOp: String
            switch name {
            case "<": typstOp = "<"
            case ">": typstOp = ">"
            case "<=": typstOp = "<="
            case ">=": typstOp = ">="
            case "!=": typstOp = "!="
            default: typstOp = "="
            }
            if args.count == 2 {
                return "\(render(args[0])) \(typstOp) \(render(args[1]))"
            }
        case "and", "or", "xor":
            if args.count >= 2 {
                let joiner = name == "and" ? " and " : " or "
                return args.map { render($0) }.joined(separator: joiner)
            }
        case "not":
            if args.count == 1 {
                return "not \(render(args[0]))"
            }
        case "!":
            if args.count == 1 {
                return "\(parenthesize(render(args[0]), atomic: isAtomicOperand(args[0])))!"
            }
        case "|":
            if args.count == 2 {
                return "\(render(args[0])) | \(render(args[1]))"
            }
        default:
            break
        }
        // Unknown operator: fall back to function-call styling.
        return renderFunction(name: name, args: args)
    }

    /// Wraps `-` results so a following `^` cannot steal the sign.
    private static func negated(_ operand: String) -> String {
        "-\(operand)"
    }

    /// An operand that can sit against an operator without grouping.
    private static func isAtomicOperand(_ e: CASExpression) -> Bool {
        switch e {
        case .number, .symbol, .constant:
            return true
        case let .operation("-", args):
            return args.count == 1 && isAtomicOperand(args[0])
        case let .operation(_, args):
            return false
        case .function:
            return true
        case .sequence, .vector, .list:
            return false
        case .string, .undefined:
            return true
        }
    }

    private static func isNamedFunction(_ e: CASExpression) -> Bool {
        if case .function = e { return true }
        return false
    }

    /// `a` and `2` can be juxtaposed in `x y`; compound operands already carry
    /// their own grouping from `render`.
    private static func operand(_ e: CASExpression, rightSide: Bool) -> String {
        let text = render(e)
        if rightSide && !isAtomicOperand(e) {
            return parenthesize(text, atomic: false)
        }
        return text
    }

    // MARK: - Functions

    private static func renderFunction(name: String, args: [CASExpression]) -> String {
        switch name {
        case "sqrt" where args.count == 1:
            return "sqrt(\(render(args[0])))"
        case "cbrt" where args.count == 1:
            return "root(\(render(args[0])), 3)"
        case "root" where args.count == 2:
            return "root(\(render(args[0])), \(render(args[1])))"
        case "abs" where args.count == 1:
            return "abs(\(render(args[0])))"
        case "inv" where args.count == 1:
            // giac prints reciprocals as inv(x); Typst has no `inv`.
            return "1/(\(render(args[0])))"
        case "exp" where args.count == 1:
            // The TI-89 prints exp(x) as e^x.
            return "e^(\(render(args[0])))"
        case "integrate", "int", "∫", "HPINT":
            return renderIntegral(args)
        case "derivative", "d", "diff":
            return renderDerivative(args)
        case "limit":
            return renderLimit(args)
        case "sum":
            return renderSum(args, word: "sum")
        case "product":
            return renderSum(args, word: "product")
        case "mat", "matrix":
            return renderMatrix(args)
        case "ln" where args.count == 1:
            return "ln(\(render(args[0])))"
        case "log" where args.count == 1:
            return "log(\(render(args[0])))"
        case "log" where args.count == 2:
            return "log_(\(render(args[1])))(\(render(args[0])))"
        case "ifte" where args.count == 3:
            return "cases(\(render(args[1])) & \"if\" & \(render(args[0])), \(render(args[2])) & \"otherwise\")"
        case "piecewise":
            return renderPiecewise(args)
        default:
            // Inverse trig prints like the TI-89: sin^(-1)(x).
            if let inverse = inverseTrig(name), args.count == 1 {
                return "\(inverse)^(-1)(\(render(args[0])))"
            }
            let fnName = renderSymbol(name)
            let renderedArgs = args.map { render($0) }.joined(separator: ", ")
            return "\(fnName)(\(renderedArgs))"
        }
    }

    /// `asin/acos/atan/…` → the forward name used to build `sin^(-1)`.
    private static func inverseTrig(_ name: String) -> String? {
        switch name {
        case "asin", "arcsin": return "sin"
        case "acos", "arccos": return "cos"
        case "atan", "arctan": return "tan"
        case "asinh", "arcsinh": return "sinh"
        case "acosh", "arccosh": return "cosh"
        case "atanh", "arctanh": return "tanh"
        default: return nil
        }
    }

    private static func renderIntegral(_ args: [CASExpression]) -> String {
        // integrate(f, x)            → integral f dif x
        // integrate(f, x, a, b)      → integral_a^b f dif x
        // The integrand is wrapped when compound so `+ 1` can't read as
        // being outside the integral.
        if args.count == 2 {
            return "integral \(integrand(args[0])) dif \(render(args[1]))"
        }
        if args.count == 4 {
            let lower = render(args[2])
            let upper = render(args[3])
            let sub = parenthesize(lower, atomic: isAtomicOperand(args[2]))
            let sup = parenthesize(upper, atomic: isAtomicOperand(args[3]))
            return "integral_\(sub)^\(sup) \(integrand(args[0])) dif \(render(args[1]))"
        }
        return fallbackCall(name: "integral", args: args)
    }

    private static func integrand(_ e: CASExpression) -> String {
        parenthesize(render(e), atomic: isAtomicOperand(e))
    }

    private static func renderDerivative(_ args: [CASExpression]) -> String {
        // derivative(f, x)       → (dif f)/(dif x)
        // derivative(f, x, n)    → (dif^n f)/(dif x^n)
        if args.count == 2 {
            return "(dif \(render(args[0])))/(dif \(render(args[1])))"
        }
        if args.count == 3 {
            let n = render(args[2])
            return "(dif^(\(n)) \(render(args[0])))/(dif^(\(n)) \(render(args[1])))"
        }
        return fallbackCall(name: "dif", args: args)
    }

    private static func renderLimit(_ args: [CASExpression]) -> String {
        // limit(expr, x, a)             → lim_(x -> a) expr
        // limit(expr, x, a, 1)          → lim_(x -> a^+) expr
        if args.count >= 3 {
            var point = render(args[2])
            if args.count == 4 {
                if case let .number(value, _) = args[3] {
                    if value == "1" { point = "\(point)^+" }
                    if value == "-1" { point = "\(point)^-" }
                }
            }
            return "lim_(\(render(args[1])) -> \(point)) \(parenthesize(render(args[0]), atomic: isAtomicOperand(args[0]) || isNamedFunction(args[0])))"
        }
        return fallbackCall(name: "lim", args: args)
    }

    private static func renderSum(_ args: [CASExpression], word: String) -> String {
        // sum(expr, x, a, b) → sum_(x=a)^b expr
        if args.count == 4 {
            let lower = "\(render(args[1])) = \(render(args[2]))"
            let upper = render(args[3])
            return "\(word)_(\(lower))^(\(upper)) \(render(args[0]))"
        }
        return fallbackCall(name: word, args: args)
    }

    private static func renderMatrix(_ args: [CASExpression]) -> String {
        // A matrix arrives as a vector of row vectors.
        if args.count == 1, case let .vector(rows) = args[0] {
            let renderedRows = rows.map { row -> String in
                if case let .vector(cells) = row {
                    return cells.map { render($0) }.joined(separator: ", ")
                }
                return render(row)
            }
            return "mat(" + renderedRows.joined(separator: "; ") + ")"
        }
        // A plain vector becomes a column-less vec.
        return fallbackCall(name: "mat", args: args)
    }

    private static func renderVector(_ items: [CASExpression]) -> String {
        // A row/column vector: `vec(a, b, c)`. A matrix (vector of vectors)
        // becomes `mat(...)` rows.
        if let first = items.first, case let .vector(cells) = first,
           !cells.isEmpty, items.allSatisfy({ item in
               if case let .vector(row) = item { return row.count == cells.count }
               return false
           }) {
            // One row is still a matrix, not a vector containing a vector.
            return renderMatrix([.vector(items)])
        }
        return "vec(" + items.map { render($0) }.joined(separator: ", ") + ")"
    }

    private static func renderPiecewise(_ args: [CASExpression]) -> String {
        // giac's unevaluated piecewise arrives as nested pairs of
        // (condition, expression).
        var lines: [String] = []
        var index = 0
        while index + 1 < args.count {
            let expression = render(args[index])
            let condition = render(args[index + 1])
            lines.append("\(expression) & \"if\" & \(condition)")
            index += 2
        }
        return "cases(" + lines.joined(separator: ", ") + ")"
    }

    private static func fallbackCall(name: String, args: [CASExpression]) -> String {
        let renderedArgs = args.map { render($0) }.joined(separator: ", ")
        return "\(renderSymbol(name))(\(renderedArgs))"
    }

    // MARK: - Text helpers

    private static func quote(_ text: String) -> String {
        "\"" + text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Typst's math grammar treats short alphabetic words as safe identifiers.
    private static func isTypstSafeWord(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter && $0.isASCII }
    }

    private static let greekNames: Set<String> = [
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
        "iota", "kappa", "lambda", "mu", "nu", "xi", "omicron", "rho", "sigma",
        "tau", "upsilon", "phi", "chi", "psi", "omega", "Alpha", "Beta",
        "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa",
        "Lambda", "Mu", "Nu", "Xi", "Omicron", "Rho", "Sigma", "Tau",
        "Upsilon", "Phi", "Chi", "Psi", "Omega",
    ]

    private static func isGreekName(_ name: String) -> Bool {
        greekNames.contains(name)
    }
}
