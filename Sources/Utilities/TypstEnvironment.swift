import Foundation

// MARK: - TypstEnvironment.swift
// Symbol table with a lexical scope stack for the Typst→Markdown interpreter.
// Same public shape as the original (define/lookup/exportVariables), retyped to
// TypstValue, plus rebinding (`x += 1`) for mutable state in loops.

public final class TypstEnvironment {
    private var scopes: [[String: TypstValue]] = [[:]]

    public init() {}

    public func pushScope() { scopes.append([:]) }

    public func popScope() {
        guard scopes.count > 1 else { return }
        scopes.removeLast()
    }

    public func define(identifier: String, value: TypstValue) {
        scopes[scopes.count - 1][identifier] = value
    }

    public func lookup(identifier: String) -> TypstValue? {
        for scope in scopes.reversed() {
            if let value = scope[identifier] { return value }
        }
        return nil
    }

    /// Rebinds through enclosing scopes; errors on unbound names.
    public func assign(identifier: String, value: TypstValue) throws {
        for index in scopes.indices.reversed() {
            if scopes[index][identifier] != nil {
                scopes[index][identifier] = value
                return
            }
        }
        throw TypstEvalError("unknown variable: \(identifier)")
    }

    public func exportVariables() -> [String: TypstValue] {
        var result: [String: TypstValue] = [:]
        for scope in scopes {
            for (key, value) in scope { result[key] = value }
        }
        return result
    }

    public var scopeCount: Int { scopes.count }
}
