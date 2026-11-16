import XCTest
@testable import TypstEdit

/// `PermissionRules`: the saved "Always allow…" / "Deny" answers to approval
/// cards. Everything here is pure and offline — no Keychain, no UserDefaults,
/// no approval queue.
@MainActor
final class PermissionRulesTests: XCTestCase {

    private func rule(_ action: PermissionRule.Action, _ pattern: String, _ effect: PermissionRule.Effect) -> PermissionRule {
        PermissionRule(action: action, pattern: pattern, effect: effect)
    }

    // MARK: - Wildcards

    func testWildcardMatchIsWholeValue() {
        XCTAssertTrue(PermissionRules.matches(pattern: "*", value: "anything/at/all"))
        XCTAssertTrue(PermissionRules.matches(pattern: "notes/*", value: "notes/a.md"))
        XCTAssertTrue(PermissionRules.matches(pattern: "notes/*", value: "notes/deep/a.md"),
                      "* spans / as well")
        XCTAssertFalse(PermissionRules.matches(pattern: "notes/*", value: "drafts/a.md"))
        XCTAssertFalse(PermissionRules.matches(pattern: "notes", value: "notes/a.md"))
        XCTAssertTrue(PermissionRules.matches(pattern: "a?c", value: "abc"))
        XCTAssertFalse(PermissionRules.matches(pattern: "a?c", value: "ac"))
    }

    func testEscapedWildcardIsLiteral() {
        XCTAssertTrue(PermissionRules.matches(pattern: "a\\*b", value: "a*b"))
        XCTAssertFalse(PermissionRules.matches(pattern: "a\\*b", value: "axxb"))
    }

    func testWildcardNeverBacktracksExponentially() {
        // A pattern of many stars against a long non-matching string must be
        // linear-ish; this would hang a naive recursive matcher.
        let pattern = String(repeating: "*a", count: 40)
        let value = String(repeating: "b", count: 4_000)
        XCTAssertFalse(PermissionRules.matches(pattern: pattern, value: value))
    }

    // MARK: - Normalization

    func testPathNormalizationDefeatsTraversal() {
        XCTAssertEqual(PermissionRules.normalizedPath("./notes//a.md"), "notes/a.md")
        XCTAssertEqual(PermissionRules.normalizedPath("notes/x/../a.md"), "notes/a.md")
        XCTAssertEqual(PermissionRules.normalizedPath("  notes/a.md  "), "notes/a.md")
    }

    func testDenyCannotBeSteppedAroundWithDotSegments() {
        let rules = [rule(.edit, "secrets/*", .deny)]
        let kind = PendingApprovalKind.fileWrite(
            relativePath: "./secrets/../secrets/key.md",
            oldContent: "", newContent: "x", isNewFile: false
        )
        guard case .deny = PermissionRules.decision(for: kind, rules: rules) else {
            return XCTFail("a dot-segment path must still match the deny rule")
        }
    }

    func testURLNormalizationLowercasesSchemeAndHost() {
        XCTAssertEqual(PermissionRules.normalizedURL("HTTPS://EXAMPLE.com"), "https://example.com/")
        XCTAssertEqual(PermissionRules.normalizedURL("https://example.com/a#frag"), "https://example.com/a")
    }

    func testDenyOnURLBeatsCaseDifference() {
        let rules = [rule(.webfetch, "https://example.com/*", .deny)]
        let kind = PendingApprovalKind.webFetch(url: "https://EXAMPLE.com/x")
        guard case .deny = PermissionRules.decision(for: kind, rules: rules) else {
            return XCTFail("host case must not slip past a deny")
        }
    }

    // MARK: - Allow only what YOLO may automate

    func testAllowRuleCoversAFileWrite() {
        let rules = [rule(.edit, "notes/*", .allow)]
        let kind = PendingApprovalKind.fileWrite(relativePath: "notes/a.md", oldContent: "", newContent: "x", isNewFile: true)
        guard case .allow = PermissionRules.decision(for: kind, rules: rules) else {
            return XCTFail("an allow rule should cover a matching write")
        }
    }

    func testAllowRuleNeverCoversAnElevatedScript() {
        let rules = [rule(.python, "*", .allow)]
        let kind = PendingApprovalKind.runPython(code: "sudo rm -rf /", wantsElevation: true)
        guard case .ask = PermissionRules.decision(for: kind, rules: rules) else {
            return XCTFail("a rule may never allow an elevated run")
        }
    }

    func testAllowRuleNeverCoversAScreenCapture() {
        let rules = [rule(.edit, "*", .allow)]
        let kind = PendingApprovalKind.screenCapture(scope: "the whole screen", purpose: "look")
        if case .allow = PermissionRules.decision(for: kind, rules: rules) {
            XCTFail("a rule may never allow a screen capture")
        }
    }

