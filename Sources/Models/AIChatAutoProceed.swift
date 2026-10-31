import Foundation

/// Heuristic detection and prompt text for AI Chat's "auto-proceed" option:
/// when a finished reply says, in so many words, that work is still left, the
/// chat can start the next step by itself after a short countdown instead of
/// waiting for the user to type "continue".
///
/// The check deliberately looks only at the end of a reply (a next-steps list
/// is how a reply ends) and only at headings or plain statements of unfinished
/// work — ordinary prose that merely mentions "next steps" must not keep a
/// conversation running.
enum AIChatAutoProceed {
    /// What prompted a continuation.
    enum Trigger: Equatable {
        /// The reply named outstanding work ("Next steps", "Still to do", …).
        case unfinished
        /// The turn ended in an error. Only used when the user opted into
        /// continuing after failures.
        case failure(String)
    }

    /// How much of the reply's tail is inspected.
    static let inspectionCharacterLimit = 4_000

    /// Heading texts that name remaining work. Matched on a normalized line —
    /// markdown markers, bullets and list numbers stripped — either exactly or
    /// followed by a colon/dash ("Next steps: run the build").
    static let unfinishedHeadings: [String] = [
        "next steps", "next step", "next actions", "next action",
        "remaining work", "remaining steps", "remaining tasks",
        "remaining items", "remaining",
        "still to do", "still to be done", "left to do",
        "what's left", "whats left", "what is still left", "what's still left",
        "what remains", "to-do", "todo",
        "follow-up steps", "follow up steps", "follow-up work",
        "outstanding work", "unfinished work", "incomplete work",
        "not yet done", "not done yet",
    ]

    /// First-person or plain statements that work is not finished. Kept to
    /// phrases that assert unfinished work (not offers such as "let me know if
    /// you'd like me to…", which end almost every reply).
    static let unfinishedPhrases: [String] = [
        "i haven't finished", "i have not finished",
        "i didn't finish", "i did not finish",
        "i couldn't finish", "i could not finish",
        "i wasn't able to finish", "i was not able to finish",
        "i haven't been able to", "i did not get to", "i didn't get to",
        "i still need to", "i still have to",
        "still needs to be", "still need to be", "still remains to be",
        "remains to be done", "remains to be implemented", "remains to be written",
        "is not yet implemented", "are not yet implemented", "not yet implemented",
        "not yet complete", "not yet finished",
        "left to do", "left to finish", "left to implement",
        "we still need to", "we still have to",
        "there's still", "there is still",
        "the remaining work", "the remaining steps", "the remaining tasks",
        "next, i'll", "next i'll", "next i will",
        "i will now continue", "i'll continue with",
        "to be continued",
        "partially complete", "partially done",
    ]

    /// Hand-off phrases. A reply that ends "…next step when you're ready" or
    /// "let me know when you're ready and I'll continue" is explicitly holding
    /// work back for a go-ahead, so it counts as unfinished: Auto-proceed is
    /// exactly the user saying "go ahead without asking me".
    static let readyPhrases: [String] = [
        "when you're ready", "when you are ready", "whenever you're ready",
        "whenever you are ready", "when ready",
        "once you're ready", "once you are ready",
        "when you're set", "when you are set",
        "ready when you are",
        "say the word", "just say go", "say go",
        "next step when", "continue when", "proceed when",
        "let me know when you're ready", "let me know when you are ready",
        "tell me when you're ready", "tell me when you are ready",
        "happy to continue", "ready to continue", "ready for the next",
        "i can continue", "shall i continue", "should i continue",
        "want me to continue", "ready to proceed",
        "awaiting your go-ahead", "awaiting your approval to continue",
        "on your go-ahead", "on your signal",
    ]

    /// Whether a finished reply implies that more work remains. Empty text is
    /// never unfinished (an empty reply has its own retry path).
    static func looksUnfinished(_ reply: String) -> Bool {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let tail = trimmed.count > inspectionCharacterLimit
            ? String(trimmed.suffix(inspectionCharacterLimit))
            : trimmed
        if tail.components(separatedBy: .newlines).contains(where: isUnfinishedHeadingLine) {
            return true
        }
        let lower = tail.lowercased()
        return (unfinishedPhrases + readyPhrases).contains { lower.contains($0) }
    }

    private static func isUnfinishedHeadingLine(_ rawLine: String) -> Bool {
        let line = normalizedHeadingLine(rawLine)
        guard !line.isEmpty else { return false }
        for heading in unfinishedHeadings {
            if line == heading { return true }
            // A single word like "todo" or "remaining" must stand on its own;
            // a longer heading may introduce the list ("Next steps: …").
            guard heading != "todo", heading != "to-do", heading != "remaining" else { continue }
            guard line.hasPrefix(heading) else { continue }
            if let separator = line.dropFirst(heading.count).first,
               separator == ":" || separator == "—" || separator == "-" {
                return true
            }
        }
        return false
    }

    /// Strips the markdown decoration a heading or list item can carry, so
    /// `### Next steps`, `- **Next steps:**` and `2. Next steps` all reduce to
    /// the same text.
    private static func normalizedHeadingLine(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        while line.hasPrefix("#") { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        if let first = line.first, "-*•>+".contains(first) {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        if let dot = line.firstIndex(of: ".") {
            let prefix = line[..<dot]
            if !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) {
                line = String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        while line.hasPrefix("*") { line.removeFirst() }
        while line.hasSuffix("*") { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        while let last = line.last, last == ":" || last == "—" || last == "-" {
            line.removeLast()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        return line.lowercased()
    }

    /// The user-role message injected to keep the run going. It is explicit
    /// that the continuation is automatic, so the transcript and the model
    /// both know why another exchange appeared without the user typing.
    static func continuationText(trigger: Trigger, round: Int, maxRounds: Int) -> String {
        let progress = maxRounds > 0 ? "round \(round) of \(maxRounds)" : "round \(round)"
        switch trigger {
        case .unfinished:
            return """
            [Auto-proceed — \(progress)]
            Your previous reply said work was still outstanding. Continue now and finish it: pick up exactly where you stopped, use your tools, and keep any plan current. Do not ask for confirmation and do not repeat work that is already done. If the task is in fact complete, say so briefly and stop.
            """
        case .failure(let message):
            let clipped = message.count > 500 ? String(message.prefix(500)) + "…" : message
            return """
            [Auto-proceed after a failed attempt — \(progress)]
            The previous attempt ended with this error: \(clipped)

            Try again from where it stopped. If the same step failed twice, take a different approach instead of repeating it. Do not ask for confirmation unless you are truly blocked. If nothing more can be done, say briefly why and stop.
            """
        }
    }
}

/// The live countdown shown while AI Chat is about to continue on its own.
struct AutoProceedState: Equatable {
    let trigger: AIChatAutoProceed.Trigger
    let totalSeconds: Int
    var remainingSeconds: Int
}

extension AIChatAutoProceed.Trigger {
    /// True for the error-driven continuation, which gets different wording.
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
