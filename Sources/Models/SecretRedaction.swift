import Foundation

/// A message the user is about to send, with every secret found in it and
/// the choice of which ones to hide.
///
/// The composer builds one when "Redact secrets before sending" is on and
/// `CredentialScanner.spans(in:)` finds something. Nothing is sent until the
/// user reviews the delta: by default every secret is replaced, and each can
/// be kept in the clear one by one (a false positive, or a key the user
/// really means to share). The model only ever receives `text(keeping:)`.
struct SecretRedaction: Equatable {

    struct Finding: Identifiable, Equatable {
        let id: Int
        let range: Range<String.Index>
        let kind: CredentialScanner.Kind
        /// First few characters plus an ellipsis, for the review card. The
        /// card never shows the whole secret again.
        let masked: String

        /// What goes to the model instead. "redacted" is one of the scanner's
        /// placeholder words, so a redacted message never flags a second time.
        var placeholder: String { "[REDACTED \(kind.displayName)]" }
    }

    /// One run of the delta, in order.
    enum Segment: Equatable {
        /// Text sent exactly as written.
        case unchanged(String)
        /// A secret that is replaced: what was written (masked) and what is sent.
        case replaced(findingID: Int, masked: String, placeholder: String)
        /// A secret the user chose to send as written.
        case kept(findingID: Int, text: String)
    }

    let original: String
    let findings: [Finding]

    /// Nil when there is nothing to redact, so the caller sends at once.
    init?(scanning text: String) {
        let spans = CredentialScanner.spans(in: text)
        guard !spans.isEmpty else { return nil }
        original = text
        findings = spans.enumerated().map { index, span in
            Finding(id: index, range: span.range, kind: span.kind, masked: span.masked)
        }
    }

    /// The delta, with the findings in `kept` sent as written.
    func segments(keeping kept: Set<Int> = []) -> [Segment] {
        var result: [Segment] = []
        var cursor = original.startIndex
        for finding in findings {
            if cursor < finding.range.lowerBound {
                result.append(.unchanged(String(original[cursor..<finding.range.lowerBound])))
            }
            if kept.contains(finding.id) {
                result.append(.kept(findingID: finding.id, text: String(original[finding.range])))
            } else {
                result.append(.replaced(findingID: finding.id, masked: finding.masked,
                                        placeholder: finding.placeholder))
            }
            cursor = finding.range.upperBound
        }
        if cursor < original.endIndex {
            result.append(.unchanged(String(original[cursor...])))
        }
        return result
    }

    /// What is actually sent, with the findings in `kept` left in the clear.
    func text(keeping kept: Set<Int> = []) -> String {
        segments(keeping: kept).map { segment in
            switch segment {
            case .unchanged(let text), .kept(_, let text): return text
            case .replaced(_, _, let placeholder): return placeholder
            }
        }.joined()
    }

    /// "1 secret" / "3 secrets", for the card's heading.
    var countLabel: String {
        findings.count == 1 ? "1 secret" : "\(findings.count) secrets"
    }
}
