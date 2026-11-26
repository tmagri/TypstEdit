import Foundation

/// What a finished unattended run shows for one run: the report the task
/// wrote, and the steps (tool calls) it took to get there.
///
/// Built from the run's saved transcript and nothing else, so it is plain data
/// that a test can construct without a window or a model.
struct RunReport: Equatable {

    /// One tool call the run made.
    struct Step: Identifiable, Equatable {
        let id: UUID
        /// The tool's short name ("web_fetch", "read_file").
        let label: String
        let status: ChatMessage.ToolStatus
        /// The call's arguments, cut to one short preview.
        let arguments: String?
        /// The tool's output, cut to `outputLimit` characters.
        let output: String?
        /// Whether `output` was cut, so the view can say so honestly.
        let outputWasCut: Bool
        /// Work done inside a delegated subagent, drawn indented.
        let isSubagent: Bool
    }

    /// The report: the last thing the task said. `nil` when it said nothing.
    let reportText: String?
    let steps: [Step]

    /// Calls the unattended run was refused (nobody was there to approve them,
    /// or its permission profile did not allow them).
    var refusedCount: Int { steps.filter { $0.status == .denied }.count }
    var failedCount: Int { steps.filter { $0.status == .failed }.count }

    /// How much of one tool's output is kept. A single tool result can run to
    /// tens of kilobytes; the view needs enough to read, not the whole page.
    static let outputLimit = 1_500

    init(messages: [ChatMessage]) {
        reportText = messages
            .last { message in
                message.role == .assistant
                    && !message.isSubagent
                    && !message.isSummary
                    && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }

        steps = messages.filter { $0.role == .toolCall }.map { message in
            let raw = (message.toolOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cut = raw.count > Self.outputLimit
            return Step(
                id: message.id,
                label: message.toolLabel,
                // A row with no recorded status was written before statuses
                // existed, by a call that ran: read it as having succeeded.
                status: message.toolStatus ?? .succeeded,
                arguments: message.toolArgumentsPreview,
                output: raw.isEmpty ? nil : (cut ? String(raw.prefix(Self.outputLimit)) : raw),
                outputWasCut: cut,
                isSubagent: message.isSubagent
            )
        }
    }

    /// One line over the steps: "4 steps · 1 refused · 1 failed".
    var summary: String {
        guard !steps.isEmpty else { return "No tools were used" }
        var parts = ["\(steps.count) step\(steps.count == 1 ? "" : "s")"]
        if refusedCount > 0 { parts.append("\(refusedCount) refused") }
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        return parts.joined(separator: " · ")
    }
}
