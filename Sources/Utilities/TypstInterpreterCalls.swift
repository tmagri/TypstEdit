import Foundation

// MARK: - TypstInterpreterCalls.swift
// Field access, method-call desugaring, argument evaluation, and closure invocation.
// Method calls follow the reference (crates/typst-eval/src/call.rs): `recv.m(args)`
// looks up `m` in the receiver TYPE's function scope and prepends the receiver as
// argument 0. Dict fields are never callable as functions (call.rs:350-354).

extension TypstInterpreter {

    // MARK: Field access

    func evalFieldAccess(base: TypstExpr, field: String) throws -> TypstValue {
        // Type-scoped functions used as values (`#let f = calc.abs`) and type names
        // that are not bound variables (`table.header`, `str.split` as a value).
        if case .ident(let typeName) = base,
           environment.lookup(identifier: typeName) == nil,
           let function = TypstBuiltins.typeFunction(typeName, field) {
            return function
        }
        let baseValue = try eval(expr: base)
        return try fieldOf(baseValue, field)
    }

    private func fieldOf(_ baseValue: TypstValue, _ field: String) throws -> TypstValue {
        switch baseValue {
        case .none:
            // Field access on none chains silently (`counter(page).get().first()`):
            // the drop-set already yields none; every further member stays none
            // instead of leaking the whole enclosing snippet.
            return .none
        case .dict(let dict):
            if let entry = dict[field] { return entry }
            // Not a stored key: fall back to the dictionary method scope so
            // `d.insert(…)`/`d.keys()` resolve through plain field access.
            if let function = TypstBuiltins.typeFunction("dictionary", field) {
                return function
            }
            throw TypstEvalError("dictionary does not contain key \"\(field)\"")
        case .function(let function):
            // Dropped state machinery chains silently: counter(page).update(1) → none.
            if case .dropped = function { return baseValue }
            // Function method scope: `f.with(...)` partial application.
            if let with = TypstBuiltins.typeFunction("function", field) {
                return with
            }
            throw TypstEvalError("cannot access field \"\(field)\" of \(baseValue.typeName)")
        default:
            if let function = TypstBuiltins.typeFunction(baseValue.typeName, field) {
                return function
            }
            throw TypstEvalError("cannot access field \"\(field)\" of \(baseValue.typeName)")
        }
    }

    // MARK: Calls

    func evalCall(callee: TypstExpr, args: [TypstCallArg]) throws -> TypstValue {
        // Type-scoped function CALL: `table.header(...)`, `calc.abs(...)`, where the
        // base name is a type, not a bound variable.
        if case .fieldAccess(let base, let field) = callee,
           case .ident(let typeName) = base,
           environment.lookup(identifier: typeName) == nil,
           let function = TypstBuiltins.typeFunction(typeName, field) {
            return try invoke(function, try evaluatedArgs(args))
        }

        let calleeValue = try eval(expr: callee)
        let evaluated = try evaluatedArgs(args)

        // A call on an unbound plain identifier (`#link(...)`, `#table(...)`, unknown
        // `#fn(...)`) becomes a content function node so the renderer can dispatch
        // known names natively and leak the rest as visible `#fn(args)` source.
        if case .ident(let name) = callee,
           environment.lookup(identifier: name) == nil,
           TypstBuiltins.globalFunction(name) == nil,
           !TypstBuiltins.droppedNames.contains(name) {
            return .content(.function(name: name, args: evaluated))
        }

        // Method desugaring: `items.len()` ≡ `array.len(items)`.
        if case .fieldAccess(let base, let field) = callee {
            let receiver = try eval(expr: base)
            if case .function(.dropped) = receiver { return .none }
            if case .none = receiver { return .none }
            if let method = TypstBuiltins.method(for: receiver.typeName, name: field) {
                let callArguments = [TypstArg(value: receiver)] + evaluated
                // Mutating builtins (push/insert/remove/…) write the modified value
                // back to the root binding; expose the receiver's name for the call.
                guard case .ident(let name) = base, environment.lookup(identifier: name) != nil else {
                    return try invoke(method, callArguments)
                }
                methodReceiverStack.append(name)
                defer { methodReceiverStack.removeLast() }
                return try invoke(method, callArguments)
            }
            // Non-method field followed by a call: dicts forbid calling their fields
            // (reference behavior); everything else errors in invoke().
        }

        return try invoke(calleeValue, evaluated)
    }

    func evaluatedArgs(_ args: [TypstCallArg]) throws -> [TypstArg] {
        var result: [TypstArg] = []
        for arg in args {
            switch arg {
            case .positional(let expr):
                result.append(TypstArg(value: try eval(expr: expr)))
            case .named(let name, let expr):
                result.append(TypstArg(name: name, value: try eval(expr: expr)))
            case .spread(let expr):
                let value = try eval(expr: expr)
                switch value {
                case .array(let items):
                    result.append(contentsOf: items.map { TypstArg(value: $0) })
                case .dict(let dict):
                    result.append(contentsOf: dict.entries.map { TypstArg(name: $0.key, value: $0.value) })
                default:
                    throw TypstEvalError("cannot spread \(value.typeName) into arguments")
                }
            }
        }
        return result
    }

