import Foundation

/// Independent AI Chat permissions. Local commits do not grant any remote
/// access. New network permissions stay off even if the old combined network
/// setting was enabled; users must choose each action explicitly.
struct GitToolPermissions: Equatable, Sendable {
    var enabled = false
    var fetchEnabled = false
    var pullEnabled = false
    var pushEnabled = false

    func allows(_ toolName: String) -> Bool {
        guard enabled else { return false }
        switch toolName {
        case "git_status", "git_diff", "git_log", "git_stage", "git_commit":
            return true
        case "git_fetch":
            return fetchEnabled
        case "git_pull":
            return pullEnabled
        case "git_push":
            return pushEnabled
        default:
            return false
        }
    }
}
