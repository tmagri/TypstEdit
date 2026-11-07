import Foundation

/// Converts Typst math (the text inside `$ … $`) into TI/Giac entry-line
/// syntax, so an equation from the editor can be loaded straight into the
/// Calculator panel ("Send to Calculator").
///
/// Typst math is not LaTeX, and several constructs mean something different
/// to Giac when passed through unchanged:
///
/// | Typst              | Typst means      | Giac would read      |
/// |--------------------|------------------|----------------------|
/// | `frac(a, b)`       | a/b              | a vector of remainders |
/// | `root(3, x)`       | cube root of x   | `3^(1/x)`            |
/// | `log(x)`           | log base 10      | natural log          |
/// | `sin^2 x`          | (sin x)²         | a malformed program  |
/// | `2 x`              | 2·x              | a syntax error       |
/// | `x y`              | x·y              | a syntax error       |
/// | `sum_(k=1)^n k`    | a sum            | a syntax error       |
///
/// So this converter removes Typst's math delimiters and rebuilds a normal
/// infix expression the calculator understands: calls are translated
/// (`frac`, `root`, `binom`, `vec`, `mat`, `cases`, `log_b`, `sin^(-1)`,
/// `attach`, `upright`/`op`/`text` wrappers), juxtaposition becomes explicit
/// multiplication, and symbols get their calculator spelling (`oo` →
/// `infinity`, `≤` → `<=`, `degree` → radians, `sec` → `1/cos`, …).
///
/// Constructs with no faithful calculator meaning (set notation, accents,
/// quoted text, `#` code, `±`, multi-line derivations) raise a descriptive
/// `ConversionError` instead of loading a wrong expression. Alignment points
/// (`&`) are layout, so they are simply dropped.
enum TypstMathToTI {

