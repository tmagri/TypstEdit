import XCTest
@testable import TypstEdit

/// `code__execute` is the one tool whose failure mode is silent: it returns a
/// string either way, so "the script did nothing" looks exactly like "the
/// script found nothing". These tests pin the behaviours a caller has to be
/// able to trust — the value comes back, the calls are recorded, an error is
/// reported rather than swallowed, and a runaway script cannot wedge the app.
@MainActor
final class CodeModeRunnerTests: XCTestCase {

    private func runner() -> CodeModeRunner {
        CodeModeRunner()
    }

    private func tools(_ names: [(String, String)]) -> [CodeModeRunner.ExposedTool] {
        names.map { pair in
            CodeModeRunner.ExposedTool(
                namespace: pair.0,
                name: pair.1,
                qualifiedName: "\(pair.0)__\(pair.1)"
            )
        }
    }

    // MARK: - Values

    func testRunsPlainJavaScriptAndReturnsTheValue() async {
        let outcome = await runner().run(code: "return 1 + 2", tools: []) { _, _ in "" }
        XCTAssertEqual(outcome.output, "3")
        XCTAssertTrue(outcome.calls.isEmpty)
    }

    func testTopLevelAwaitIsAvailable() async {
        let outcome = await runner().run(code: "const value = await Promise.resolve(41); return value + 1", tools: []) { _, _ in "" }
        XCTAssertEqual(outcome.output, "42")
    }

    func testReturnedObjectIsPrettyPrintedJSON() async {
        let outcome = await runner().run(code: "return { total: 13, names: ['a'] }", tools: []) { _, _ in "" }
        XCTAssertTrue(outcome.output.contains("\"total\": 13"), outcome.output)
        XCTAssertTrue(outcome.output.contains("\"a\""), outcome.output)
    }

    /// Every tool returns text, so a string result must not arrive quoted.
    func testStringResultIsNotJSONQuoted() async {
        let outcome = await runner().run(
            code: "return await tools.reference.read_file({ path: 'notes.md' })",
            tools: tools([("reference", "read_file")])
        ) { name, _ in "line one\nline two" }

        XCTAssertEqual(outcome.output, "line one\nline two\n\nTool calls made by the script (oldest first):\n- reference__read_file → line one line two")
    }

    func testScriptWithNoReturnSaysSo() async {
        let outcome = await runner().run(code: "const unused = 1;", tools: []) { _, _ in "" }
        XCTAssertTrue(outcome.output.contains("without returning a value"), outcome.output)
    }

    // MARK: - Tool calls

    func testNestedCallReceivesArgumentsAndItsResultFlowsBack() async {
        var seen: [(String, String)] = []
        let outcome = await runner().run(
            code: """
            const text = await tools.reference.read_file({ path: 'notes/todo.md', start_line: 2 });
            return text.toUpperCase();
            """,
            tools: tools([("reference", "read_file")])
        ) { name, arguments in
            seen.append((name, arguments))
            return "hello"
        }

        XCTAssertEqual(outcome.output, "HELLO\n\nTool calls made by the script (oldest first):\n- reference__read_file → hello")
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, "reference__read_file")
        // The arguments are JSON the tool can parse, exactly as written.
        let parsed = try? JSONSerialization.jsonObject(with: Data((seen.first?.1 ?? "").utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["path"] as? String, "notes/todo.md")
        XCTAssertEqual(parsed?["start_line"] as? Int, 2)
    }

    /// The point of the whole feature: six reads, one round.
    func testIndependentCallsRunConcurrentlyAndAreAllRecorded() async {
        let names = (1...6).map { ("reference", "read_file_\($0)") }
        let outcome = await runner().run(
            code: """
            const results = await Promise.all([1, 2, 3, 4, 5, 6].map((n) => tools.reference['read_file_' + n]({ n })));
            return results.length;
            """,
            tools: tools(names)
        ) { _, arguments in
            "read \(arguments)"
        }

        XCTAssertTrue(outcome.output.hasPrefix("6"), outcome.output)
        XCTAssertEqual(outcome.calls.count, 6)
    }

    func testToolErrorPropagatesToTheScriptsCatch() async {
        let outcome = await runner().run(
            code: """
            try {
              await tools.python.run({ code: 'print(1)' });
              return 'the call should not have succeeded';
            } catch (error) {
              return 'caught: ' + error;
            }
            """,
            tools: tools([("python", "run")])
        ) { _, _ in
            // `executeTool` reports a declined approval this way.
            "Error: The user declined this tool call."
        }

        // The host's error text reaches the script, so the model can react to
        // a declined approval instead of silently continuing.
        XCTAssertTrue(outcome.output.contains("caught: The user declined"), outcome.output)
    }

    func testUncaughtErrorIsReportedWithTheCallSummary() async {
        let outcome = await runner().run(
            code: """
            await tools.reference.read_file({ path: 'a.md' });
            throw new Error('the file had no headings');
            """,
            tools: tools([("reference", "read_file")])
        ) { _, _ in "ok" }

        XCTAssertTrue(outcome.output.contains("the file had no headings"), outcome.output)
        XCTAssertTrue(outcome.output.contains("reference__read_file"), outcome.output)
    }

    func testHiddenHostBindingsExplainThemselves() async {
        let outcome = await runner().run(code: "try { fetch('https://example.com'); } catch (error) { return String(error.message); }", tools: []) { _, _ in "" }
        XCTAssertTrue(outcome.output.contains("not available in code mode"), outcome.output)
        XCTAssertTrue(outcome.output.contains("tools."), outcome.output)
    }

