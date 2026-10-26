import Foundation

/// Exact / approximate / automatic result modes, mirroring the TI-89's
/// Exact/Approx/Auto setting in its MODE screen.
enum CASExactMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "Auto"
    case exact = "Exact"
    case approx = "Approx"

    var id: String { rawValue }
}

/// Trigonometric angle unit, mirroring the TI-89's RADIAN/DEGREE mode.
enum CASAngleMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case radians = "RAD"
    case degrees = "DEG"

    var id: String { rawValue }
}

/// One evaluated line in the calculator history.
/// Persisted in `.tcalc` files, so it must stay `Codable` and stable.
struct CalculatorEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// The input exactly as typed on the entry line, e.g. `solve(x^2-4=0,x)`.
    var input: String
    /// Whether this line was forced to an approximate result (⌥↩).
    var approx: Bool
    /// The result rendered as Typst math (empty when the line errored).
    var resultTypst: String
    /// The CAS's plain-text result, e.g. `[x=-2,x=2]`.
    var resultPlain: String
    /// The input rendered as Typst math — used by "Insert Input = Result"
    /// and by "Export as .typ", not by the history (which shows plain text,
    /// like the TI-89's entry line).
    var inputTypst: String
    var isError: Bool
    var errorMessage: String
    var timestamp: Date

    init(id: UUID = UUID(),
         input: String,
         approx: Bool = false,
         resultTypst: String = "",
         resultPlain: String = "",
         inputTypst: String = "",
         isError: Bool = false,
         errorMessage: String = "",
         timestamp: Date = Date()) {
        self.id = id
        self.input = input
        self.approx = approx
        self.resultTypst = resultTypst
        self.resultPlain = resultPlain
        self.inputTypst = inputTypst
        self.isError = isError
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }
}

/// A value the session has stored (`5→a`). Kept as text and replayed through
/// the engine when a saved session is reopened, so a `.tcalc` file never
/// depends on internal representation details.
struct CalculatorStoredVariable: Codable, Hashable, Sendable {
    var name: String
    var value: String

    init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The structured form of an expression as reported by the CAS helper.
/// The helper walks the CAS's own expression graph and emits one of these
/// nodes per subexpression; Swift never parses the printed output.
indirect enum CASExpression: Hashable, Codable, Sendable {
    /// A literal number. `value` is the CAS's exact printing (`1/2`, `7`),
    /// `approx` is the decimal form when it differs (`1.4142…` for √2).
    case number(value: String, approx: String?)
    /// A plain identifier: `x`, `ab`, `alpha`.
    case symbol(String)
    /// A named constant the renderer must typeset specially: `pi`, `e`, `i`,
    /// `infinity`, `true`, `false`, …
    case constant(String)
    case string(String)
    /// An operator with fixed arity: `+`, `-`, `*`, `/`, `^`, `=`, `<`, …
    case operation(name: String, args: [CASExpression])
    /// A function application: `sin(x)`, `solve(eq,x)`, `integrate(f,x,a,b)`.
    case function(name: String, args: [CASExpression])
    /// A comma sequence (multi-result printing).
    case sequence([CASExpression])
    /// A `[...]` vector, or a matrix as a vector of vectors.
    case vector([CASExpression])
    /// A `{...}` set / list.
    case list([CASExpression])
    case undefined
}

// MARK: - JSON decoding (helper protocol v1)

/// Decodes the JSON node objects produced by `typstedit-cas`. Kept separate
/// from `CASExpression` so the wire format can evolve without touching the
/// model the rest of the app sees.
enum CASExpressionDecoder {
    struct DecodingError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Accepts a dictionary-shaped JSON value (`["t": …]`).
    static func decode(_ object: [String: Any]) throws -> CASExpression {
        guard let type = object["t"] as? String else {
            throw DecodingError(message: "CAS node is missing its type tag")
        }
        switch type {
        case "num":
            let value = (object["v"] as? String) ?? ""
            if value.isEmpty { throw DecodingError(message: "number node without a value") }
            return .number(value: value, approx: object["approx"] as? String)
        case "sym":
            guard let name = object["name"] as? String, !name.isEmpty else {
                throw DecodingError(message: "symbol node without a name")
            }
            return .symbol(name)
        case "cst":
            guard let name = object["name"] as? String, !name.isEmpty else {
                throw DecodingError(message: "constant node without a name")
            }
            return .constant(name)
        case "str":
            return .string((object["v"] as? String) ?? "")
        case "op":
            return .operation(name: (object["name"] as? String) ?? "?",
                              args: try decodeArgs(object))
        case "func":
            return .function(name: (object["name"] as? String) ?? "?",
                             args: try decodeArgs(object))
        case "seq":
            return .sequence(try decodeArgs(object))
        case "vect":
            return .vector(try decodeArgs(object))
        case "list":
            return .list(try decodeArgs(object))
        case "undef":
            return .undefined
        default:
            throw DecodingError(message: "unknown CAS node type '\(type)'")
        }
    }

    /// Accepts any JSON value; used for the `args` array entries.
    static func decode(any: Any) throws -> CASExpression {
        if let object = any as? [String: Any] {
            return try decode(object)
        }
        if let string = any as? String {
            // Bare JSON strings are treated as symbols for tolerance.
            return .symbol(string)
        }
        throw DecodingError(message: "unexpected CAS node payload")
    }

    private static func decodeArgs(_ object: [String: Any]) throws -> [CASExpression] {
        guard let args = object["args"] as? [Any] else { return [] }
        return try args.map { try decode(any: $0) }
    }
}

/// The result of one evaluation, as decoded from the helper's reply.
struct CASEvalResult: Sendable {
    var inputTree: CASExpression?
    var resultTree: CASExpression?
    /// Plain-text result as the CAS prints it (already exact/approx-aware).
    var resultText: String
    /// Rendered Typst math for the result; empty when there is none.
    var resultTypst: String
    /// Rendered Typst math for the (unevaluated) input.
    var inputTypst: String
    var errorMessage: String
    var ok: Bool
}
