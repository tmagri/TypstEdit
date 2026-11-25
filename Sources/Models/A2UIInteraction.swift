import Foundation

// MARK: - Result

/// What ended a surface interaction: a pressed button, or a dismissal.
enum A2UIInteractionResult: Equatable {
    /// A server action. The context is resolved and the data model snapshot
    /// rides along, so the model sees the whole form's state and not only the
    /// fields the button happened to name.
    case action(
        surfaceId: String,
        sourceComponentId: String,
        action: A2UIAction,
        dataModel: A2UIValue
    )
    case dismissed(surfaceIds: [String])
}

/// The surfaces waiting on the user, plus the interaction so far. Lives on
/// `AIChatManager` only while a surface card is on screen — the same shape as
/// `PendingQuestion`, because it solves the same problem: the run is suspended
/// on a continuation and the card is the whole interaction.
struct PendingSurfaceUI: Identifiable, Equatable {
    var id = UUID()
    var document: A2UIDocument
    /// The tool call that is suspended on this card, for the transcript row.
    var toolCallName: String
    /// An optional one-line caption the model asked for, above the card.
    var title: String? = nil

    /// How the rendered card is titled: the theme's own attribution when the
    /// model set one, otherwise the view supplies the assistant's name.
    var agentDisplayName: String? {
        document.surfaces.compactMap { $0.theme.agentDisplayName }.first
    }
}

extension PendingSurfaceUI {
    /// The tool result for a pressed button. The data model is included because
    /// a form is usually submitted by one button that names only a session id;
    /// without the model's own state the model would have to ask for the
    /// fields one at a time.
    static func resultText(
        surfaceId: String,
        sourceComponentId: String,
        action: A2UIAction,
        dataModel: A2UIValue
    ) -> String {
        var lines = [
            "The user submitted the form. Action \"\(action.name)\" came from component \"\(sourceComponentId)\" on surface \"\(surfaceId)\"."
        ]
        if action.context.isEmpty {
            lines.append("Action context: (none)")
        } else {
            lines.append("Action context: \(action.contextJSON)")
        }
        let snapshot = dataModel.jsonText ?? "{}"
        lines.append("Data model at submission: \(snapshot)")
        lines.append("Continue with these values in mind. Do not show the same form again in this run.")
        return lines.joined(separator: "\n")
    }

    /// The result when the card was dismissed. Same rule as a dismissed
    /// question: the model is told to proceed on a stated assumption, so a
    /// dismissal costs an assumption and not the turn.
    static func dismissedText(surfaceIds: [String]) -> String {
        let named = surfaceIds.isEmpty ? "the form" : surfaceIds.map { "\"\($0)\"" }.joined(separator: ", ")
        return "The user dismissed \(named) without submitting it. Proceed with your best judgment, state the assumption you are making, and do not show the same form again in this run."
    }
}
