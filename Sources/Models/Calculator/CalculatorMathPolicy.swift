import Foundation

/// Restrict AI calls to math expressions. Giac also has programming and file
/// commands, which must never be available through the chat math tool.
/// The OS sandbox is a separate boundary, not a replacement for this check.
enum CalculatorMathPolicy {
    static let maximumInputBytes = 4_096
    static let maximumOutputBytes = 20_000

    /// Only audited, mathematical builtins. Do not add eval, map, apply,
    /// programming, context-changing, file, shell, or network commands here.
    static let functions: Set<String> = [
        "solve", "csolve", "zeros", "cZeros", "fsolve", "factor", "expand",
        "normal", "propfrac", "texpand", "simplify", "collect", "coeff",
        "degree", "subst", "diff", "integrate", "limit", "sum", "product",
        "taylor", "series", "approx", "evalf", "exact", "abs", "sqrt",
        "root", "exp", "ln", "log", "log10", "sin", "cos", "tan",
        "asin", "acos", "atan", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
        "floor", "ceil", "ceiling", "round", "sign", "min", "max",
        "gcd", "lcm", "irem", "iquo", "isprime", "ifactor", "factorial",
        "binomial", "numer", "denom", "re", "im", "conj", "arg",
        "det", "transpose", "inv", "inverse", "rref", "rank", "trace",
        "identity", "diag", "eigenvals", "eigenvects", "cross", "dot",
        "norm", "matrix", "mean", "median", "stddev", "variance", "sort"
    ]

    private static let constants: Set<String> = [
        "pi", "e", "i", "infinity", "inf", "true", "false", "undef",
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
        "iota", "kappa", "lambda", "mu", "nu", "xi", "rho", "sigma",
        "tau", "upsilon", "phi", "chi", "psi", "omega", "and", "or", "not"
    ]

    struct Rejection: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Return engine syntax after validating a single, stateless expression.
    static func prepare(_ expression: String) throws -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Rejection(message: "expression is required.") }
        guard trimmed.utf8.count <= maximumInputBytes else {
            throw Rejection(message: "The expression exceeds the 4096-byte limit.")
        }
        let prepared = TISyntax.preprocess(trimmed)
            .replacingOccurrences(of: "∫", with: "integrate")
            .replacingOccurrences(of: "√", with: "sqrt")
        guard !prepared.contains("//"), !prepared.contains("/*"), !prepared.contains("*/") else {
            throw Rejection(message: "Comments are not permitted in math expressions.")
        }
        let characters = Array(prepared)
        var delimiters: [Character] = []
        var index = 0
        let operators: Set<Character> = ["+", "-", "*", "/", "^", "=", "<", ">", "!", "|", "%", ".", ","]
        while index < characters.count {
            let character = characters[index]
            if character.isLetter || character == "_" {
                let start = index
                while index < characters.count && (characters[index].isLetter || characters[index].isNumber || characters[index] == "_") {
                    index += 1
                }
                let name = String(characters[start..<index])
                var next = index
                while next < characters.count && characters[next].isWhitespace { next += 1 }
                if next < characters.count && characters[next] == "(" {
                    guard functions.contains(name) else {
                        throw Rejection(message: "The math tool does not permit the function '\(name)'.")
                    }
                } else {
                    // Single-letter variables with an optional index:
                    // x, a, y2, x_1. Anything longer could name a command.
                    let isVariable = name.range(of: "^[A-Za-z](_?[0-9]+)?$", options: .regularExpression) != nil
                    guard isVariable || constants.contains(name) else {
                        throw Rejection(message: "Use single-letter variables, optional numeric suffixes, or named math constants. '\(name)' is not permitted.")
                    }
                }
                continue
            }
            if character == "(" || character == "[" || character == "{" {
                delimiters.append(character)
                guard delimiters.count <= 64 else {
                    throw Rejection(message: "The expression exceeds the nesting limit.")
                }
            } else if character == ")" || character == "]" || character == "}" {
                let expected: Character = character == ")" ? "(" : (character == "]" ? "[" : "{")
                guard delimiters.popLast() == expected else {
                    throw Rejection(message: "The expression has mismatched brackets.")
                }
            } else if character == ";" {
                guard delimiters.last == "[" else {
                    throw Rejection(message: "A semicolon is permitted only between matrix rows.")
                }
            } else if !character.isWhitespace && !character.isNumber && !operators.contains(character) {
                throw Rejection(message: "The math tool does not permit '\(character)'. Strings, assignments, and programs are not supported.")
            }
            index += 1
        }
        guard delimiters.isEmpty else { throw Rejection(message: "The expression has unclosed brackets.") }
        return prepared
    }
}
