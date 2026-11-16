import XCTest
@testable import TypstEdit

/// `SafetyMonitor`: the rules that can send a YOLO-skipped card back to the
/// human. The important property is that a hit can only ever *add* a card,
/// never remove one — so most of these tests assert that
/// `canAutoApprove` turns false.
@MainActor
final class SafetyMonitorTests: XCTestCase {

    private func call(_ name: String, args: [String: String] = [:], status: ChatMessage.ToolStatus = .succeeded, output: String = "ok") -> SafetyTrace.ToolCall {
        let json = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return SafetyTrace.ToolCall(name: name, argumentsJSON: json, status: status, output: output)
    }

    private func trace(_ calls: [SafetyTrace.ToolCall]) -> SafetyTrace {
        SafetyTrace(task: "test", toolCalls: calls)
    }

    override func tearDown() {
        SafetyMonitor.humanApprovedWebHosts = []
        super.tearDown()
    }

    /// A kind YOLO may normally automate: a project file write.
    private var plainWrite: PendingApprovalKind {
        .fileWrite(relativePath: "notes/a.md", oldContent: "", newContent: "x", isNewFile: true)
    }

    // MARK: - Detectors

    func testToolsCalledRequiresTheCallToHaveRun() {
        let skipped = trace([call("\(SafetyMonitor.pythonPrefix)run", status: .skipped)])
        XCTAssertFalse(AttackDetector.toolsCalled(["python__run"])(skipped),
                       "a skipped call never ran")
        let ran = trace([call("\(SafetyMonitor.pythonPrefix)run", status: .succeeded)])
        XCTAssertTrue(AttackDetector.toolsCalled(["python__run"])(ran))
    }

    func testCountToolCallsIsStrictlyGreaterThanThreshold() {
        let three = trace(Array(repeating: call("project__write_file"), count: 3))
        let four = trace(Array(repeating: call("project__write_file"), count: 4))
        let detector = AttackDetector.countToolCalls("project__write_file", threshold: 3)
        XCTAssertFalse(detector(three))
        XCTAssertTrue(detector(four))
    }

    func testAllOfRequiresEveryDetector() {
        let onlyRead = trace([call("project__read_file", args: ["path": ".env"])])
        let readThenFetch = trace([
            call("project__read_file", args: ["path": ".env"]),
            call("project__web_fetch", args: ["url": "https://example.com"]),
        ])
        let detector = SafetyMonitor.builtInRules.first { $0.id == "credential_read_then_egress" }!.detector
        XCTAssertFalse(detector(onlyRead), "a secret read alone is not exfiltration")
        XCTAssertTrue(detector(readThenFetch))
    }

    func testSecretPathPatternMatchesCredentialNames() {
        let detector = SafetyMonitor.builtInRules.first { $0.id == "credential_read_then_egress" }!
            .detector
        for path in [".env", "id_rsa", "certs/server.pem", "credentials.json", "auth/token.txt"] {
            let trace = trace([
                call("project__read_file", args: ["path": path]),
                call("project__web_fetch", args: ["url": "https://example.com"]),
            ])
            XCTAssertTrue(detector(trace), "\(path) should look like a credential")
        }
        let harmless = trace([
            call("project__read_file", args: ["path": "notes/a.typ"]),
            call("project__web_fetch", args: ["url": "https://example.com"]),
        ])
        XCTAssertFalse(detector(harmless))
    }

    func testPrivateKeyInOutputIsCaught() {
        let detector = AttackDetector.logContains("(-----BEGIN [A-Z ]*PRIVATE KEY-----|password\\s*[:=]\\s*\\S+)", caseSensitive: false)
        let leaky = trace([call("project__read_file", output: "-----BEGIN RSA PRIVATE KEY-----\nMIIE…")])
        XCTAssertTrue(detector(leaky))
        let password = trace([call("python__run", output: "PASSWORD=hunter2")])
        XCTAssertTrue(detector(password))
        let clean = trace([call("project__read_file", output: "Just some prose.")])
        XCTAssertFalse(detector(clean))
    }

    // MARK: - The gate

    func testSafetyHitTakesBackAYoloAutoApproval() {
        // The built-in sweep rule fires on the fifth write (`count > 4`), the
        // same threshold Clippy ships: four writes is still YOLO's business.
        let sweep = trace(Array(repeating: call("project__write_file"), count: 5))
        XCTAssertTrue(plainWrite.canAutoApprove(yoloMode: true), "YOLO alone would skip the card")
        XCTAssertFalse(SafetyMonitor.canAutoApprove(
            kind: plainWrite, yoloMode: true, rules: [], trace: sweep, userRules: []
        ), "the sweep rule must bring the card back")
        let fourWrites = trace(Array(repeating: call("project__write_file"), count: 4))
        XCTAssertTrue(SafetyMonitor.canAutoApprove(
            kind: plainWrite, yoloMode: true, rules: [], trace: fourWrites, userRules: []
        ), "four writes is below the sweep threshold")
    }

