import Foundation

// MARK: - TypstCodeParser.swift
// Expression/statement parsing for Typst code, plus the shared scanner. Semantics follow
// the reference parser (crates/typst-syntax/src/parser.rs):
//   - precedence: assign(right-assoc) < or < and < comparisons/in < +- < */ < unary +-;
//     unary `not` binds at comparison level; postfix call/field binds tightest
//   - `#expr` in markup is atomic: only *directly attached* postfixes (no space before
//     `(`/`[`/`.`), no binary operators (those need `#{...}`)
//   - keyword forms (`if/for/while/let/...`) allow whitespace/newlines before their
//     `[...]`/`{...}` bodies; `else if` chains
//   - `(x)` is a grouping, `(x,)` a one-element array, `()` an array, `(:)`/`key:` a dict

/// The markup-side tree. The markup parser (TypstToMarkdownConverter.swift) produces
/// these; `.code` nodes carry the raw source of the `#`-region so a failed parse or
/// evaluation can leak the original snippet instead of the whole document failing.
public indirect enum TypstMarkupNode {
    case document([TypstMarkupNode])
    case text(String)
    case heading(level: Int, content: [TypstMarkupNode])
    case bold(content: [TypstMarkupNode])
    case italic(content: [TypstMarkupNode])
    case math(String)
    case code(expr: TypstExpr, rawSource: String)
}

/// Where a statement is being parsed. The app dialect differs from stock Typst in one
/// place: a `{...}` body directly after `if/for/while` in *markup* is markup
/// (`#if enabled { Hello }`), because hybrid .note documents use that shape. In code
/// context braces are code blocks, as in the reference.
public enum TypstBodyContext {
    case markupEmbed
    case code
}

public indirect enum TypstExpr {
    // Literals & composites
    case none
    case auto
    case bool(Bool)
    case int(Int64)
    case float(Double)
    case quantity(Double, String)
    case str(String)
    case array([TypstExpr])
    case dict([(key: String, value: TypstExpr)])
    case spread(TypstExpr)
    case content([TypstMarkupNode])
    case codeBlock([TypstExpr])
    case closure(params: [TypstParam], body: TypstExpr)

    // Access & calls
    case ident(String)
    case fieldAccess(TypstExpr, String)
    case call(callee: TypstExpr, args: [TypstCallArg])

    // Operators
    case binary(TypstBinOp, TypstExpr, TypstExpr)
    case unary(TypstUnOp, TypstExpr)
    case assign(target: TypstExpr, op: TypstBinOp, value: TypstExpr)

    // Keyword statements (also usable as expressions in code position)
    case letStmt(pattern: TypstPattern, value: TypstExpr?)
    case ifStmt(cond: TypstExpr, then: TypstExpr, elseBody: TypstExpr?)
    case forLoop(pattern: TypstPattern, iterable: TypstExpr, body: TypstExpr)
    case whileLoop(cond: TypstExpr, body: TypstExpr)
    case returnStmt(TypstExpr?)
    case breakStmt
    case continueStmt
    case context(TypstExpr)
    case setRule(name: String, args: [TypstCallArg])
    case showRule(String)
    /// Apply-form show rule: `#show: transform` — the transform (usually
    /// `template.with(...)`) receives the rest of the document as its argument.
    case showApply(TypstExpr)
    case importStmt(path: TypstExpr, alias: String?, items: TypstImportItems)
    case includeStmt(path: TypstExpr)
}

public enum TypstImportItems {
    case none
    case wildcard          // : *
    case names([String])   // : a, b
}

public enum TypstBinOp {
    case add, sub, mul, div
    case eq, neq, lt, leq, gt, geq, inOp, notIn
    case and, or
    case assignOp, addAssign, subAssign, mulAssign, divAssign

    var isAssignment: Bool {
        switch self {
        case .assignOp, .addAssign, .subAssign, .mulAssign, .divAssign: return true
        default: return false
        }
    }
}

public enum TypstUnOp {
    case pos, neg, not
}

public enum TypstCallArg {
    case positional(TypstExpr)
    case named(String, TypstExpr)
    case spread(TypstExpr)
}

/// Binding patterns for `let`/`for`: identifiers, `_`, nested parens, `..sink`,
/// dict entries `key: pattern`.
public indirect enum TypstPattern {
    case wildcard
    case ident(String)
    case array([TypstPattern], sink: TypstPattern?)
    case dict([(key: String, pattern: TypstPattern)], sink: TypstPattern?)
}

// MARK: - Scanner

/// Shared cursor over the source. A class so the markup parser and the code parser
/// handed the same region stay in lockstep.
public final class TypstScanner {
    public let input: String
    public var index: String.Index

    public init(_ input: String, index: String.Index? = nil) {
        self.input = input
        self.index = index ?? input.startIndex
    }

    public var isAtEnd: Bool { index >= input.endIndex }

    public func peek(_ offset: Int = 0) -> Character? {
        var cursor = index
        for _ in 0..<max(0, offset) {
            guard cursor < input.endIndex else { return nil }
            cursor = input.index(after: cursor)
        }
        guard cursor < input.endIndex else { return nil }
        return input[cursor]
    }

    @discardableResult
    public func advance() -> Character {
        let character = input[index]
        index = input.index(after: index)
        return character
    }

    public func hasPrefix(_ prefix: String) -> Bool {
        input[index...].hasPrefix(prefix)
    }

    @discardableResult
    public func match(_ prefix: String) -> Bool {
        guard hasPrefix(prefix) else { return false }
        index = input.index(index, offsetBy: prefix.count)
        return true
    }

    public func bookmark() -> String.Index { index }

    public func reset(to mark: String.Index) { index = mark }

    /// Spaces and tabs only (no newlines).
    public func skipSpaces() {
        while let character = peek(), character == " " || character == "\t" {
            _ = advance()
        }
    }

    /// All whitespace plus line (`//`) and block (`/* */`) comments — code-mode skipping.
    public func skipCodeTrivia() {
        while !isAtEnd {
            if let character = peek(), character.isWhitespace {
                _ = advance()
            } else if hasPrefix("//") {
                skipLineComment()
            } else if hasPrefix("/*") {
                _ = advance()
                _ = advance()
                while !isAtEnd, !hasPrefix("*/") { _ = advance() }
                if hasPrefix("*/") { _ = advance(); _ = advance() }
            } else {
                break
            }
        }
    }

