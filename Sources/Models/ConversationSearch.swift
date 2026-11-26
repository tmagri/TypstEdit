import Foundation

/// Text search across a conversation — the engine behind the chat's Find
/// bar and the history picker's full-text search.
///
/// Deliberately plain string matching, not the embedding index: finding a
/// phrase you remember is a "same words" problem, and it has to work before
/// anything has been embedded, on every message, and instantly as you type.
/// `ConversationRecall` is the opposite tool — it searches what left the
/// context by meaning, behind the model's own tool call.
enum ConversationSearch {
    /// One hit inside a message.
    struct Match: Identifiable, Equatable {
        /// Stable per (message, occurrence) so SwiftUI can tell hits apart.
        var id: String { "\(messageID.uuidString)#\(occurrence)" }
        let messageID: UUID
        let role: ChatMessage.Role
        let occurrence: Int
        /// Where the hit sits in the message's searchable text.
        let range: Range<Int>
    }

    /// The text a message is searched by: what the user can see, plus the
    /// tool output and reasoning the transcript also shows. A tool call's
    /// arguments are included so "which file did we read?" finds the path.
    static func searchableText(of message: ChatMessage) -> String {
        var parts: [String] = []
        if !message.text.isEmpty { parts.append(message.text) }
        if let reasoning = message.reasoning, !reasoning.isEmpty { parts.append(reasoning) }
        if let output = message.toolOutput, !output.isEmpty { parts.append(output) }
        if let arguments = message.toolArgumentsJSON, !arguments.isEmpty { parts.append(arguments) }
        return parts.joined(separator: "\n")
    }

    /// All hits in one conversation, in transcript order.
    static func matches(for query: String, in messages: [ChatMessage], maxMatches: Int = 1000) -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var matches: [Match] = []
        for message in messages {
            let text = searchableText(of: message)
            guard !text.isEmpty else { continue }
            var searchStart = text.startIndex
            var occurrence = 0
            var currentOffset = 0
            var lastIndex = text.startIndex
            while let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
                let dist = text.distance(from: lastIndex, to: found.lowerBound)
                currentOffset += dist
                let matchLen = text.distance(from: found.lowerBound, to: found.upperBound)
                let lower = currentOffset
                let upper = currentOffset + matchLen
                matches.append(Match(
                    messageID: message.id,
                    role: message.role,
                    occurrence: occurrence,
                    range: lower..<upper
                ))
                occurrence += 1
                if matches.count >= maxMatches {
                    return matches
                }
                currentOffset = upper
                lastIndex = found.upperBound
                // Overlapping hits would double-count a repeated phrase; step
                // past this one, but never past the end (a zero-width match
                // can't happen with a non-empty needle, but be defensive).
                searchStart = found.upperBound > found.lowerBound ? found.upperBound : text.index(after: found.lowerBound)
                if searchStart >= text.endIndex { break }
            }
        }
        return matches
    }

    /// A one-line window around a hit, with ellipses where text was cut, so
    /// a result shows the words that matched in their sentence instead of a
    /// bare message start.
    static func snippet(in text: String, around range: Range<Int>, context: Int = 48) -> String {
        guard !text.isEmpty else { return "" }
        let lower = max(0, range.lowerBound - context)
        let upper = min(text.count, range.upperBound + context)
        let start = text.index(text.startIndex, offsetBy: lower)
        let end = text.index(text.startIndex, offsetBy: upper)
        let flat = text[start..<end]
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = lower > 0 ? "…" : ""
        let suffix = upper < text.count ? "…" : ""
        return prefix + flat + suffix
    }

    /// The first match at or after `index` (wrapping to the start), for the
    /// Find bar's Next/Previous without tracking duplicate state in the view.
    static func stepping(_ matches: [Match], from index: Int, forward: Bool) -> Match? {
        guard !matches.isEmpty else { return nil }
        if forward {
            return index + 1 < matches.count ? matches[index + 1] : matches.first
        }
        return index - 1 >= 0 ? matches[index - 1] : matches.last
    }

    /// One conversation that matches, with the best snippet to show under
    /// its title in the history list.
    struct SessionMatch: Equatable {
        let sessionID: UUID
        /// A short window of the message text around the first hit.
        let snippet: String
        /// How many hits the query has anywhere in the conversation.
        let hitCount: Int
    }

    /// Which conversations contain the query, with a snippet from the first
    /// hit. Titles are checked too: a chat whose title matches but whose
    /// messages do not still belongs in the results, with an empty snippet.
    static func sessionMatches(for query: String, in sessions: [ChatSession]) -> [UUID: SessionMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [:] }
        var results: [UUID: SessionMatch] = [:]
        for session in sessions {
            let hits = matches(for: needle, in: session.messages)
            if let first = hits.first,
               let message = session.messages.first(where: { $0.id == first.messageID }) {
                results[session.id] = SessionMatch(
                    sessionID: session.id,
                    snippet: snippet(in: searchableText(of: message), around: first.range),
                    hitCount: hits.count
                )
            } else if session.title.localizedCaseInsensitiveContains(needle) {
                results[session.id] = SessionMatch(sessionID: session.id, snippet: "", hitCount: 0)
            }
        }
        return results
    }
}
