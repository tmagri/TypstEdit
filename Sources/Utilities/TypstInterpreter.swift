import Foundation

// MARK: - TypstInterpreter.swift
// Executes the parsed expression tree: #let bindings, #if/#for/#while with
// break/continue/return, operators, collection literals, #context, #import/#include.
// Flow-event semantics follow the reference (crates/typst-eval/src/flow.rs):
// break/continue are consumed by the nearest loop, return unwinds to the enclosing
// closure; a top-level return stops the document.
//
// Field/method/call dispatch lives in TypstInterpreterCalls.swift; binary/unary
// operator application in TypstInterpreterOps.swift; the builtin battery in
// TypstBuiltins.swift.

/// Control-flow event (reference FlowEvent). `isActive` avoids needing Equatable on
/// the payload-carrying enum.
public enum TypstFlowEvent {
    case none
    case `break`
    case `continue`
    case returned(TypstValue?)

    var isActive: Bool {
        if case .none = self { return false }
        return true
    }
}

public final class TypstInterpreter {
    let environment: TypstEnvironment
    let fileLoader: ((String) -> String?)?
    /// Paths currently being imported up the chain — guards against import cycles.
    let importStack: [String]

    var flow: TypstFlowEvent = .none
    /// Root identifier names of in-flight method receivers (`items` in
    /// `items.push(x)`) so mutating builtins can write the new value back.
    var methodReceiverStack: [String] = []

    /// Call-stack depth cap so runaway recursion can't blow the main-thread stack.
    var callDepth = 0
    static let maxCallDepth = 200
    /// Reference MAX_ITERATIONS for `while` (flow.rs:10).
    static let maxWhileIterations = 10_000

    init(
        environment: TypstEnvironment = TypstEnvironment(),
        fileLoader: ((String) -> String?)? = nil,
        importStack: [String] = []
    ) {
        self.environment = environment
        self.fileLoader = fileLoader
        self.importStack = importStack
    }

    // MARK: Root evaluation

    /// Evaluates a whole markup tree. A failing snippet leaks its raw source and the
    /// document survives; only markup parse failures throw out of `convert`.
    public func evalRoot(_ nodes: [TypstMarkupNode]) -> TypstContent {
        var pieces: [TypstContent] = []
        // Apply-form show rule: everything after `#show: transform` joins into one
        // content value passed to the transform exactly once (reference show-apply).
        var showTransform: TypstValue? = nil
        var wrapped: [TypstContent] = []
        for node in nodes {
            if flow.isActive { break }
            if case .code(let expr, _) = node, case .showApply(let transformExpr) = expr {
                if let value = try? eval(expr: transformExpr), case .function = value {
                    showTransform = value
                }
                continue
            }
            let piece = evalMarkupNodeRecovering(node)
            if showTransform != nil {
                wrapped.append(piece)
            } else {
                pieces.append(piece)
            }
        }
        if let transform = showTransform {
            let body = wrapped.reduce(TypstContent.empty, TypstValue.joinContent)
            do {
                let result = try invoke(transform, [TypstArg(value: .content(body))])
                if case .content(let content) = result {
                    pieces.append(content)
                } else {
                    pieces.append(body)
                }
            } catch {
                // Transform failed: the document content passes through unwrapped.
                pieces.append(body)
            }
        }
        return .sequence(pieces)
    }

    fileprivate func evalMarkupNodeRecovering(_ node: TypstMarkupNode) -> TypstContent {
        switch node {
        case .document(let children):
            return evalRoot(children)
        case .text(let text):
            return .text(text)
        case .heading(let level, let children):
            return .heading(level: level, children: children.map(evalMarkupNodeRecovering))
        case .bold(let children):
            return .bold(children.map(evalMarkupNodeRecovering))
        case .italic(let children):
            return .italic(children.map(evalMarkupNodeRecovering))
        case .math(let source):
            return .math(source)
        case .code(let expr, let rawSource):
            do {
                let value = try eval(expr: expr)
                return value.display()
            } catch {
                // Leak this snippet's raw source; the document survives.
                return .text(rawSource)
            }
        }
    }

    /// Evaluates markup inside a code position (`[...]` content block): snippet errors
    /// propagate so the enclosing snippet-level catch leaks the whole block.
    func evalMarkupStrict(_ nodes: [TypstMarkupNode]) throws -> TypstContent {
        var pieces: [TypstContent] = []
        for node in nodes {
            if flow.isActive { break }
            switch node {
            case .code(let expr, _):
                pieces.append(try eval(expr: expr).display())
            default:
                pieces.append(evalMarkupNodeRecovering(node))
            }
        }
        return .sequence(pieces)
    }

    // MARK: Expression dispatch