    func testCleanTraceKeepsYoloFast() {
        let clean = trace([call("project__read_file")])
        XCTAssertTrue(SafetyMonitor.canAutoApprove(
            kind: plainWrite, yoloMode: true, rules: [], trace: clean, userRules: []
        ))
    }

    // MARK: - The Settings toggle

    func testDisabledMonitorLetsYoloDecideAlone() {
        let sweep = trace(Array(repeating: call("project__write_file"), count: 5))
        XCTAssertFalse(SafetyMonitor.canAutoApprove(
            kind: plainWrite, yoloMode: true, rules: [], trace: sweep, userRules: [], monitorEnabled: true
        ))
        XCTAssertTrue(SafetyMonitor.canAutoApprove(
            kind: plainWrite, yoloMode: true, rules: [], trace: sweep, userRules: [], monitorEnabled: false
        ), "with the monitor off, YOLO decides on its own")
    }

    func testDisabledMonitorStillHonoursADenyRule() {
        let deny = PermissionRule(action: .edit, pattern: "notes/*", effect: .deny)
        XCTAssertFalse(SafetyMonitor.canAutoApprove(
            kind: plainWrite, yoloMode: true, rules: [deny], trace: trace([]),
            userRules: [], monitorEnabled: false
        ), "a deny rule is not part of the safety monitor and still refuses")
    }

    // MARK: - Signed-in fetches

    func testSignedInFetchIsNeverAutomatedWithoutAHandApproval() {
        let signedIn = PendingApprovalKind.webFetch(url: "https://example.com/page", savedSignInHost: "example.com")
        SafetyMonitor.humanApprovedWebHosts = []
        XCTAssertFalse(SafetyMonitor.canAutoApprove(
            kind: signedIn, yoloMode: true, rules: [], trace: trace([]), userRules: []
        ), "a credentialed fetch is not automated on the cookies alone")
    }

    func testSignedInFetchIsAutomatedOnceTheHostWasApprovedByHand() {
        let signedIn = PendingApprovalKind.webFetch(url: "https://example.com/page", savedSignInHost: "example.com")
        SafetyMonitor.humanApprovedWebHosts = ["example.com"]
        XCTAssertTrue(SafetyMonitor.canAutoApprove(
            kind: signedIn, yoloMode: true, rules: [], trace: trace([]), userRules: []
        ))
    }

    func testAnAllowRuleCannotSupplyTheHandApproval() {
        let allow = PermissionRule(action: .webfetch, pattern: "*", effect: .allow)
        let signedIn = PendingApprovalKind.webFetch(url: "https://example.com/page", savedSignInHost: "example.com")
        SafetyMonitor.humanApprovedWebHosts = []
        XCTAssertFalse(SafetyMonitor.canAutoApprove(
            kind: signedIn, yoloMode: true, rules: [allow], trace: trace([]), userRules: []
        ))
    }

    func testPlainFetchIsUnaffectedByTheSignInGate() {
        let plain = PendingApprovalKind.webFetch(url: "https://example.com/page", savedSignInHost: nil)
        SafetyMonitor.humanApprovedWebHosts = []
        XCTAssertTrue(SafetyMonitor.canAutoApprove(
            kind: plain, yoloMode: true, rules: [], trace: trace([]), userRules: []
        ))
    }

    func testHandApprovedHostsComeFromSucceededFetchesOnly() {
        var approved = ChatMessage(role: .toolCall)
        approved.toolName = "project__web_fetch"
        approved.toolArgumentsJSON = #"{"url":"https://example.com/a"}"#
        approved.toolStatus = .succeeded
        var refused = ChatMessage(role: .toolCall)
        refused.toolName = "project__web_fetch"
        refused.toolArgumentsJSON = #"{"url":"https://other.test/b"}"#
        refused.toolStatus = .denied
        var subagent = ChatMessage(role: .toolCall)
        subagent.toolName = "project__web_fetch"
        subagent.toolArgumentsJSON = #"{"url":"https://nested.test/c"}"#
        subagent.toolStatus = .succeeded
        subagent.isSubagent = true

        let hosts = SafetyMonitor.humanApprovedWebHosts(in: [approved, refused, subagent])
        XCTAssertEqual(hosts, ["example.com"],
                       "a refusal is not permission, and a subagent's fetch is not the user's decision")
    }

