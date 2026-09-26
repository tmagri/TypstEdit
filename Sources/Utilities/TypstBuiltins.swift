import Foundation

// MARK: - TypstBuiltins.swift
// Registry of builtin functions: globals (range, conversions, numbering, emph/strong),
// the `calc` scope, type-scoped element functions (table.header, …), and the drop-set
// of state/layout machinery with no Markdown meaning (counter, state, query, …).
// The collection method batteries live in TypstBuiltinsCollections.swift.

// @Sendable: every builtin closure is stateless — all state arrives through the
// interpreter argument — so the static registries below are safe as `static let`
// under Swift 6 strict concurrency.
typealias TypstBuiltin = @Sendable (TypstInterpreter, [TypstArg]) throws -> TypstValue

enum TypstBuiltins {
    /// State/layout machinery that Markdown cannot express. Referencing one yields a
    /// dropped function value; calling it or accessing fields on it yields none, so
    /// chains like `#counter(page).update(1)` stay silent.
    static let droppedNames: Set<String> = [
        "counter", "state", "query", "locate", "measure", "here", "metadata",
        "style", "luma", "rgb", "cmyk", "oklab", "oklch", "color",
    ]

    // MARK: Registries

    static func globalFunction(_ name: String) -> TypstValue? {
        guard let impl = globalImpl(name) else { return nil }
        return .function(.builtin(name: name, impl: impl))
    }

    /// Type-scope functions addressable as `type.member`: `table.header`,
    /// `calc.abs`, `array.range`, …
    static func typeFunction(_ typeName: String, _ name: String) -> TypstValue? {
        switch typeName {
        case "calc":
            guard let impl = calcImpl(name) else { return nil }
            return .function(.builtin(name: "calc.\(name)", impl: impl))
        case "table", "grid":
            // Element functions survive as content nodes for the renderer.
            // `row`/`footer` carry cells; `hline`/`vline` are rule lines the
            // renderer skips — either way the table must not leak raw.
            let contentNames: Set<String> = ["header", "hline", "cell", "vline", "row", "footer", "hline-stroke"]
            guard contentNames.contains(name) else { return nil }
            return .function(.content("\(typeName).\(name)"))
        case "array", "str", "dictionary":
            let scopeName = typeName == "dictionary" ? "dict" : typeName
            guard let impl = collectionImpl(scopeName, name) else { return nil }
            return .function(.builtin(name: "\(typeName).\(name)", impl: impl))
        case "numbering":
            guard let impl = globalImpl("numbering") else { return nil }
            return .function(.builtin(name: "numbering.\(name)", impl: impl))
        case "datetime":
            guard let impl = datetimeImpl(name) else { return nil }
            return .function(.builtin(name: "datetime.\(name)", impl: impl))
        case "function":
            guard name == "with" else { return nil }
            return .function(.builtin(name: "function.with", impl: builtinFunctionWith))
        default:
            return nil
        }
    }

    /// Method lookup for the `recv.m(args)` → `type.m(recv, args)` desugaring.
    static func method(for typeName: String, name: String) -> TypstValue? {
        if typeName == "datetime", let impl = datetimeImpl(name) {
            return .function(.builtin(name: "datetime.\(name)", impl: impl))
        }
        if typeName == "function", name == "with" {
            return .function(.builtin(name: "function.with", impl: builtinFunctionWith))
        }
        guard let impl = collectionImpl(typeName, name) else { return nil }
        return .function(.builtin(name: "\(typeName).\(name)", impl: impl))
    }

    /// `f.with(args…)` — binds arguments ahead of the call; invoked later with the
    /// remaining arguments (used by `#show: document-layout.with(title: …)`).
    private static let builtinFunctionWith: TypstBuiltin = { _, args in
        guard let receiver = args.first else {
            throw TypstEvalError("with() requires a function")
        }
        return .function(.partial(receiver.value, Array(args.dropFirst())))
    }

    private static func globalImpl(_ name: String) -> TypstBuiltin? {
        switch name {
        case "range": return builtinRange
        case "str": return builtinStr
        case "int": return builtinInt
        case "float": return builtinFloat
        case "type": return builtinType
        case "repr": return builtinRepr
        case "emph": return builtinEmph
        case "strong": return builtinStrong
        case "upper": return builtinUpper
        case "lower": return builtinLower
        case "numbering": return builtinNumbering
        case "datetime": return builtinDatetime
        case "l": return nil  // spacing shorthand stays a content leak
        default: return nil
        }
    }

