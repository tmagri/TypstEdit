import Foundation

/// Which slice of the transcript's rows the window draws.
///
/// The transcript stacks its rows eagerly (`VStack`, not `LazyVStack`). A lazy
/// stack sizes the rows it has not measured yet from an estimate, and in a
/// chat of very uneven rows — a one-line question above a long code block, a
/// folded tool run above a table — that estimate inflates the reported content
/// height. The follow scroll then parks on the empty space below the real
/// rows, and the window reads as blank until a manual scroll or a resize makes
/// it measure again: "the messages vanish, and resizing fixes it". Only the
/// rows it estimates are laid out, too, so scrolling to a row it has not built
/// yet can land nowhere at all.
///
/// Eager layout is exact, so the price is paid in row count instead: the
/// window draws the newest `defaultLimit` rows and puts the rest behind one
/// "Show earlier messages" button. A long agentic chat stays cheap because
/// `TranscriptLayout` folds its earlier tool runs, so the drawn rows are a
/// small fraction of the messages. Nothing is dropped — the conversation, the
/// transcript on disk and Find all keep every message.
enum TranscriptWindow {
    /// Rows drawn before "Show earlier messages" appears.
    static let defaultLimit = 80
    /// Rows one press reveals.
    static let step = 80

    /// The newest `limit` rows, oldest first.
    static func visible(_ rows: [TranscriptRow], limit: Int = defaultLimit) -> [TranscriptRow] {
        guard limit > 0, rows.count > limit else { return rows }
        return Array(rows.suffix(limit))
    }

    /// How many messages `visible` leaves out, for the button's count. Rows,
    /// not messages, are what is hidden, and a folded row stands for many.
    static func hiddenMessageCount(in rows: [TranscriptRow], limit: Int = defaultLimit) -> Int {
        guard limit > 0, rows.count > limit else { return 0 }
        return rows.prefix(rows.count - limit).reduce(0) { $0 + $1.messageCount }
    }

    /// The limit after one press of "Show earlier messages": one more step of
    /// rows, never past the start of the transcript.
    static func widenedLimit(_ limit: Int, rowCount: Int, step: Int = step) -> Int {
        guard rowCount > limit else { return limit }
        return min(rowCount, limit + max(1, step))
    }

    /// A limit that draws the row holding `rowID`, or `nil` when it is already
    /// drawn. Find uses this: a scroll target that is not in the stack cannot
    /// be scrolled to, so stepping to an old hit would do nothing at all.
    static func limit(
        showing rowID: UUID,
        in rows: [TranscriptRow],
        limit: Int = defaultLimit,
        step: Int = step
    ) -> Int? {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return nil }
        let needed = rows.count - index
        guard needed > limit else { return nil }
        return min(rows.count, needed + max(1, step))
    }
}

/// One row of the drawn transcript: a message, or a run of older tool calls
/// collapsed into a single line.
///
/// A long agentic conversation is almost entirely tool activity. Measured on
/// a real 1.8 MB chat on this machine: 396 messages, of which 326 were tool
/// calls in 25 runs — one run 62 rows long. Drawing them all meant hundreds
/// of rows for the lazy stack to track, none of which the user reads; what
/// they read are the questions, the answers and what the model is doing now.
///
/// So runs of *finished* tool calls from earlier turns fold into one line that
/// expands on click. The turn in progress is never folded: watching the tools
/// run is the point of it. No message is dropped — the transcript on disk keeps
/// everything, Find still searches it, and a folded run expands in place.
enum TranscriptRow: Identifiable, Equatable {
    case message(UUID)
    /// `messageIDs` are in transcript order. `id` is the first of them, so a
    /// fold keeps a stable identity as the conversation grows.
    case foldedTools(id: UUID, messageIDs: [UUID], failedCount: Int)

    var id: UUID {
        switch self {
        case .message(let id): return id
        case .foldedTools(let id, _, _): return id
        }
    }

    /// How many messages the row stands for, for tests and for the count on a
    /// folded row.
    var messageCount: Int {
        switch self {
        case .message: return 1
        case .foldedTools(_, let ids, _): return ids.count
        }
    }
}

enum TranscriptLayout {    /// Runs shorter than this are left alone: folding two rows into one saves
    /// a row and costs a click, which is not a trade worth making.
    static let minimumRunToFold = 3

    /// The rows to draw, oldest first.
    ///
    /// Everything before the newest user message is "old" and may fold.
    /// Everything from the newest user message on is the turn in progress and
    /// is drawn in full. A run is only folded when every call in it has
    /// settled (no `running` row), so a transcript saved mid-turn never hides
    /// work that is still in flight.
    static func rows(
        for messages: [ChatMessage],
        minimumRunToFold: Int = minimumRunToFold
    ) -> [TranscriptRow] {
        guard !messages.isEmpty else { return [] }

        // The current turn starts at the last user message. With none, the
        // whole transcript is old (e.g. a chat that opens on an answer).
        let currentStart = messages.lastIndex { $0.role == .user } ?? messages.endIndex

        var rows: [TranscriptRow] = []
        rows.reserveCapacity(messages.count)
        var run: [Int] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            let settled = run.allSatisfy { messages[$0].toolStatus != .running }
            if run.count >= minimumRunToFold, settled {
                let ids = run.map { messages[$0].id }
                rows.append(.foldedTools(
                    id: ids[0],
                    messageIDs: ids,
                    failedCount: run.filter { messages[$0].toolStatus == .failed }.count
                ))
            } else {
                rows.append(contentsOf: run.map { .message(messages[$0].id) })
            }
            run.removeAll(keepingCapacity: true)
        }

        for index in messages.indices {
            let message = messages[index]
            if index >= currentStart {
                // The turn in progress is never folded.
                flushRun()
                rows.append(.message(message.id))
            } else if message.role == .toolCall {
                run.append(index)
            } else {
                flushRun()
                rows.append(.message(message.id))
            }
        }
        flushRun()
        return rows
    }


    /// The fold a message sits inside, if the transcript has folded it away.
    /// Find uses this so a hit inside a folded run is reachable: stepping to
    /// it opens the fold rather than scrolling to a row that is not drawn.
    static func foldID(containing messageID: UUID, in rows: [TranscriptRow]) -> UUID? {
        for row in rows {
            if case .foldedTools(let id, let ids, _) = row, ids.contains(messageID) {
                return id
            }
        }
        return nil
    }
}
