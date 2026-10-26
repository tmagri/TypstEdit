import XCTest
@testable import TypstEdit

/// The chat-side math tool: available without a project, no approval prompts,
/// validated input, and isolated from the Calculator panel.
@MainActor
final class CalculatorToolTests: XCTestCase {

    func testDescriptorIdentityAndSchema() {
        let tool = CalculatorTool.descriptor
        XCTAssertEqual(tool.qualifiedName, "calculator__evaluate_math")
        let schema = tool.inputSchema
        XCTAssertEqual(schema["required"] as? [String], ["expression"])
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["expression"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

    func testRegisteredForAStandaloneChat() {
        let standalone = LocalToolExecutor()
        let tool = standalone.toolDescriptors().first { $0.name == "evaluate_math" }
        XCTAssertEqual(tool?.serverName, "calculator")
    }

    func testRegisteredForProjectChat() {
        let executor = LocalToolExecutor()
        executor.scope = .project(root: FileManager.default.temporaryDirectory)
        XCTAssertTrue(executor.toolDescriptors().contains { $0.qualifiedName == "calculator__evaluate_math" })
    }

    func testSubagentToolsIncludeMathButNoWritersOrRunner() {
        let names = AIChatManager.subagentReadOnlyToolNames
        XCTAssertTrue(names.contains(CalculatorTool.name))
        XCTAssertFalse(names.contains("write_file"))
        XCTAssertFalse(names.contains("edit_file"))
        XCTAssertFalse(names.contains("run"))
        XCTAssertFalse(names.contains("delegate_task"))
    }

    func testEvaluationRequiresNoApprovalAndReturnsResult() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("CAS helper not built") }
        let executor = LocalToolExecutor()
        let output = try await executor.execute(
            toolName: CalculatorTool.name,
            arguments: ["expression": "2+2"]
        ) { _ in
            XCTFail("Math evaluation must not request approval")
            return false
        }
        let payload = try decode(output)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["result"] as? String, "4")
        XCTAssertEqual(payload["typst"] as? String, "4")
        XCTAssertEqual(payload["angle"] as? String, "rad")
    }

    func testSolvedEquationReturnsEquationMath() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("CAS helper not built") }
        let output = try await CalculatorTool.evaluate(["expression": "solve(x^2-4=0,x)"])
        let payload = try decode(output)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertTrue((payload["typst"] as? String ?? "").contains("-2"))
    }

    func testApproximateAndAngleOptions() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("CAS helper not built") }
        let exact = try decode(try await CalculatorTool.evaluate(["expression": "2/3"]))
        XCTAssertEqual(exact["result"] as? String, "2/3")

        let decimal = try decode(try await CalculatorTool.evaluate([
            "expression": "2/3", "approx": true, "digits": 5
        ]))
        XCTAssertEqual(decimal["approx"] as? Bool, true)
        XCTAssertTrue((decimal["result"] as? String ?? "").hasPrefix("0.666"))

        let degrees = try decode(try await CalculatorTool.evaluate([
            "expression": "sin(30)", "angle": "deg", "approx": true
        ]))
        XCTAssertEqual(degrees["result"] as? String, "0.5")
    }

    func testRejectionsThrowInvalidArguments() async {
        let cases: [[String: Any]] = [
            [:],
            ["expression": ""],
            ["expression": "2+2", "approx": "yes"],
            ["expression": "2+2", "angle": "gradians"],
            ["expression": "2+2", "digits": 50],
            ["expression": "2+2", "digits": 2.5],
            ["expression": "system(\"ls\")"],
            ["expression": "5→a"],
            ["expression": "2+2", "unexpected": 1],
        ]
        for arguments in cases {
            do {
                _ = try await CalculatorTool.evaluate(arguments)
                XCTFail("Expected rejection for \(arguments)")
            } catch let error as LocalToolError {
                if case .invalidArguments = error {} else {
                    XCTFail("Unexpected error for \(arguments): \(error)")
                }
            } catch {
                XCTFail("Unexpected error type for \(arguments): \(error)")
            }
        }
    }

    func testPanelAndChatContextsAreIsolated() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("CAS helper not built") }
        let store = await CASEngine.shared.eval(
            input: "42►q", approx: false, angle: .radians, digits: 12, timeout: 10)
        XCTAssertTrue(store.ok, store.errorMessage)

        // A fresh sandboxed engine must not see the panel's variables.
        let isolated = try decode(try await CalculatorTool.evaluate(["expression": "q"]))
        XCTAssertEqual(isolated["result"] as? String, "q")

        // And it must not change them.
        do {
            _ = try await CalculatorTool.evaluate(["expression": "7►q"])
            XCTFail("Assignments must be refused by the policy")
        } catch {}
        let check = await CASEngine.shared.eval(
            input: "q", approx: false, angle: .radians, digits: 12, timeout: 10)
        XCTAssertEqual(check.resultText, "42")
        _ = await CASEngine.shared.eval(
            input: "purge(q)", approx: false, angle: .radians, digits: 12, timeout: 5)
    }

    private func decode(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
