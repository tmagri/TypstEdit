import XCTest
@testable import TypstEdit

/// macOS `sandbox-exec` is the boundary that keeps an AI math call from
/// touching files or the network.
final class CASEngineSandboxTests: XCTestCase {

    func testSandboxProfileDeniesTheDangerousClasses() {
        let profile = CASEngine.sandboxProfile(helperPath: "/Applications/TypstEdit.app/Contents/Resources/bin/typstedit-cas")
        XCTAssertTrue(profile.contains("(deny network*)"))
        XCTAssertTrue(profile.contains("(deny file-write*)"))
        XCTAssertTrue(profile.contains("(deny process-exec)"))
        XCTAssertTrue(profile.contains("(deny process-fork)"))
        // User data, project folders and configuration stay unreadable.
        XCTAssertTrue(profile.contains("(subpath \"/Users\")"))
        XCTAssertTrue(profile.contains("(subpath \"/Volumes\")"))
        XCTAssertTrue(profile.contains("(subpath \"/private/var/folders\")"))
        // The helper itself must remain runnable.
        XCTAssertTrue(profile.contains("(allow process-exec (literal \"/Applications/TypstEdit.app/Contents/Resources/bin/typstedit-cas\"))"))
    }

    func testSandboxedEvaluationWorksAndIsIsolated() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("CAS helper not built") }
        guard CASEngine.sandboxAvailable else { throw XCTSkip("sandbox-exec unavailable") }
        let engine = CASEngine(sandboxed: true)
        defer { Task { await engine.shutdown() } }

        let result = await engine.eval(input: "solve(x^2-4=0,x)", approx: false,
                                       angle: .radians, digits: 12, timeout: 30)
        XCTAssertTrue(result.ok, result.errorMessage)
        XCTAssertTrue(result.resultText.contains("-2"))
    }

    func testSandboxedEvaluationCannotReadFiles() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("CAS helper not built") }
        guard CASEngine.sandboxAvailable else { throw XCTSkip("sandbox-exec unavailable") }
        let engine = CASEngine(sandboxed: true)
        defer { Task { await engine.shutdown() } }

        // The policy layer already refuses file commands; this proves the
        // second boundary holds even if a command slips through.
        let home = NSHomeDirectory()
        let result = await engine.eval(
            input: "read(\"\(home)/.zshrc\")",
            approx: false, angle: .radians, digits: 12, timeout: 30)
        let text = result.ok ? result.resultText : result.errorMessage
        XCTAssertTrue(text == "undef" || text.isEmpty, "unexpected read result: \(text)")
    }
}