    /// Applies a callee value to evaluated arguments. Content functions and unknown
    /// names survive as content nodes for the Markdown renderer.
    func invoke(_ calleeValue: TypstValue, _ args: [TypstArg]) throws -> TypstValue {
        switch calleeValue {
        case .function(.builtin(_, let impl)):
            return try runDepthCapped { try impl(self, args) }
        case .function(.dropped):
            return .none
        case .function(.content(let name)):
            return .content(.function(name: name, args: args))
        case .function(.closure(let params, let body, let definingScopeDepth)):
            return try runDepthCapped {
                try self.invokeClosure(params: params, body: body, definingScopeDepth: definingScopeDepth, args: args)
            }
        case .function(.partial(let base, let bound)):
            // Partial application: bound arguments lead the next call's arguments.
            return try runDepthCapped { try self.invoke(base, bound + args) }
        case .content(.function(let name, _)):
            // Re-invoking a stored content function keeps its name but takes the new args.
            return .content(.function(name: name, args: args))
        case .none:
            // Calling none stays silent — dropped state machinery chains
            // (`counter(page).get()` → none → `.first()`) must not leak.
            return .none
        default:
            throw TypstEvalError("cannot call a value of type \(calleeValue.typeName)")
        }
    }

    private func runDepthCapped<R>(_ body: () throws -> R) throws -> R {
        callDepth += 1
        defer { callDepth -= 1 }
        guard callDepth <= TypstInterpreter.maxCallDepth else {
            throw TypstEvalError("maximum call depth exceeded")
        }
        return try body()
    }

    // MARK: Closures

    /// Binds parameters (positional, named, defaults, spread) and runs the body with a
    /// lexical scope fence: scopes newer than the definition site are invisible.
    private func invokeClosure(
        params: [TypstParam],
        body: TypstExpr,
        definingScopeDepth: Int,
        args: [TypstArg]
    ) throws -> TypstValue {
        let savedFlow = flow
        flow = .none
        defer { flow = savedFlow }

        let savedCount = environment.scopeCount
        // Drop scopes created after definition (never above the global scope).
        while environment.scopeCount > max(1, definingScopeDepth + 1) {
            environment.popScope()
        }
        defer {
            while environment.scopeCount < savedCount { environment.pushScope() }
        }

        environment.pushScope()
        defer { environment.popScope() }

        var positionals = args.filter { $0.name == nil }
        let named = args.filter { $0.name != nil }
        var usedNamed: Set<String> = []

        // Positional arguments bind to positional (default-less) parameters in
        // declaration order; named-default parameters (`title: none`) are only
        // reachable by name or their default (reference call.rs), so
        // `#let f(date: none, body)` called as `#f(x)` fills `body`.
        for param in params {
            switch param {
            case .simple(let name):
                if let first = positionals.first {
                    positionals.removeFirst()
                    environment.define(identifier: name, value: first.value)
                } else if let namedArg = named.first(where: { $0.name == name }) {
                    usedNamed.insert(name)
                    environment.define(identifier: name, value: namedArg.value)
                } else {
                    flow = savedFlow
                    throw TypstEvalError("missing argument: \(name)")
                }
            case .spread(let name):
                environment.define(identifier: name, value: .array(positionals.map(\.value)))
                positionals.removeAll()
            case .withDefault:
                break
            }
        }
        for param in params {
            guard case .withDefault(let name, let defaultExpr) = param else { continue }
            if let namedArg = named.first(where: { $0.name == name }) {
                usedNamed.insert(name)
                environment.define(identifier: name, value: namedArg.value)
            } else {
                environment.define(identifier: name, value: try eval(expr: defaultExpr))
            }
        }

        if !positionals.isEmpty {
            throw TypstEvalError("too many arguments")
        }

        let result = try evalBodyToValue(body)
        if case .returned(let value) = flow {
            return value ?? .none
        }
        return result
    }

    // MARK: Assignment

    /// `x = v`, `x += v`, and dict field writes (`d.a = v`: mutate a copy, write the
    /// root binding back).
    func evalAssign(target: TypstExpr, op: TypstBinOp, value: TypstExpr) throws -> TypstValue {
        let newValue = try eval(expr: value)
        guard op.isAssignment else {
            throw TypstEvalError("invalid assignment operator")
        }

        func augmented(_ op: TypstBinOp, _ current: TypstValue, _ addition: TypstValue) throws -> TypstValue {
            if op == .assignOp { return addition }
            return try applyBinary(op: augmentedForm(op), lhs: current, rhs: addition)
        }

        switch target {
        case .ident(let name):
            if op == .assignOp {
                // Rebind in place: current scope if bound there, else outward.
                try environment.assign(identifier: name, value: newValue)
            } else {
                guard let current = environment.lookup(identifier: name) else {
                    throw TypstEvalError("unknown variable: \(name)")
                }
                try environment.assign(identifier: name, value: try augmented(op, current, newValue))
            }
        case .fieldAccess(let base, let field):
            guard case .ident(let rootName) = base else {
                throw TypstEvalError("cannot assign to a nested field expression")
            }
            guard let root = environment.lookup(identifier: rootName), case .dict(var dict) = root else {
                throw TypstEvalError("cannot assign to field of a non-dictionary")
            }
            let current = dict[field] ?? .none
            dict.set(field, try augmented(op, current, newValue))
            try environment.assign(identifier: rootName, value: .dict(dict))
        default:
            throw TypstEvalError("cannot assign to this expression")
        }
        // Assignment is a statement in Typst; it produces none, not the value.
        return .none
    }

    private func augmentedForm(_ op: TypstBinOp) -> TypstBinOp {
        switch op {
        case .addAssign: return .add
        case .subAssign: return .sub
        case .mulAssign: return .mul
        case .divAssign: return .div
        default: return op
        }
    }
}