    public func skipLineComment() {
        while !isAtEnd, peek() != "\n", peek() != "\r" {
            _ = advance()
        }
    }

    /// True when the character at `index` is `[A-Za-z_]`.
    public var atIdentStart: Bool {
        guard let character = peek() else { return false }
        return character.isLetter || character == "_"
    }

    /// Scans a full identifier: `[A-Za-z_][A-Za-z0-9_-]*`. Hyphens are continue
    /// characters (reference is_id_continue), so `a-b` is one identifier and
    /// subtraction needs spaces — a deliberate Typst quirk we keep.
    public func scanIdent() -> String {
        guard atIdentStart else { return "" }
        var ident = ""
        while let character = peek(),
              character.isLetter || character.isNumber || character == "_" || character == "-" {
            ident.append(character)
            _ = advance()
        }
        return ident
    }

    public var rest: Substring { input[index...] }
}

// MARK: - Parser

public final class TypstCodeParser {
    let scanner: TypstScanner
    /// Parses `[ ... ]` (brackets consumed) into markup nodes — provided by the markup
    /// parser so code can embed content blocks.
    private let parseMarkupBracketBlock: () throws -> [TypstMarkupNode]
    /// Parses `{ ... }` (braces consumed) as MARKUP — the app-dialect body form.
    private let parseMarkupBracedBlock: () throws -> [TypstMarkupNode]

    /// Paren/bracket/brace nesting depth — newline termination of statements only
    /// applies at depth 0.
    private var depth = 0

    public init(
        scanner: TypstScanner,
        parseMarkupBracketBlock: @escaping () throws -> [TypstMarkupNode],
        parseMarkupBracedBlock: @escaping () throws -> [TypstMarkupNode]
    ) {
        self.scanner = scanner
        self.parseMarkupBracketBlock = parseMarkupBracketBlock
        self.parseMarkupBracedBlock = parseMarkupBracedBlock
    }

    // MARK: Entry points from the markup layer

    /// Parses everything after a `#` in markup. Keyword forms become statements whose
    /// bodies are markup; anything else is an atomic expression.
    public func parseHashRegion(context: TypstBodyContext) throws -> TypstExpr {
        scanner.skipSpaces()
        guard scanner.atIdentStart else {
            // `#1`, `#"str"`, `#[...]` etc. — a bare primary expression.
            return try parseExpr(atomic: true, context: context, stopAtBody: false)
        }
        let ident = scanner.scanIdent()

        switch ident {
        case "let": return try parseLetStatement(context: context)
        case "if": return try parseIfStatement(context: context)
        case "for": return try parseForStatement(context: context)
        case "while": return try parseWhileStatement(context: context)
        case "return": return try parseReturnStatement(context: context)
        case "break": consumeStatementTerminator(); return .breakStmt
        case "continue": consumeStatementTerminator(); return .continueStmt
        case "context":
            scanner.skipCodeTrivia()
            let inner = try parseExpr(atomic: false, context: context, stopAtBody: true)
            consumeStatementTerminator()
            return .context(inner)
        case "set": return try parseSetRule()
        case "show": return try parseShowRule()
        case "import": return try parseImportStatement()
        case "include":
            scanner.skipCodeTrivia()
            let path = try parseExpr(atomic: true, context: context, stopAtBody: true)
            consumeStatementTerminator()
            return .includeStmt(path: path)
        default:
            scanner.resetToBefore(ident: ident)
            return try parseExpr(atomic: true, context: context, stopAtBody: false)
        }
    }

    /// Parses a `{ stmt; stmt }` code block (opening brace already consumed is NOT
    /// supported — this consumes both braces).
    public func parseCodeBlock(consumingBrace: Bool) throws -> [TypstExpr] {
        if consumingBrace {
            guard scanner.peek() == "{" else { throw TypstParseError("expected {") }
            _ = scanner.advance()
        }
        depth += 1
        defer { depth -= 1 }

        var statements: [TypstExpr] = []
        while !scanner.isAtEnd {
            scanner.skipCodeTrivia()
            if scanner.peek() == "}" { _ = scanner.advance(); break }
            if scanner.isAtEnd { break }

            let before = scanner.bookmark()
            if let statement = try parseStatement(context: .code) {
                statements.append(statement)
            }
            if scanner.bookmark() == before {
                // Unconsumed stray character inside the block; skip it to make progress.
                _ = scanner.advance()
            }
        }
        return statements
    }

    // MARK: Statements

    /// Parses one statement. Returns nil for an empty statement (`;`).
    private func parseStatement(context: TypstBodyContext) throws -> TypstExpr? {
        scanner.skipCodeTrivia()
        if scanner.peek() == ";" { _ = scanner.advance(); return nil }
        if scanner.peek() == "}" { return nil }

        if scanner.atIdentStart {
            let mark = scanner.bookmark()
            // The keyword ident is consumed here: every keyword handler below
            // expects to start after it (same contract as parseHashRegion).
            let ident = scanner.scanIdent()

            switch ident {
            case "let": return try parseLetStatement(context: context)
            case "if": return try parseIfStatement(context: context)
            case "for": return try parseForStatement(context: context)
            case "while": return try parseWhileStatement(context: context)
            case "return": return try parseReturnStatement(context: context)
            case "break": consumeStatementTerminator(); return .breakStmt
            case "continue": consumeStatementTerminator(); return .continueStmt
            case "context":
                scanner.skipCodeTrivia()
                let inner = try parseExpr(atomic: false, context: context, stopAtBody: false)
                return .context(inner)
            case "set": return try parseSetRule()
            case "show": return try parseShowRule()
            case "import": return try parseImportStatement()
            case "include":
                scanner.skipCodeTrivia()
                let path = try parseExpr(atomic: true, context: context, stopAtBody: false)
                return .includeStmt(path: path)
            default:
                // Plain expression: rewind so parseExpr sees the whole text.
                scanner.reset(to: mark)
            }
        }

        let expression = try parseExpr(atomic: false, context: context, stopAtBody: false, stopsAtNewline: true)
        consumeStatementTerminator()
        return expression
    }

