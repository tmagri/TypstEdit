import Foundation

/// How much the safety monitor checks.
///
/// The three modes are a user-facing dial over the same rule set, because the
/// rules differ enormously in how much noise they make. The credential rules
/// are high-confidence and cheap to obey; a "many script runs" rule is a
/// suspicion, not a secret. Splitting them lets a person who finds the noise
/// unbearable keep the part that protects the keys.
enum SafetyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Every rule, including the heuristics that only flag "worth a look".
    case strict
    /// Credential and exfiltration rules only — the checks about secrets
    /// leaving the machine. Suspicion-only rules are off.
    case safe
    /// The monitor does nothing. `canAutoApprove` falls back to the plain
    /// YOLO rules.
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strict: return "Strict"
        case .safe: return "Safe"
        case .off: return "Off"
        }
    }

    var explanation: String {
        switch self {
        case .strict:
            return "Every rule: credential exfiltration, script bursts, and repeated writes. The most protection, and the most approval cards."
        case .safe:
            return "Only the rules about secrets leaving this Mac: a key-shaped value reaching the network or a Git push, and a read of a credential file followed by either. Suspicion-only rules are off."
        case .off:
            return "No safety checks. YOLO approves exactly what it approved before this feature existed."
        }
    }

    /// The built-in rule ids this mode runs.
    var enabledBuiltInRuleIDs: Set<String> {
        switch self {
        case .off:
            return []
        case .safe:
            return [
                "credential_in_script_to_network",
                "credential_in_args_to_network",
                "credential_file_then_egress",
                "secret_read_then_git_push",
                "private_key_in_write",
            ]
        case .strict:
            return Set(SafetyMonitor.allBuiltInRuleIDs)
        }
    }

    /// Whether the monitor is doing anything at all.
    var isActive: Bool { self != .off }
}
