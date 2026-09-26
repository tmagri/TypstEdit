import Foundation

// MARK: - TypstValue.swift
// The runtime value model for the Typst→Markdown interpreter. Mirrors the semantics of
// the reference compiler (/typst-main crates/typst-library/src/foundations/value.rs):
// display() is what placing a value into markup produces; repr() is the code form.
// This file holds no evaluation logic.

/// Insertion-ordered dictionary with Typst dict semantics (reference dict.rs uses an
/// IndexMap; iteration order is insertion order, never sorted).
public struct TypstDict {
    public private(set) var entries: [(key: String, value: TypstValue)] = []

    public init() {}
    public init(_ entries: [(key: String, value: TypstValue)]) {
        for (key, value) in entries { self.set(key, value) }
    }

    public subscript(key: String) -> TypstValue? {
        get { entries.first(where: { $0.key == key })?.value }
        set {
            if let newValue {
                set(key, newValue)
            } else {
                remove(key)
            }
        }
    }

    public mutating func set(_ key: String, _ value: TypstValue) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].value = value
        } else {
            entries.append((key, value))
        }
    }

    @discardableResult
    public mutating func remove(_ key: String) -> TypstValue? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        return entries.remove(at: index).value
    }

    public func keys() -> [String] { entries.map(\.key) }
    public func values() -> [TypstValue] { entries.map(\.value) }
    public var pairs: [TypstValue] {
        entries.map { .array([.str($0.key), $0.value]) }
    }
    public var count: Int { entries.count }
}

/// A parameter in a closure/function parameter list.
public enum TypstParam {
    case simple(String)
    case withDefault(String, TypstExpr)
    case spread(String)   // ..rest (name is required in Typst parameter lists)

    var name: String? {
        switch self {
        case .simple(let name), .withDefault(let name, _), .spread(let name): return name
        }
    }
}

/// A callable value. Closures carry the scope-stack depth at their definition site so
/// lookups are fenced lexically (and recursion works, since the binding exists by the
/// time the body runs).
public enum TypstFunction {
    case closure(params: [TypstParam], body: TypstExpr, definingScopeDepth: Int)
    case builtin(name: String, impl: (TypstInterpreter, [TypstArg]) throws -> TypstValue)
    /// Content-level functions (table, link, image, … and unknown names) survive to the
    /// MarkdownRenderer instead of being executed here.
    case content(String)
    /// State/layout machinery that has no Markdown meaning (counter, state, query, …).
    /// Any call or field access on it yields itself/none so chained uses stay silent.
    case dropped(String)
    /// `f.with(...)` partial application: bound arguments prepend to the next
    /// call's arguments (`document-layout.with(title: …)` + body content).
    case partial(TypstValue, [TypstArg])
}

/// A single call argument. `name == nil` → positional. Spreads are expanded before the
/// callee sees the argument list.
public struct TypstArg {
    public let name: String?
    public let value: TypstValue

    public init(name: String? = nil, value: TypstValue) {
        self.name = name
        self.value = value
    }
}

/// The runtime value kind. Numbers use Int64 (reference i64); `/` promotes to float.
public indirect enum TypstValue {
    case none
    case auto
    case bool(Bool)
    case int(Int64)
    case float(Double)
    /// Unit-suffixed quantities (`2cm`, `1em`, `50%`) — kept so unit arguments don't
    /// explode into parse leaks; no arithmetic support (leaks if used numerically).
    case quantity(Double, unit: String)
    /// A calendar date-time (`datetime.today()`). Carries the date so
    /// `.display(pattern)` can render real dates in Markdown footers.
    case datetime(Date)
    case str(String)
    case array([TypstValue])
    case dict(TypstDict)
    case content(TypstContent)
    case function(TypstFunction)

    public var typeName: String {
        switch self {
        case .none: return "none"
        case .auto: return "auto"
        case .bool: return "bool"
        case .int: return "int"
        case .float: return "float"
        case .quantity: return "length"
        case .datetime: return "datetime"
        case .str: return "str"
        case .array: return "array"
        case .dict: return "dictionary"
        case .content: return "content"
        case .function: return "function"
        }
    }

    public var isTruthyForConditions: Bool {
        if case .bool(let value) = self { return value }
        return false
    }
}

// MARK: - Content

/// Content produced by markup blocks and content functions. Mirrors the old
/// ResolvedDocumentAST case-for-case so the renderer port stays mechanical.
public indirect enum TypstContent {
    case sequence([TypstContent])
    case text(String)
    /// Inline code span (rendered wrapped in backticks). Also used for code-style reprs.
    case code(String)
    case heading(level: Int, children: [TypstContent])
    case bold([TypstContent])
    case italic([TypstContent])
    case math(String)
    case function(name: String, args: [TypstArg])

    public static var empty: TypstContent { .sequence([]) }

    public var isEmpty: Bool {
        switch self {
        case .sequence(let children): return children.allSatisfy(\.isEmpty)
        case .text(let text): return text.isEmpty
        default: return false
        }
    }
}

// MARK: - Display (what placing the value in markup produces)

extension TypstValue {
    /// Reference value.rs display(): none → empty; int/float → decimal text;
    /// str → raw unquoted; bool → its name; content → itself; everything else →
    /// a code element containing repr().
    public func display() -> TypstContent {
        switch self {
        case .none:
            return .empty
        case .auto:
            return .code("auto")
        case .bool(let value):
            return .text(value ? "true" : "false")
        case .int(let value):
            return .text(String(value))
        case .float(let value):
            return .text(Self.displayFloat(value))
        case .quantity(let value, let unit):
            return .text(Self.displayFloat(value) + unit)
        case .str(let value):
            return .text(value)
        case .array, .dict, .datetime, .function:
            return .code(repr())
        case .content(let content):
            return content
        }
    }

