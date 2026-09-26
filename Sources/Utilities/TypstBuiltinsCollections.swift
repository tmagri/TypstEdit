import Foundation

// MARK: - TypstBuiltinsCollections.swift
// The array / str / dict / content method batteries behind the `recv.m(args)` →
// `type.m(recv, args)` desugaring and the `array.*` / `str.*` / `dictionary.*`
// type scopes. The receiver arrives as positional argument 0, so user arguments
// start at positional index 1.
//
// Mutating methods (push/pop/insert/remove, dict insert/remove) write the modified
// value back to the receiver's root binding, reproducing reference copy-on-write
// semantics for the common `#items.push(x)` case. Bindings reached through nested
// field paths are not written back (best-effort, documented simplification).

// Bridges the registry call sites in TypstBuiltins.typeFunction / .method.
extension TypstBuiltins {
    static func collectionImpl(_ scopeName: String, _ name: String) -> TypstBuiltin? {
        TypstCollectionBuiltins.implementation(for: scopeName, name)
    }
}

enum TypstCollectionBuiltins {
    static func implementation(for scope: String, _ name: String) -> TypstBuiltin? {
        switch scope {
        case "array": return arrayImpl(name)
        case "str": return strImpl(name)
        case "dict", "dictionary": return dictImpl(name)
        case "content": return contentImpl(name)
        default: return nil
        }
    }

    // MARK: Array (reference crates/typst-library/src/foundations/array.rs)

