import Foundation

/// How many times a model request may be tried again after it fails.
///
/// A chat keeps its own retry settings: the user is watching, and a dropped
/// connection that comes back is worth waiting for. Unattended runs (a
/// subagent, a detached background delegation) are different: retrying behind
/// the user's back spends tokens invisibly. `resolve` is the single place
/// that decision is made, so the agent's request sites agree.
struct RequestRetries: Equatable {
    /// Attempts after the first, for a request that failed before any reply.
    var transport: Int
    /// Times the model is asked to carry on after an empty or stalled reply.
    var autoContinue: Int
    var autoContinueUnlimited: Bool
    /// Whether a lost network is waited out instead of failing the request.
    var waitForNetwork: Bool

    /// One attempt, then fail.
    static let none = RequestRetries(
        transport: 0, autoContinue: 0, autoContinueUnlimited: false, waitForNetwork: false
    )

    /// - Parameters:
    ///   - isBackgroundRun: whether this request runs unattended.
    ///   - retryFailedRuns: the user's setting for unattended retries.
    ///   - chat: the chat's own retry settings, used as they are by a chat and,
    ///     when the setting allows, by an unattended run.
    static func resolve(
        isBackgroundRun: Bool,
        retryFailedRuns: Bool,
        chat: RequestRetries
    ) -> RequestRetries {
        if isBackgroundRun && !retryFailedRuns { return .none }
        return chat
    }
}