    // MARK: - Limits

    func testRunawayLoopIsStoppedByTheWatchdog() async {
        let outcome = await runner().run(code: "while (true) {}", tools: [], budget: 0.5) { _, _ in "" }
        XCTAssertTrue(outcome.output.contains("endless loop"), outcome.output)
    }

    /// A script that has already made its calls must still report them when
    /// it is stopped: the model needs to know what really ran.
    func testStoppedScriptStillReportsItsCalls() async {
        let outcome = await runner().run(
            code: """
            await tools.reference.read_file({ path: 'a.md' });
            while (true) {}
            """,
            tools: tools([("reference", "read_file")]),
            budget: 0.5
        ) { _, _ in "read a.md" }

        XCTAssertTrue(outcome.output.contains("endless loop"), outcome.output)
        XCTAssertTrue(outcome.output.contains("reference__read_file"), outcome.output)
    }

    /// The case that used to hang the app: the runaway loop starts *after* an
    /// await, so it runs inside promise resolution rather than the initial
    /// evaluate. The watchdog has to cover that too.
    func testRunawayLoopAfterAnAwaitIsStopped() async {
        let outcome = await runner().run(
            code: """
            const value = await tools.reference.read_file({ path: 'a.md' });
            while (true) {}
            """,
            tools: tools([("reference", "read_file")]),
            budget: 0.5
        ) { _, _ in "read a.md" }

        XCTAssertTrue(outcome.output.contains("endless loop"), outcome.output)
    }

    func testNestedCallsAreCapped() async {
        var calls = 0
        let outcome = await runner().run(
            code: """
            const results = [];
            for (let i = 0; i < 200; i += 1) {
              try { results.push(await tools.reference.read_file({ n: i })); }
              catch (error) { results.push(String(error)); }
            }
            return {
              errors: results.filter((r) => r.includes('limit')).length,
              reads: results.filter((r) => r === 'ok').length
            };
            """,
            tools: tools([("reference", "read_file")])
        ) { _, _ in
            calls += 1
            return "ok"
        }

        // The cap holds: the tool ran exactly the budget, and every further
        // call was refused with a message the model can act on rather than
        // silently dropped.
        XCTAssertEqual(calls, CodeModeRunner.maxNestedCalls)
        XCTAssertTrue(outcome.output.contains("\"reads\": \(CodeModeRunner.maxNestedCalls)"), outcome.output)
        XCTAssertTrue(outcome.output.contains("\"errors\": \(200 - CodeModeRunner.maxNestedCalls)"), outcome.output)
    }

    func testHugeResultIsTruncated() async {
        let outcome = await runner().run(code: "return 'x'.repeat(50000)", tools: []) { _, _ in "" }
        XCTAssertTrue(outcome.output.contains("truncated"), outcome.output)
        XCTAssertLessThan(outcome.output.count, CodeModeRunner.maxOutputChars + 200)
    }

    // MARK: - Rendering

    func testCallSummaryListsCallsOldestFirst() {
        let summary = CodeModeRunner.callSummary([
            .init(tool: "reference__grep", argumentsJSON: "{}", outcome: "3 matches"),
            .init(tool: "reference__read_file", argumentsJSON: "{}", outcome: "read 40 lines"),
        ])
        XCTAssertEqual(summary, """
        Tool calls made by the script (oldest first):
        - reference__grep → 3 matches
        - reference__read_file → read 40 lines
        """)
    }

    func testLongOutcomeIsShortenedToOneLine() {
        let line = CodeModeRunner.oneLine(String(repeating: "a", count: 400) + "\nsecond")
        XCTAssertEqual(line.count, 121)
        XCTAssertTrue(line.hasSuffix("…"))
        XCTAssertFalse(line.contains("\n"))
    }

    func testWatchdogIsAvailableOnThisMac() {
        // If the SPI ever disappears the feature still works, but the model
        // loses the endless-loop guard — worth knowing in a test run.
        XCTAssertTrue(Watchdog().isAvailable)
    }
}

private enum TestError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// The plan-mode boundary around code mode: the descriptor is withheld and
/// the dispatch-time check refuses it, so a script can never compose a
/// write the mode just withheld.
@MainActor
final class CodeModePlanBoundaryTests: XCTestCase {
    func testPlanModeBlocksCodeExecute() {
        XCTAssertTrue(AIChatManager.isPlanModeBlockedTool("code__execute"))
        XCTAssertFalse(AIChatManager.isPlanModeBlockedTool("agent__recall"))
    }

    func testCodeModeCanCallExcludesTheInterpreterAndQuestions() {
        XCTAssertFalse(AgentHarnessTools.codeModeCanCall("code__execute"))
        XCTAssertFalse(AgentHarnessTools.codeModeCanCall("agent__ask_question"))
        XCTAssertTrue(AgentHarnessTools.codeModeCanCall("project__read_file"))
        XCTAssertTrue(AgentHarnessTools.codeModeCanCall("agent__update_plan"))
    }

    func testCatalogListingDegradesPastTheBudget() {
        let tools = (1...80).map { MCPTool(serverName: "srv", name: "tool_\($0)", description: "d", inputSchema: ["type": "object"]) }
        let listing = AgentHarnessTools.catalogListing(tools, budget: 300)
        XCTAssertTrue(listing.contains("80 tools"), listing)
        XCTAssertFalse(listing.contains("tool_1("), listing)
    }
}