    struct ConversionError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Marker that tags a parsed `dif` operand, so division can turn
    /// `(dif f)/(dif x)` into `diff(f, x)`. Not valid in output.
    private static let differentialMarker = "\u{E000}dif\u{E001}"

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
        let normalized = try normalize(input)
        let tokens = stripAlignmentPoints(try tokenize(normalized))
        guard !tokens.isEmpty else { throw ConversionError(reason: "The equation is empty.") }
        var parser = Parser(tokens: tokens)
        let output = try parser.parse()
        try validate(output)
        return output
    }

    // MARK: - Delimiters

    /// Removes the math delimiters Typst (and pasted LaTeX) put around an
    /// equation: `$…$`, `$$…$$`, `\[…\]` and `\(…\)`.
    static func stripDelimiters(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\\[") && text.hasSuffix("\\]") && text.count >= 4 {
            text = String(text.dropFirst(2).dropLast(2))
        } else if text.hasPrefix("\\(") && text.hasSuffix("\\)") && text.count >= 4 {
            text = String(text.dropFirst(2).dropLast(2))
        } else if text.hasPrefix("$$") && text.hasSuffix("$$") && text.count >= 4 {
            text = String(text.dropFirst(2).dropLast(2))
        } else if text.hasPrefix("$") && text.hasSuffix("$") && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        let filler = CharacterSet(charactersIn: "$").union(.whitespacesAndNewlines)
        return text.trimmingCharacters(in: filler)
    }

    // MARK: - Normalization

    /// Removes invisible markers and Typst-specific escapes, and rejects
    /// multi-line derivations (one entry line cannot hold them).
    private static func normalize(_ input: String) throws -> String {
        // Invisible formatting characters Typst may insert (U+2061 function
        // application, zero-width spaces) confuse both the tokenizer and Giac.
        var text = String(input.filter { character in
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first else { return true }
            return !((0x200B...0x200D).contains(scalar.value)
                || scalar.value == 0xFEFF
                || (0x2061...0x2064).contains(scalar.value))
        })

        // Escaped math punctuation (`\_`, `\&`, `\%`, …) is a literal
        // character in Typst; Giac wants the bare character.
        var unescaped = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                unescaped.append(character)
                continue
            }
            guard let following = iterator.next() else { break }
            switch following {
            case "$", "%", "&", "_", "#", "{", "}":
                unescaped.append(following)
            case ",", ";", " ":
                unescaped.append(" ")
            default:
                // A LaTeX-ish command (`\alpha`, `\cdot`): keep the leading
                // backslash so the translation table below can see it.
                unescaped.append("\\")
                unescaped.append(following)
            }
        }
        text = unescaped

        // LaTeX commands pasted into a Typst document are not Typst; accept
        // the handful with an unambiguous calculator spelling.
        let latex: [(String, String)] = [
            ("\\alpha", "alpha"), ("\\beta", "beta"), ("\\gamma", "gamma"),
            ("\\delta", "delta"), ("\\epsilon", "epsilon"), ("\\theta", "theta"),
            ("\\lambda", "lambda"), ("\\mu", "mu"), ("\\pi", "pi"),
            ("\\sigma", "sigma"), ("\\phi", "phi"), ("\\omega", "omega"),
            ("\\infty", "infinity"), ("\\cdot", " times "), ("\\times", " times "),
            ("\\div", " div "), ("\\leq", "<="), ("\\le", "<="), ("\\geq", ">="),
            ("\\ge", ">="), ("\\neq", "!="), ("\\ne", "!="), ("\\to", "->"),
            ("\\left", ""), ("\\right", ""),
        ]
        for (from, to) in latex {
            text = text.replacingOccurrences(of: from, with: to)
        }

        // A `\\` line break means the source is a multi-line derivation. One
        // entry line cannot hold several equations, so refuse it rather than
        // silently keep only one line.
        let lines = text.components(separatedBy: "\\\\")
        if lines.count > 1 {
            let nonEmpty = lines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if nonEmpty.count > 1 {
                throw ConversionError(
                    reason: "the equation spans several lines — send a single equation at a time")
            }
            text = nonEmpty.first ?? ""
        }

        // Any remaining backslash is a Typst escape with no calculator meaning.
        text = text.replacingOccurrences(of: "\\", with: "")
        return text
    }

    // MARK: - Tokens

    private enum TokenKind: Equatable {
        case number(String)
        case name(String)
        case symbol(String)
        case string(String)
    }

    private struct Token {
        let kind: TokenKind
        let spaceBefore: Bool
    }

    /// Longest first, so `<=` wins over `<`.
    private static let multiCharacterOperators = [
        "<=>", "->>", "|->", "...", "..",
        ":=", "<=", ">=", "!=", "==", "=>", "->", "<-", "+-", "-+", "<<", ">>", "~~", "||",
    ]

    private static let symbolTranslations: [String: String] = [
        "≤": "<=", "≥": ">=", "≠": "!=", "≈": "=", "≡": "=", "≔": ":=",
        "×": "*", "÷": "/", "·": "*", "∙": "*", "⋅": "*", "−": "-", "–": "-",
        "→": "->", "⇒": "=>", "∞": "infinity", "π": "pi",
        "∑": "sum", "∏": "product", "∫": "integral", "√": "sqrt", "°": "degree",
    ]

    private static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        var spaceBefore = false

        func advance(_ count: Int = 1) {
            index = text.index(index, offsetBy: count, limitedBy: text.endIndex) ?? text.endIndex
        }
        func peekCharacter(at offset: Int = 0) -> Character? {
            guard let position = text.index(index, offsetBy: offset, limitedBy: text.endIndex),
                  position < text.endIndex else { return nil }
            return text[position]
        }
        func hasPrefix(_ prefix: String) -> Bool {
            text[index...].hasPrefix(prefix)
        }

        while index < text.endIndex {
            let character = text[index]

            if character.isWhitespace {
                spaceBefore = true
                advance()
                continue
            }

            // Quoted text, needed by `cases(… & "if" …)`.
            if character == "\"" {
                advance()
                var payload = ""
                while index < text.endIndex, text[index] != "\"" {
                    if text[index] == "\\", let following = peekCharacter(at: 1) {
                        payload.append(following)
                        advance(2)
                        continue
                    }
                    payload.append(text[index])
                    advance()
                }
                guard index < text.endIndex else {
                    throw ConversionError(reason: "the equation has an unclosed quoted string")
                }
                advance() // closing quote
                tokens.append(Token(kind: .string(payload), spaceBefore: spaceBefore))
                spaceBefore = false
                continue
            }

            if character.isNumber {
                var number = ""
                var seenDot = false
                while let current = peekCharacter(), current.isNumber || (current == "." && !seenDot) {
                    if current == "." {
                        // `1.foo` is a number followed by a dotted symbol name.
                        guard let next = peekCharacter(at: 1), next.isNumber else { break }
                        seenDot = true
                    }
                    number.append(current)
                    advance()
                }
                // Scientific notation (`1.5e-7`, `2E+12`) is one number. Typst
                // itself would read it as 1.5·e·(−7), which nobody means.
                if number.contains(".") || number.count <= 3,
                   let marker = peekCharacter(), marker == "e" || marker == "E" {
                    var cursor = 1
                    var exponent = ""
                    if let sign = peekCharacter(at: cursor), sign == "+" || sign == "-" {
                        exponent.append(sign)
                        cursor += 1
                    }
                    var digits = ""
                    while let digit = peekCharacter(at: cursor), digit.isNumber {
                        digits.append(digit)
                        cursor += 1
                    }
                    if !digits.isEmpty, peekCharacter(at: cursor) != "." {
                        number += "e" + exponent + digits
                        advance(cursor)
                    }
                }
                tokens.append(Token(kind: .number(number), spaceBefore: spaceBefore))
                spaceBefore = false
                continue
            }

            if character.isLetter {
                var name = ""
                while let current = peekCharacter(), current.isLetter {
                    name.append(current)
                    advance()
                }
                // Dotted symbol/modifier names: `dot.op`, `plus.minus`,
                // `arrow.r`, `integral.double`.
                while peekCharacter() == ".", let next = peekCharacter(at: 1), next.isLetter {
                    name.append(".")
                    advance()
                    while let current = peekCharacter(), current.isLetter {
                        name.append(current)
                        advance()
                    }
                }
                // Primes belong to the name so `f'(x)` stays one token.
                while let current = peekCharacter(), current == "'" || current == "′" {
                    name.append("'")
                    advance()
                }
                tokens.append(Token(kind: .name(name), spaceBefore: spaceBefore))
                spaceBefore = false
                continue
            }

            if let match = multiCharacterOperators.first(where: { hasPrefix($0) }) {
                tokens.append(Token(kind: .symbol(match), spaceBefore: spaceBefore))
                advance(match.count)
                spaceBefore = false
                continue
            }

            if let translated = symbolTranslations[String(character)] {
                // Translated symbols that are words become names, so
                // `sqrt`/`sum`/`pi` reach the same parser paths as their
                // spelled-out forms.
                if translated.allSatisfy(\.isLetter) {
                    tokens.append(Token(kind: .name(translated), spaceBefore: spaceBefore))
                } else {
                    tokens.append(Token(kind: .symbol(translated), spaceBefore: spaceBefore))
                }
                spaceBefore = false
                advance()
                continue
            }

            if character == "#" {
                throw ConversionError(
                    reason: "the equation contains Typst code (`#…`), which the calculator cannot evaluate")
            }
            if character == "%" {
                // `50%` is a percentage; Giac's `%` means something else.
                tokens.append(Token(kind: .symbol("/100"), spaceBefore: spaceBefore))
                spaceBefore = false
                advance()
                continue
            }
            if character == "±" || character == "∓" {
                throw ConversionError(
                    reason: "the equation uses ± (plus/minus), which is two values, not one — write `+` or `-`")
            }
            tokens.append(Token(kind: .symbol(String(character)), spaceBefore: spaceBefore))
            spaceBefore = false
            advance()
        }
        return tokens
    }

    /// Drops alignment points (`&`) outside parentheses. In Typst they only
    /// mark layout columns (`x &= 2` is a one-line derivation), which has no
    /// calculator meaning; inside a call they are meaningful (`cases` uses
    /// them to separate a branch from its condition).
    private static func stripAlignmentPoints(_ tokens: [Token]) -> [Token] {
        var result: [Token] = []
        var depth = 0
        for token in tokens {
            if case .symbol(let symbol) = token.kind {
                if symbol == "(" || symbol == "[" || symbol == "{" { depth += 1 }
                if symbol == ")" || symbol == "]" || symbol == "}" { depth -= 1 }
                if depth == 0 && symbol == "&" { continue }
            }
            result.append(token)
        }
        return result
    }

    // MARK: - Parser

    /// Operator precedence, loosest first.
    private enum Level {
        static let boolean = 1
        static let relation = 2
        static let additive = 3
        static let multiplicative = 4
        static let unary = 5
        static let power = 6
        static let atom = 7
    }

    private struct Piece {
        var text: String
        var precedence: Int

        static func atom(_ text: String) -> Piece { Piece(text: text, precedence: Level.atom) }
    }

    private struct Stop {
        var symbols: Set<String> = [",", ";", ")", "]", "}", "&"]
        var names: Set<String> = []
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0

        init(tokens: [Token]) { self.tokens = tokens }

        // MARK: Token helpers

        private var current: Token? { index < tokens.count ? tokens[index] : nil }

        private func kind(at offset: Int = 0) -> TokenKind? {
            let position = index + offset
            return position < tokens.count ? tokens[position].kind : nil
        }

        private func token(at offset: Int = 0) -> Token? {
            let position = index + offset
            return position < tokens.count ? tokens[position] : nil
        }

        private func isSymbol(_ symbol: String, at offset: Int = 0) -> Bool {
            kind(at: offset) == .symbol(symbol)
        }

        private func isName(_ name: String, at offset: Int = 0) -> Bool {
            kind(at: offset) == .name(name)
        }

        private func atStop(_ stop: Stop) -> Bool {
            guard let token = current else { return true }
            switch token.kind {
            case .symbol(let symbol): return stop.symbols.contains(symbol)
            case .name(let name): return stop.names.contains(name)
            default: return false
            }
        }

        private mutating func consume() {
            if index < tokens.count { index += 1 }
        }

        private mutating func expect(_ symbol: String) throws {
            guard isSymbol(symbol) else {
                throw ConversionError(reason: "the equation has an unbalanced `\(symbol)`")
            }
            consume()
        }

        // MARK: Grammar

        mutating func parse() throws -> String {
            try parsePiece().text
        }

        /// The parsed expression with its precedence, for callers that need to
        /// re-group it (a fraction's numerator and denominator).
        mutating func parsePiece() throws -> Piece {
            let value = try parseBoolean(stop: Stop())
            if let token = current {
                throw ConversionError(reason: "unexpected \(Self.describe(token.kind)) in the equation")
            }
            return value
        }

        private static func describe(_ kind: TokenKind) -> String {
            switch kind {
            case .number(let value): return "number `\(value)`"
            case .name(let name): return "`\(name)`"
            case .symbol(let symbol): return "`\(symbol)`"
            case .string(let value): return "text \"\(value)\""
            }
        }

        private mutating func parseBoolean(stop: Stop) throws -> Piece {
            var left = try parseRelation(stop: stop)
            while let token = current, !atStop(stop), case .name(let name) = token.kind,
                  name == "and" || name == "or" {
                consume()
                let right = try parseRelation(stop: stop)
                left = Piece(
                    text: "\(wrap(left, atLeast: Level.relation)) \(name) \(wrap(right, atLeast: Level.relation))",
                    precedence: Level.boolean)
            }
            return left
        }

        private mutating func parseRelation(stop: Stop) throws -> Piece {
            var left = try parseAdditive(stop: stop)
            while let token = current, !atStop(stop) {
                let op: String
                switch token.kind {
                case .symbol(let symbol) where ["=", ":=", "<", ">", "<=", ">=", "!=", "=="].contains(symbol):
                    op = symbol == "==" ? "=" : symbol
                case .symbol("&"):
                    consume()
                    continue
                case .name("in"), .name("subset"), .name("supset"), .name("union"), .name("sect"):
                    throw ConversionError(
                        reason: "the equation uses set notation, which the calculator cannot evaluate")
                case .name("plus.minus"), .name("minus.plus"):
                    throw ConversionError(
                        reason: "the equation uses ± (plus/minus), which is two values, not one")
                default:
                    return left
                }
                consume()
                let right = try parseAdditive(stop: stop)
                left = Piece(
                    text: "\(wrap(left, atLeast: Level.additive)) \(op) \(wrap(right, atLeast: Level.additive))",
                    precedence: Level.relation)
            }
            return left
        }

        private mutating func parseAdditive(stop: Stop) throws -> Piece {
            var left = try parseMultiplicative(stop: stop)
            while let token = current, !atStop(stop) {
                guard case .symbol(let symbol) = token.kind, symbol == "+" || symbol == "-" else { break }
                consume()
                let right = try parseMultiplicative(stop: stop)
                left = Piece(
                    text: "\(wrap(left, atLeast: Level.additive)) \(symbol) \(wrap(right, atLeast: Level.additive))",
                    precedence: Level.additive)
            }
            return left
        }

        private static let infixWords: Set<String> = [
            "times", "dot", "dot.op", "dot.c", "cdot", "div", "mod", "degree", "Degree", "dif", "Dif",
            "and", "or", "in", "subset", "supset", "union", "sect", "plus.minus", "minus.plus",
        ]

        private mutating func parseMultiplicative(stop: Stop) throws -> Piece {
            try parseProduct(stop: stop, stopsAtFunction: false)
        }

        /// The argument of a function written without parentheses: a run of
        /// juxtaposed factors, ending before a binary operator or another
        /// function name (`sin x cos x` is sin(x)·cos(x)).
        private mutating func parseArgumentRun(stop: Stop) throws -> Piece {
            try parseProduct(stop: stop, stopsAtFunction: true)
        }

        /// Juxtaposition and the multiplicative operators. `stopsAtFunction`
        /// ends the run when another known function starts, which is what a
        /// parenthesis-free argument needs.
        private mutating func parseProduct(stop: Stop, stopsAtFunction: Bool) throws -> Piece {
            var left = try parseUnary(stop: stop)
            while let token = current, !atStop(stop) {
                if stopsAtFunction, case .name(let name) = token.kind,
                   Self.knownFunctions.contains(name) {
                    break
                }
                if case .symbol("/100") = token.kind {
                    // A percent sign: `50%` is 50/100.
                    consume()
                    left = Piece(
                        text: "\(wrap(left, atLeast: Level.multiplicative))/100",
                        precedence: Level.multiplicative)
                    continue
                }
                if case .symbol(let symbol) = token.kind, symbol == "*" || symbol == "/" {
                    consume()
                    let right = try parseUnary(stop: stop)
                    left = try combine(left, right, division: symbol == "/")
                    continue
                }
                if case .name(let name) = token.kind {
                    switch name {
                    case "times", "dot", "dot.op", "dot.c", "cdot":
                        consume()
                        let right = try parseUnary(stop: stop)
                        left = try combine(left, right, division: false)
                        continue
                    case "div":
                        consume()
                        let right = try parseUnary(stop: stop)
                        left = try combine(left, right, division: true)
                        continue
                    case "mod":
                        consume()
                        let right = try parseUnary(stop: stop)
                        left = .atom("mod(\(left.text), \(right.text))")
                        continue
                    case "degree", "Degree":
                        // Typst's degree symbol; Giac works in radians.
                        consume()
                        left = Piece(
                            text: "\(wrap(left, atLeast: Level.multiplicative))*pi/180",
                            precedence: Level.multiplicative)
                        continue
                    default:
                        break
                    }
                }
                guard startsFactor() else { break }
                let right = try parseUnary(stop: stop)
                left = try combine(left, right, division: false)
            }
            return left
        }

        private func startsFactor() -> Bool {
            guard let token = current else { return false }
            switch token.kind {
            case .number:
                return true
            case .string:
                return false
            case .name(let name):
                return !Self.infixWords.contains(name)
            case .symbol(let symbol):
                return ["(", "[", "{"].contains(symbol)
            }
        }

        private mutating func parseUnary(stop: Stop) throws -> Piece {
            if isSymbol("-") {
                consume()
                let operand = try parseUnary(stop: stop)
                return Piece(text: "-\(wrap(operand, atLeast: Level.power))", precedence: Level.unary)
            }
            if isSymbol("+") {
                consume()
                return try parseUnary(stop: stop)
            }
            if isName("not") {
                consume()
                let operand = try parseUnary(stop: stop)
                return .atom("not(\(operand.text))")
            }
            return try parsePower(stop: stop)
        }

        private mutating func parsePower(stop: Stop) throws -> Piece {
            var base = try parseAtom(stop: stop)
            while let token = current, !atStop(stop) {
                guard case .symbol(let symbol) = token.kind else { break }
                if symbol == "!" {
                    consume()
                    base = Piece(text: "\(wrap(base, atLeast: Level.power))!", precedence: Level.power)
                    continue
                }
                guard symbol == "^" || symbol == "_" else { break }
                consume()
                let script = try parseScriptOperand(stop: stop)
                base = Piece(
                    text: symbol == "^"
                        ? "\(wrap(base, atLeast: Level.power))^\(wrap(script, atLeast: Level.power))"
                        : "\(wrap(base, atLeast: Level.power))_\(wrap(script, atLeast: Level.power))",
                    precedence: Level.power)
            }
            return base
        }

        /// The operand of `^` or `_`: a parenthesised expression or one atom.
        private mutating func parseScriptOperand(stop: Stop) throws -> Piece {
            if isSymbol("(") {
                consume()
                let inner = try parseBoolean(stop: Stop())
                try expect(")")
                return Piece(text: inner.text, precedence: inner.precedence)
            }
            if isSymbol("-") || isSymbol("+") {
                let sign = isSymbol("-") ? "-" : ""
                consume()
                let operand = try parseScriptOperand(stop: stop)
                return Piece(text: sign + operand.text, precedence: Level.unary)
            }
            return try parseAtom(stop: stop)
        }

        private mutating func parseAtom(stop: Stop) throws -> Piece {
            guard let token = current else {
                throw ConversionError(reason: "the equation ends unexpectedly")
            }

            switch token.kind {
            case .number(let value):
                consume()
                return .atom(value)

            case .string(let value):
                // Only `cases` uses quoted words ("if", "otherwise"); any other
                // quoted string is text, which has no calculator value.
                throw ConversionError(
                    reason: "the equation contains the text \u{201C}\(value)\u{201D}, which the calculator cannot evaluate")

            case .symbol("("):
                consume()
                let inner = try parseBoolean(stop: Stop())
                try expect(")")
                return .atom("(\(inner.text))")

            case .symbol("{"):
                // Typst renders braces literally; the equation editor and
                // pasted LaTeX use them for grouping.
                consume()
                let inner = try parseBoolean(stop: Stop())
                try expect("}")
                return .atom("(\(inner.text))")

            case .symbol("["):
                consume()
                let items = try parseList(close: "]")
                return .atom("[" + items.joined(separator: ",") + "]")

            case .symbol("|"):
                return try parseAbsolute(closeTokens: 1)

            case .symbol("||"):
                consume()
                let inner = try parseBoolean(stop: Stop())
                guard isSymbol("||") else {
                    throw ConversionError(reason: "the equation has an unbalanced `‖`")
                }
                consume()
                return .atom("norm(\(inner.text))")

            case .symbol("+-"), .symbol("-+"):
                throw ConversionError(
                    reason: "the equation uses ± (plus/minus), which is two values, not one")

            case .symbol(let symbol):
                throw ConversionError(reason: "unexpected `\(symbol)` in the equation")

            case .name(let name):
                return try parseName(name, stop: stop)
            }
        }

        /// `|x|` is an absolute value. `closeTokens` says how many `|` tokens
        /// end it (one for `|…|`, two for `‖…‖`).
        private mutating func parseAbsolute(closeTokens: Int) throws -> Piece {
            for _ in 0..<closeTokens { consume() }
            let inner = try parseBoolean(stop: Stop())
            for _ in 0..<closeTokens {
                guard isSymbol("|") else {
                    throw ConversionError(
                        reason: "the equation has an unmatched `|` — absolute value needs both bars, "
                            + "and conditional notation such as `P(A | B)` has no calculator equivalent")
                }
                consume()
            }
            return .atom(closeTokens == 1 ? "abs(\(inner.text))" : "norm(\(inner.text))")
        }

        // MARK: Names

        private mutating func parseName(_ name: String, stop: Stop) throws -> Piece {
            switch name {
            case "integral", "integral.double", "integral.triple", "integral.cont":
                return try parseIntegral(name: name, stop: stop)
            case "sum", "product":
                return try parseBigOperator(name: name, stop: stop)
            case "lim":
                return try parseLimit(stop: stop)
            case "dif", "Dif":
                return try parseDifferential(stop: stop)
            case "upright", "bold", "italic", "cal", "frak", "bb", "mono", "sans", "serif",
                 "display", "inline", "block", "lr", "stretch", "class", "styled", "script", "op", "text":
                return try parseWrapper(name: name)
            case "hat", "acute", "grave", "tilde", "macron", "breve", "caron", "dot",
                 "dot.double", "dot.triple", "arrow", "arrow.l", "arrow.r", "overline",
                 "underline", "accent":
                throw ConversionError(
                    reason: "the equation uses a Typst accent or decoration (`\(name)`), which the calculator cannot represent")
            case "attach":
                return try parseAttach(stop: stop)
            case "frac", "root", "binom", "binom.binom", "vec", "mat", "matrix", "cases":
                return try parseStructuralCall(name: name)
            default:
                break
            }

            if Self.knownFunctions.contains(name) || name.hasSuffix("'") {
                return try parseFunctionCall(name: name, stop: stop)
            }

            // Bessel letters: `J_1(x)` is what `CASTypstRenderer` prints for
            // `BesselJ(1, x)`, so restore the engine's spelling when the
            // subscripted letter is applied directly.
            if let bessel = Self.besselFunctions[name],
               kind(at: 1) == .symbol("_") {
                var cursor = index + 2
                var orderText: String?
                if cursor + 2 < tokens.count,
                   tokens[cursor].kind == .symbol("("),
                   case .number(let value) = tokens[cursor + 1].kind,
                   tokens[cursor + 2].kind == .symbol(")") {
                    orderText = value
                    cursor += 3
                } else if cursor < tokens.count, case .number(let value) = tokens[cursor].kind {
                    orderText = value
                    cursor += 1
                }
                if let orderText, cursor < tokens.count,
                   tokens[cursor].kind == .symbol("("), !tokens[cursor].spaceBefore {
                    index = cursor + 1
                    let arguments = try parseArguments().positional
                    guard !arguments.isEmpty else {
                        throw ConversionError(reason: "`\(name)` needs an argument")
                    }
                    let rendered = arguments.map(\.text).joined(separator: ", ")
                    return .atom("\(bessel)(\(orderText), \(rendered))")
                }
            }

            // A plain variable or constant.
            consume()
            let mapped = Self.constantNames[name] ?? name

            // A bare Typst symbol variant (`dot.op`, `plus.minus`) only means
            // something between two operands.
            if Self.symbolWords.contains(name) {
                throw ConversionError(
                    reason: "the symbol `\(name)` needs a value on each side")
            }

            // A name directly followed by `(` is function application
            // (`f(x)`), which the CAS keeps symbolic — the visually obvious
            // reading, and what `f(x) = x^2` needs. After a space it is Typst
            // juxtaposition (`x (2)` means x·2).
            if isSymbol("("), current?.spaceBefore == false {
                consume()
                let args = try parseList(close: ")")
                return .atom("\(mapped)(\(args.joined(separator: ", ")))")
            }
            return .atom(mapped)
        }

        /// Typst symbol variants that are operators, never standalone values.
        private static let symbolWords: Set<String> = [
            "plus.minus", "minus.plus", "dot.op", "dot.c", "arrow.r", "arrow.l",
            "arrow.l.r", "dots.h", "dots.v", "dots.c", "times", "div", "mod",
        ]

        private static let constantNames: [String: String] = [
            "oo": "infinity", "infinity": "infinity", "inf": "infinity",
        ]

        private static let knownFunctions: Set<String> = [
            "sin", "cos", "tan", "cot", "sec", "csc",
            "sinh", "cosh", "tanh", "coth", "sech", "csch",
            "arcsin", "arccos", "arctan", "arccot", "arcsec", "arccsc",
            "arcsinh", "arccosh", "arctanh",
            "asin", "acos", "atan", "acot", "asec", "acsc",
            "asinh", "acosh", "atanh",
            "ln", "log", "log10", "log2", "exp", "sqrt", "cbrt", "root",
            "abs", "norm", "floor", "ceil", "ceiling", "round", "trunc",
            "sign", "min", "max", "gcd", "lcm",
            "gamma", "lgamma", "erf", "erfc",
            "factorial", "comb", "binomial",
            "det", "trace", "transpose", "inv", "inverse", "rank", "rref",
            "identity", "diag", "BesselJ", "BesselY", "BesselI", "BesselK",
            "besselJ", "besselY", "besselI", "besselK",
            "re", "im", "conj", "arg", "mean", "median", "stddev", "variance", "sort",
        ]

        private static let inverseFunctions: [String: String] = [
            "sin": "asin", "cos": "acos", "tan": "atan", "cot": "acot",
            "sec": "asec", "csc": "acsc",
            "sinh": "asinh", "cosh": "acosh", "tanh": "atanh",
        ]

        private static let reciprocalFunctions: [String: String] = [
            "sec": "cos", "csc": "sin", "cot": "tan",
            "sech": "cosh", "csch": "sinh", "coth": "tanh",
        ]

        /// Bessel letters, as `CASTypstRenderer` prints them.
        private static let besselFunctions: [String: String] = [
            "J": "BesselJ", "Y": "BesselY", "I": "BesselI", "K": "BesselK",
        ]

        private static let renamedFunctions: [String: String] = [
            "arcsin": "asin", "arccos": "acos", "arctan": "atan",
            "arccot": "acot", "arcsec": "asec", "arccsc": "acsc",
            "arcsinh": "asinh", "arccosh": "acosh", "arctanh": "atanh",
            "ceiling": "ceil", "binomial": "comb",
        ]

        // MARK: Functions

        private mutating func parseFunctionCall(name: String, stop: Stop) throws -> Piece {
            consume()

            var primes = 0
            var baseName = name
            while baseName.hasSuffix("'") {
                primes += 1
                baseName = String(baseName.dropLast())
            }
            if baseName.isEmpty { baseName = name }

            // Scripts before the argument: `sin^2 x`, `log_2 x`.
            var sub: Piece?
            var sup: Piece?
            while let token = current, case .symbol(let symbol) = token.kind, symbol == "_" || symbol == "^" {
                consume()
                let script = try parseScriptOperand(stop: stop)
                if symbol == "_" { sub = script } else { sup = script }
            }

            // Parenthesised argument list.
            if isSymbol("(") {
                consume()
                let arguments = try parseArguments()
                let positional = arguments.positional
                if primes > 0 {
                    guard positional.count == 1 else {
                        throw ConversionError(reason: "prime notation needs exactly one argument")
                    }
                    let order = primes > 1 ? ", \(primes)" : ""
                    return .atom("diff(\(baseName), \(positional[0].text)\(order))")
                }
                return try buildFunction(
                    name: baseName, positional: positional, named: arguments.named,
                    sub: sub, sup: sup)
            }

            if primes > 0 {
                throw ConversionError(reason: "prime notation needs parentheses, as in `f'(x)`")
            }

            // Juxtaposed argument: `sin x`, `sqrt 2`, `ln 2x`, `sin -x`.
            // Typst itself renders `sin xy` without parentheses, which every
            // reader takes as sin(xy); the argument therefore runs over the
            // juxtaposed factors, but stops where another function starts
            // (`sin x cos x` is sin(x)·cos(x)).
            if startsFactor() || isSymbol("-") || isSymbol("+") {
                let argument = try parseArgumentRun(stop: stop)
                return try buildFunction(
                    name: baseName, positional: [argument], named: [:],
                    sub: sub, sup: sup)
            }

            return try buildFunction(name: baseName, positional: [], named: [:], sub: sub, sup: sup)
        }

        private struct Arguments {
            var positional: [Piece] = []
            var named: [String: Piece] = [:]
        }

        private mutating func parseArguments() throws -> Arguments {
            var arguments = Arguments()
            while true {
                if isSymbol(")") {
                    consume()
                    return arguments
                }
                if index >= tokens.count {
                    throw ConversionError(reason: "the equation has an unbalanced `(`")
                }
                if isSymbol(",") || isSymbol(";") {
                    consume()
                    continue
                }
                // `name: value` is a named argument (`mat(delim: "[")`).
                if case .name(let potential)? = kind(), isSymbol(":", at: 1) {
                    consume()
                    consume()
                    arguments.named[potential] = try parseBoolean(stop: Stop())
                    continue
                }
                arguments.positional.append(try parseBoolean(stop: Stop()))
            }
        }

        private mutating func parseList(close: String) throws -> [String] {
            var items: [String] = []
            while !isSymbol(close) {
                if index >= tokens.count {
                    throw ConversionError(reason: "the equation has an unbalanced `\(close)`")
                }
                if isSymbol(",") || isSymbol(";") { consume(); continue }
                items.append(try parseBoolean(stop: Stop()).text)
            }
            consume()
            return items
        }

        private mutating func buildFunction(
            name: String,
            positional: [Piece],
            named: [String: Piece],
            sub: Piece?,
            sup: Piece?
        ) throws -> Piece {
            let argumentTexts = positional.map(\.text)
            let argument = argumentTexts.first

            // Inverse trig is printed as `sin^(-1)(x)` by the CAS renderer and
            // written that way by hand; Giac spells it `asin`.
            if let sup,
               sup.text.replacingOccurrences(of: " ", with: "") == "-1",
               let inverse = Self.inverseFunctions[name],
               let argument {
                return .atom("\(inverse)(\(argument))")
            }

            // Typst's `log` defaults to base 10; Giac's is the natural log.
            if name == "log" {
                if let base = sub ?? named["base"], let argument {
                    return .atom("logb(\(argument), \(base.text))")
                }
                if let argument {
                    return .atom("log10(\(argument))")
                }
            }

            switch name {
            case "frac":
                guard positional.count >= 2 else {
                    throw ConversionError(reason: "`frac` needs a numerator and a denominator")
                }
                // `frac(dif f, dif x)` is the derivative, like `(dif f)/(dif x)`.
                if let numerator = Self.differentialOperand(positional[0].text),
                   let denominator = Self.differentialOperand(positional[1].text) {
                    return Self.derivative(numerator: numerator, denominator: denominator)
                }
                return Piece(
                    text: "\(wrap(positional[0], atLeast: Level.power))/\(wrap(positional[1], atLeast: Level.power))",
                    precedence: Level.multiplicative)

            case "root":
                // Typst: root(index, radicand); `root(x)` is a square root.
                guard let radicand = positional.last else {
                    throw ConversionError(reason: "`root` needs a radicand")
                }
                if positional.count >= 2 {
                    let index = positional[0]
                    return Piece(
                        text: "\(wrap(radicand, atLeast: Level.power))^(1/\(wrap(index, atLeast: Level.power)))",
                        precedence: Level.power)
                }
                return .atom("sqrt(\(radicand.text))")

            case "cbrt":
                guard let radicand = positional.first else {
                    throw ConversionError(reason: "`cbrt` needs an argument")
                }
                return Piece(
                    text: "\(wrap(radicand, atLeast: Level.power))^(1/3)",
                    precedence: Level.power)

            case "binom", "binom.binom":
                guard positional.count >= 2 else {
                    throw ConversionError(reason: "`binom` needs two arguments")
                }
                return .atom("comb(\(positional[0].text), \(positional[1].text))")

            case "vec":
                guard !argumentTexts.isEmpty else {
                    throw ConversionError(reason: "`vec` needs at least one item")
                }
                return .atom("[" + argumentTexts.joined(separator: ",") + "]")

            case "matrix":
                return .atom("[" + argumentTexts.joined(separator: ",") + "]")

            default:
                break
            }

            let callName = Self.renamedFunctions[name] ?? name

            // Reciprocals: Giac has no `sec`, and a quotient is unambiguous.
            if let denominator = Self.reciprocalFunctions[name], let argument {
                return Piece(
                    text: "1/\(denominator)(\(argument))",
                    precedence: Level.multiplicative)
            }

            // A power attached to the function: `sin^2 x` is `(sin(x))^2`.
            if let sup, let argument {
                return Piece(
                    text: "(\(callName)(\(argument)))^\(wrap(sup, atLeast: Level.power))",
                    precedence: Level.power)
            }

            // A subscript on a non-log function (`J_1(x)`) is an order. The
            // four Bessel letters are exactly what CASTypstRenderer prints, so
            // they round-trip back to the engine's spelling.
            if let sub, let argument, name != "log" {
                if let bessel = Self.besselFunctions[name] {
                    return .atom("\(bessel)(\(sub.text), \(argument))")
                }
                return .atom("\(callName)_\(wrap(sub, atLeast: Level.power))(\(argument))")
            }

            guard !argumentTexts.isEmpty else {
                throw ConversionError(reason: "`\(name)` needs an argument")
            }
            return .atom("\(callName)(\(argumentTexts.joined(separator: ", ")))")
        }

        // MARK: Structurally special calls

        private mutating func parseStructuralCall(name: String) throws -> Piece {
            consume()
            guard isSymbol("(") else {
                throw ConversionError(reason: "`\(name)` needs parentheses, as in `\(name)(…)`")
            }
            let inner = try captureGroupTokens()

            switch name {
            case "frac", "root", "binom", "binom.binom", "vec", "matrix":
                let arguments = try splitArguments(inner)
                return try buildFunction(
                    name: name,
                    positional: arguments.map(\.value),
                    named: [:],
                    sub: nil,
                    sup: nil)
            case "mat":
                return try buildMatrix(inner)
            case "cases":
                return try buildCases(inner)
            default:
                throw ConversionError(reason: "the equation uses an unsupported construct `\(name)`")
            }
        }

        private mutating func parseWrapper(name: String) throws -> Piece {
            consume()
            guard isSymbol("(") else {
                throw ConversionError(reason: "`\(name)` needs parentheses")
            }
            let inner = try captureGroupTokens()
            let arguments = try splitArguments(inner)
            // `upright(d)`, `op("d")`, `bold(A)`: keep the content, drop the
            // styling. Named arguments (size:, fill:, weight:) are ignored.
            guard let content = arguments.first(where: { !$0.named }) else {
                throw ConversionError(reason: "`\(name)` is empty")
            }
            let trimmed = content.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                throw ConversionError(reason: "`\(name)` is empty")
            }
            return .atom(trimmed)
        }

        private mutating func parseAttach(stop: Stop) throws -> Piece {
            consume()
            guard isSymbol("(") else {
                throw ConversionError(reason: "`attach` needs parentheses")
            }
            let inner = try captureGroupTokens()
            let arguments = try splitArguments(inner)
            guard let base = arguments.first(where: { !$0.named }) else {
                throw ConversionError(reason: "`attach` needs a base")
            }
            var piece = Piece.atom(base.text)
            for argument in arguments where argument.named {
                switch argument.name {
                case "t", "tr", "tl":
                    piece = Piece(
                        text: "\(wrap(piece, atLeast: Level.power))^\(wrap(.atom(argument.text), atLeast: Level.power))",
                        precedence: Level.power)
                case "b", "br", "bl":
                    piece = Piece(
                        text: "\(wrap(piece, atLeast: Level.power))_\(wrap(.atom(argument.text), atLeast: Level.power))",
                        precedence: Level.power)
                default:
                    break
                }
            }
            return piece
        }

        /// `dif f` / `dif x^2` marks a differential. It only becomes a
        /// calculator expression as a quotient of two of them — that is, a
        /// derivative.
        private mutating func parseDifferential(stop: Stop) throws -> Piece {
            consume()
            var order: Piece?
            if isSymbol("^") {
                consume()
                order = try parseScriptOperand(stop: stop)
            }
            let operand = try parsePower(stop: stop)
            var payload = operand.text
            if let order { payload += "\u{E002}\(order.text)" }
            return .atom(TypstMathToTI.differentialMarker + payload)
        }

        private mutating func parseIntegral(name: String, stop: Stop) throws -> Piece {
            consume()
            let multiplicity: String
            switch name {
            case "integral.double": multiplicity = "2"
            case "integral.triple": multiplicity = "3"
            case "integral.cont": multiplicity = "1"
            default: multiplicity = "1"
            }

            var lower: Piece?
            var upper: Piece?
            while let token = current, case .symbol(let symbol) = token.kind, symbol == "_" || symbol == "^" {
                consume()
                let script = try parseScriptOperand(stop: stop)
                if symbol == "_" { lower = script } else { upper = script }
            }

            // The integrand runs until the differential (`dif x`), and may
            // contain additions: `∫ x + 1 dx` integrates x + 1.
            var bodyStop = stop
            bodyStop.names.insert("dif")
            bodyStop.names.insert("Dif")
            let body = try parseAdditive(stop: bodyStop)

            var variable = "x"
            if isName("dif") || isName("Dif") {
                consume()
                variable = try parseAtom(stop: stop).text
            }

            if (lower == nil) != (upper == nil) {
                throw ConversionError(
                    reason: "a definite integral needs both bounds, as in `integral_0^1`, or none for an antiderivative")
            }
            var arguments = [body.text, variable]
            if let lower, let upper {
                arguments.append(lower.text)
                arguments.append(upper.text)
            }
            if multiplicity != "1" { arguments.append(multiplicity) }
            return .atom("integrate(\(arguments.joined(separator: ", ")))")
        }

        private mutating func parseBigOperator(name: String, stop: Stop) throws -> Piece {
            consume()
            var lower: [Token] = []
            var upper: Piece?
            while let token = current, case .symbol(let symbol) = token.kind, symbol == "_" || symbol == "^" {
                consume()
                if symbol == "_" {
                    if isSymbol("(") {
                        lower = try captureGroupTokens()
                    } else {
                        let script = try parseAtom(stop: stop)
                        lower = [Token(kind: .name(script.text), spaceBefore: false)]
                    }
                } else {
                    upper = try parseScriptOperand(stop: stop)
                }
            }

            let body = try parseMultiplicative(stop: stop)

            // The lower bound is `k = 1`: variable on the left, start on the right.
            var variable = "k"
            var start = "1"
            if let equals = lower.firstIndex(where: { $0.kind == .symbol("=") }) {
                variable = try renderTokens(Array(lower[..<equals]))
                start = try renderTokens(Array(lower[(equals + 1)...]))
            } else if !lower.isEmpty {
                variable = try renderTokens(lower)
            }
            guard !variable.isEmpty else {
                throw ConversionError(reason: "`\(name)` needs a variable, as in `\(name)_(k=1)^n`")
            }

            guard let upper else {
                throw ConversionError(
                    reason: "`\(name)` needs an upper bound, as in `\(name)_(k=1)^n`")
            }
            let arguments = [body.text, variable, start.isEmpty ? "1" : start, upper.text]
            return .atom("\(name)(\(arguments.joined(separator: ", ")))")
        }

        private mutating func parseLimit(stop: Stop) throws -> Piece {
            consume()
            var lower: [Token] = []
            while let token = current, case .symbol(let symbol) = token.kind, symbol == "_" {
                consume()
                if isSymbol("(") {
                    lower = try captureGroupTokens()
                } else {
                    let script = try parseAtom(stop: stop)
                    lower = [Token(kind: .name(script.text), spaceBefore: false)]
                }
            }
            let body = try parseMultiplicative(stop: stop)

            guard let arrow = lower.firstIndex(where: {
                $0.kind == .symbol("->") || $0.kind == .name("arrow.r") || $0.kind == .symbol("→")
            }) else {
                throw ConversionError(reason: "`lim` needs a direction such as `lim_(x -> 0)`")
            }
            let variable = try renderTokens(Array(lower[..<arrow]))
            var targetTokens = Array(lower[(arrow + 1)...])

            // `0^+` / `0^-` is a one-sided limit: Giac's fourth argument.
            var direction: String?
            if targetTokens.count >= 2, targetTokens[targetTokens.count - 2].kind == .symbol("^"),
               case .symbol(let sign)? = targetTokens.last?.kind, sign == "+" || sign == "-" {
                direction = sign == "+" ? "1" : "-1"
                targetTokens.removeLast(2)
            }

            let target = try renderTokens(targetTokens)
            guard !variable.isEmpty, !target.isEmpty else {
                throw ConversionError(reason: "`lim` needs a variable and a target, as in `lim_(x -> 0)`")
            }
            var arguments = [body.text, variable, target]
            if let direction { arguments.append(direction) }
            return .atom("limit(\(arguments.joined(separator: ", ")))")
        }

        // MARK: Token-range helpers

        /// Returns the tokens between a `(` and its matching `)`.
        private mutating func captureGroupTokens() throws -> [Token] {
            guard isSymbol("(") else {
                throw ConversionError(reason: "the equation has an unbalanced `(`")
            }
            consume()
            var depth = 0
            var collected: [Token] = []
            while let token = current {
                if case .symbol(let symbol) = token.kind {
                    if symbol == ")" {
                        if depth == 0 {
                            consume()
                            return collected
                        }
                        depth -= 1
                    }
                    if symbol == "(" { depth += 1 }
                }
                collected.append(token)
                consume()
            }
            throw ConversionError(reason: "the equation has an unbalanced `(`")
        }

        private struct Argument {
            let name: String?
            /// Text plus precedence: a fraction must re-group a compound
            /// numerator (`frac(a + b, c)` is (a+b)/c, not a + b/c).
            let value: Piece
            var text: String { value.text }
            var named: Bool { name != nil }
        }

        private func splitArguments(_ tokens: [Token]) throws -> [Argument] {
            var arguments: [Argument] = []
            var currentTokens: [Token] = []
            var name: String?
            var depth = 0
            var index = 0

            func flush() throws {
                guard !currentTokens.isEmpty else { name = nil; return }
                // A lone quoted string is literal text, which only wrappers
                // (`op("d")`) can use; everything else rejects it in parseAtom.
                if currentTokens.count == 1, case .string(let value) = currentTokens[0].kind {
                    arguments.append(Argument(name: name, value: .atom(value)))
                } else {
                    var parser = Parser(tokens: currentTokens)
                    arguments.append(Argument(name: name, value: try parser.parsePiece()))
                }
                currentTokens = []
                name = nil
            }

            while index < tokens.count {
                let token = tokens[index]
                if case .symbol(let symbol) = token.kind {
                    if symbol == "(" || symbol == "[" || symbol == "{" { depth += 1 }
                    if symbol == ")" || symbol == "]" || symbol == "}" { depth -= 1 }
                    if depth == 0 && (symbol == "," || symbol == ";") {
                        try flush()
                        index += 1
                        continue
                    }
                }
                // A leading `name:` marks a named argument.
                if depth == 0, name == nil, currentTokens.isEmpty,
                   case .name(let potential) = token.kind,
                   index + 1 < tokens.count, tokens[index + 1].kind == .symbol(":") {
                    name = potential
                    index += 2
                    continue
                }
                currentTokens.append(token)
                index += 1
            }
            try flush()
            return arguments
        }

        private func renderTokens(_ tokens: [Token]) throws -> String {
            guard !tokens.isEmpty else { return "" }
            var parser = Parser(tokens: tokens)
            return try parser.parse()
        }

        private func buildMatrix(_ tokens: [Token]) throws -> Piece {
            // Drop named arguments (`delim: "[", augment: #2`) before rows.
            var filtered: [Token] = []
            var index = 0
            var argumentDepth = 0
            while index < tokens.count {
                let token = tokens[index]
                if case .symbol(let symbol) = token.kind {
                    if symbol == "(" || symbol == "[" || symbol == "{" { argumentDepth += 1 }
                    if symbol == ")" || symbol == "]" || symbol == "}" { argumentDepth -= 1 }
                }
                if argumentDepth == 0, case .name(let name) = token.kind,
                   ["delim", "align", "augment", "gap", "column-gap", "row-gap"].contains(name),
                   index + 1 < tokens.count, tokens[index + 1].kind == .symbol(":") {
                    index += 2
                    var valueDepth = 0
                    while index < tokens.count {
                        if case .symbol(let symbol) = tokens[index].kind {
                            if symbol == "(" || symbol == "[" || symbol == "{" { valueDepth += 1 }
                            if symbol == ")" || symbol == "]" || symbol == "}" { valueDepth -= 1 }
                            if valueDepth == 0 && (symbol == "," || symbol == ";") { break }
                        }
                        index += 1
                    }
                    continue
                }
                filtered.append(token)
                index += 1
            }

            var rows: [[String]] = []
            var row: [String] = []
            var currentTokens: [Token] = []
            var cellDepth = 0
            func flushCell() throws {
                guard !currentTokens.isEmpty else { return }
                var parser = Parser(tokens: currentTokens)
                row.append(try parser.parse())
                currentTokens = []
            }
            func flushRow() throws {
                try flushCell()
                if !row.isEmpty { rows.append(row) }
                row = []
            }
            for token in filtered {
                if case .symbol(let symbol) = token.kind {
                    if symbol == "(" || symbol == "[" || symbol == "{" { cellDepth += 1 }
                    if symbol == ")" || symbol == "]" || symbol == "}" { cellDepth -= 1 }
                    if cellDepth == 0 && symbol == "," {
                        try flushCell()
                        continue
                    }
                    if cellDepth == 0 && symbol == ";" {
                        try flushRow()
                        continue
                    }
                }
                currentTokens.append(token)
            }
            try flushRow()
            guard !rows.isEmpty else {
                throw ConversionError(reason: "`mat` needs at least one row")
            }
            let rendered = rows.map { "[" + $0.joined(separator: ",") + "]" }.joined(separator: ",")
            return .atom("[" + rendered + "]")
        }

        private func buildCases(_ tokens: [Token]) throws -> Piece {
            // Split into rows at top-level commas.
            var rows: [[Token]] = []
            var currentRow: [Token] = []
            var depth = 0
            for token in tokens {
                if case .symbol(let symbol) = token.kind {
                    if symbol == "(" || symbol == "[" || symbol == "{" { depth += 1 }
                    if symbol == ")" || symbol == "]" || symbol == "}" { depth -= 1 }
                    if depth == 0 && symbol == "," {
                        rows.append(currentRow)
                        currentRow = []
                        continue
                    }
                }
                currentRow.append(token)
            }
            if !currentRow.isEmpty { rows.append(currentRow) }
            guard !rows.isEmpty else {
                throw ConversionError(reason: "`cases` is empty")
            }

            // Each row is `expression & "if" & condition`.
            struct Branch {
                let expression: String
                let keyword: String
                let condition: String
            }
            var branches: [Branch] = []
            for row in rows {
                var parts: [[Token]] = []
                var currentPart: [Token] = []
                var partDepth = 0
                for token in row {
                    if case .symbol(let symbol) = token.kind {
                        if symbol == "(" || symbol == "[" || symbol == "{" { partDepth += 1 }
                        if symbol == ")" || symbol == "]" || symbol == "}" { partDepth -= 1 }
                        if partDepth == 0 && symbol == "&" {
                            parts.append(currentPart)
                            currentPart = []
                            continue
                        }
                    }
                    currentPart.append(token)
                }
                parts.append(currentPart)

                func text(of part: [Token]) -> String {
                    if part.count == 1, case .string(let value)? = part.first?.kind {
                        return value.lowercased()
                    }
                    return (try? renderTokens(part)) ?? ""
                }
                let expression = text(of: parts[0])
                guard !expression.isEmpty else { continue }

                // The annotation column is `"if" condition` (one `&`) or
                // `"if" & condition` (two `&`). Leading text names the branch
                // keyword; whatever follows it is the condition.
                var annotation: [Token] = []
                if parts.count > 1 {
                    // `x & "if" & cond` puts the keyword in its own column.
                    if parts.count > 2 {
                        annotation = parts[1] + parts[2...].flatMap { $0 }
                    } else {
                        annotation = parts[1]
                    }
                }
                var keyword = ""
                if case .string(let value)? = annotation.first?.kind {
                    keyword = value.lowercased()
                    annotation.removeFirst()
                }
                let condition = keyword.isEmpty ? "" : text(of: annotation)
                branches.append(Branch(
                    expression: expression,
                    keyword: keyword,
                    condition: condition))
            }
            guard !branches.isEmpty else {
                throw ConversionError(reason: "`cases` is empty")
            }

            // Without any `if`/`otherwise` keyword it is a column of values.
            let isPiecewise = branches.contains {
                ["if", "for", "otherwise", "else"].contains($0.keyword)
            }
            if !isPiecewise {
                return .atom("[" + branches.map(\.expression).joined(separator: ",") + "]")
            }

            var arguments: [String] = []
            for branch in branches {
                switch branch.keyword {
                case "if", "for":
                    guard !branch.condition.isEmpty else {
                        throw ConversionError(reason: "`cases` has an `if` without a condition")
                    }
                    arguments.append(branch.condition)
                    arguments.append(branch.expression)
                case "otherwise", "else":
                    arguments.append("true")
                    arguments.append(branch.expression)
                default:
                    arguments.append("true")
                    arguments.append(branch.expression)
                }
            }
            return .atom("piecewise(\(arguments.joined(separator: ", ")))")
        }

        // MARK: Rendering helpers

        private func wrap(_ piece: Piece, atLeast level: Int) -> String {
            piece.precedence < level ? "(\(piece.text))" : piece.text
        }

        private func combine(_ left: Piece, _ right: Piece, division: Bool) throws -> Piece {
            if division {
                // `(dif f)/(dif x)` is the derivative of f with respect to x.
                if let numerator = Self.differentialOperand(left.text),
                   let denominator = Self.differentialOperand(right.text) {
                    return Self.derivative(numerator: numerator, denominator: denominator)
                }
                // A fraction binds its immediate neighbours, so numerator and
                // denominator are grouped: `(a+b)/2` stays a fraction.
                return Piece(
                    text: "\(wrap(left, atLeast: Level.power))/\(wrap(right, atLeast: Level.power))",
                    precedence: Level.multiplicative)
            }
            return Piece(
                text: "\(wrap(left, atLeast: Level.multiplicative))*\(wrap(right, atLeast: Level.multiplicative))",
                precedence: Level.multiplicative)
        }

        /// Extracts `(body, order?)` from a parser-tagged differential,
        /// ignoring the parentheses a fraction may have added.
        private static func differentialOperand(_ text: String) -> (body: String, order: String?)? {
            var candidate = text
            while candidate.hasPrefix("("), candidate.hasSuffix(")"), candidate.count > 2 {
                let inner = String(candidate.dropFirst().dropLast())
                guard Self.isBalanced(inner) else { break }
                candidate = inner
            }
            guard candidate.hasPrefix(TypstMathToTI.differentialMarker) else { return nil }
            let text = candidate
            let payload = String(text.dropFirst(TypstMathToTI.differentialMarker.count))
            let pieces = payload.components(separatedBy: "\u{E002}")
            return (pieces[0], pieces.count > 1 ? pieces[1] : nil)
        }

        private static func isBalanced(_ text: String) -> Bool {
            var depth = 0
            for character in text {
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth < 0 { return false }
                }
            }
            return depth == 0
        }

        private static func derivative(
            numerator: (body: String, order: String?),
            denominator: (body: String, order: String?)
        ) -> Piece {
            // `dif x^(2)` in the denominator carries the derivative order.
            var variable = denominator.body
            var order = denominator.order
            if order == nil, let match = variable.range(of: #"^(.*)\^\(?([0-9]+)\)?$"#, options: .regularExpression) {
                let full = String(variable[match])
                if let caret = full.lastIndex(of: "^") {
                    let base = String(full[..<caret])
                    let exponent = full[full.index(after: caret)...]
                        .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    if !base.isEmpty { variable = base; order = exponent }
                }
            }
            if order == nil { order = numerator.order }
            let arguments = [numerator.body, variable] + (order.map { [$0] } ?? [])
            return .atom("diff(\(arguments.joined(separator: ", ")))")
        }
    }

    // MARK: - Output validation

    private static func validate(_ output: String) throws {
        if output.contains(differentialMarker) {
            throw ConversionError(
                reason: "`dif` only works inside an integral or a derivative, as in `(dif f)/(dif x)`")
        }
        let unsupported: [(token: String, label: String)] = [
            ("&", "an alignment (&)"),
            ("#", "Typst code (#)"),
            ("$", "a math delimiter ($)"),
            ("\\", "a backslash escape"),
            ("{", "a brace"),
            ("}", "a brace"),
            ("±", "a plus/minus sign"),
        ]
        for (token, label) in unsupported where output.contains(token) {
            throw ConversionError(reason: "the equation still contains \(label)")
        }
        if output.contains(";") {
            throw ConversionError(reason: "the equation contains a semicolon")
        }
        let open = output.filter { "([{".contains($0) }.count
        let close = output.filter { ")]}".contains($0) }.count
        guard open == close else {
            throw ConversionError(reason: "the equation has unbalanced brackets")
        }
    }
}
