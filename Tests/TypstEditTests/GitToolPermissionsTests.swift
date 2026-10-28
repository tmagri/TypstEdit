import XCTest
@testable import TypstEdit

@MainActor
final class GitToolPermissionsTests: XCTestCase {
    func testAllPermissionsDefaultOff() {
        let permissions = GitToolPermissions()
        XCTAssertFalse(permissions.enabled)
        XCTAssertFalse(permissions.fetchEnabled)
        XCTAssertFalse(permissions.pullEnabled)
        XCTAssertFalse(permissions.pushEnabled)
        XCTAssertTrue(GitTools.descriptors(permissions: permissions).isEmpty)
    }

    func testEachNetworkPermissionIsIndependent() {
        for flags in 0..<16 {
            let permissions = GitToolPermissions(
                enabled: flags & 1 != 0,
                fetchEnabled: flags & 2 != 0,
                pullEnabled: flags & 4 != 0,
                pushEnabled: flags & 8 != 0
            )
            let tools = Set(GitTools.descriptors(permissions: permissions).map(\.name))
            XCTAssertEqual(tools.contains("git_commit"), permissions.enabled)
            XCTAssertEqual(tools.contains("git_fetch"), permissions.enabled && permissions.fetchEnabled)
            XCTAssertEqual(tools.contains("git_pull"), permissions.enabled && permissions.pullEnabled)
            XCTAssertEqual(tools.contains("git_push"), permissions.enabled && permissions.pushEnabled)
            for name in ["git_status", "git_diff", "git_log", "git_stage", "git_commit", "git_fetch", "git_pull", "git_push"] {
                XCTAssertEqual(permissions.allows(name), tools.contains(name))
            }
            XCTAssertFalse(permissions.allows("git_force_push"))
        }
    }

    func testCommitSchemaAlwaysRequiresAMessage() throws {
        let tool = try XCTUnwrap(GitTools.descriptors(permissions: GitToolPermissions(enabled: true))
            .first { $0.name == "git_commit" })
        XCTAssertEqual(tool.inputSchema["required"] as? [String], ["message"])
        let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
        let message = try XCTUnwrap(properties["message"] as? [String: Any])
        XCTAssertEqual(message["type"] as? String, "string")
        XCTAssertEqual(message["minLength"] as? Int, 1)
    }

    func testSubagentToolAccessIsEnforcedAtExecution() {
        for name in ["git_stage", "git_commit", "git_fetch", "git_pull", "git_push"] {
            XCTAssertThrowsError(try AIChatManager.validateToolAccess(qualifiedName: "git__\(name)", isSubagent: true))
            XCTAssertNoThrow(try AIChatManager.validateToolAccess(qualifiedName: "git__\(name)", isSubagent: false))
        }
        for name in GitTools.readOnlyToolNames {
            XCTAssertNoThrow(try AIChatManager.validateToolAccess(qualifiedName: "git__\(name)", isSubagent: true))
        }
        XCTAssertThrowsError(try AIChatManager.validateToolAccess(qualifiedName: "project__write_file", isSubagent: true))
        XCTAssertThrowsError(try AIChatManager.validateToolAccess(qualifiedName: "python__run", isSubagent: true))
        XCTAssertThrowsError(try AIChatManager.validateToolAccess(qualifiedName: "agent__delegate_task", isSubagent: true))
    }

    func testPushCannotBeAutoApprovedEvenInYOLOMode() {
        let push = PendingApprovalKind.gitNetwork(operation: .push, branch: "main", upstream: "origin/main")
        XCTAssertFalse(push.canAutoApprove(yoloMode: false))
        XCTAssertFalse(push.canAutoApprove(yoloMode: true))
    }

    func testYOLOCanApproveLocalCommitsAndPermittedPulls() {
        let commit = PendingApprovalKind.gitCommit(message: "Update heading", files: ["main.typ"],
                                                  branch: "main", stageAll: false)
        let pull = PendingApprovalKind.gitNetwork(operation: .pull,
                                                  branch: "main", upstream: "origin/main")
        XCTAssertTrue(commit.canAutoApprove(yoloMode: true))
        XCTAssertFalse(commit.canAutoApprove(yoloMode: false))
        XCTAssertTrue(pull.canAutoApprove(yoloMode: true))
        XCTAssertFalse(pull.canAutoApprove(yoloMode: false))
    }
}