    private func consumeStatementTerminator() {
        // No space skipping: markup after an inline snippet must keep its space
        // (`#3 #x` renders "3 x"). A stray `;` after trivia is picked up by the
        // next parseStatement instead.
        if scanner.peek() == ";" { _ = scanner.advance() }
    }

    // MARK: let

    private func parseLetStatement(context: TypstBodyContext) throws -> TypstExpr {
        let pattern = try parsePattern(allowParens: true)

        // Function sugar: `let f(x, y) = ...` — parameters must be directly attached
        // to a plain identifier pattern.
        var params: [TypstParam]? = nil
        if case .ident(let name) = pattern, !name.isEmpty, scanner.peek() == "(" {
            params = try parseParamList()
        }

        let valueMark = scanner.bookmark()
        scanner.skipSpaces()
        var value: TypstExpr? = nil
        if scanner.match("=") {
            scanner.skipCodeTrivia()
            if scanner.match("=") {
                throw TypstParseError("let binding cannot start with ==")
            }
            value = try parseExpr(atomic: false, context: context, stopAtBody: false, stopsAtNewline: true)
        } else if params != nil {
            throw TypstParseError("expected = after function parameters")
        } else {
            // Binding without a value (`#let x` followed by more markup): give
            // the consumed whitespace back so the following text keeps its spacing.
            scanner.reset(to: valueMark)
        }
        consumeStatementTerminator()

        if let params {
            guard let value else { throw TypstParseError("function binding needs a body") }
            return .letStmt(pattern: pattern, value: .closure(params: params, body: value))
        }
        return .letStmt(pattern: pattern, value: value)
    }

    // MARK: if / for / while / return

    /// Parses `if cond <body> [else (<body> | if ...)]`. `else if` chains nest.
    private func parseIfStatement(context: TypstBodyContext) throws -> TypstExpr {
        scanner.skipCodeTrivia()
        let condition = try parseExpr(atomic: false, context: context, stopAtBody: true)
        let thenBody = try parseBody(context: context)

        var elseBody: TypstExpr? = nil
        let mark = scanner.bookmark()
        scanner.skipSpaces()
        scanner.skipCodeTrivia()
        if scanner.atIdentStart, scanner.rest.hasPrefix("else") {
            _ = scanner.scanIdent()
            scanner.skipCodeTrivia()
            if scanner.atIdentStart, scanner.rest.hasPrefix("if") {
                _ = scanner.scanIdent()
                elseBody = try parseIfStatement(context: context)
            } else {
                elseBody = try parseBody(context: context)
            }
        } else if context == .markupEmbed, scanner.peek() == "[" {
            // App dialect: `#if cond [a] [b]` — a second bracket block stands in for
            // a missing `else` (hybrid .note documents rely on this shape).
            elseBody = try parseBody(context: context)
        } else {
            scanner.reset(to: mark)
        }

        return .ifStmt(cond: condition, then: thenBody, elseBody: elseBody)
    }

    private func parseForStatement(context: TypstBodyContext) throws -> TypstExpr {
        scanner.skipCodeTrivia()
        let pattern = try parsePattern(allowParens: true)
        scanner.skipCodeTrivia()
        guard scanner.atIdentStart, scanner.rest.hasPrefix("in") else {
            throw TypstParseError("expected in after for pattern")
        }
        _ = scanner.scanIdent()
        scanner.skipCodeTrivia()
        let iterable = try parseExpr(atomic: false, context: context, stopAtBody: true)
        let body = try parseBody(context: context)
        return .forLoop(pattern: pattern, iterable: iterable, body: body)
    }

    private func parseWhileStatement(context: TypstBodyContext) throws -> TypstExpr {
        scanner.skipCodeTrivia()
        let condition = try parseExpr(atomic: false, context: context, stopAtBody: true)
        let body = try parseBody(context: context)
        return .whileLoop(cond: condition, body: body)
    }

    private func parseReturnStatement(context: TypstBodyContext) throws -> TypstExpr {
        scanner.skipCodeTrivia()
        // The value is only present if an expression actually starts here.
        if scanner.isAtEnd || peekIsNewline() || scanner.peek() == ";" || scanner.peek() == "}"
            || scanner.peek() == "]" || scanner.peek() == "," {
            return .returnStmt(nil)
        }
        let value = try parseExpr(atomic: false, context: context, stopAtBody: false, stopsAtNewline: true)
        consumeStatementTerminator()
        return .returnStmt(value)
    }

    // MARK: set / show

    private func parseSetRule() throws -> TypstExpr {
        scanner.skipCodeTrivia()
        guard scanner.atIdentStart else { throw TypstParseError("expected target after set") }
        var name = scanner.scanIdent()
        while scanner.peek() == "." {
            _ = scanner.advance()
            name += "." + scanner.scanIdent()
        }
        var args: [TypstCallArg] = []
        scanner.skipSpaces()
        if scanner.peek() == "(" {
            _ = scanner.advance()
            args = try parseArgumentList()
        }
        return .setRule(name: name, args: args)
    }

    private func parseShowRule() throws -> TypstExpr {
        scanner.skipCodeTrivia()
        if scanner.peek() == ":" {
            // Apply form: `#show: document-layout.with(...)` wraps the rest of the
            // document; template functions render their header into the Markdown.
            _ = scanner.advance()
            scanner.skipCodeTrivia()
            let transform = try parseExpr(atomic: true, context: .code, stopAtBody: true)
            consumeStatementTerminator()
            return .showApply(transform)
        }
        // Selector rules have no Markdown meaning; scan the rest of the statement away
        // (balanced across brackets so multi-line rules don't leak).
        var nesting = 0
        while !scanner.isAtEnd {
            let character = scanner.peek()!
            if character == "{" || character == "[" || character == "(" { nesting += 1 }
            if character == "}" || character == "]" || character == ")" {
                if nesting == 0 { break }
                nesting -= 1
            }
            if nesting == 0, peekIsNewline() { break }
            _ = scanner.advance()
        }
        consumeStatementTerminator()
        return .showRule("")
    }