    private static func arrayImpl(_ name: String) -> TypstBuiltin? {
        switch name {
        case "len":
            return { _, args in .int(Int64(try receiverArray(args).count)) }
        case "first":
            return { _, args in
                let items = try receiverArray(args)
                return items.first ?? named(args, "default") ?? .none
            }
        case "last":
            return { _, args in
                let items = try receiverArray(args)
                return items.last ?? named(args, "default") ?? .none
            }
        case "at":
            return { _, args in
                let items = try receiverArray(args)
                let index = try TypstBuiltins.requireInt(positionalArgs(args, 2)[1], "index")
                return element(items, index: index, default: named(args, "default"))
            }
        case "push":
            return { interpreter, args in
                let positional = TypstBuiltins.positionals(args)
                let addition = positional.count > 1 ? positional[1] : .none
                return try mutatedArray(interpreter, args) { items in
                    var copy = items
                    copy.append(addition)
                    return copy
                }
            }
        case "pop":
            return { interpreter, args in
                let items = try receiverArray(args)
                let removed = items.last ?? named(args, "default") ?? .none
                if !items.isEmpty {
                    try writeBack(interpreter, .array(Array(items.dropLast())))
                }
                return removed
            }
        case "insert":
            return { interpreter, args in
                let positional = positionalArgs(args, 3)
                let index = try TypstBuiltins.requireInt(positional[1], "index")
                let value = positional[2]
                return try mutatedArray(interpreter, args) { items in
                    var copy = items
                    let clamped = max(0, min(items.count, Int(index)))
                    copy.insert(value, at: clamped)
                    return copy
                }
            }
        case "remove":
            return { interpreter, args in
                let items = try receiverArray(args)
                let index = try TypstBuiltins.requireInt(positionalArgs(args, 2)[1], "index")
                let resolved = index < 0 ? items.count + Int(index) : Int(index)
                guard resolved >= 0 && resolved < items.count else {
                    return named(args, "default") ?? .none
                }
                var copy = items
                let removed = copy.remove(at: resolved)
                try writeBack(interpreter, .array(copy))
                return removed
            }
        case "slice":
            return { _, args in
                let items = try receiverArray(args)
                let positional = positionalArgs(args, 2)
                let start = Int(try TypstBuiltins.requireInt(positional[1], "start"))
                var end = items.count
                if positional.count > 2, case .int(let e) = positional[2] { end = Int(e) }
                if let count = named(args, "count").flatMap({ try? TypstBuiltins.requireInt($0, "count") }) {
                    end = start + Int(count)
                }
                let lo = max(0, min(items.count, resolve(items.count, start)))
                let hi = max(lo, min(items.count, resolve(items.count, end)))
                return .array(Array(items[lo..<hi]))
            }
        case "contains":
            return { _, args in
                let needle = positionalArgs(args, 2)[1]
                return .bool(try receiverArray(args).contains { $0 == needle })
            }
        case "find":
            return { interpreter, args in
                let searcher = try functionArg(args)
                for item in try receiverArray(args) {
                    if try callBool(interpreter, searcher, item) {
                        return item
                    }
                }
                return named(args, "default") ?? .none
            }
        case "position":
            return { interpreter, args in
                let searcher = try functionArg(args)
                for (index, item) in try receiverArray(args).enumerated() {
                    if try callBool(interpreter, searcher, item) {
                        return .int(Int64(index))
                    }
                }
                return named(args, "default") ?? .none
            }
        case "filter":
            return { interpreter, args in
                let searcher = try functionArg(args)
                var kept: [TypstValue] = []
                for item in try receiverArray(args) {
                    if try callBool(interpreter, searcher, item) {
                        kept.append(item)
                    }
                }
                return .array(kept)
            }
        case "map":
            return { interpreter, args in
                let function = try functionArg(args)
                var mapped: [TypstValue] = []
                for item in try receiverArray(args) {
                    mapped.append(try interpreter.invoke(function, [TypstArg(value: item)]))
                }
                return .array(mapped)
            }
        case "enumerate":
            return { _, args in
                let start = named(args, "start").flatMap { try? TypstBuiltins.requireInt($0, "start") } ?? 0
                var result: [TypstValue] = []
                for (index, item) in try receiverArray(args).enumerated() {
                    result.append(.array([.int(Int64(index) + start), item]))
                }
                return .array(result)
            }
        case "zip":
            return { _, args in
                let items = try receiverArray(args)
                let others = try TypstBuiltins.positionals(args).dropFirst()
                    .map { try TypstBuiltins.toArray($0) }
                let rowCount = ([items.count] + others.map(\.count)).min() ?? 0
                var result: [TypstValue] = []
                for index in 0..<rowCount {
                    result.append(.array([items[index]] + others.map { $0[index] }))
                }
                return .array(result)
            }
        case "fold":
            return { interpreter, args in
                let positional = TypstBuiltins.positionals(args)
                guard positional.count >= 3 else {
                    throw TypstEvalError("fold expects an init value and a function")
                }
                var accumulator = positional[1]
                let function = positional[2]
                for item in try receiverArray(args) {
                    accumulator = try interpreter.invoke(function, [
                        TypstArg(value: accumulator),
                        TypstArg(value: item),
                    ])
                }
                return accumulator
            }
        case "sum":
            return { interpreter, args in
                let items = try receiverArray(args)
                guard var total = items.first else {
                    return named(args, "default") ?? .none
                }
                for item in items.dropFirst() {
                    total = try interpreter.applyBinary(op: .add, lhs: total, rhs: item)
                }
                return total
            }
        case "product":
            return { interpreter, args in
                let items = try receiverArray(args)
                guard var total = items.first else {
                    return named(args, "default") ?? .int(1)
                }
                for item in items.dropFirst() {
                    total = try interpreter.applyBinary(op: .mul, lhs: total, rhs: item)
                }
                return total
            }
        case "any":
            return { interpreter, args in
                let searcher = try functionArg(args)
                for item in try receiverArray(args) {
                    if try callBool(interpreter, searcher, item) { return .bool(true) }
                }
                return .bool(false)
            }
        case "all":
            return { interpreter, args in
                let searcher = try functionArg(args)
                for item in try receiverArray(args) {
                    if !(try callBool(interpreter, searcher, item)) { return .bool(false) }
                }
                return .bool(true)
            }
        case "flatten":
            return { _, args in .array(flatten(try receiverArray(args))) }
        case "rev":
            return { _, args in .array(try receiverArray(args).reversed()) }
        case "join":
            return { interpreter, args in
                let items = try receiverArray(args)
                let positional = TypstBuiltins.positionals(args)
                let separator = positional.count > 1 ? positional[1] : .none
                var accumulated = TypstValue.none
                for (index, item) in items.enumerated() {
                    if index > 0 {
                        var gap = separator
                        if index == items.count - 1, let last = named(args, "last") { gap = last }
                        accumulated = try TypstValue.join(accumulated, gap)
                    }
                    accumulated = try TypstValue.join(accumulated, item)
                }
                return accumulated
            }
        case "sorted":
            return { interpreter, args in
                var sorted = try receiverArray(args)
                switch named(args, "by") ?? .auto {
                case .auto:
                    try sorted.sort { try defaultLess($0, $1) }
                case .function(let comparator):
                    try sorted.sort { lhs, rhs in
                        let verdict = try interpreter.invoke(.function(comparator), [
                            TypstArg(value: lhs),
                            TypstArg(value: rhs),
                        ])
                        switch verdict {
                        case .bool(let less): return less
                        case .int(let order): return order < 0
                        case .float(let order): return order < 0
                        default: return false
                        }
                    }
                default:
                    break
                }
                return .array(sorted)
            }
        case "dedup":
            return { _, args in
                var seen: [TypstValue] = []
                for item in try receiverArray(args) where !seen.contains(item) {
                    seen.append(item)
                }
                return .array(seen)
            }
        default:
            return nil
        }
    }