    private static func calcImpl(_ name: String) -> TypstBuiltin? {
        switch name {
        case "abs": return calcAbs
        case "min": return calcMin
        case "max": return calcMax
        case "floor": return calcFloor
        case "ceil": return calcCeil
        case "round": return calcRound
        case "sqrt": return calcSqrt
        case "pow": return calcPow
        case "rem": return calcRem
        case "clamp": return calcClamp
        case "even": return calcEven
        case "odd": return calcOdd
        default: return nil
        }
    }

    // MARK: datetime

    private static func datetimeImpl(_ name: String) -> TypstBuiltin? {
        switch name {
        case "today": return builtinDatetimeToday
        case "display": return builtinDatetimeDisplay
        case "year": return componentImpl { $0.year }
        case "month": return componentImpl { $0.month }
        case "day": return componentImpl { $0.day }
        case "weekday": return componentImpl { components in components.weekday.map { ($0 + 5) % 7 + 1 } }
        case "hour": return componentImpl { $0.hour }
        case "minute": return componentImpl { $0.minute }
        case "second": return componentImpl { $0.second }
        default: return nil
        }
    }

    /// `datetime(year: …, month: …, day: …, hour: …, minute: …, second: …)` —
    /// named components only; missing ones default to zero.
    static let builtinDatetime: TypstBuiltin = { _, args in
        var components = DateComponents()
        for arg in args {
            guard let name = arg.name, case .int(let value) = arg.value else { continue }
            switch name {
            case "year": components.year = Int(value)
            case "month": components.month = Int(value)
            case "day": components.day = Int(value)
            case "hour": components.hour = Int(value)
            case "minute": components.minute = Int(value)
            case "second": components.second = Int(value)
            default: break
            }
        }
        guard let date = Calendar(identifier: .gregorian).date(from: components) else {
            throw TypstEvalError("invalid datetime")
        }
        return .datetime(date)
    }

    static let builtinDatetimeToday: TypstBuiltin = { _, _ in .datetime(Date()) }

    /// `dt.display("[month repr:long] [day], [year]")` — fields we don't model
    /// render empty so an exotic pattern can never leak raw source.
    static let builtinDatetimeDisplay: TypstBuiltin = { _, args in
        guard case .datetime(let date) = args.first?.value ?? .none else {
            throw TypstEvalError("expected datetime, found none")
        }
        // display() with no pattern uses typst's documented default.
        var pattern = "[year]-[month repr:short]-[day]"
        if case .str(let text) = args.dropFirst().first(where: { $0.name == nil })?.value ?? .none {
            pattern = text
        }
        return .str(formatDatetime(date, pattern: pattern))
    }

    /// Component accessors (`dt.year()`, `dt.month()`, …). Weekday is Typst's
    /// Monday = 1 numbering, converted from Foundation's Sunday = 1.
    private static func componentImpl(
        _ pick: @escaping @Sendable (DateComponents) -> Int?
    ) -> TypstBuiltin {
        { _, args in
            guard case .datetime(let date) = args.first?.value ?? .none else {
                throw TypstEvalError("expected datetime, found none")
            }
            let components = Calendar(identifier: .gregorian).dateComponents(
                [.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
            return .int(Int64(pick(components) ?? 0))
        }
    }

    static func formatDatetime(_ date: Date, pattern: String) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .weekday, .hour, .minute, .second], from: date)