    /// Reference float display (repr.rs display_float): shortest round-trip form,
    /// integral values without a trailing ".0", inf → ∞ / −∞, NaN → NaN.
    /// Divergence: uses ASCII "-" in "-∞" where the reference uses U+2212.
    public static func displayFloat(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "∞" : "-∞" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    /// Code form of a date-time, mirroring the reference constructor shape.
    static func reprDatetime(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return "datetime(year: \(components.year ?? 0), month: \(components.month ?? 0), "
            + "day: \(components.day ?? 0), hour: \(components.hour ?? 0), "
            + "minute: \(components.minute ?? 0), second: \(components.second ?? 0))"
    }

    // MARK: Repr (the code form)

    public func repr() -> String {
        switch self {
        case .none: return "none"
        case .auto: return "auto"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .float(let value):
            if value.isNaN { return "float.nan" }
            if value.isInfinite { return value > 0 ? "float.inf" : "-float.inf" }
            return String(value)   // Swift keeps the ".0" for integral doubles
        case .quantity(let value, let unit): return Self.displayFloat(value) + unit
        case .datetime(let date): return Self.reprDatetime(date)
        case .str(let value): return Self.reprString(value)
        case .array(let items):
            if items.isEmpty { return "()" }
            let rendered = items.map { $0.repr() }
            // Single-element arrays keep a trailing comma in the code form.
            if rendered.count == 1 { return "(\(rendered[0]),)" }
            return "(\(rendered.joined(separator: ", ")))"
        case .dict(let dict):
            if dict.entries.isEmpty { return "(:)" }
            let rendered = dict.entries.map { "\($0.key): \($0.value.repr())" }
            return "(\(rendered.joined(separator: ", ")))"
        case .content: return "content"
        case .function(let function):
            switch function {
            case .closure: return "function"
            case .builtin(let name, _), .content(let name), .dropped(let name):
                return name
            case .partial: return "function"
            }
        }
    }

    public static func reprString(_ value: String) -> String {
        var result = "\""
        for character in value {
            switch character {
            case "\\": result.append("\\\\")
            case "\"": result.append("\\\"")
            case "\n": result.append("\\n")
            case "\r": result.append("\\r")
            case "\t": result.append("\\t")
            default: result.append(character)
            }
        }
        result.append("\"")
        return result
    }
}

// MARK: - Join (reference ops.rs join — used for loop/code-block accumulation)

extension TypstValue {
    /// Join two values the way reference `ops::join` does. `none` is the identity;
    /// strings concatenate; content sequences; arrays concatenate; dicts merge.
    /// Numbers are NOT joined (that is addition's job) — this errors like the reference.
    public static func join(_ lhs: TypstValue, _ rhs: TypstValue) throws -> TypstValue {
        switch (lhs, rhs) {
        case (.none, _): return rhs
        case (_, .none): return lhs
        case (.str(let a), .str(let b)):
            return .str(a + b)
        case (.content(let a), .content(let b)):
            return .content(joinContent(a, b))
        case (.content(let a), .str(let b)):
            return .content(joinContent(a, .text(b)))
        case (.str(let a), .content(let b)):
            return .content(joinContent(.text(a), b))
        case (.array(let a), .array(let b)):
            return .array(a + b)
        case (.dict(let a), .dict(let b)):
            var merged = a
            for (key, value) in b.entries { merged.set(key, value) }
            return .dict(merged)
        default:
            throw TypstEvalError("cannot join \(lhs.typeName) with \(rhs.typeName)")
        }
    }

    public static func joinContent(_ lhs: TypstContent, _ rhs: TypstContent) -> TypstContent {
        if case .sequence(let a) = lhs { return .sequence(a + [rhs]) }
        return .sequence([lhs, rhs])
    }
}

// MARK: - Equality (reference ops: numeric cross-type equality, structural for others)

extension TypstValue: Equatable {
    public static func == (lhs: TypstValue, rhs: TypstValue) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none), (.auto, .auto): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.float(let a), .float(let b)): return a == b
        case (.int(let a), .float(let b)), (.float(let b), .int(let a)):
            return Double(a) == b
        case (.str(let a), .str(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.dict(let a), .dict(let b)): return a.entries.map(\.key) == b.entries.map(\.key)
            && a.entries.map(\.value) == b.entries.map(\.value)
        case (.quantity(let a, let ua), .quantity(let b, let ub)): return a == b && ua == ub
        case (.datetime(let a), .datetime(let b)): return a == b
        case (.content(let a), .content(let b)): return a == b
        default: return false
        }
    }
}

extension TypstContent: Equatable {
    public static func == (lhs: TypstContent, rhs: TypstContent) -> Bool {
        switch (lhs, rhs) {
        case (.sequence(let a), .sequence(let b)): return a == b
        case (.text(let a), .text(let b)): return a == b
        case (.code(let a), .code(let b)): return a == b
        case (.heading(let l1, let a), .heading(let l2, let b)): return l1 == l2 && a == b
        case (.bold(let a), .bold(let b)), (.italic(let a), .italic(let b)): return a == b
        case (.math(let a), .math(let b)): return a == b
        case (.function(let n1, _), .function(let n2, _)): return n1 == n2
        default: return false
        }
    }
}

// MARK: - Errors

/// Evaluation error inside a snippet. Caught per snippet; the snippet's raw source is
/// emitted as text so one bad expression never takes down the document.
public struct TypstEvalError: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Parse error for a `#`-region. Also recovered per snippet.
public struct TypstParseError: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}
