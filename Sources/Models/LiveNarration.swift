import Foundation

/// The words a tool-calling turn has already written, round by round.
///
/// A model narrates before each round ("Now let me check the remaining
/// callers…"), and every round's words used to accumulate in one streaming
/// buffer. A long engineering turn therefore filled the live box with dozens
/// of narrations, joined with no separator at all — a real transcript read
/// "…finish the verification.All four edits are in place", because one
/// round's last word butted straight against the next round's first. The box
/// grew to the height of the turn, so it pushed the answer being written off
/// screen and could not be put away.
///
/// So the live box keeps two things apart: the **round in flight**, which
/// `AIChatManager.liveAnswer` streams and which must stay visible, and the
/// rounds that have **finished**, which this folds into one block the view
/// zips (see `ChatView.liveRow`). A fold is not a summary — nothing is
/// reworded — it only stops one round's ending from running into the next
/// round's start.
enum LiveNarration {
    /// How much finished-round narration the live box keeps. Every round of a
    /// tool-calling turn narrates, and a long run has dozens; the newest are
    /// the ones a reader can still act on, and the older rounds are already
    /// in the transcript's own tool rows.
    static let displayLimit = 6_000

    /// `round` appended to `narration`, separated by a blank line.
    ///
    /// A round that wrote nothing (the model went straight to a tool call,
    /// which is the common case) adds nothing and leaves `narration`
    /// unchanged — so the fold's step count means "rounds that said
    /// something", not "rounds that ran".
    static func fold(_ round: String, into narration: String) -> String {
        let finished = round.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finished.isEmpty else { return narration }
        guard !narration.isEmpty else { return finished }
        return narration + "\n\n" + finished
    }
}
