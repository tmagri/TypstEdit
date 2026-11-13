import Foundation

/// Unit-aware calculator input: `212 mm x 174 mm x 90 mm in cubic metres`,
/// `5 kg to lb`, `100 km/h in mph`.
///
/// Giac has a unit system, but its names are not what anyone types:
/// millimetres are `_mm`, minutes are `_mn` (`_min` makes the helper spin
/// forever), an inch is `_inch` (`_in` is undefined) and a gallon is
/// `_galUS`. Plain `212 mm x 174 mm` is worse: Giac reads `mm` as an unknown
/// variable and `x` as a syntax error, and answers `undef`.
///
/// This layer turns everyday spelling into a `convert(…)` call and the
/// answer back into `0.00331992 m³`, so the calculator panel and the chat's
/// calculator tool both understand units. Parsing and formatting are pure
/// and unit tested; evaluation stays in `CASEngine`.
enum UnitConversion {

    // MARK: - Parsed request

    struct Request: Equatable {
        /// What to evaluate, e.g. `convert(212*_mm*174*_mm*90*_mm,_m^3)`.
        var casInput: String
        /// The value side, readable: `212 mm × 174 mm × 90 mm`.
        var value: String
        /// The target unit, readable (`m³`); `nil` when nothing was asked
        /// for and the entry just carries units (`212 mm x 174 mm`).
        var target: String?
    }

    // MARK: - Parsing

    /// Recognises a unit entry. Returns `nil` for anything else, so ordinary
    /// math (`2x`, `sin(x)`, `solve(…)`) is never captured.
    static func parse(_ raw: String) -> Request? {
        let text = normalize(raw)
        guard !text.isEmpty else { return nil }

        // `… in …` / `… to …`: the rightmost separator whose right side is a
        // pure unit, so `10 in to cm` reads as ten inches.
        for (head, tail) in splitCandidates(text) {
            guard let value = parseSide(head, allowsNumbers: true),
                  !value.units.isEmpty,
                  let target = parseSide(tail, allowsNumbers: false),
                  !target.units.isEmpty else { continue }
            return Request(
                casInput: "convert(\(value.cas),\(target.cas))",
                value: value.display,
                target: target.display
            )
        }

        // No conversion asked: still a unit entry when it names a unit of
        // two or more letters (a lone `t`, `s` or `m` stays a variable).
        guard let value = parseSide(text, allowsNumbers: true),
              value.units.contains(where: { $0.count > 1 }),
              value.hasNumber else { return nil }
        return Request(casInput: value.cas, value: value.display, target: nil)
    }

    /// Every way to split on a conversion keyword, rightmost first.
    private static func splitCandidates(_ text: String) -> [(String, String)] {
        let separators = [" to ", " into ", " in ", "->", "→"]
        var found: [(offset: Int, head: String, tail: String)] = []
        for separator in separators {
            var searchStart = text.startIndex
            while let range = text.range(of: separator, range: searchStart..<text.endIndex) {
                found.append((
                    offset: text.distance(from: text.startIndex, to: range.lowerBound),
                    head: String(text[..<range.lowerBound]),
                    tail: String(text[range.upperBound...])
                ))
                searchStart = range.upperBound
            }
        }
        return found.sorted { $0.offset > $1.offset }.map { ($0.head, $0.tail) }
    }

    private struct ParsedSide {
        var cas: String
        var display: String
        /// Unit words as typed, so callers can tell units from variables.
        var units: [String]
        var hasNumber: Bool
    }

    private enum Joiner {
        /// `212 mm`: shown with a space, sent as `*`.
        case adjacent
        case times
        case divide
    }

    private enum Term {
        case number(String)
        case unit(symbol: String, display: String, power: Int)
    }