    func testAllowRuleNeverCoversAGitPush() {
        let rules = [rule(.git, "*", .allow)]
        let kind = PendingApprovalKind.gitNetwork(operation: .push, branch: "main", upstream: "origin/main")
        if case .allow = PermissionRules.decision(for: kind, rules: rules) {
            XCTFail("a rule may never allow a push")
        }
    }

    func testDenyBeatsAllow() {
        let rules = [
            rule(.edit, "notes/*", .allow),
            rule(.edit, "notes/secret.md", .deny),
        ]
        let kind = PendingApprovalKind.fileWrite(relativePath: "notes/secret.md", oldContent: "", newContent: "x", isNewFile: false)
        guard case .deny = PermissionRules.decision(for: kind, rules: rules) else {
            return XCTFail("deny must win over allow")
        }
    }

    func testBlankRuleMatchesNothing() {
        let rules = [rule(.edit, "   ", .deny)]
        let kind = PendingApprovalKind.fileWrite(relativePath: "a.md", oldContent: "", newContent: "x", isNewFile: false)
        guard case .ask = PermissionRules.decision(for: kind, rules: rules) else {
            return XCTFail("a blank pattern must never deny (or allow) everything")
        }
    }

    // MARK: - Batch patches

    func testBatchPatchIsDeniedWhenAnyFileIsDenied() {
        let rules = [rule(.edit, "drafts/*", .deny)]
        let changes = [
            PatchChange(path: "notes/a.md", oldContent: "", newContent: "x", kind: .modified, fromPath: nil),
            PatchChange(path: "drafts/b.md", oldContent: "", newContent: "y", kind: .added, fromPath: nil),
        ]
        let kind = PendingApprovalKind.batchPatch(changes: changes)
        guard case .deny = PermissionRules.decision(for: kind, rules: rules) else {
            return XCTFail("one denied path must refuse the whole batch")
        }
    }

    func testBatchPatchIsAllowedOnlyWhenEveryFileIsCovered() {
        let rules = [rule(.edit, "notes/*", .allow)]
        let covered = PendingApprovalKind.batchPatch(changes: [
            PatchChange(path: "notes/a.md", oldContent: "", newContent: "x", kind: .modified, fromPath: nil),
            PatchChange(path: "notes/b.md", oldContent: "", newContent: "y", kind: .added, fromPath: nil),
        ])
        guard case .allow = PermissionRules.decision(for: covered, rules: rules) else {
            return XCTFail("a batch fully covered by an allow rule may skip its card")
        }
        let partly = PendingApprovalKind.batchPatch(changes: [
            PatchChange(path: "notes/a.md", oldContent: "", newContent: "x", kind: .modified, fromPath: nil),
            PatchChange(path: "other/b.md", oldContent: "", newContent: "y", kind: .added, fromPath: nil),
        ])
        guard case .ask = PermissionRules.decision(for: partly, rules: rules) else {
            return XCTFail("a partly covered batch must still ask")
        }
    }

    // MARK: - Suggestions

    func testSuggestionsAreOfferedForAPlainWrite() {
        let kind = PendingApprovalKind.fileWrite(relativePath: "notes/a.md", oldContent: "", newContent: "x", isNewFile: false)
        let titles = PermissionRules.suggestions(for: kind).map(\.title)
        XCTAssertEqual(titles.count, 3, "this file, this folder, any file")
        XCTAssertTrue(titles.contains { $0.contains("notes/a.md") })
    }

    func testSuggestionsAreEmptyForAKindARuleMayNotAllow() {
        let capture = PendingApprovalKind.screenCapture(scope: "a region", purpose: "look")
        XCTAssertTrue(PermissionRules.suggestions(for: capture).isEmpty)
        let elevated = PendingApprovalKind.runPython(code: "sudo x", wantsElevation: true)
        XCTAssertTrue(PermissionRules.suggestions(for: elevated).isEmpty)
    }

    func testSuggestionPatternForThisFileEscapesWildcards() {
        let kind = PendingApprovalKind.fileWrite(relativePath: "a*b?c.md", oldContent: "", newContent: "x", isNewFile: false)
        let first = PermissionRules.suggestions(for: kind).first
        XCTAssertEqual(first?.rule.pattern, "a\\*b\\?c.md")
        XCTAssertTrue(PermissionRules.matches(pattern: first?.rule.pattern ?? "", value: "a*b?c.md"))
        XCTAssertFalse(PermissionRules.matches(pattern: first?.rule.pattern ?? "", value: "axbxc.md"))
    }

    // MARK: - Store

    func testStoreReplacesAnIdenticalRuleInsteadOfDuplicating() {
        let suite = UserDefaults(suiteName: "PermissionRulesTests-\(UUID().uuidString)")!
        let store = PermissionRuleStore(defaults: suite)
        let rule = self.rule(.webfetch, "https://example.com/*", .allow)
        store.add(rule)
        store.add(rule)
        XCTAssertEqual(store.rules.count, 1)
        store.removeAll()
        XCTAssertTrue(store.rules.isEmpty)
    }
}
