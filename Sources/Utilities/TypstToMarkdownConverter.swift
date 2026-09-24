import Foundation

/// The public entry point used by the app and tests.
public struct TypstToMarkdownConverter {
    public var fileLoader: ((String) -> String?)?

    public init(fileLoader: ((String) -> String?)? = nil) {
        self.fileLoader = fileLoader
    }

    public static func convert(_ source: String, isAlreadyMarkdown: Bool = false, fileLoader: ((String) -> String?)? = nil) -> String {
        if isAlreadyMarkdown {
            return source
        }

        do {
            let compiler = TypstASTCompiler(fileLoader: fileLoader)
            return try compiler.compile(source: source)
        } catch {
            return source
        }
    }

    public func convert(source: String) throws -> String {
        let compiler = TypstASTCompiler(fileLoader: fileLoader)
        return try compiler.compile(source: source)
    }
}

/// Errors that can occur during the parsing phase.
public enum ParserError: Error {
    case expectedEquals
    case expectedValue
}

/// Errors that can occur during the evaluation/compilation phase.
public enum CompilerError: Error {
    case undefinedVariable(String)
    case unimplemented(String)
}

/// Represents the raw syntax tree produced by the parser.
/// Includes structural markup and programming logic like #let, variable access, and calls.
public indirect enum TypstAST {
    case document([TypstAST])
    case text(String)
    case heading(level: Int, content: [TypstAST])
    case bold(content: [TypstAST])
    case italic(content: [TypstAST])
    case letBinding(identifier: String, value: TypstAST)
    case setRule(identifier: String, args: [TypstAST])
    case variableAccess(identifier: String)
    case boolLiteral(Bool)
    case functionCall(name: String, args: [TypstAST])
    case contentBlock([TypstAST])
    case ifStmt(condition: TypstAST, thenBranch: [TypstAST], elseBranch: [TypstAST]?)
    case math(String)

    // Advanced scripting nodes
    case importStmt(String)
    case showRule(String)
    case codeBlock(String)
}

/// Represents the evaluated syntax tree after all #let and variable substitutions are resolved.
public indirect enum ResolvedDocumentAST {
    case document([ResolvedDocumentAST])
    case text(String)
    case heading(level: Int, content: [ResolvedDocumentAST])
    case bold(content: [ResolvedDocumentAST])
    case italic(content: [ResolvedDocumentAST])
    case functionCall(name: String, args: [ResolvedDocumentAST])
    case contentBlock([ResolvedDocumentAST])
    case math(String)
}

/// Lexes and parses a Typst source string into a TypstAST.
internal final class TypstParser {
    private let input: String
    private var currentIndex: String.Index

    init(input: String) {
        self.input = input
        self.currentIndex = input.startIndex
    }

    private var isAtEnd: Bool {
        currentIndex >= input.endIndex
    }

    private func peek() -> Character? {
        guard !isAtEnd else { return nil }
        return input[currentIndex]
    }

    private func advance() -> Character {
        let character = input[currentIndex]
        currentIndex = input.index(after: currentIndex)
        return character
    }

    private func match(_ prefix: String) -> Bool {
        guard input[currentIndex...].hasPrefix(prefix) else { return false }
        currentIndex = input.index(currentIndex, offsetBy: prefix.count)
        return true
    }

    private func skipWhitespace() {
        while !isAtEnd {
            if let character = peek(), character.isWhitespace {
                _ = advance()
            } else if match("//") {
                // Consume line comments entirely so they don't break parsing
                while !isAtEnd, peek() != "\n" {
                    _ = advance()
                }
            } else {
                break
            }
        }
    }

    func parse() throws -> TypstAST {
        var nodes: [TypstAST] = []
        while !isAtEnd {
            if isAtEnd { break }
            
            let startIndex = currentIndex
            if let node = try parseNext() {
                nodes.append(node)
            }
            
            // Prevent infinite loop if stopping characters (e.g., ], }, )) are left unconsumed
            if currentIndex == startIndex {
                nodes.append(.text(String(advance())))
            }
        }
        return .document(nodes)
    }

    private func parseNext() throws -> TypstAST? {
        guard let character = peek() else { return nil }

        if character == "\\" {
            _ = advance() // Consume backslash
            if !isAtEnd { return .text(String(advance())) }
            return .text("\\")
        } else if character == "`" {
            return try parseCode()
        } else if character == "#" {
            return try parseHashExpression()
        } else if character == "=" {
            return try parseHeading()
        } else if character == "*" {
            return try parseBold()
        } else if character == "$" {
            return try parseMath()
        } else {
            return try parseText()
        }
    }

