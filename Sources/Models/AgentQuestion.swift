import Foundation

/// A structured question the assistant asks mid-run, and the answer that
/// resumes it.
///
/// The alternative — ending the turn and hoping the user replies in prose —
/// costs a whole round trip and usually loses the thread: the model has to
/// re-read the conversation and guess which of its open questions was
/// answered. Asking through a tool keeps the run suspended in place, so the
/// answer lands where the model asked for it.
///
/// This is deliberately **opt-in** (Settings → AI Chat → Ask Questions,
/// off by default). A question blocks the run until someone answers, which is
/// exactly wrong for an unattended job; the tool is most useful while
/// planning, where a couple of decisions up front save a lot of rewriting.
/// It is also never offered to a `delegate_task` subagent, which cannot talk
/// to the user at all.
struct AgentQuestion: Identifiable, Equatable {
    var id = UUID()
    /// The question itself, in one sentence — what the answer decides.
    var question: String
    /// A couple of words naming the topic, shown as the card's title.
    var header: String
    /// Suggested answers. The user can always type their own instead.
    var options: [AgentQuestionOption]
    /// Allow more than one selection.
    var multiple: Bool
}

struct AgentQuestionOption: Identifiable, Equatable {
    var id = UUID()
    /// The answer as it will be handed to the model.
    var label: String
    /// One line explaining the consequence of choosing it.
    var detail: String?

    /// Options are shown in the order the model gave them; a recommendation
    /// is expected to come first, per the tool's description.
    var isRecommended: Bool {
        label.localizedCaseInsensitiveContains("(recommended)")
    }
}

/// What the user answered for one question. Empty `selections` with no custom
/// text means they skipped it.
struct AgentQuestionAnswer: Equatable {
    var questionID: UUID
    var selections: [String] = []
    var custom: String?

    /// The answer as one line of the tool's result. `nil` when skipped.
    var text: String? {
        var parts = selections
        if let custom = custom?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            parts.append(custom)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    var isSkipped: Bool { text == nil }
}

/// The question set waiting on the user, plus the answer accumulated so far.
/// Lives on `AIChatManager` only while a question card is on screen.
struct PendingQuestion: Identifiable, Equatable {
    var id = UUID()
    var questions: [AgentQuestion]
    /// The tool call that is suspended on this card, for the transcript row.
    var toolCallName: String
    /// In-progress answers, keyed by question id. Held here rather than in the
    /// view so a redraw or a panel switch doesn't lose typing.
    var answers: [UUID: AgentQuestionAnswer] = [:]

    /// True when every question has something picked or typed.
    var isComplete: Bool {
        questions.allSatisfy { answers[$0.id]?.isSkipped == false }
    }

    /// True when the user has at least one answer to hand back.
    var hasAnyAnswer: Bool {
        questions.contains { answers[$0.id]?.isSkipped == false }
    }
}

extension PendingQuestion {
    /// Builds the tool result the model reads. Matches opencode's wording so
    /// models that have seen it before recognise the shape.
    ///
    /// A skipped question is reported as "Unanswered" rather than dropped, so
    /// the model knows it was considered and refused, not overlooked.
    static func resultText(questions: [AgentQuestion], answers: [UUID: AgentQuestionAnswer]) -> String {
        let formatted = questions
            .map { question in
                let answer = answers[question.id]?.text ?? "Unanswered"
                return "\"\(question.question)\"=\"\(answer)\""
            }
            .joined(separator: ", ")
        return "The user answered your questions: \(formatted). Continue with these answers in mind."
    }

    /// The result when the card was dismissed without an answer. The model is
    /// told to proceed and not to ask again in the same run, which is what
    /// keeps a dismissed question from costing the rest of the turn.
    static func dismissedText(questions: [AgentQuestion]) -> String {
        let asked = questions.map { "\"\($0.question)\"" }.joined(separator: ", ")
        return "The user dismissed these questions without answering: \(asked). Proceed with your best judgment, state the assumption you are making, and do not ask again in this run."
    }
}