    // MARK: import / include

    private func parseImportStatement() throws -> TypstExpr {
        scanner.skipCodeTrivia()
        let path = try parseExpr(atomic: true, context: .code, stopAtBody: true)

        var alias: String? = nil
        var items: TypstImportItems = .none

        scanner.skipCodeTrivia()
        if scanner.atIdentStart, scanner.rest.hasPrefix("as") {
            _ = scanner.scanIdent()
            scanner.skipCodeTrivia()
            alias = scanner.scanIdent()
            scanner.skipCodeTrivia()
        }
        if scanner.peek() == ":" {
            _ = scanner.advance()
            scanner.skipCodeTrivia()
            if scanner.match("*") {
                items = .wildcard
            } else {
                var names: [String] = []
                while !scanner.isAtEnd {
                    scanner.skipCodeTrivia()
                    let name = scanner.scanIdent()
                    guard !name.isEmpty else { break }
                    names.append(name)
                    scanner.skipCodeTrivia()
                    if scanner.peek() == "," { _ = scanner.advance() } else { break }
                }
                items = .names(names)
            }
        }
        consumeStatementTerminator()
        return .importStmt(path: path, alias: alias, items: items)
    }

    // MARK: Bodies

    /// Parses the `[...]`/`{...}` body after a keyword form. Whitespace/newlines before
    /// the body are allowed (reference conditional/loops do this).
    private func parseBody(context: TypstBodyContext) throws -> TypstExpr {
        scanner.skipCodeTrivia()
        switch scanner.peek() {
        case "[":
            return .content(try parseMarkupBracketBlock())
        case "{":
            if context == .markupEmbed {
                // App dialect: braced bodies in markup are markup.
                return .content(try parseMarkupBracedBlock())
            }
            return .codeBlock(try parseCodeBlock(consumingBrace: true))
        case "(":
            // Parenthesized expression body (`if n <= 1 (1) else (n * fact(n - 1))`).
            return try parseExpr(atomic: false, context: context, stopAtBody: false, stopsAtNewline: true)
        default:
            throw TypstParseError("expected [ or { body")
        }
    }

    // MARK: Patterns & parameters

    /// - Parameter allowParens: true only when the pattern directly follows `let`/`for`
    ///   — a `(` there starts a destructuring pattern. An identifier NOT followed
    ///   directly by `(` keeps its parens for the function-params form (`let f(x) =`).
    private func parsePattern(allowParens: Bool) throws -> TypstPattern {
        scanner.skipCodeTrivia()
        if allowParens && scanner.peek() == "(" {
            return try parseParenPattern()
        }
        guard scanner.atIdentStart else { throw TypstParseError("expected pattern") }
        let name = scanner.scanIdent()
        return name == "_" ? .wildcard : .ident(name)
    }

    private func parseParenPattern() throws -> TypstPattern {
        guard scanner.peek() == "(" else { throw TypstParseError("expected (") }
        _ = scanner.advance()

        var positional: [TypstPattern] = []
        var named: [(key: String, pattern: TypstPattern)] = []
        var sink: TypstPattern? = nil
        var isDict = false

        while true {
            scanner.skipCodeTrivia()
            if scanner.peek() == ")" { _ = scanner.advance(); break }
            if scanner.isAtEnd { throw TypstParseError("unterminated pattern") }

            if scanner.hasPrefix("..") {
                _ = scanner.advance(); _ = scanner.advance()
                scanner.skipCodeTrivia()
                let sinkName = scanner.atIdentStart ? scanner.scanIdent() : ""
                guard sink == nil else { throw TypstParseError("duplicate sink in pattern") }
                sink = .ident(sinkName)
            } else {
                let itemMark = scanner.bookmark()
                let key = scanner.scanIdent()
                scanner.skipSpaces()
                if !key.isEmpty, key != "_", scanner.peek() == ":" {
                    isDict = true
                    _ = scanner.advance()
                    named.append((key, try parsePattern(allowParens: true)))
                } else {
                    scanner.reset(to: itemMark)
                    positional.append(try parsePattern(allowParens: true))
                }
            }

            scanner.skipCodeTrivia()
            if scanner.peek() == "," { _ = scanner.advance() }
        }

        if isDict {
            return .dict(named, sink: sink)
        }
        return .array(positional, sink: sink)
    }

    private func parseParamList() throws -> [TypstParam] {
        guard scanner.peek() == "(" else { throw TypstParseError("expected (") }
        _ = scanner.advance()
        var params: [TypstParam] = []

        while true {
            scanner.skipCodeTrivia()
            if scanner.peek() == ")" { _ = scanner.advance(); break }
            if scanner.isAtEnd { throw TypstParseError("unterminated parameter list") }

            if scanner.hasPrefix("..") {
                _ = scanner.advance(); _ = scanner.advance()
                scanner.skipCodeTrivia()
                let name = scanner.atIdentStart ? scanner.scanIdent() : "args"
                params.append(.spread(name))
            } else {
                let name = scanner.scanIdent()
                guard !name.isEmpty else { throw TypstParseError("expected parameter name") }
                scanner.skipSpaces()
                if scanner.peek() == ":" {
                    _ = scanner.advance()
                    scanner.skipCodeTrivia()
                    let defaultValue = try parseExpr(atomic: false, context: .code, stopAtBody: false)
                    params.append(.withDefault(name, defaultValue))
                } else {
                    params.append(.simple(name))
                }
            }

            scanner.skipCodeTrivia()
            if scanner.peek() == "," { _ = scanner.advance() }
        }
        return params
    }

    // MARK: Expressions (precedence climbing)

    private struct BinaryOpInfo {
        let op: TypstBinOp
        let precedence: Int
        let length: Int
    }