    /// Parses numbers, unit names, multiplication, division and powers.
    /// Anything else (a function call, a bracket, an unknown word) rejects
    /// the whole side.
    private static func parseSide(_ text: String, allowsNumbers: Bool) -> ParsedSide? {
        let characters = Array(text.trimmingCharacters(in: .whitespaces))
        guard !characters.isEmpty else { return nil }

        var terms: [Term] = []
        var joiners: [Joiner] = []
        var units: [String] = []
        var pendingJoiner: Joiner?
        var pendingPower = 1
        var index = 0

        func push(_ term: Term) {
            if !terms.isEmpty { joiners.append(pendingJoiner ?? .adjacent) }
            pendingJoiner = nil
            terms.append(term)
        }

        /// A `*` or `/` must sit between two terms.
        func setJoiner(_ joiner: Joiner) -> Bool {
            guard !terms.isEmpty, pendingJoiner == nil, pendingPower == 1 else { return false }
            pendingJoiner = joiner
            return true
        }

        /// `^3`, or a digit glued to a unit (`m3`, `cm2`), raises the unit
        /// just read.
        func readPower(glued: Bool) -> Int? {
            var cursor = index
            if cursor < characters.count, characters[cursor] == "^" {
                cursor += 1
            } else if !glued {
                return nil
            }
            var negative = false
            if cursor < characters.count, characters[cursor] == "-" {
                negative = true
                cursor += 1
            }
            let start = cursor
            while cursor < characters.count, characters[cursor].isNumber { cursor += 1 }
            guard cursor > start, let value = Int(String(characters[start..<cursor])), value <= 12 else {
                return nil
            }
            index = cursor
            return negative ? -value : value
        }

        while index < characters.count {
            let character = characters[index]

            if character.isWhitespace {
                index += 1
                continue
            }
            if character == "*" {
                guard setJoiner(.times) else { return nil }
                index += 1
                continue
            }
            if character == "/" {
                guard setJoiner(.divide) else { return nil }
                index += 1
                continue
            }

            if character.isNumber || character == "." {
                guard allowsNumbers, pendingPower == 1 else { return nil }
                let start = index
                var seenDot = false
                while index < characters.count {
                    if characters[index].isNumber {
                        index += 1
                    } else if characters[index] == ".", !seenDot {
                        seenDot = true
                        index += 1
                    } else {
                        break
                    }
                }
                // Exponent form: 1e-3, 2.5e6.
                if index + 1 < characters.count, characters[index] == "e" {
                    var lookahead = index + 1
                    if characters[lookahead] == "+" || characters[lookahead] == "-" { lookahead += 1 }
                    if lookahead < characters.count, characters[lookahead].isNumber {
                        index = lookahead
                        while index < characters.count, characters[index].isNumber { index += 1 }
                    }
                }
                var number = String(characters[start..<index])
                if number == "." { return nil }
                if number.hasPrefix(".") { number = "0" + number }
                push(.number(number))
                continue
            }

            guard character.isLetter || character == "µ" else { return nil }
            let start = index
            while index < characters.count, characters[index].isLetter || characters[index] == "µ" {
                index += 1
            }
            let word = String(characters[start..<index])

            switch word {
            case "x", "by", "times":
                guard setJoiner(.times) else { return nil }
                continue
            case "per", "over":
                guard setJoiner(.divide) else { return nil }
                continue
            case "square", "sq":
                guard pendingPower == 1 else { return nil }
                pendingPower = 2
                continue
            case "cubic", "cu":
                guard pendingPower == 1 else { return nil }
                pendingPower = 3
                continue
            case "squared":
                guard case .unit(let symbol, let display, 1)? = terms.last else { return nil }
                terms[terms.count - 1] = .unit(symbol: symbol, display: display, power: 2)
                continue
            case "cubed":
                guard case .unit(let symbol, let display, 1)? = terms.last else { return nil }
                terms[terms.count - 1] = .unit(symbol: symbol, display: display, power: 3)
                continue
            default:
                break
            }

            guard let definition = lookup(word) else { return nil }
            let glued = index < characters.count && characters[index].isNumber
            var power = pendingPower
            if let explicit = readPower(glued: glued) {
                guard pendingPower == 1 else { return nil }
                power = explicit
            }
            pendingPower = 1
            push(.unit(symbol: definition.symbol, display: definition.display, power: power))
            units.append(word)
        }

        // A dangling operator or modifier (`5 kg /`, `5 cubic`) is not a unit.
        guard !terms.isEmpty, pendingJoiner == nil, pendingPower == 1 else { return nil }

        var cas = ""
        var display = ""
        var hasNumber = false
        for (position, term) in terms.enumerated() {
            if position > 0 {
                switch joiners[position - 1] {
                case .adjacent:
                    cas += "*"
                    display += " "
                case .times:
                    cas += "*"
                    display += " × "
                case .divide:
                    cas += "/"
                    display += "/"
                }
            }
            switch term {
            case .number(let number):
                hasNumber = true
                cas += number
                display += number
            case .unit(let symbol, let name, let power):
                cas += symbol
                display += name
                if power != 1 {
                    cas += "^\(power)"
                    display += superscript(power)
                }
            }
        }
        // `km/h` reads better without spaces round the slash, but a value
        // like `90 km / 2 h` keeps them: only tighten unit-to-unit slashes.
        return ParsedSide(cas: cas, display: display, units: units, hasNumber: hasNumber)
    }

    /// Lowercases, folds the glyphs people actually type, and drops the
    /// "convert …" / "what is …" framing.
    static func normalize(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "✕", with: "*")
            .replacingOccurrences(of: "·", with: "*")
            .replacingOccurrences(of: "⋅", with: "*")
            .replacingOccurrences(of: "³", with: "^3")
            .replacingOccurrences(of: "²", with: "^2")
            .replacingOccurrences(of: "→", with: "->")
            .replacingOccurrences(of: "\n", with: " ")
            .lowercased()