        var output = ""
        var cursor = pattern.startIndex
        while let open = pattern[cursor...].firstIndex(of: "[") {
            output += pattern[cursor..<open]
            guard let close = pattern[open...].firstIndex(of: "]") else {
                output += pattern[open...]  // unterminated: keep literal
                cursor = pattern.endIndex
                break
            }
            let spec = String(pattern[pattern.index(after: open)..<close])
            output += renderDatetimeField(spec, components)
            cursor = pattern.index(after: close)
        }
        output += pattern[cursor...]
        return output
    }

    private static func renderDatetimeField(_ spec: String, _ components: DateComponents) -> String {
        let parts = spec.split(separator: " ", maxSplits: 1).map(String.init)
        var modifiers: [String: String] = [:]
        if parts.count > 1 {
            for piece in parts[1].split(separator: ",") {
                let pair = piece.split(separator: ":", maxSplits: 1).map(String.init)
                if pair.count == 2 {
                    modifiers[pair[0].trimmingCharacters(in: .whitespaces)] =
                        pair[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        let padding = modifiers["padding"]

        func padded(_ value: Int) -> String {
            padding == "none" ? String(value) : (value < 10 && value >= 0 ? "0\(value)" : String(value))
        }

        switch parts.first ?? "" {
        case "year": return String(components.year ?? 0)
        case "month":
            switch modifiers["repr"] {
            case "long": return longMonthNames[(components.month ?? 1) - 1]
            case "short": return shortMonthNames[(components.month ?? 1) - 1]
            default: return padded(components.month ?? 0)
            }
        case "day": return padded(components.day ?? 0)
        case "weekday":
            let weekday = ((components.weekday ?? 1) + 5) % 7 + 1  // Monday = 1
            switch modifiers["repr"] {
            case "long": return longWeekdayNames[weekday - 1]
            case "short": return shortWeekdayNames[weekday - 1]
            default: return String(weekday)
            }
        case "hour": return padded(components.hour ?? 0)
        case "minute": return padded(components.minute ?? 0)
        case "second": return padded(components.second ?? 0)
        default: return ""  // unknown field → empty (never leak)
        }
    }

    private static let longMonthNames = ["January", "February", "March", "April", "May", "June",
                                         "July", "August", "September", "October", "November", "December"]
    private static let shortMonthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let longWeekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday",
                                           "Friday", "Saturday", "Sunday"]
    private static let shortWeekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    // MARK: Argument helpers

    static func positionals(_ args: [TypstArg]) -> [TypstValue] {
        args.filter { $0.name == nil }.map(\.value)
    }

    static func named(_ args: [TypstArg], _ name: String) -> TypstValue? {
        args.first { $0.name == name }?.value
    }

    static func requireString(_ value: TypstValue, _ role: String) throws -> String {
        guard case .str(let string) = value else {
            throw TypstEvalError("expected string for \(role), found \(value.typeName)")
        }
        return string
    }

    static func requireInt(_ value: TypstValue, _ role: String) throws -> Int64 {
        switch value {
        case .int(let i): return i
        case .float(let f): return Int64(f)
        default:
            throw TypstEvalError("expected integer for \(role), found \(value.typeName)")
        }
    }

    static func toArray(_ value: TypstValue) throws -> [TypstValue] {
        guard case .array(let items) = value else {
            throw TypstEvalError("expected array, found \(value.typeName)")
        }
        return items
    }

    // MARK: Globals

    /// `range(end)` / `range(start, end, step: 1, inclusive: false)` — one positional
    /// means END (reference array.rs:384-443); negative steps count down.
    static let builtinRange: TypstBuiltin = { _, args in
        let positional = positionals(args)
        guard (1...2).contains(positional.count) else {
            throw TypstEvalError("range expects 1 or 2 positional arguments")
        }
        let start = positional.count == 2 ? try requireInt(positional[0], "start") : 0
        let end = try requireInt(positional.last!, "end")
        let step = try requireInt(named(args, "step") ?? .int(1), "step")
        guard step != 0 else { throw TypstEvalError("step must not be zero") }
        let inclusive = named(args, "inclusive") == .bool(true)

        var result: [TypstValue] = []
        if step > 0 {
            var value = start
            while value < end || (inclusive && value == end) {
                result.append(.int(value))
                let (next, overflow) = value.addingReportingOverflow(step)
                if overflow { break }
                value = next
            }
        } else {
            var value = start
            while value > end || (inclusive && value == end) {
                result.append(.int(value))
                let (next, overflow) = value.addingReportingOverflow(step)
                if overflow { break }
                value = next
            }
        }
        return .array(result)
    }

    static let builtinStr: TypstBuiltin = { _, args in
        let value = positionals(args).first ?? .none
        switch value {
        case .str(let s): return .str(s)
        case .int, .float, .bool, .quantity:
            switch value.display() {
            case .text(let text): return .str(text)
            case .code(let code): return .str(code)
            default: return .str(value.repr())
            }
        case .none: return .str("none")
        case .auto: return .str("auto")
        default:
            throw TypstEvalError("cannot convert \(value.typeName) to string")
        }
    }

    static let builtinInt: TypstBuiltin = { _, args in
        let value = positionals(args).first ?? .none
        switch value {
        case .int(let i): return .int(i)
        case .float(let f): return .int(Int64(f.rounded(.towardZero)))
        case .bool(let b): return .int(b ? 1 : 0)
        case .str(let s):
            guard let i = Int64(s.trimmingCharacters(in: .whitespaces)) else {
                throw TypstEvalError("invalid integer: \"\(s)\"")
            }
            return .int(i)
        default:
            throw TypstEvalError("cannot convert \(value.typeName) to integer")
        }
    }

    static let builtinFloat: TypstBuiltin = { _, args in
        let value = positionals(args).first ?? .none
        switch value {
        case .int(let i): return .float(Double(i))
        case .float(let f): return .float(f)
        case .bool(let b): return .float(b ? 1 : 0)
        case .str(let s):
            switch s.trimmingCharacters(in: .whitespaces) {
            case "inf": return .float(.infinity)
            case "-inf": return .float(-.infinity)
            case "nan": return .float(.nan)
            default:
                guard let f = Double(s) else {
                    throw TypstEvalError("invalid float: \"\(s)\"")
                }
                return .float(f)
            }
        default:
            throw TypstEvalError("cannot convert \(value.typeName) to float")
        }
    }

    static let builtinType: TypstBuiltin = { _, args in
        .str((positionals(args).first ?? .none).typeName)
    }

    static let builtinRepr: TypstBuiltin = { _, args in
        .str((positionals(args).first ?? .none).repr())
    }

    static let builtinEmph: TypstBuiltin = { interpreter, args in
        let payload = try contentPayload(args, interpreter)
        return .content(.italic([payload]))
    }

    static let builtinStrong: TypstBuiltin = { interpreter, args in
        let payload = try contentPayload(args, interpreter)
        return .content(.bold([payload]))
    }

    static let builtinUpper: TypstBuiltin = { _, args in
        let value = positionals(args).first ?? .none
        return .str(try requireString(value, "text").uppercased())
    }

    static let builtinLower: TypstBuiltin = { _, args in
        let value = positionals(args).first ?? .none
        return .str(try requireString(value, "text").lowercased())
    }

    /// `numbering("I. 1)", 2, 3)` — supports the 1 / a / A / i / I counting symbols;
    /// unknown symbols pass through unchanged. Good enough for the common patterns.
    static let builtinNumbering: TypstBuiltin = { _, args in
        let positional = positionals(args)
        guard positional.count >= 1 else { return .str("") }
        let pattern = try requireString(positional[0], "pattern")
        let numbers = positional.dropFirst().compactMap { value -> Int64? in
            if case .int(let i) = value { return i }
            if case .float(let f) = value { return Int64(f) }
            return nil
        }

        var output = ""
        var numberIndex = 0
        for character in pattern {
            switch character {
            case "1", "a", "A", "i", "I":
                let value = numberIndex < numbers.count ? numbers[numberIndex] : 1
                output += formatNumbered(value, symbol: character)
                numberIndex += 1
            default:
                output.append(character)
            }
        }
        return .str(output)
    }

    private static func formatNumbered(_ value: Int64, symbol: Character) -> String {
        switch symbol {
        case "a": return alphaNumbering(value, lowercase: true)
        case "A": return alphaNumbering(value, lowercase: false)
        case "i": return romanNumbering(value).lowercased()
        case "I": return romanNumbering(value)
        default: return String(value)
        }
    }

    private static func alphaNumbering(_ value: Int64, lowercase: Bool) -> String {
        guard value > 0 else { return String(value) }
        var n = value
        var letters = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            let letter = Character(UnicodeScalar(UInt8(97 + remainder)))
            letters.insert(letter, at: letters.startIndex)
            n = (n - 1) / 26
        }
        return lowercase ? letters : letters.uppercased()
    }

    private static func romanNumbering(_ value: Int64) -> String {
        guard value > 0 else { return String(value) }
        let pairs: [(Int64, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var n = value
        var result = ""
        for (threshold, symbol) in pairs {
            while n >= threshold {
                result += symbol
                n -= threshold
            }
        }
        return result
    }

    // MARK: calc scope

    static let calcAbs: TypstBuiltin = { _, args in
        switch positionals(args).first ?? .none {
        case .int(let i): return .int(i < 0 ? -i : i)
        case .float(let f): return .float(Swift.abs(f))
        case .quantity(let q, let u): return .quantity(Swift.abs(q), unit: u)
        case let other: throw TypstEvalError("cannot take abs of \(other.typeName)")
        }
    }

    static let calcMin: TypstBuiltin = { _, args in
        try extremum(args, preferLarger: false)
    }

    static let calcMax: TypstBuiltin = { _, args in
        try extremum(args, preferLarger: true)
    }

    private static func extremum(_ args: [TypstArg], preferLarger: Bool) throws -> TypstValue {
        var positional = positionals(args)
        if positional.count == 1 { positional = try toArray(positional[0]) }
        guard let first = positional.first else { throw TypstEvalError("expected comparable arguments") }
        var best = first
        for candidate in positional.dropFirst() {
            let wins: Bool
            if case .str(let a) = best, case .str(let b) = candidate {
                wins = preferLarger ? b > a : b < a
            } else {
                let a = try numeric(best), b = try numeric(candidate)
                wins = preferLarger ? b > a : b < a
            }
            if wins { best = candidate }
        }
        return best
    }

    private static func numeric(_ value: TypstValue) throws -> Double {
        switch value {
        case .int(let i): return Double(i)
        case .float(let f): return f
        case .quantity(let q, _): return q
        default: throw TypstEvalError("expected a number, found \(value.typeName)")
        }
    }

    static let calcFloor: TypstBuiltin = { _, args in
        switch positionals(args).first ?? .none {
        case .int(let i): return .int(i)
        case .float(let f): return .int(Int64(f.rounded(.down)))
        case let other: throw TypstEvalError("cannot floor \(other.typeName)")
        }
    }

    static let calcCeil: TypstBuiltin = { _, args in
        switch positionals(args).first ?? .none {
        case .int(let i): return .int(i)
        case .float(let f): return .int(Int64(f.rounded(.up)))
        case let other: throw TypstEvalError("cannot ceil \(other.typeName)")
        }
    }

    static let calcRound: TypstBuiltin = { _, args in
        let positional = positionals(args)
        switch positional.first ?? .none {
        case .int(let i): return .int(i)
        case .float(let f):
            let digits = positional.count > 1 ? (try? requireInt(positional[1], "digits")) ?? 0 : 0
            let factor = pow(10, Double(digits))
            return .float((f * factor).rounded() / factor)
        case let other: throw TypstEvalError("cannot round \(other.typeName)")
        }
    }

    static let calcSqrt: TypstBuiltin = { _, args in
        let value = try numeric(positionals(args).first ?? .none)
        guard value >= 0 else { throw TypstEvalError("cannot take square root of negative number") }
        return .float(value.squareRoot())
    }

    static let calcPow: TypstBuiltin = { _, args in
        let positional = positionals(args)
        guard positional.count == 2 else { throw TypstEvalError("pow expects base and exponent") }
        let base = try numeric(positional[0])
        let exponent = try numeric(positional[1])
        return .float(Foundation.pow(base, exponent))
    }

    static let calcRem: TypstBuiltin = { _, args in
        let positional = positionals(args)
        guard positional.count == 2 else { throw TypstEvalError("rem expects two arguments") }
        if case .int(let a) = positional[0], case .int(let b) = positional[1] {
            guard b != 0 else { throw TypstEvalError("remainder by zero") }
            return .int(a % b)
        }
        let a = try numeric(positional[0])
        let b = try numeric(positional[1])
        return .float(a.remainder(dividingBy: b))
    }

    static let calcClamp: TypstBuiltin = { _, args in
        let positional = positionals(args)
        guard positional.count == 3 else { throw TypstEvalError("clamp expects value, min, max") }
        let value = try numeric(positional[0])
        let low = try numeric(positional[1])
        let high = try numeric(positional[2])
        return .float(min(max(value, low), high))
    }

    static let calcEven: TypstBuiltin = { _, args in
        let i = try requireInt(positionals(args).first ?? .none, "value")
        return .bool(i % 2 == 0)
    }

    static let calcOdd: TypstBuiltin = { _, args in
        let i = try requireInt(positionals(args).first ?? .none, "value")
        return .bool(i % 2 != 0)
    }

    // MARK: Shared payload extraction

    /// First content-ish argument rendered through the interpreter (used by emph/strong).
    static func contentPayload(_ args: [TypstArg], _ interpreter: TypstInterpreter) throws -> TypstContent {
        let positional = positionals(args)
        if let content = positional.first(where: { if case .content = $0 { return true }; return false }),
           case .content(let payload) = content {
            return payload
        }
        let strings = positional.compactMap { value -> String? in
            if case .str(let s) = value { return s }
            return nil
        }
        if !strings.isEmpty {
            return .text(strings.joined(separator: " "))
        }
        _ = interpreter
        return .empty
    }
}
