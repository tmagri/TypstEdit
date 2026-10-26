import Foundation
import CoreFoundation

/// A built-in, read-only chat tool. Each call starts a fresh sandboxed CAS
/// process, so AI calls cannot observe or alter the Calculator panel.
@MainActor
enum CalculatorTool {
    static let namespace = "calculator"
    static let name = "evaluate_math"

    static var descriptor: MCPTool {
        MCPTool(
            serverName: namespace,
            name: name,
            description: """
            Evaluate arithmetic, algebra, calculus, and matrices with the bundled Giac CAS. No Python or project is required.
            Use calculator syntax, not Typst markup. Examples: solve(x^2-4=0,x), d(x^3,x), ∫(x^2,x,0,1), det([[1,2][3,4]]).
            Each call has a fresh context. Use single-letter variables, optional numeric suffixes, or named math constants.
            Stored variables, ans, entry, strings, assignments, programs, file access, and network access are not supported.
            Returns JSON with ok, result (plain text), typst (math without dollar delimiters), and input_typst.
            For document changes, use the returned Typst with the approved file tools. A calculation does not modify the document.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "expression": ["type": "string", "description": "One math expression, up to 4096 bytes."],
                    "approx": ["type": "boolean", "description": "Return a decimal approximation. Default false (exact)."],
                    "angle": ["type": "string", "enum": ["rad", "deg"], "description": "Trigonometric angle unit. Default rad."],
                    "digits": ["type": "integer", "minimum": 1, "maximum": 15, "description": "Significant digits for approximate results. Default 12."]
                ],
                "required": ["expression"],
                "additionalProperties": false
            ])
    }

    static func evaluate(_ arguments: [String: Any]) async throws -> String {
        let knownKeys: Set<String> = ["expression", "approx", "angle", "digits"]
        guard Set(arguments.keys).isSubset(of: knownKeys),
              let expression = arguments["expression"] as? String else {
            throw LocalToolError.invalidArguments("expression is required. Permitted options: approx, angle, digits.")
        }
        let prepared: String
        do { prepared = try CalculatorMathPolicy.prepare(expression) }
        catch { throw LocalToolError.invalidArguments(error.localizedDescription) }

        var approx = false
        if let raw = arguments["approx"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw LocalToolError.invalidArguments("approx must be a boolean.")
            }
            approx = number.boolValue
        }
        let angleString = arguments["angle"] as? String ?? "rad"
        guard arguments["angle"] == nil || arguments["angle"] is String,
              angleString == "rad" || angleString == "deg" else {
            throw LocalToolError.invalidArguments("angle must be rad or deg.")
        }
        var digits = 12
        if let raw = arguments["digits"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue,
                  (1...15).contains(number.doubleValue) else {
                throw LocalToolError.invalidArguments("digits must be an integer from 1 to 15.")
            }
            digits = number.intValue
        }

        let engine = CASEngine(sandboxed: true)
        let result = await engine.eval(input: prepared, approx: approx,
                                       angle: angleString == "deg" ? .degrees : .radians,
                                       digits: digits, timeout: 10)
        await engine.shutdown()
        if !result.ok {
            return try json(["ok": false, "error": result.errorMessage])
        }
        // Do not return truncated Typst that the agent can accidentally put
        // into a document. Ask for a smaller expression instead.
        let outputBytes = result.resultText.utf8.count + result.resultTypst.utf8.count + result.inputTypst.utf8.count
        guard outputBytes <= CalculatorMathPolicy.maximumOutputBytes else {
            return try json(["ok": false, "error": "The result exceeds the output limit. Use a smaller expression."])
        }
        return try json([
            "ok": true,
            "result": result.resultText,
            "typst": result.resultTypst,
            "input_typst": result.inputTypst,
            "approx": approx,
            "angle": angleString,
            "digits": digits
        ])
    }

    private static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