    /// Precedence per the reference ast.rs table. Higher binds tighter.
    private func binaryOp(at position: String.Index) -> BinaryOpInfo? {
        let remaining = scanner.input[position...]
        func identPrefix(_ word: String) -> Bool {
            guard remaining.hasPrefix(word) else { return false }
            if let after = remaining.index(position, offsetBy: word.count, limitedBy: scanner.input.endIndex) {
                let next = scanner.input[after]
                return !(next.isLetter || next.isNumber || next == "_" || next == "-")
            }
            return true
        }

        // Assignment family (right-assoc, lowest).
        for (token, op) in [("=", TypstBinOp.assignOp), ("+=", TypstBinOp.addAssign),
                            ("-=", TypstBinOp.subAssign), ("*=", TypstBinOp.mulAssign),
                            ("/=", TypstBinOp.divAssign)] {
            if remaining.hasPrefix(token) {
                // `=` must not be `==` or `=>`.
                if token == "=" {
                    let after = remaining.index(remaining.startIndex, offsetBy: 1)
                    if after < remaining.endIndex, remaining[after] == "=" || remaining[after] == ">" {
                        continue
                    }
                }
                return BinaryOpInfo(op: op, precedence: 1, length: token.count)
            }
        }
        if identPrefix("or") { return BinaryOpInfo(op: .or, precedence: 2, length: 2) }
        if identPrefix("and") { return BinaryOpInfo(op: .and, precedence: 3, length: 3) }
        if remaining.hasPrefix("==") { return BinaryOpInfo(op: .eq, precedence: 4, length: 2) }
        if remaining.hasPrefix("!=") { return BinaryOpInfo(op: .neq, precedence: 4, length: 2) }
        if remaining.hasPrefix("<=") { return BinaryOpInfo(op: .leq, precedence: 4, length: 2) }
        if remaining.hasPrefix(">=") { return BinaryOpInfo(op: .geq, precedence: 4, length: 2) }
        if remaining.hasPrefix("<") { return BinaryOpInfo(op: .lt, precedence: 4, length: 1) }
        if remaining.hasPrefix(">") { return BinaryOpInfo(op: .gt, precedence: 4, length: 1) }
        if identPrefix("in") { return BinaryOpInfo(op: .inOp, precedence: 4, length: 2) }
        if identPrefix("not"), remaining.count > 3 {
            let afterNot = remaining.index(remaining.startIndex, offsetBy: 3)
            let tail = scanner.input[afterNot...]
            if tail.hasPrefix("in") {
                let afterIn = tail.index(tail.startIndex, offsetBy: 2)
                if afterIn >= tail.endIndex || !(tail[afterIn].isLetter || tail[afterIn].isNumber || tail[afterIn] == "_" || tail[afterIn] == "-") {
                    return BinaryOpInfo(op: .notIn, precedence: 4, length: scanner.input.distance(from: position, to: afterIn))
                }
            }
        }
        if remaining.hasPrefix("+") { return BinaryOpInfo(op: .add, precedence: 5, length: 1) }
        if remaining.hasPrefix("-") { return BinaryOpInfo(op: .sub, precedence: 5, length: 1) }
        if remaining.hasPrefix("*") { return BinaryOpInfo(op: .mul, precedence: 6, length: 1) }
        if remaining.hasPrefix("/") {
            // `//` and `/*` are comments, not division.
            let after = remaining.index(after: remaining.startIndex)
            if after < remaining.endIndex, remaining[after] == "/" || remaining[after] == "*" {
                return nil
            }
            return BinaryOpInfo(op: .div, precedence: 6, length: 1)
        }
        return nil
    }

    /// - Parameters:
    ///   - atomic: `#expr` mode — no binary operators; only directly-attached postfixes.
    ///   - stopAtBody: stop before an unbracketed `[`/`{` (condition/iterable position).
    ///   - stopsAtNewline: end the expression at a newline at depth 0 unless the line
    ///     clearly continues (trailing operator/comma/open bracket).
    private func parseExpr(
        atomic: Bool,
        context: TypstBodyContext,
        stopAtBody: Bool,
        stopsAtNewline: Bool = false
    ) throws -> TypstExpr {
        scanner.skipCodeTrivia()
        var expression = try parsePrimary(context: context, stopAtBody: stopAtBody)
        expression = try parsePostfixLoop(expression: expression, atomic: atomic, stopAtBody: stopAtBody)

        if atomic {
            // `#expr` is one directly-attached expression — no binary operators, no
            // assignment. `#x = 3` renders the value of `x` followed by " = 3" text,
            // like the reference; assignments belong in code blocks (`#{ x = 3 }`).
            return expression
        }

        let result = try continueBinary(
            expression: expression,
            minPrecedence: 1,
            context: context,
            stopAtBody: stopAtBody,
            stopsAtNewline: stopsAtNewline
        )

        // Assignment operators are deliberately left unconsumed by continueBinary;
        // statement position picks them up here so code blocks can rebind
        // (`n = n - 1`, `total += 3`).
        let assignMark = scanner.bookmark()
        scanner.skipSpaces()
        if let info = binaryOp(at: scanner.bookmark()), info.op.isAssignment {
            scanner.index = scanner.input.index(scanner.bookmark(), offsetBy: info.length)
            scanner.skipCodeTrivia()
            let value = try parseExpr(atomic: false, context: context, stopAtBody: stopAtBody, stopsAtNewline: stopsAtNewline)
            return .assign(target: result, op: info.op, value: value)
        }
        scanner.reset(to: assignMark)
        return result
    }

    /// Parses an operand at exactly `minPrecedence`, handling unary operators whose
    /// precedence permits them here (unary `not` = comparison level, unary `+`/`-` = 7).
    private func parseExprPrecedence(
        minPrecedence: Int,
        context: TypstBodyContext,
        stopAtBody: Bool,
        stopsAtNewline: Bool
    ) throws -> TypstExpr {
        scanner.skipCodeTrivia()
        if let (op, precedence) = unaryOp(at: scanner.bookmark()), precedence >= minPrecedence {
            _ = scanner.advance()
            scanner.skipCodeTrivia()
            let operand = try parseExprPrecedence(minPrecedence: precedence, context: context, stopAtBody: stopAtBody, stopsAtNewline: stopsAtNewline)
            var expression = TypstExpr.unary(op, operand)
            expression = try parsePostfixLoop(expression: expression, atomic: false, stopAtBody: stopAtBody)
            return try continueBinary(expression: expression, minPrecedence: precedence + 1, context: context, stopAtBody: stopAtBody, stopsAtNewline: stopsAtNewline)
        }
        var expression = try parsePrimary(context: context, stopAtBody: stopAtBody)
        expression = try parsePostfixLoop(expression: expression, atomic: false, stopAtBody: stopAtBody)
        return try continueBinary(expression: expression, minPrecedence: minPrecedence, context: context, stopAtBody: stopAtBody, stopsAtNewline: stopsAtNewline)
    }

