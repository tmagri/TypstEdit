import Foundation

/// The arithmetic behind the compaction trigger: how far below the model's
/// budget the conversation is allowed to grow before older turns are
/// summarized.
///
/// The buffer exists because a single step can be large — one `read_file` on a
/// long document, a pasted chapter — so compacting exactly at the limit means
/// that step overflows and the request is rejected. Keeping a margin free lets
/// the conversation still be sent unchanged, which also preserves the
/// provider's cached prefix. A *share* of the budget, rather than a fixed token
/// count, is what lets one setting fit a 32k local model and a million-token
/// cloud model alike.
enum CompactionBuffer {

    /// Percentage actually applied. Capped at half the budget: past that, the
    /// conversation would be summarized constantly to protect headroom it
    /// never gets to use.
    static func clampedPercent(_ raw: Double) -> Double {
        min(max(raw, 0), 50)
    }

    /// The context size at which compaction starts: the budget minus the
    /// buffer, never below a working floor.
    ///
    /// The floor matters because a small budget with a large buffer would
    /// otherwise leave almost no room to work in, which compacts on every
    /// message and defeats the purpose.
    static func trigger(budget: Int, bufferPercent: Double) -> Int {
        let share = clampedPercent(bufferPercent) / 100
        return max(minimumWorkingTokens, Int(Double(budget) * (1 - share)))
    }

    /// The least headroom compaction ever leaves. Matches the floor the
    /// context budget itself is clamped to.
    static let minimumWorkingTokens = 2_000

    /// Share of the trigger at which a background summary starts, so it is
    /// ready before the context actually reaches the limit.
    static let precomputeRatio = 0.85

    /// Floor below which a background summary is never worth it, whatever the
    /// model's window: a summary would cost more context than the turns it
    /// replaces.
    static let precomputeMinimumTokens = 8_000

    /// Whether a background summary is worth starting now.
    static func shouldPrecompute(
        estimatedTokens: Int,
        triggerTokens: Int,
        alreadyPrecomputed: Bool,
        isBusy: Bool
    ) -> Bool {
        guard !alreadyPrecomputed, !isBusy, triggerTokens > 0 else { return false }
        // Never for a conversation too short for a summary to pay for itself.
        guard estimatedTokens >= max(precomputeMinimumTokens, triggerTokens / 4) else { return false }
        return Double(estimatedTokens) >= Double(triggerTokens) * precomputeRatio
    }
}