    func testMonitorCanOnlyNarrowNeverWiden() {
        // No YOLO, no rule: a clean trace must still ask.
        XCTAssertFalse(SafetyMonitor.canAutoApprove(
            kind: plainWrite, yoloMode: false, rules: [], trace: trace([]), userRules: []
        ), "the monitor must never approve a call the user would have been asked about")
    }

    func testDenyRuleRefusesEvenWithACleanTrace() {
        let deny = PermissionRule(action: .edit, pattern: "notes/*", effect: .deny)
        XCTAssertFalse(SafetyMonitor.canAutoApprove(
            kind: plainWrite, yoloMode: true, rules: [deny], trace: trace([]), userRules: []
        ))
    }

    func testAllowRuleSkipsTheCardWhenNothingFires() {
        let allow = PermissionRule(action: .edit, pattern: "notes/*", effect: .allow)
        XCTAssertTrue(SafetyMonitor.canAutoApprove(
            kind: plainWrite, yoloMode: false, rules: [allow], trace: trace([]), userRules: []
        ))
    }

    func testUserRuleFires() {
        let userRule = UserSafetyRule(
            title: "Never run scripts",
            kind: .toolCalled,
            toolName: "python__run"
        )
        XCTAssertNotNil(userRule.makeRule())
        let ran = trace([call("python__run")])
        XCTAssertFalse(SafetyMonitor.canAutoApprove(
            kind: plainWrite, yoloMode: true, rules: [], trace: ran, userRules: [userRule]
        ))
        XCTAssertTrue(SafetyMonitor.canAutoApprove(
            kind: plainWrite, yoloMode: true, rules: [], trace: trace([]), userRules: [userRule]
        ))
    }

    // MARK: - Half-written rules are skipped

    func testUserRuleWithEmptyToolNameMatchesNothing() {
        let sloppy = UserSafetyRule(title: "Everything", kind: .toolCalled, toolName: "   ")
        XCTAssertNil(sloppy.makeRule(), "a blank tool name would match every call")
        XCTAssertTrue(SafetyMonitor.canAutoApprove(
            kind: plainWrite, yoloMode: true, rules: [], trace: trace([]), userRules: [sloppy]
        ))
    }

    func testOutputRuleWithInvalidRegexIsSkipped() {
        let broken = UserSafetyRule(title: "Bad regex", kind: .outputMatched, pattern: "([unclosed")
        XCTAssertNil(broken.makeRule())
    }

    func testDisabledUserRuleIsIgnored() {
        var disabled = UserSafetyRule(title: "Off", kind: .toolCalled, toolName: "python__run")
        disabled.isEnabled = false
        let ran = trace([call("python__run")])
        XCTAssertEqual(SafetyMonitor.rules(userRules: [disabled]).count, SafetyMonitor.builtInRules.count)
        XCTAssertFalse(SafetyMonitor.hits(for: ran, userRules: [disabled]).contains { $0.title == "Off" })
    }

    // MARK: - Trace selection

    func testCurrentTurnTraceIgnoresEarlierTurns() {
        var messages: [ChatMessage] = []
        var earlier = ChatMessage(role: .toolCall)
        earlier.toolName = "project__read_file"
        earlier.toolStatus = .succeeded
        messages.append(earlier)
        messages.append(ChatMessage(role: .user, text: "now do something else"))

        XCTAssertTrue(SafetyTrace.currentTurnTrace(from: messages).toolCalls.isEmpty,
                      "a .env read in an earlier turn must not veto this turn's YOLO")
    }

    func testTraceSkipsPlanUpdates() {
        var planCall = ChatMessage(role: .toolCall)
        planCall.toolName = "\(AgentHarnessTools.namespace)__update_plan"
        planCall.toolStatus = .succeeded
        var write = ChatMessage(role: .toolCall)
        write.toolName = "project__write_file"
        write.toolStatus = .succeeded
        let trace = SafetyTrace.from(messages: [planCall, write])
        XCTAssertEqual(trace.toolCalls.count, 1)
        XCTAssertEqual(trace.toolCalls.first?.name, "project__write_file")
    }

    // MARK: - Namespace agreement

    func testNamespacePrefixesMatchTheExecutors() {
        XCTAssertEqual(SafetyMonitor.projectPrefix, LocalToolExecutor.namespace + "__")
        XCTAssertEqual(SafetyMonitor.pythonPrefix, LocalToolExecutor.pythonNamespace + "__")
        XCTAssertEqual(SafetyMonitor.gitPrefix, GitTools.namespace + "__")
        XCTAssertEqual(SafetyMonitor.networkTools, ["project__web_fetch"])
    }
}