    private func continueBinary(
        expression: TypstExpr,
        minPrecedence: Int,
        context: TypstBodyContext,
        stopAtBody: Bool,
        stopsAtNewline: Bool
    ) throws -> TypstExpr {
        var result = expression
        while true {
            if stopsAtNewline && depth == 0, let current = scanner.peek(), current == "\n" || current == "\r" {
                if !lineContinuesAfterNewline() { break }
            }
            let mark = scanner.bookmark()
            scanner.skipCodeTrivia()
            if stopAtBody, let current = scanner.peek(), current == "[" || current == "{" { break }
            if scanner.isAtEnd { break }
            guard let info = binaryOp(at: scanner.bookmark()), info.precedence >= minPrecedence else {
                scanner.reset(to: mark)
                break
            }
            if info.op.isAssignment {
                scanner.reset(to: mark)
                break
            }
            scanner.index = scanner.input.index(scanner.bookmark(), offsetBy: info.length)
            scanner.skipCodeTrivia()
            let operand = try parseExprPrecedence(minPrecedence: info.precedence + 1, context: context, stopAtBody: stopAtBody, stopsAtNewline: stopsAtNewline)
            result = .binary(info.op, result, operand)
        }
        return result
    }

    private func unaryOp(at position: String.Index) -> (TypstUnOp, Int)? {
        let remaining = scanner.input[position...]
        if remaining.hasPrefix("-") { return (.neg, 7) }
        if remaining.hasPrefix("+") {
            let after = remaining.index(after: remaining.startIndex)
            if after < remaining.endIndex, remaining[after].isNumber { return nil } // `+5` literal handled in primary
            return (.pos, 7)
        }
        if remaining.hasPrefix("not") {
            let after = remaining.index(remaining.startIndex, offsetBy: 3)
            if after >= remaining.endIndex || !(remaining[after].isLetter || remaining[after].isNumber || remaining[after] == "_" || remaining[after] == "-") {
                return (.not, 4)
            }
        }
        return nil
    }

    /// After a newline at statement level, continue the expression only when the line
    /// that just ended ends with an operator/comma/open bracket (trailing continuation).
    private func lineContinuesAfterNewline() -> Bool {
        // Look at the source between the last non-trivia position and the newline.
        let before = scanner.input[..<scanner.index]
        guard let lastSignificant = before.last(where: { !$0.isWhitespace && $0 != ";" }) else {
            return false
        }
        switch lastSignificant {
        case "+", "-", "*", "/", "=", "<", ">", "!", ",", "(", "[", "{", ":", "|", "&":
            return true
        default:
            // Trailing `and`/`or`/`in`/`not` keywords also continue (whitespace-tolerant,
            // word-boundary checked so `for`/`import` don't count).
            let trimmed = before.reversed().drop(while: { $0.isWhitespace || $0 == ";" })
            for keyword in ["and", "or", "in", "not"] {
                let chars = Array(keyword)
                guard trimmed.count >= chars.count else { continue }
                let candidate = String(trimmed.prefix(chars.count).reversed())
                guard candidate == keyword else { continue }
                if let preceding = trimmed.dropFirst(chars.count).first,
                   preceding.isLetter || preceding.isNumber || preceding == "_" || preceding == "-" {
                    continue
                }
                return true
            }
            return false
        }
    }

    private func peekIsNewline() -> Bool {
        guard let character = scanner.peek() else { return false }
        return character == "\n" || character == "\r"
    }

    // MARK: Postfix (calls & field access)

    private func parsePostfixLoop(expression: TypstExpr, atomic: Bool, stopAtBody: Bool) throws -> TypstExpr {
        var result = expression
        while !scanner.isAtEnd {
            switch scanner.peek() {
            case "(":
                // Only directly-attached parentheses call.
                let args = try parseArgumentListParens()
                result = .call(callee: result, args: args)
            case "[":
                if stopAtBody { return result }
                // Directly-attached content block = trailing call argument.
                let content = TypstExpr.content(try parseMarkupBracketBlock())
                if case .call(let callee, var args) = result {
                    args.append(.positional(content))
                    result = .call(callee: callee, args: args)
                } else {
                    result = .call(callee: result, args: [.positional(content)])
                }
            case ".":
                // A dot with no identifier after it (`#ch.` ending a sentence) is
                // markup punctuation, not a field access — leave it to the markup layer.
                let dotMark = scanner.bookmark()
                _ = scanner.advance()
                scanner.skipSpaces()
                let field = scanner.scanIdent()
                guard !field.isEmpty else {
                    scanner.reset(to: dotMark)
                    return result
                }
                result = .fieldAccess(result, field)
            default:
                return result
            }
        }
        return result
    }

    // MARK: Primaries

    private func parsePrimary(context: TypstBodyContext, stopAtBody: Bool) throws -> TypstExpr {
        scanner.skipCodeTrivia()
        guard !scanner.isAtEnd else { throw TypstParseError("unexpected end of input") }

        switch scanner.peek() {
        case "(", "[", "{":
            return try parseBracketPrimary(context: context, stopAtBody: stopAtBody)
        case "\"", "'":
            return .str(try parseStringLiteral())
        default:
            break
        }

        if let character = scanner.peek(), character.isNumber {
            return parseNumberLiteral()
        }

        if scanner.atIdentStart {
            let mark = scanner.bookmark()
            let ident = scanner.scanIdent()

            switch ident {
            case "none": return .none
            case "auto": return .auto
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "if": return try parseIfStatement(context: context)
            case "while": return try parseWhileStatement(context: context)
            case "for": return try parseForStatement(context: context)
            case "context":
                scanner.skipCodeTrivia()
                let inner = try parseExpr(atomic: false, context: context, stopAtBody: stopAtBody)
                return .context(inner)
            default:
                break
            }

            // Single-parameter arrow closure: `x => expr`. Whitespace is only
            // consumed when an arrow actually follows, so `#nope stays` keeps
            // the space between the value and the next word.
            let arrowMark = scanner.bookmark()
            scanner.skipSpaces()
            if scanner.hasPrefix("=>") {
                _ = scanner.advance(); _ = scanner.advance()
                scanner.skipCodeTrivia()
                let body = try parseExpr(atomic: false, context: context, stopAtBody: false)
                return .closure(params: [.simple(ident)], body: body)
            }
            scanner.reset(to: arrowMark)

            _ = mark
            return .ident(ident)
        }

        if let (op, precedence) = unaryOp(at: scanner.bookmark()) {
            _ = scanner.advance()
            scanner.skipCodeTrivia()
            let operand = try parseExprPrecedence(minPrecedence: precedence, context: context, stopAtBody: stopAtBody, stopsAtNewline: false)
            return .unary(op, operand)
        }

        throw TypstParseError("unexpected character '\(String(scanner.peek() ?? "?"))'")
    }