    // MARK: Str (reference str.rs; pattern-typed methods simplify to literal strings)

    private static func strImpl(_ name: String) -> TypstBuiltin? {
        switch name {
        case "len":
            return { _, args in .int(Int64(try receiverString(args).count)) }
        case "first":
            return { _, args in
                guard let first = try receiverString(args).first else {
                    return named(args, "default") ?? .none
                }
                return .str(String(first))
            }
        case "last":
            return { _, args in
                guard let last = try receiverString(args).last else {
                    return named(args, "default") ?? .none
                }
                return .str(String(last))
            }
        case "at":
            return { _, args in
                let characters = Array(try receiverString(args))
                let index = try TypstBuiltins.requireInt(positionalArgs(args, 2)[1], "index")
                let resolved = index < 0 ? characters.count + Int(index) : Int(index)
                guard resolved >= 0 && resolved < characters.count else {
                    return named(args, "default") ?? .none
                }
                return .str(String(characters[resolved]))
            }
        case "slice":
            return { _, args in
                let characters = Array(try receiverString(args))
                let positional = positionalArgs(args, 2)
                let start = Int(try TypstBuiltins.requireInt(positional[1], "start"))
                var end = characters.count
                if positional.count > 2, case .int(let e) = positional[2] { end = Int(e) }
                if let count = named(args, "count").flatMap({ try? TypstBuiltins.requireInt($0, "count") }) {
                    end = start + Int(count)
                }
                let lo = max(0, min(characters.count, resolve(characters.count, start)))
                let hi = max(lo, min(characters.count, resolve(characters.count, end)))
                return .str(String(characters[lo..<hi]))
            }
        case "clusters":
            return { _, args in .array(try receiverString(args).map { .str(String($0)) }) }
        case "codepoints":
            return { _, args in
                .array(try receiverString(args).unicodeScalars.map { .str(String($0)) })
            }
        case "contains":
            return { _, args in
                let needle = try TypstBuiltins.requireString(positionalArgs(args, 2)[1], "pattern")
                return .bool(try receiverString(args).contains(needle))
            }
        case "starts-with":
            return { _, args in
                let prefix = try TypstBuiltins.requireString(positionalArgs(args, 2)[1], "pattern")
                return .bool(try receiverString(args).hasPrefix(prefix))
            }
        case "ends-with":
            return { _, args in
                let suffix = try TypstBuiltins.requireString(positionalArgs(args, 2)[1], "pattern")
                return .bool(try receiverString(args).hasSuffix(suffix))
            }
        case "find":
            return { _, args in
                let haystack = try receiverString(args)
                let needle = try TypstBuiltins.requireString(positionalArgs(args, 2)[1], "pattern")
                guard let range = haystack.range(of: needle) else { return .none }
                return .str(String(haystack[range]))
            }
        case "position":
            return { _, args in
                let haystack = try receiverString(args)
                let needle = try TypstBuiltins.requireString(positionalArgs(args, 2)[1], "pattern")
                guard let range = haystack.range(of: needle) else { return .none }
                return .int(Int64(haystack.distance(from: haystack.startIndex, to: range.lowerBound)))
            }
        case "replace":
            return { _, args in
                let positional = positionalArgs(args, 3)
                let haystack = try receiverString(args)
                let needle = try TypstBuiltins.requireString(positional[1], "pattern")
                let replacement = try TypstBuiltins.requireString(positional[2], "replacement")
                return .str(haystack.replacingOccurrences(of: needle, with: replacement))
            }
        case "trim":
            // Named variants (at/start/end/repeat) simplify to a both-ends whitespace trim.
            return { _, args in
                .str(try receiverString(args).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case "split":
            // Pattern-typed splitting simplifies to literal patterns; no pattern
            // splits on spaces (lenient extension).
            return { _, args in
                let haystack = try receiverString(args)
                let positional = TypstBuiltins.positionals(args)
                guard positional.count > 1 else {
                    return .array(
                        haystack.split(separator: " ", omittingEmptySubsequences: false)
                            .map { .str(String($0)) }
                    )
                }
                let pattern = try TypstBuiltins.requireString(positional[1], "pattern")
                if pattern.isEmpty {
                    return .array(haystack.map { .str(String($0)) })
                }
                return .array(haystack.components(separatedBy: pattern).map { .str($0) })
            }
        case "rev":
            return { _, args in .str(String(try receiverString(args).reversed())) }
        case "upper":
            return TypstBuiltins.builtinUpper
        case "lower":
            return TypstBuiltins.builtinLower
        default:
            return nil
        }
    }

    // MARK: Dict (reference dictionary.rs)

    private static func dictImpl(_ name: String) -> TypstBuiltin? {
        switch name {
        case "len":
            return { _, args in .int(Int64(try receiverDict(args).count)) }
        case "keys":
            return { _, args in .array(try receiverDict(args).keys().map { .str($0) }) }
        case "values":
            return { _, args in .array(try receiverDict(args).values()) }
        case "pairs":
            return { _, args in .array(try receiverDict(args).pairs) }
        case "at":
            return { _, args in
                let dict = try receiverDict(args)
                let key = try TypstBuiltins.requireString(positionalArgs(args, 2)[1], "key")
                return dict[key] ?? named(args, "default") ?? .none
            }
        case "insert":
            return { interpreter, args in
                let positional = positionalArgs(args, 3)
                let key = try TypstBuiltins.requireString(positional[1], "key")
                let dict = try receiverDict(args)
                var copy = dict
                copy.set(key, positional[2])
                try writeBack(interpreter, .dict(copy))
                return .none
            }
        case "remove":
            return { interpreter, args in
                let key = try TypstBuiltins.requireString(positionalArgs(args, 2)[1], "key")
                let dict = try receiverDict(args)
                let removed = dict[key] ?? named(args, "default") ?? .none
                var copy = dict
                copy.remove(key)
                try writeBack(interpreter, .dict(copy))
                return removed
            }
        case "filter":
            // The predicate receives (key, value) like the reference.
            return { interpreter, args in
                let searcher = try functionArg(args)
                var result = TypstDict()
                for (key, value) in try receiverDict(args).entries {
                    let verdict = try interpreter.invoke(searcher, [
                        TypstArg(value: .str(key)),
                        TypstArg(value: value),
                    ])
                    if verdict.isTruthyForConditions { result.set(key, value) }
                }
                return .dict(result)
            }
        case "map":
            // The function receives (key, value) and replaces the value.
            return { interpreter, args in
                let function = try functionArg(args)
                var result = TypstDict()
                for (key, value) in try receiverDict(args).entries {
                    let mapped = try interpreter.invoke(function, [
                        TypstArg(value: .str(key)),
                        TypstArg(value: value),
                    ])
                    result.set(key, mapped)
                }
                return .dict(result)
            }
        default:
            return nil
        }
    }

    // MARK: Content

    private static func contentImpl(_ name: String) -> TypstBuiltin? {
        switch name {
        case "fields":
            return { _, args in
                guard case .content(.function(_, let functionArgs)) = receiver(args) else {
                    return .dict(TypstDict())
                }
                var dict = TypstDict()
                for (index, arg) in functionArgs.enumerated() {
                    if let name = arg.name {
                        dict.set(name, arg.value)
                    } else {
                        dict.set(String(index), arg.value)
                    }
                }
                return .dict(dict)
            }
        default:
            return nil
        }
    }

    // MARK: Helpers

    /// Positional values (receiver at index 0), padded with none so argument access
    /// never crashes — a missing argument surfaces as a type error downstream.
    private static func positionalArgs(_ args: [TypstArg], _ minCount: Int) -> [TypstValue] {
        let values = TypstBuiltins.positionals(args)
        guard values.count < minCount else { return values }
        return values + Array(repeating: .none, count: minCount - values.count)
    }

    private static func receiver(_ args: [TypstArg]) -> TypstValue {
        TypstBuiltins.positionals(args).first ?? .none
    }

    private static func receiverArray(_ args: [TypstArg]) throws -> [TypstValue] {
        try TypstBuiltins.toArray(receiver(args))
    }

    private static func receiverString(_ args: [TypstArg]) throws -> String {
        try TypstBuiltins.requireString(receiver(args), "string receiver")
    }

    private static func receiverDict(_ args: [TypstArg]) throws -> TypstDict {
        guard case .dict(let dict) = receiver(args) else {
            throw TypstEvalError("expected dictionary, found \(receiver(args).typeName)")
        }
        return dict
    }

    private static func named(_ args: [TypstArg], _ name: String) -> TypstValue? {
        TypstBuiltins.named(args, name)
    }

    /// First positional argument after the receiver: the searcher/mapper function.
    private static func functionArg(_ args: [TypstArg]) throws -> TypstValue {
        let values = TypstBuiltins.positionals(args)
        guard values.count >= 2 else {
            throw TypstEvalError("expected a function argument")
        }
        return values[1]
    }

    private static func callBool(
        _ interpreter: TypstInterpreter,
        _ function: TypstValue,
        _ item: TypstValue
    ) throws -> Bool {
        try interpreter.invoke(function, [TypstArg(value: item)]).isTruthyForConditions
    }

    /// Negative-index resolution shared by slice/at (reference indexing rules).
    private static func resolve(_ count: Int, _ index: Int) -> Int {
        index < 0 ? count + index : index
    }

    private static func defaultLess(_ lhs: TypstValue, _ rhs: TypstValue) throws -> Bool {
        if case .str(let a) = lhs, case .str(let b) = rhs { return a < b }
        if let a = orderNumber(lhs), let b = orderNumber(rhs) { return a < b }
        throw TypstEvalError("cannot order \(lhs.typeName) and \(rhs.typeName)")
    }

    private static func orderNumber(_ value: TypstValue) -> Double? {
        switch value {
        case .int(let i): return Double(i)
        case .float(let f): return f
        case .quantity(let q, _): return q
        default: return nil
        }
    }

    private static func element(_ items: [TypstValue], index: Int64, default defaultValue: TypstValue?) -> TypstValue {
        let resolved = index < 0 ? items.count + Int(index) : Int(index)
        guard resolved >= 0 && resolved < items.count else { return defaultValue ?? .none }
        return items[resolved]
    }

    private static func flatten(_ items: [TypstValue]) -> [TypstValue] {
        var result: [TypstValue] = []
        for item in items {
            if case .array(let nested) = item {
                result.append(contentsOf: flatten(nested))
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// Applies a mutating transform to the receiver array and writes the copy back.
    private static func mutatedArray(
        _ interpreter: TypstInterpreter,
        _ args: [TypstArg],
        _ transform: ([TypstValue]) throws -> [TypstValue]
    ) throws -> TypstValue {
        let mutated = try transform(try receiverArray(args))
        try writeBack(interpreter, .array(mutated))
        // Reference push/insert return none — the mutation is the effect.
        return .none
    }

    /// Writes a mutated receiver back to its root binding. No-op when the receiver
    /// was not a plain bound identifier (expression receivers are value-only).
    private static func writeBack(_ interpreter: TypstInterpreter, _ value: TypstValue) throws {
        guard let rootName = interpreter.methodReceiverStack.last else { return }
        try interpreter.environment.assign(identifier: rootName, value: value)
    }
}