    func eval(expr: TypstExpr) throws -> TypstValue {
        switch expr {
        case .none: return .none
        case .auto: return .auto
        case .bool(let value): return .bool(value)
        case .int(let value): return .int(value)
        case .float(let value): return .float(value)
        case .quantity(let value, let unit): return .quantity(value, unit: unit)
        case .str(let value): return .str(value)
        case .array(let elements): return try evalArrayLiteral(elements)
        case .dict(let entries): return try evalDictLiteral(entries)
        case .spread:
            throw TypstEvalError("spread is only valid inside a collection or call")
        case .content(let nodes):
            return .content(try evalMarkupStrict(nodes))
        case .codeBlock(let statements):
            return try evalCodeBlock(statements)
        case .closure(let params, let body):
            return .function(.closure(
                params: params,
                body: body,
                definingScopeDepth: environment.scopeCount - 1
            ))
        case .ident(let name):
            return try evalIdentifier(name)
        case .fieldAccess(let base, let field):
            return try evalFieldAccess(base: base, field: field)
        case .call(let callee, let args):
            return try evalCall(callee: callee, args: args)
        case .binary(let op, let lhs, let rhs):
            return try evalBinary(op: op, lhs: lhs, rhs: rhs)
        case .unary(let op, let operand):
            return try evalUnary(op: op, operand: operand)
        case .assign(let target, let op, let value):
            return try evalAssign(target: target, op: op, value: value)
        case .letStmt(let pattern, let value):
            return try evalLet(pattern: pattern, value: value)
        case .ifStmt(let condition, let thenBody, let elseBody):
            return try evalIf(cond: condition, then: thenBody, elseBody: elseBody)
        case .forLoop(let pattern, let iterable, let body):
            return try evalFor(pattern: pattern, iterable: iterable, body: body)
        case .whileLoop(let condition, let body):
            return try evalWhile(cond: condition, body: body)
        case .returnStmt(let value):
            let resolved = try value.map { try eval(expr: $0) }
            if !flow.isActive { flow = .returned(resolved) }
            return resolved ?? .none
        case .breakStmt:
            if !flow.isActive { flow = .`break` }
            return .none
        case .continueStmt:
            if !flow.isActive { flow = .continue }
            return .none
        case .context(let inner):
            return try eval(expr: inner)
        case .setRule, .showRule:
            // No Markdown meaning; ignored exactly as before the rewrite.
            return .none
        case .showApply(let transform):
            // Only meaningful at the root (evalRoot intercepts it); elsewhere the
            // transform expression is evaluated and discarded.
            return try eval(expr: transform)
        case .importStmt(let path, let alias, let items):
            return try evalImport(path: path, alias: alias, items: items)
        case .includeStmt(let path):
            return try evalInclude(path: path)
        }
    }

    private func evalIdentifier(_ name: String) throws -> TypstValue {
        if let value = environment.lookup(identifier: name) { return value }
        if let builtin = TypstBuiltins.globalFunction(name) { return builtin }
        if TypstBuiltins.droppedNames.contains(name) { return .function(.dropped(name)) }
        // Lenient fallback (unchanged from the old evaluator): unknown identifiers
        // render as their own text rather than failing the document.
        return .str(name)
    }

    // MARK: Literals

    private func evalArrayLiteral(_ elements: [TypstExpr]) throws -> TypstValue {
        var items: [TypstValue] = []
        for element in elements {
            switch element {
            case .spread(let inner):
                let value = try eval(expr: inner)
                guard case .array(let more) = value else {
                    throw TypstEvalError("cannot spread \(value.typeName) into an array")
                }
                items.append(contentsOf: more)
            default:
                items.append(try eval(expr: element))
            }
        }
        return .array(items)
    }

    private func evalDictLiteral(_ entries: [(key: String, value: TypstExpr)]) throws -> TypstValue {
        var dict = TypstDict()
        for (key, valueExpr) in entries {
            if dict[key] != nil {
                throw TypstEvalError("duplicate dict key: \(key)")
            }
            dict.set(key, try eval(expr: valueExpr))
        }
        return .dict(dict)
    }

    private func evalCodeBlock(_ statements: [TypstExpr]) throws -> TypstValue {
        environment.pushScope()
        defer { environment.popScope() }
        var output = TypstValue.none
        for statement in statements {
            if flow.isActive { break }
            let value = try eval(expr: statement)
            output = try TypstValue.join(output, value)
        }
        return output
    }

    // MARK: Bindings

    private func evalLet(pattern: TypstPattern, value: TypstExpr?) throws -> TypstValue {
        let resolved = try value.map { try eval(expr: $0) } ?? .none
        try bindPattern(pattern, resolved)
        return .none
    }