    private func parseBracketPrimary(context: TypstBodyContext, stopAtBody: Bool) throws -> TypstExpr {
        switch scanner.peek() {
        case "[":
            return .content(try parseMarkupBracketBlock())
        case "{":
            return .codeBlock(try parseCodeBlock(consumingBrace: true))
        default:
            break
        }

        // `(` — grouping, array, dict, or parenthesized closure. Disambiguate by
        // scanning ahead for `) =>`.
        if isParenthesizedClosure() {
            let params = try parseParamList()
            scanner.skipSpaces()
            guard scanner.hasPrefix("=>") else { throw TypstParseError("expected =>") }
            _ = scanner.advance(); _ = scanner.advance()
            scanner.skipCodeTrivia()
            let body = try parseExpr(atomic: false, context: context, stopAtBody: false)
            return .closure(params: params, body: body)
        }

        return try parseParenGroup()
    }

    /// Looks ahead past a balanced `(...)` to see whether `=>` follows.
    private func isParenthesizedClosure() -> Bool {
        let mark = scanner.bookmark()
        defer { scanner.reset(to: mark) }

        guard scanner.peek() == "(" else { return false }
        _ = scanner.advance()
        var nesting = 1
        var inString = false
        while !scanner.isAtEnd && nesting > 0 {
            let character = scanner.peek()!
            if inString {
                if character == "\\" { _ = scanner.advance() }
                else if character == "\"" { inString = false }
                _ = scanner.advance()
                continue
            }
            switch character {
            case "\"": inString = true
            case "(", "[", "{": nesting += 1
            case ")", "]", "}": nesting -= 1
            default: break
            }
            _ = scanner.advance()
        }
        scanner.skipSpaces()
        return scanner.hasPrefix("=>")
    }

    /// Parses a `(...)` group, deciding between grouping, array literal, and dict
    /// literal per the reference rules.
    private func parseParenGroup() throws -> TypstExpr {
        guard scanner.peek() == "(" else { throw TypstParseError("expected (") }
        _ = scanner.advance()
        depth += 1
        defer { depth -= 1 }

        // A leading colon forces a dict: `(:)` is the empty dict.
        scanner.skipCodeTrivia()
        var forcedDict = false
        if scanner.peek() == ":" {
            forcedDict = true
            _ = scanner.advance()
        }

        var elements: [TypstExpr] = []
        var entries: [(key: String, value: TypstExpr)] = []
        var sawComma = false
        var sawSpread = false

        while true {
            scanner.skipCodeTrivia()
            if scanner.peek() == ")" { _ = scanner.advance(); break }
            if scanner.isAtEnd { throw TypstParseError("unterminated parentheses") }

            if scanner.hasPrefix("..") {
                _ = scanner.advance(); _ = scanner.advance()
                let spreadExpr = try parseExpr(atomic: false, context: .code, stopAtBody: false)
                elements.append(.spread(spreadExpr))
                sawSpread = true
            } else {
                let itemMark = scanner.bookmark()

                // Dict key: identifier or string followed by `:`.
                if scanner.atIdentStart {
                    let key = scanner.scanIdent()
                    scanner.skipSpaces()
                    if scanner.peek() == ":" {
                        _ = scanner.advance()
                        scanner.skipCodeTrivia()
                        let value = try parseExpr(atomic: false, context: .code, stopAtBody: false)
                        entries.append((key, value))
                    } else {
                        scanner.reset(to: itemMark)
                        elements.append(try parseExpr(atomic: false, context: .code, stopAtBody: false))
                    }
                } else if scanner.peek() == "\"" || scanner.peek() == "'" {
                    let keyMark = try parseStringLiteral()
                    scanner.skipSpaces()
                    if scanner.peek() == ":" {
                        _ = scanner.advance()
                        scanner.skipCodeTrivia()
                        let value = try parseExpr(atomic: false, context: .code, stopAtBody: false)
                        entries.append((keyMark, value))
                    } else {
                        // Not `key:` — a plain string element.
                        scanner.reset(to: itemMark)
                        elements.append(try parseExpr(atomic: false, context: .code, stopAtBody: false))
                    }
                } else {
                    elements.append(try parseExpr(atomic: false, context: .code, stopAtBody: false))
                }
            }

            scanner.skipCodeTrivia()
            if scanner.peek() == "," {
                sawComma = true
                _ = scanner.advance()
            }
        }

        if forcedDict || !entries.isEmpty {
            // Reference: positional items after a key are an error; stay strict so the
            // snippet leaks instead of silently mis-shaping.
            if !elements.isEmpty { throw TypstParseError("cannot mix positional and named dict literal items") }
            return .dict(entries)
        }
        if elements.count == 1, !sawComma, !sawSpread {
            // `(x)` — grouping, not an array.
            return elements[0]
        }
        return .array(elements)
    }

    // MARK: Argument lists