    private func parseHashExpression() throws -> TypstAST {
        _ = advance()

        if match("import") || match("include") {
            var stmt = ""
            var nesting = 0
            while !isAtEnd {
                guard let current = peek() else { break }
                if (current == "\n" || current == "\r") && nesting == 0 { break }
                if current == "(" || current == "[" || current == "{" { nesting += 1 }
                if current == ")" || current == "]" || current == "}" { nesting = max(0, nesting - 1) }
                stmt.append(advance())
            }
            return .importStmt(stmt.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if match("show") {
            var stmt = ""
            var nesting = 0
            while !isAtEnd {
                guard let current = peek() else { break }
                if (current == "\n" || current == "\r") && nesting == 0 { break }
                if current == "(" || current == "[" || current == "{" { nesting += 1 }
                if current == ")" || current == "]" || current == "}" { nesting = max(0, nesting - 1) }
                stmt.append(advance())
            }
            return .showRule(stmt.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if match("if") {
            let condition = try parseConditionExpression()
            let thenBranch = try parseBranch()
            skipWhitespace()

            var elseBranch: [TypstAST]? = nil
            if match("else") {
                skipWhitespace()
                if match("if") {
                    let nestedIf = try parseHashExpression()
                    elseBranch = [nestedIf]
                } else {
                    elseBranch = try parseBranch()
                }
            }

            return .ifStmt(condition: condition, thenBranch: thenBranch, elseBranch: elseBranch)
        }

        if match("let") {
            skipWhitespace()
            let identifier = parseIdentifier()
            skipWhitespace()

            if peek() == "(" {
                var nesting = 0
                while !isAtEnd {
                    let current = advance()
                    if current == "(" { nesting += 1 }
                    else if current == ")" {
                        nesting -= 1
                        if nesting == 0 { break }
                    }
                }
            }

            skipWhitespace()
            guard match("=") else {
                throw ParserError.expectedEquals
            }

            skipWhitespace()

            if peek() == "{" {
                var block = ""
                var nesting = 0
                while !isAtEnd {
                    let current = advance()
                    block.append(current)
                    if current == "{" { nesting += 1 }
                    else if current == "}" {
                        nesting -= 1
                        if nesting == 0 { break }
                    }
                }
                return .letBinding(identifier: identifier, value: .codeBlock(block))
            }

            if peek() == "[" {
                let content = try parseBranch()
                return .letBinding(identifier: identifier, value: .contentBlock(content))
            }

            guard let valueNode = try parseNext() else {
                throw ParserError.expectedValue
            }

            return .letBinding(identifier: identifier, value: valueNode)
        }

        if match("set") {
            skipWhitespace()
            let identifier = parseIdentifier()
            skipWhitespace()

            var args: [TypstAST] = []
            if match("(") {
                args = try parseArguments()
                skipWhitespace()
                if peek() == ")" { _ = advance() }
            }
            return .setRule(identifier: identifier, args: args)
        }

        let identifier = parseIdentifier()
        skipWhitespace()

        guard match("(") else {
            if identifier == "true" { return .boolLiteral(true) }
            if identifier == "false" { return .boolLiteral(false) }
            return .variableAccess(identifier: identifier)
        }

        let args = try parseArguments()
        skipWhitespace()
        if peek() == ")" {
            _ = advance()
        }

        skipWhitespace()
        var finalArgs = args
        if peek() == "[" {
            let trailingContent = try parseArgument()
            finalArgs.append(trailingContent)
        }

        return .functionCall(name: identifier, args: finalArgs)
    }

    private func parseConditionExpression() throws -> TypstAST {
        skipWhitespace()
        var condition = ""
        var nesting = 0
        var inString = false

        while let current = peek() {
            if inString {
                condition.append(advance())
                if current == "\"" { inString = false }
                continue
            }

            if current == "\"" {
                inString = true
                condition.append(advance())
                continue
            }

            if current == "(" || current == "[" || current == "{" {
                nesting += 1
                condition.append(advance())
                continue
            }

            if current == ")" || current == "]" || current == "}" {
                if nesting > 0 {
                    nesting -= 1
                    condition.append(advance())
                    continue
                }
                break
            }

            if nesting == 0 && (current == "{" || current == "[") {
                break
            }

            if nesting == 0 && current.isWhitespace {
                let remaining = String(input[currentIndex...]).trimmingCharacters(in: .whitespaces)
                if remaining.hasPrefix("{") || remaining.hasPrefix("[") {
                    break
                }
            }
            condition.append(advance())
        }

        let trimmed = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "true" { return .boolLiteral(true) }
        if trimmed == "false" { return .boolLiteral(false) }
        return .variableAccess(identifier: trimmed)
    }
    
    private func parseBranch() throws -> [TypstAST] {
        skipWhitespace()
        if peek() == "{" {
            return try parseBracedBlock()
        } else if peek() == "[" {
            _ = advance() // consume '['
            var content = ""
            var nesting = 0
            
            while let character = peek() {
                if character == "[" {
                    nesting += 1
                    content.append(advance())
                } else if character == "]" {
                    if nesting == 0 {
                        _ = advance()
                        break
                    }
                    nesting -= 1
                    content.append(advance())
                } else {
                    content.append(advance())
                }
            }
            
            let innerParser = TypstParser(input: content)
            let ast = try innerParser.parse()
            if case .document(let children) = ast {
                return children
            }
            return [ast]
        }
        
        let startIndex = currentIndex
        if let node = try parseNext() {
            return [node]
        }
        if currentIndex == startIndex {
            _ = advance()
        }
        return []
    }

    private func parseBracedBlock() throws -> [TypstAST] {
        skipWhitespace()
        guard peek() == "{" else { return [] }
        _ = advance()

        var nodes: [TypstAST] = []
        while !isAtEnd {
            skipWhitespace()
            if peek() == "}" {
                _ = advance()
                break
            }
            
            let startIndex = currentIndex
            if let node = try parseNext() {
                nodes.append(node)
            }
            
            // Prevent infinite loop if stopping characters (e.g., ], }, )) are left unconsumed
            if currentIndex == startIndex {
                nodes.append(.text(String(advance())))
            }
        }
        return nodes
    }

    private func parseArguments() throws -> [TypstAST] {
        var args: [TypstAST] = []
        skipWhitespace()

        while !isAtEnd {
            if peek() == ")" {
                break
            }

            let argument = try parseArgument()
            
            // Allow structural arguments (like content blocks) OR non-empty text strings
            switch argument {
            case .text(let value):
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    args.append(argument)
                }
            default:
                args.append(argument)
            }

            skipWhitespace()
            if peek() == "," {
                _ = advance()
                skipWhitespace()
                continue
            }

            if peek() == ")" {
                break
            }
        }

        return args
    }

    private func parseArgument() throws -> TypstAST {
        skipWhitespace()
        
        if peek() == "[" {
            _ = advance() // consume '['
            var content = ""
            var nesting = 0
            
            while let character = peek() {
                if character == "[" {
                    nesting += 1
                    content.append(advance())
                } else if character == "]" {
                    if nesting == 0 {
                        _ = advance()
                        break
                    }
                    nesting -= 1
                    content.append(advance())
                } else {
                    content.append(advance())
                }
            }
            
            let innerParser = TypstParser(input: content)
            let ast = try innerParser.parse()
            if case .document(let children) = ast {
                return .contentBlock(children)
            }
            return .contentBlock([ast])
        }

        var content = ""
        var nesting = 0
        var inString = false

        while let character = peek() {
            if inString {
                content.append(advance())
                if character == "\"" {
                    inString = false
                }
                continue
            }

            switch character {
            case "\"":
                inString = true
                content.append(advance())
            case "(", "{":
                nesting += 1
                content.append(advance())
            case "[": // In case of a stray nested bracket during string capture
                nesting += 1
                content.append(advance())
            case ")", "}", "]":
                if nesting > 0 {
                    nesting -= 1
                    content.append(advance())
                } else {
                    return .text(content.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            case ",":
                if nesting == 0 {
                    return .text(content.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                content.append(advance())
            default:
                content.append(advance())
            }
        }

        return .text(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parseHeading() throws -> TypstAST {
        var level = 0
        while peek() == "=" {
            _ = advance()
            level += 1
        }

        // Only skip spaces and tabs, preserving newlines
        while let character = peek(), character == " " || character == "\t" {
            _ = advance()
        }

        var content: [TypstAST] = []
        while !isAtEnd, peek() != "\n", peek() != "\r" {
            if peek() == "#" {
                content.append(try parseHashExpression())
            } else if peek() == "*" {
                content.append(try parseBold())
            } else {
                var text = ""
                while let character = peek(), character != "\n", character != "\r", character != "#", character != "*" {
                    if input[currentIndex...].hasPrefix("//") {
                        while !isAtEnd, peek() != "\n" { _ = advance() }
                        break
                    }
                    text.append(advance())
                }
                if !text.isEmpty {
                    content.append(.text(text))
                }
            }
        }

        if peek() == "\r" { _ = advance() }
        if peek() == "\n" { _ = advance() }

        return .heading(level: level, content: content)
    }

    private func parseBold() throws -> TypstAST {
        _ = advance()

        var content: [TypstAST] = []
        while !isAtEnd, peek() != "*" {
            if peek() == "#" {
                content.append(try parseHashExpression())
            } else {
                var text = ""
                while let character = peek(), character != "*", character != "#" {
                    if input[currentIndex...].hasPrefix("//") {
                        while !isAtEnd, peek() != "\n" { _ = advance() }
                        continue
                    }
                    text.append(advance())
                }
                if !text.isEmpty {
                    content.append(.text(text))
                }
            }
        }

        if peek() == "*" {
            _ = advance()
        }

        return .bold(content: content)
    }

    private func parseCode() throws -> TypstAST {
        var content = String(advance())
        let isBlock = input[currentIndex...].hasPrefix("``")
        
        if isBlock {
            content.append(advance())
            content.append(advance())
        }

        while !isAtEnd {
            let current = advance()
            content.append(current)

            if current == "`" {
                if isBlock {
                    if input[currentIndex...].hasPrefix("``") {
                        content.append(advance())
                        content.append(advance())
                        break
                    }
                } else {
                    break
                }
            }
        }
        // Markdown natively understands backticks, so we just return it as pure text!
        return .text(content)
    }

    private func parseMath() throws -> TypstAST {    var content = String(advance()) // consume first '$'
        let isDisplay = peek() == "$"
        if isDisplay {
            content.append(advance()) // consume second '$'
        }

        while !isAtEnd {
            let current = advance()
            content.append(current)

            if current == "$" {
                if isDisplay {
                    if peek() == "$" {
                        content.append(advance())
                        break
                    }
                } else {
                    break
                }
            }
        }
        return .math(content)
    }

    private func parseText() throws -> TypstAST {
        var text = ""

        if peek() == "\"" {
            _ = advance()
            while let character = peek(), character != "\"" {
                text.append(advance())
            }
            if peek() == "\"" {
                _ = advance()
            }
            return .text(text)
        }

        while let character = peek(),
              character != "#",
              character != "=",
              character != "*",
              character != "$",
              character != "}",
              character != "]",
              character != ")" {
            
            // Consume line comments natively so they aren't parsed as text
            if input[currentIndex...].hasPrefix("//") {
                while !isAtEnd, peek() != "\n" {
                    _ = advance()
                }
                continue
            }
            
            text.append(advance())
        }

        return .text(text)
    }

    private func parseIdentifier() -> String {
        var identifier = ""
        // Allow dots in identifiers to support module/dictionary-style variable names like troy.note or troy.typ
        while let character = peek(), character.isLetter || character.isNumber || character == "_" || character == "-" || character == "." {
            identifier.append(advance())
        }
        return identifier
    }
}

/// Acts as the symbol table for variable scoping.
public final class TypstEnvironment {
    private var scopes: [[String: ResolvedDocumentAST]] = [[:]]

    public init() {}

    public func pushScope() {
        scopes.append([:])
    }

    public func popScope() {
        guard scopes.count > 1 else {
            fatalError("Cannot pop the global scope.")
        }
        scopes.removeLast()
    }

    public func define(identifier: String, value: ResolvedDocumentAST) {
        scopes[scopes.count - 1][identifier] = value
    }

    public func lookup(identifier: String) -> ResolvedDocumentAST? {
        for scope in scopes.reversed() {
            if let value = scope[identifier] {
                return value
            }
        }
        return nil
    }

    public func exportVariables() -> [String: ResolvedDocumentAST] {
        var result = [String: ResolvedDocumentAST]()
        for scope in scopes {
            for (key, value) in scope {
                result[key] = value
            }
        }
        return result
    }
}

/// Traverses the raw TypstAST, executes logic, and produces a resolved document tree.
public final class Evaluator {
    private let environment: TypstEnvironment
    private let fileLoader: ((String) -> String?)?

    public init(environment: TypstEnvironment, fileLoader: ((String) -> String?)? = nil) {
        self.environment = environment
        self.fileLoader = fileLoader
    }

    public func evaluate(node: TypstAST) throws -> ResolvedDocumentAST? {
        switch node {
        case .document(let children):
            var resolvedChildren: [ResolvedDocumentAST] = []
            for child in children {
                if let resolved = try? evaluate(node: child) {
                    resolvedChildren.append(resolved)
                }
            }
            return .document(resolvedChildren)

        case .text(let content):
            return .text(content)

        case .heading(let level, let content):
            let resolvedContent = content.compactMap { try? evaluate(node: $0) }.compactMap { $0 }
            return .heading(level: level, content: resolvedContent)

        case .bold(let content):
            let resolvedContent = content.compactMap { try? evaluate(node: $0) }.compactMap { $0 }
            return .bold(content: resolvedContent)

        case .italic(let content):
            let resolvedContent = content.compactMap { try? evaluate(node: $0) }.compactMap { $0 }
            return .italic(content: resolvedContent)

        case .letBinding(let identifier, let valueAST):
            guard let resolvedValue = try evaluate(node: valueAST) else {
                return nil
            }
            environment.define(identifier: identifier, value: resolvedValue)
            return nil

        case .boolLiteral(let value):
            return .text(value ? "true" : "false")

        case .setRule:
            // Markdown has no page/text settings, safely ignore
            return nil

        case .importStmt(let stmt):
            let tokens = stmt.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
            guard !tokens.isEmpty else { return nil }
            
            let filename = tokens[0].replacingOccurrences(of: "\"", with: "")
            let alias = (tokens.count >= 3 && tokens[1] == "as") ? tokens[2] : nil
            
            if let loader = self.fileLoader, let content = loader(filename) {
                let subParser = TypstParser(input: content)
                if let subAst = try? subParser.parse() {
                    let subEnv = TypstEnvironment()
                    let subEvaluator = Evaluator(environment: subEnv, fileLoader: loader)
                    _ = try? subEvaluator.evaluate(node: subAst)
                    
                    let exported = subEnv.exportVariables()
                    
                    if let a = alias {
                        for (k, v) in exported {
                            environment.define(identifier: "\(a).\(k)", value: v)
                        }
                    } else {
                        for (k, v) in exported {
                            environment.define(identifier: k, value: v)
                        }
                    }
                }
            }
            return nil

        case .showRule, .codeBlock:
            // Advanced scripting concepts safely ignored in Markdown translation
            return nil

        case .ifStmt(let condition, let thenBranch, let elseBranch):
            let conditionValue = try evaluate(node: condition)
            let isTrue: Bool

            switch conditionValue {
            case .some(.text(let text)):
                isTrue = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
            case .some(.functionCall(let name, _)):
                isTrue = name == "true"
            case .some(.document(let children)):
                isTrue = !children.isEmpty
            default:
                isTrue = false
            }

            let selectedBranch = isTrue ? thenBranch : (elseBranch ?? [])
            var resolved: [ResolvedDocumentAST] = []
            for child in selectedBranch {
                if let value = try evaluate(node: child) {
                    resolved.append(value)
                }
            }
            return .document(resolved)

        case .math(let equation):
            return .math(equation)

        case .contentBlock(let content):
            let resolvedContent = content.compactMap { try? evaluate(node: $0) }.compactMap { $0 }
            return .contentBlock(resolvedContent)

        case .variableAccess(let identifier):
            guard let resolvedValue = environment.lookup(identifier: identifier) else {
                // Graceful fallback: Treat unknown variables natively as plain text instead of crashing!
                return .text(identifier)
            }
            return resolvedValue

        case .functionCall(let name, let args):
            let resolvedArgs = args.compactMap { try? evaluate(node: $0) }.compactMap { $0 }
            return .functionCall(name: name, args: resolvedArgs)
        }
    }
}

/// Blindly serializes a resolved AST into Markdown, translating known Typst functions natively.
public final class MarkdownRenderer {
    public init() {}

    public func render(node: ResolvedDocumentAST) -> String {
        switch node {
        case .document(let children):
            return children.map { render(node: $0) }.joined()

        case .text(let content):
            return content

        case .heading(let level, let content):
            let prefix = String(repeating: "#", count: level)
            let renderedContent = content.map { render(node: $0) }.joined()
            return "\(prefix) \(renderedContent)\n"

        case .bold(let content):
            let renderedContent = content.map { render(node: $0) }.joined()
            return "**\(renderedContent)**"

        case .italic(let content):
            let renderedContent = content.map { render(node: $0) }.joined()
            return "*\(renderedContent)*"
            
        case .math(let equation):
            return equation

        case .contentBlock(let content):
            return content.map { render(node: $0) }.joined()

        case .functionCall(let name, let args):
            switch name {
            case "table", "grid":
                return renderTable(args: args)
            case "v":
                return "\n\n"
            case "pagebreak", "line":
                return "\n---\n\n"
            case "outline":
                return "\n[TOC]\n\n"
            case "link":
                guard !args.isEmpty else { return "" }
                var url = render(node: args[0]).replacingOccurrences(of: "\"", with: "")
                if args.count > 1 {
                    let label = render(node: args[1])
                    return "[\(label)](\(url))"
                }
                return "<\(url)>"
            case "image":
                return renderImage(args: args)
            case "align", "text", "box", "block", "pad", "rect", "stack", "center", "quote":
                // For formatting wrappers, we just extract their inner text content payloads
                let contentArgs = args.filter {
                    if case .contentBlock = $0 { return true }
                    return false
                }
                if !contentArgs.isEmpty {
                    return contentArgs.map { render(node: $0) }.joined()
                }
                // Fallback: exclude args that look like key-value configurations
                let positionalArgs = args.filter {
                    if case .text(let t) = $0, t.contains(":") { return false }
                    return true
                }
                return positionalArgs.map { render(node: $0) }.joined(separator: " ")
            default:
                let renderedArgs = args.map { render(node: $0) }.joined(separator: ", ")
                return "#\(name)(\(renderedArgs))"
            }
        }
    }
    
    private func renderTable(args: [ResolvedDocumentAST]) -> String {
        var columnCount = 1
        var cells: [ResolvedDocumentAST] = []
        
        for arg in args {
            switch arg {
            case .text(let str):
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                let noSpaces = trimmed.replacingOccurrences(of: " ", with: "")
                
                if noSpaces.hasPrefix("columns:") {
                    if trimmed.contains("(") {
                        columnCount = trimmed.filter { $0 == "," }.count + 1
                    } else {
                        let valStr = noSpaces.replacingOccurrences(of: "columns:", with: "")
                        if let num = Int(valStr) {
                            columnCount = num
                        }
                    }
                } else if noSpaces.contains(":") && !trimmed.hasPrefix("\"") && !trimmed.hasPrefix("'") {
                    continue
                } else {
                    cells.append(arg)
                }
            default:
                cells.append(arg)
            }
        }
        
        guard !cells.isEmpty else { return "" }
        
        var markdown = ""
        var row: [String] = []
        var isHeader = true
        
        for (index, cellAST) in cells.enumerated() {
            var cellStr = render(node: cellAST)
            cellStr = cellStr.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            row.append(cellStr)
            
            if row.count == columnCount || index == cells.count - 1 {
                while row.count < columnCount {
                    row.append("")
                }
                
                markdown += "| " + row.joined(separator: " | ") + " |\n"
                
                if isHeader {
                    let separator = Array(repeating: "---", count: columnCount).joined(separator: " | ")
                    markdown += "| " + separator + " |\n"
                    isHeader = false
                }
                
                row = []
            }
        }
        
        return markdown + "\n"
    }

    private func renderImage(args: [ResolvedDocumentAST]) -> String {
        var imagePath = ""
        for arg in args {
            if case .text(let str) = arg {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("\"") {
                    imagePath = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    break
                }
            }
        }
        return "![image](\(imagePath))\n\n"
    }
}

/// Compiler pipeline: parser -> evaluator -> renderer.
public final class TypstASTCompiler {
    private let environment: TypstEnvironment
    private let fileLoader: ((String) -> String?)?

    public init(environment: TypstEnvironment = TypstEnvironment(), fileLoader: ((String) -> String?)? = nil) {
        self.environment = environment
        self.fileLoader = fileLoader
    }

    public func compile(source: String) throws -> String {
        let parser = TypstParser(input: source)
        let ast = try parser.parse()
        return try compile(ast: ast)
    }

    public func compile(ast: TypstAST) throws -> String {
        let evaluator = Evaluator(environment: environment, fileLoader: fileLoader)
        let resolved = try evaluator.evaluate(node: ast)
        let renderer = MarkdownRenderer()
        return renderer.render(node: resolved ?? .document([]))
    }
}