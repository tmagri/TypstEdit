import Foundation

// MARK: - FactCandidate

/// A potential environment fact extracted from a single session's transcript.
///
/// A candidate is promoted to a ``ConfirmedFact`` once it has been observed
/// in at least three separate sessions (``sessionCount`` ≥ 3).
struct FactCandidate: Codable {
    /// Human-readable description of the corrected command or environment
    /// constraint, e.g. "pytest must be run as `python -m pytest`".
    var body: String

    /// How many sessions have independently produced this same fact body
    /// (fuzzy-matched by lowercased equality).
    var sessionCount: Int

    /// Timestamp of the most recent session that contributed this candidate.
    var lastSeen: Date
}

// MARK: - ConfirmedFact

/// A workspace fact that has been confirmed across enough sessions to be
/// injected into the system prompt.
///
/// `confidence` starts at 5 and decrements each time a tool call that matches
/// this fact's command appears and **fails**. The fact is removed when
/// confidence reaches 0.
struct ConfirmedFact: Codable {
    /// Human-readable description, identical to the ``FactCandidate/body``
    /// that was promoted.
    var body: String

    /// Confidence level (1–5). Decremented on observed regressions;
    /// the fact is removed when this reaches 0.
    var confidence: Int

    /// When the candidate was promoted to a confirmed fact.
    var addedAt: Date
}
