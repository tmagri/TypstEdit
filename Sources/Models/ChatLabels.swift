import Foundation

/// A conversation's labels: free-form tags like "Work" or "🎮" that the user
/// sticks on a chat, and that the History picker can filter and sort by.
///
/// Deliberately plain strings rather than a fixed enum: a label set is the
/// user's own vocabulary, and an emoji is a perfectly good label — the whole
/// point of one is to be recognised at a glance in a tab strip. The rules
/// below are the only ones the type enforces: a label is short, one line,
/// and unique within a conversation apart from letter case.
enum ChatLabel {
    /// How many labels one conversation may carry. Enough for a few themes,
    /// few enough that the chips still fit under a title.
    static let maxPerConversation = 8

    /// Long enough for a couple of words or an emoji phrase, short enough
    /// that a label still reads as a chip and not as a sentence.
    static let maxLength = 24

    /// Cleans a typed label: trims the ends, collapses inner whitespace to
    /// single spaces (so "Game  night" is one label), and refuses anything
    /// empty or overlong. `nil` means "not a label worth keeping".
    static func normalize(_ raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= maxLength else { return nil }
        return collapsed
    }

    /// Cleans a whole label set: normalizes each entry, drops duplicates that
    /// differ only by case ("work" and "Work" are one label), and stops at
    /// `maxPerConversation`.
    static func normalize(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in labels {
            guard let label = normalize(raw) else { continue }
            guard seen.insert(label.lowercased()).inserted else { continue }
            result.append(label)
            if result.count == maxPerConversation { break }
        }
        return result
    }

    /// Whether two labels mean the same thing. Label matching ignores case
    /// and accents, so "café" and "Cafe" do not become two separate filters.
    static func equals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// True when a label is nothing but emoji (and spacing) — the kind a user
    /// adds to be seen rather than read. Tabs show these before the title.
    static func isEmojiOnly(_ label: String) -> Bool {
        var sawEmoji = false
        for scalar in label.unicodeScalars {
            switch scalar.value {
            case 0x20, 0x09:            // plain spacing
                continue
            case 0xFE0E, 0xFE0F:        // variation selectors
                continue
            case 0x200D:                // zero-width joiner, as in 👩‍💻
                continue
            case 0x20E3:                // combining keycap
                continue
            default:
                break
            }
            guard scalar.properties.isEmoji else { return false }
            sawEmoji = true
        }
        return sawEmoji
    }

    /// The emoji-only labels of a conversation, joined, for the tab strip's
    /// at-a-glance marker. Word labels are left out — a tab is a title, not a
    /// list, and the tooltip carries the rest.
    static func emojiPrefix(of labels: [String], limit: Int = 2) -> String {
        labels.filter(isEmojiOnly).prefix(limit).joined()
    }
}

/// The labels offered when tagging a conversation: a small ordered set the
/// user grows as they tag. Stored beside the transcripts (`labels.json`), so
/// the vocabulary travels with the chat history rather than with one Mac's
/// defaults.
///
/// Seeded with three plain labels so the first visit to the label page has
/// something to click; anything the user types is appended after them.
struct ChatLabelCatalog: Codable, Equatable {
    /// What a fresh install starts from. Kept short on purpose: a long
    /// pre-made list is a decision the user did not make.
    static let seed = ["Work", "Gaming", "Personal"]

    /// In suggestion order: the seed first, then labels in the order they
    /// were first used.
    var labels: [String]

    init(labels: [String] = ChatLabelCatalog.seed) {
        self.labels = ChatLabel.normalize(labels)
    }

    func contains(_ label: String) -> Bool {
        labels.contains { ChatLabel.equals($0, label) }
    }

    /// Adds a label at the end of the suggestions, ignoring one already there
    /// (in any letter case).
    mutating func add(_ raw: String) {
        guard let label = ChatLabel.normalize(raw), !contains(label) else { return }
        labels.append(label)
    }

    mutating func remove(_ label: String) {
        labels.removeAll { ChatLabel.equals($0, label) }
    }
}

/// How the History picker orders the saved conversations. Raw values are
/// what `@AppStorage` remembers between launches, so renaming a case loses
/// the stored choice — keep them stable.
enum ChatSortOrder: String, CaseIterable, Identifiable, Codable {
    case recent
    case oldest
    case title
    case messages
    case label

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "Last active"
        case .oldest: return "Oldest first"
        case .title: return "Title A–Z"
        case .messages: return "Most messages"
        case .label: return "Label A–Z"
        }
    }

    var icon: String {
        switch self {
        case .recent: return "clock"
        case .oldest: return "clock.badge.questionmark"
        case .title: return "textformat"
        case .messages: return "bubble.left.and.bubble.right"
        case .label: return "tag"
        }
    }
}

/// The sorting rules themselves, kept free of SwiftUI so they can be read and
/// tested on their own. Every order falls back to newest-activity so the list
/// never jitters between equally-ranked rows.
enum ChatHistoryOrdering {
    static func sorted(_ summaries: [ChatSessionSummary], by order: ChatSortOrder) -> [ChatSessionSummary] {
        switch order {
        case .recent:
            return summaries.sorted { $0.updatedAt > $1.updatedAt }

        case .oldest:
            return summaries.sorted { $0.updatedAt < $1.updatedAt }

        case .title:
            return summaries.sorted { lhs, rhs in
                let comparison = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.updatedAt > rhs.updatedAt
            }

        case .messages:
            return summaries.sorted { lhs, rhs in
                if lhs.messageCount != rhs.messageCount { return lhs.messageCount > rhs.messageCount }
                return lhs.updatedAt > rhs.updatedAt
            }

        case .label:
            // Grouped by first label; untagged conversations gather at the
            // bottom, where they are easy to find and tag.
            return summaries.sorted { lhs, rhs in
                switch (lhs.labelList.first, rhs.labelList.first) {
                case let (left?, right?):
                    let comparison = left.localizedCaseInsensitiveCompare(right)
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                case (nil, .some):
                    return false
                case (.some, nil):
                    return true
                case (nil, nil):
                    break
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        }
    }
}
