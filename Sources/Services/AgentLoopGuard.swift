import Foundation
import CryptoKit

/// Detects action-level loops: an agent cycling through the same failing tool
/// calls, or alternating between multiple different-but-consistently-failing
/// approaches. Distinct from `RepetitionDetector`, which catches output-level
/// byte repetition.
///
/// This is a value type owned per-turn by the caller. Initialise fresh at the
/// start of every turn, call `record` after each tool completion, then call
/// `checkForLoop` to get a redirect hint to inject when a loop is detected.
struct AgentLoopGuard {

    // MARK: - Nested Types

    /// One recorded tool invocation result.
    struct CallRecord {
        /// Qualified tool name, e.g. `"fs__run_script"`.
        let toolName: String
        /// First 12 hex characters of the SHA-256 of the arguments JSON.
        let argumentFingerprint: String
        /// Whether the call succeeded.
        let succeeded: Bool
        /// Wall-clock time of the call.
        let timestamp: Date
    }

    // MARK: - Configuration

    /// Maximum number of recent calls kept in the sliding window.
    static let windowSize = 8
    /// How many failures of the same (tool, fingerprint) pair trigger a same-fingerprint loop alert.
    static let minFailuresForLoop = 2
    /// Minimum window population before any alert fires, to avoid false positives on the very first calls.
    static let minWindowForDuration = 4

    // MARK: - State

    private var window: [CallRecord] = []

    // MARK: - Public API

    /// Records the result of a completed tool call, maintaining a sliding window of the last `windowSize` entries.
    ///
    /// - Parameters:
    ///   - toolName: The qualified tool name (e.g. `"fs__run_script"`).
    ///   - argumentsJSON: The raw JSON string of tool arguments; fingerprinted internally.
    ///   - succeeded: `true` if the call succeeded, `false` if it failed.
    mutating func record(toolName: String, argumentsJSON: String, succeeded: Bool) {
        let record = CallRecord(
            toolName: toolName,
            argumentFingerprint: Self.fingerprint(argumentsJSON),
            succeeded: succeeded,
            timestamp: Date()
        )
        window.append(record)
        if window.count > Self.windowSize {
            window.removeFirst(window.count - Self.windowSize)
        }
    }

    /// Inspects the current window for loop patterns. Call after every `record`.
    ///
    /// - Returns: A human-readable redirect hint string when a loop is detected,
    ///   or `nil` when no loop is apparent.
    func checkForLoop() -> String? {
        guard window.count >= Self.minWindowForDuration else { return nil }

        // 1. Same-fingerprint failure loop: same (tool, args) pair fails ≥ minFailuresForLoop times.
        typealias Key = String  // "toolName::fingerprint"
        var failCounts: [Key: (toolName: String, count: Int)] = [:]
        for record in window where !record.succeeded {
            let key = "\(record.toolName)::\(record.argumentFingerprint)"
            let existing = failCounts[key]
            failCounts[key] = (record.toolName, (existing?.count ?? 0) + 1)
        }
        if let worst = failCounts.values.max(by: { $0.count < $1.count }),
           worst.count >= Self.minFailuresForLoop {
            return "[Loop detected] You have called \(worst.toolName) with the same arguments \(worst.count) times and it keeps failing. Stop and try a fundamentally different approach, or ask the user for guidance."
        }

        // 2. Alternating failure loop: 2+ distinct fingerprints all failed within the window.
        let failedRecords = window.filter { !$0.succeeded }
        let distinctFingerprints = Set(failedRecords.map { "\($0.toolName)::\($0.argumentFingerprint)" })
        if distinctFingerprints.count >= 2, distinctFingerprints.count == Set(window.map { "\($0.toolName)::\($0.argumentFingerprint)" }).count {
            let distinctCount = distinctFingerprints.count
            return "[Loop detected] You have tried \(distinctCount) different approaches in the last \(Self.windowSize) tool calls and all have failed. Consider asking the user, checking assumptions, or taking a step back."
        }

        return nil
    }

    // MARK: - Private Helpers

    /// Returns the first 12 hex characters of the SHA-256 digest of `json`.
    private static func fingerprint(_ json: String) -> String {
        let data = Data(json.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12).description
    }
}