    /// Binds a destructuring pattern against a value (reference binding.rs).
    func bindPattern(_ pattern: TypstPattern, _ value: TypstValue) throws {
        switch pattern {
        case .wildcard:
            break
        case .ident(let name):
            environment.define(identifier: name, value: value)
        case .array(let items, let sink):
            guard case .array(let values) = value else {
                throw TypstEvalError("cannot destructure \(value.typeName) as an array pattern")
            }
            guard values.count >= items.count else {
                throw TypstEvalError("not enough elements to destructure")
            }
            for (index, itemPattern) in items.enumerated() {
                try bindPattern(itemPattern, values[index])
            }
            if let sink {
                let rest = Array(values.dropFirst(items.count))
                environment.define(identifier: sinkName(sink), value: .array(rest))
            }
        case .dict(let entries, let sink):
            guard case .dict(let dict) = value else {
                throw TypstEvalError("cannot destructure \(value.typeName) as a dictionary pattern")
            }
            var consumed: Set<String> = []
            for (key, itemPattern) in entries {
                guard let entry = dict[key] else {
                    throw TypstEvalError("dictionary does not contain key \"\(key)\"")
                }
                consumed.insert(key)
                try bindPattern(itemPattern, entry)
            }
            if let sink {
                var leftover = TypstDict()
                for (key, entry) in dict.entries where !consumed.contains(key) {
                    leftover.set(key, entry)
                }
                environment.define(identifier: sinkName(sink), value: .dict(leftover))
            }
        }
    }

    private func sinkName(_ pattern: TypstPattern) -> String {
        if case .ident(let name) = pattern { return name }
        return "rest"
    }

    // MARK: Control flow

    private func evalIf(cond: TypstExpr, then thenBody: TypstExpr, elseBody: TypstExpr?) throws -> TypstValue {
        let condition = try eval(expr: cond)
        guard let isTrue = truth(of: condition) else {
            throw TypstEvalError("expected boolean, found \(condition.typeName)")
        }
        if isTrue {
            return try evalBodyToValue(thenBody)
        } else if let elseBody {
            return try evalBodyToValue(elseBody)
        }
        return .none
    }

    private func evalFor(pattern: TypstPattern, iterable: TypstExpr, body: TypstExpr) throws -> TypstValue {
        let iterableValue = try eval(expr: iterable)
        let elements = try iterationElements(iterableValue)

        environment.pushScope()
        defer { environment.popScope() }

        var output = TypstValue.none
        for element in elements {
            environment.pushScope()
            try bindPattern(pattern, element)
            let piece = try evalBodyToValue(body)
            output = try TypstValue.join(output, piece)
            environment.popScope()

            switch flow {
            case .`break`:
                flow = .none
                return output
            case .continue:
                flow = .none
                continue
            case .returned:
                return output
            case .none:
                break
            }
        }
        return output
    }

    private func evalWhile(cond: TypstExpr, body: TypstExpr) throws -> TypstValue {
        var output = TypstValue.none
        var iterations = 0
        while true {
            guard iterations < TypstInterpreter.maxWhileIterations else {
                throw TypstEvalError("loop seems to be infinite")
            }
            let condition = try eval(expr: cond)
            guard let go = truth(of: condition) else {
                throw TypstEvalError("expected boolean, found \(condition.typeName)")
            }
            guard go else { break }
            iterations += 1

            environment.pushScope()
            let piece = try evalBodyToValue(body)
            output = try TypstValue.join(output, piece)
            environment.popScope()

            switch flow {
            case .`break`:
                flow = .none
                return output
            case .continue:
                flow = .none
                continue
            case .returned:
                return output
            case .none:
                break
            }
        }
        return output
    }

    /// Condition truth: strictly bool, with the old app-lenient extension of
    /// accepting the strings "true"/"false" (legacy .note documents rely on it).
    func truth(of value: TypstValue) -> Bool? {
        switch value {
        case .bool(let b): return b
        case .str(let s):
            let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed == "true" { return true }
            if trimmed == "false" { return false }
            return nil
        default: return nil
        }
    }

    // MARK: Bodies & iteration elements

    func evalBodyToValue(_ body: TypstExpr) throws -> TypstValue {
        switch body {
        case .content(let nodes):
            return .content(try evalMarkupStrict(nodes))
        case .codeBlock(let statements):
            return try evalCodeBlock(statements)
        default:
            return try eval(expr: body)
        }
    }

    /// What `for` iterates: array → values; dict → insertion-ordered (key, value)
    /// pairs; string → grapheme clusters (reference flow.rs:153-176).
    func iterationElements(_ value: TypstValue) throws -> [TypstValue] {
        switch value {
        case .array(let items):
            return items
        case .dict(let dict):
            return dict.pairs
        case .str(let string):
            // Swift Characters are extended grapheme clusters — matches reference.
            return string.map { .str(String($0)) }
        case .int(let count) where count >= 0:
            return (0..<count).map { .int($0) }
        case .function(let function):
            if case .dropped = function { return [] }
            throw TypstEvalError("cannot loop over \(value.typeName)")
        default:
            throw TypstEvalError("cannot loop over \(value.typeName)")
        }
    }
}