    /// Parses `( ... )` call arguments (opening paren consumed by caller).
    private func parseArgumentList() throws -> [TypstCallArg] {
        depth += 1
        defer { depth -= 1 }

        var args: [TypstCallArg] = []
        while true {
            scanner.skipCodeTrivia()
            if scanner.peek() == ")" { _ = scanner.advance(); break }
            if scanner.isAtEnd { throw TypstParseError("unterminated argument list") }

            if scanner.hasPrefix("..") {
                _ = scanner.advance(); _ = scanner.advance()
                args.append(.spread(try parseExpr(atomic: false, context: .code, stopAtBody: false)))
            } else if scanner.atIdentStart {
                let mark = scanner.bookmark()
                let name = scanner.scanIdent()
                scanner.skipSpaces()
                if scanner.peek() == ":" {
                    _ = scanner.advance()
                    scanner.skipCodeTrivia()
                    args.append(.named(name, try parseExpr(atomic: false, context: .code, stopAtBody: false)))
                } else {
                    scanner.reset(to: mark)
                    args.append(.positional(try parseExpr(atomic: false, context: .code, stopAtBody: false)))
                }
            } else {
                args.append(.positional(try parseExpr(atomic: false, context: .code, stopAtBody: false)))
            }

            scanner.skipCodeTrivia()
            if scanner.peek() == "," { _ = scanner.advance() }
        }
        return args
    }

    private func parseArgumentListParens() throws -> [TypstCallArg] {
        guard scanner.peek() == "(" else { return [] }
        _ = scanner.advance()
        return try parseArgumentList()
    }

    // MARK: Literals

    private func parseStringLiteral() throws -> String {
        guard let quote = scanner.peek(), quote == "\"" || quote == "'" else {
            throw TypstParseError("expected string")
        }
        _ = scanner.advance()
        var result = ""
        while !scanner.isAtEnd {
            let character = scanner.advance()
            if character == quote { return result }
            if character == "\\" {
                guard let escape = scanner.peek() else { break }
                _ = scanner.advance()
                switch escape {
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "'": result.append("'")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    guard scanner.peek() == "{" else { throw TypstParseError("expected { after \\u") }
                    _ = scanner.advance()
                    var hex = ""
                    while let h = scanner.peek(), h != "}" {
                        hex.append(h)
                        _ = scanner.advance()
                    }
                    if scanner.peek() == "}" { _ = scanner.advance() }
                    if let scalar = UInt32(hex, radix: 16), let unicode = Unicode.Scalar(scalar) {
                        result.append(Character(unicode))
                    }
                default:
                    result.append(escape)
                }
                continue
            }
            result.append(character)
        }
        throw TypstParseError("unterminated string")
    }

    private func isValidDigit(_ character: Character, radix: Int) -> Bool {
        switch radix {
        case 16: return character.isHexDigit
        case 8: return ("0"..."7").contains(character)
        case 2: return character == "0" || character == "1"
        default: return character.isNumber
        }
    }

    private func parseNumberLiteral() -> TypstExpr {
        var digits = ""
        while let character = scanner.peek(), character.isNumber || character == "_" {
            if character != "_" { digits.append(character) }
            _ = scanner.advance()
        }

        // 0x / 0o / 0b literals.
        if digits == "0", let marker = scanner.peek(), "xXoObB".contains(marker) {
            let radix: Int
            switch marker {
            case "x", "X": radix = 16
            case "o", "O": radix = 8
            default: radix = 2
            }
            _ = scanner.advance()
            var body = ""
            while let character = scanner.peek(), isValidDigit(character, radix: radix) {
                body.append(character)
                _ = scanner.advance()
            }
            if let value = Int64(body, radix: radix) {
                return .int(value)
            }
            return .int(0)
        }

        var isFloat = false
        var text = digits
        if scanner.peek() == ".", let after = scanner.peek(1), after.isNumber {
            isFloat = true
            text.append(".")
            _ = scanner.advance()
            var fraction = ""
            while let character = scanner.peek(), character.isNumber || character == "_" {
                if character != "_" { fraction.append(character) }
                _ = scanner.advance()
            }
            text.append(fraction)
        }
        if let exponent = scanner.peek(), exponent == "e" || exponent == "E" {
            var lookahead = 1
            if let sign = scanner.peek(1), sign == "+" || sign == "-" { lookahead = 2 }
            if let first = scanner.peek(lookahead), first.isNumber {
                isFloat = true
                text.append("e")
                _ = scanner.advance()
                if let sign = scanner.peek(), sign == "+" || sign == "-" {
                    text.append(sign)
                    _ = scanner.advance()
                }
                var exponentDigits = ""
                while let character = scanner.peek(), character.isNumber {
                    exponentDigits.append(character)
                    _ = scanner.advance()
                }
                text.append(exponentDigits)
            }
        }

        if isFloat, let value = Double(text) {
            return attachQuantity(.float(value))
        }
        if let value = Int64(text) {
            return attachQuantity(.int(value))
        }
        return .int(0)
    }

    /// Consumes a unit suffix (`2cm`, `50%`, `1em`) if present.
    private func attachQuantity(_ value: TypstExpr) -> TypstExpr {
        let units = ["em", "pt", "cm", "mm", "in", "deg", "rad", "fr", "%", "s", "ms", "ns", "d"]
        // Longest match first so "ms" wins over "s".
        for unit in units.sorted(by: { $0.count > $1.count }) {
            if scanner.hasPrefix(unit) {
                // `%` attaches directly; named units must not glue onto an identifier.
                if unit == "%" {
                    _ = scanner.advance()
                    if case .float(let v) = value { return .quantity(v / 100.0, "%") }
                    if case .int(let v) = value { return .quantity(Double(v) / 100.0, "%") }
                } else {
                    let after = scanner.input.index(scanner.index, offsetBy: unit.count, limitedBy: scanner.input.endIndex) ?? scanner.input.endIndex
                    if after < scanner.input.endIndex {
                        let next = scanner.input[after]
                        if next.isLetter || next.isNumber || next == "_" || next == "-" { continue }
                    }
                    for _ in unit { _ = scanner.advance() }
                    if case .float(let v) = value { return .quantity(v, unit) }
                    if case .int(let v) = value { return .quantity(Double(v), unit) }
                }
                break
            }
        }
        return value
    }
}

extension TypstScanner {
    /// Rewinds so that `ident` can be re-scanned (used when an identifier turns out not
    /// to be a keyword).
    func resetToBefore(ident: String) {
        index = input.index(index, offsetBy: -ident.count)
    }
}