        // Multi-word unit names, longest first, before words are split.
        let phrases: [(String, String)] = [
            ("pounds per square inch", "psi"),
            ("pound per square inch", "psi"),
            ("kilometres per hour", "kph"),
            ("kilometers per hour", "kph"),
            ("kilometre per hour", "kph"),
            ("kilometer per hour", "kph"),
            ("miles per hour", "mph"),
            ("mile per hour", "mph"),
            ("km/h", "kph"),
            ("nautical miles", "nmi"),
            ("nautical mile", "nmi"),
            ("imperial gallons", "galuk"),
            ("imperial gallon", "galuk"),
            ("uk gallons", "galuk"),
            ("uk gallon", "galuk"),
            ("us gallons", "galus"),
            ("us gallon", "galus"),
            ("metric tonnes", "tonne"),
            ("metric tonne", "tonne"),
            ("metric tons", "tonne"),
            ("metric ton", "tonne"),
        ]
        for (phrase, replacement) in phrases {
            text = text.replacingOccurrences(of: phrase, with: replacement)
        }

        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["convert ", "how many ", "how much is ", "what is ", "what's ", "whats ", "calculate "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        while let last = text.last, last == "?" || last == "." || last == " " {
            text.removeLast()
        }
        return text
    }

    // MARK: - Evaluation

    struct Outcome {
        var ok: Bool
        /// The readable answer (`0.00331992 m³`) or the error sentence.
        var text: String
        /// The CAS's own printing, for the model and for copy/`ans`.
        var casText: String
    }

    /// A Typst math expression that keeps the converted unit as upright text.
    static func typst(from readableText: String) -> String {
        let parts = readableText.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "\"\(readableText.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        let unit = parts[1].replacingOccurrences(of: "\"", with: "\\\"")
        return "\(parts[0]) \"\(unit)\""
    }

    /// Runs a parsed request through the CAS and formats the answer.
    static func evaluate(_ request: Request,
                         engine: CASEngine = .shared,
                         approx: Bool,
                         angle: CASAngleMode,
                         digits: Int,
                         timeout: TimeInterval) async -> Outcome {
        let result = await engine.eval(input: request.casInput, approx: approx,
                                       angle: angle, digits: digits, timeout: timeout)
        guard result.ok else {
            return Outcome(ok: false, text: friendlyError(result.errorMessage), casText: "")
        }
        let readable = formatted(result) ?? result.resultText
        return Outcome(ok: true, text: readable, casText: result.resultText)
    }

    // MARK: - Result formatting

    /// The answer in readable form. Giac tags a value with its unit as
    /// `_(value, unit)` and prints it `0.00331992_(m^3)`; this gives
    /// `0.00331992 m³`. `nil` when the result is not a tagged value.
    static func formatted(_ result: CASEvalResult) -> String? {
        guard let tree = result.resultTree,
              case .function(let name, let args) = tree, name == "_", args.count == 1,
              case .vector(let parts) = args[0], parts.count == 2,
              case .number(let value, let approx) = parts[0],
              let unit = unitText(parts[1]) else { return nil }
        let number = value.count <= 18 ? value : (approx ?? value)
        return "\(trimZeros(number)) \(unit)"
    }

    private static func unitText(_ node: CASExpression) -> String? {
        switch node {
        case .symbol(let name) where name.hasPrefix("_"):
            return displayName(forSymbol: name)
        case .operation("^", let args) where args.count == 2:
            guard let base = unitText(args[0]), let power = integer(args[1]) else { return nil }
            return power == 1 ? base : base + superscript(power)
        case .operation(let op, let args) where op == "*" || op == "/":
            var top: [String] = []
            var bottom: [String] = []
            for (position, argument) in args.enumerated() {
                // Giac writes `km/h` as `km*h^-1`.
                if case .operation("^", let inner) = argument, inner.count == 2,
                   let power = integer(inner[1]), power < 0,
                   let base = unitText(inner[0]) {
                    bottom.append(power == -1 ? base : base + superscript(-power))
                    continue
                }
                guard let text = unitText(argument) else { return nil }
                if op == "/" && position > 0 { bottom.append(text) } else { top.append(text) }
            }
            guard !top.isEmpty else { return nil }
            let numerator = top.joined(separator: "·")
            return bottom.isEmpty ? numerator : "\(numerator)/\(bottom.joined(separator: "·"))"
        default:
            return nil
        }
    }

    private static func integer(_ node: CASExpression) -> Int? {
        switch node {
        case .number(let value, _):
            return Int(value)
        case .operation("-", let args) where args.count == 1:
            return integer(args[0]).map { -$0 }
        default:
            return nil
        }
    }

    /// Readable name for a Giac unit symbol: the table's own display name
    /// when there is one (`_mn` → `min`), else the symbol without `_`.
    private static func displayName(forSymbol symbol: String) -> String {
        displayBySymbol[symbol] ?? String(symbol.dropFirst())
    }

    private static func trimZeros(_ text: String) -> String {
        guard text.contains("."), !text.lowercased().contains("e") else { return text }
        var trimmed = text
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }

    static func superscript(_ power: Int) -> String {
        let digits: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "-": "⁻",
        ]
        return String(String(power).map { digits[$0] ?? $0 })
    }

    /// One sentence instead of Giac's `Incompatible units Error: Bad
    /// Argument Value`.
    static func friendlyError(_ message: String) -> String {
        if message.contains("Incompatible units") || message.contains("could not be converted to MKS") {
            return "Those units measure different things (for example length and volume), so one cannot be converted into the other."
        }
        return message
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? message
    }

    // MARK: - Unit table

    private struct Definition {
        let symbol: String
        let display: String
    }

    /// Finds a unit word, accepting plurals (`metres`, `inches`, `lbs`).
    /// Plurals are only stripped down to names of three or more letters, or
    /// a known short plural: `ms` must not turn into metres.
    private static func lookup(_ word: String) -> Definition? {
        if let match = table[word] { return match }
        if word.hasSuffix("es"), word.count > 4, let match = table[String(word.dropLast(2))] { return match }
        if word.hasSuffix("s") {
            let singular = String(word.dropLast())
            if singular.count >= 3 || ["lb", "kg", "hr", "yd", "oz", "mi"].contains(singular),
               let match = table[singular] {
                return match
            }
        }
        return nil
    }

    /// Each entry was checked against the bundled helper.
    private static let entries: [(names: [String], symbol: String, display: String)] = [
        // Length
        (["m", "metre", "meter"], "_m", "m"),
        (["mm", "millimetre", "millimeter"], "_mm", "mm"),
        (["cm", "centimetre", "centimeter"], "_cm", "cm"),
        (["km", "kilometre", "kilometer"], "_km", "km"),
        (["in", "inch"], "_inch", "in"),
        (["ft", "foot", "feet"], "_ft", "ft"),
        (["yd", "yard"], "_yd", "yd"),
        (["mi", "mile"], "_mi", "mi"),
        (["nmi"], "_nmi", "nmi"),
        // Mass
        (["mg", "milligram"], "_mg", "mg"),
        (["g", "gram"], "_g", "g"),
        (["kg", "kilogram", "kilo"], "_kg", "kg"),
        (["lb", "pound"], "_lb", "lb"),
        (["oz", "ounce"], "_oz", "oz"),
        (["t", "tonne"], "_t", "t"),
        (["ton"], "_ton", "short ton"),
        // Volume
        (["l", "litre", "liter"], "_L", "L"),
        (["ml", "millilitre", "milliliter"], "_mL", "mL"),
        (["gal", "gallon", "galus"], "_galUS", "US gal"),
        (["galuk"], "_galUK", "UK gal"),
        // Time
        (["s", "sec", "second"], "_s", "s"),
        (["min", "minute"], "_mn", "min"),
        (["h", "hr", "hour"], "_h", "h"),
        // Speed
        (["mph"], "_mph", "mph"),
        (["kph", "kmh"], "_kph", "km/h"),
        (["knot", "kn"], "_knot", "kn"),
        // Area
        (["ha", "hectare"], "_ha", "ha"),
        (["acre"], "_acre", "acre"),
        // Pressure
        (["pa", "pascal"], "_Pa", "Pa"),
        (["bar"], "_bar", "bar"),
        (["atm", "atmosphere"], "_atm", "atm"),
        (["psi"], "_psi", "psi"),
        // Energy, power, force
        (["j", "joule"], "_J", "J"),
        (["wh"], "_Wh", "Wh"),
        (["w", "watt"], "_W", "W"),
        (["hp", "horsepower"], "_hp", "hp"),
        (["n", "newton"], "_N", "N"),
        (["lbf"], "_lbf", "lbf"),
    ]

    private static let table: [String: Definition] = {
        var map: [String: Definition] = [:]
        for entry in entries {
            for name in entry.names {
                map[name] = Definition(symbol: entry.symbol, display: entry.display)
            }
        }
        return map
    }()

    private static let displayBySymbol: [String: String] = {
        var map: [String: String] = [:]
        for entry in entries where map[entry.symbol] == nil {
            map[entry.symbol] = entry.display
        }
        return map
    }()
}
