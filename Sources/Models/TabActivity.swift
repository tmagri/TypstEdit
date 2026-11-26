import Foundation
import Combine
import SwiftUI

/// What an open conversation is doing, for the tab strip.
///
/// The strip used to ask the *front* agent only (`tab.id == agent.session.id &&
/// agent.isGenerating`), so a chat running in another tab showed nothing at
/// all. Worse, nothing republished a background tab's run-level state, so even
/// a spinner that had been drawn would have stayed there after the run ended:
/// a run that finished, failed or parked on an approval card in a tab nobody
/// was looking at left no trace on screen. That is the "fails silently" shape —
/// the work is real, the window says nothing.
///
/// The states are deliberately about *run level*, not content: this type never
/// sees a streamed token.
enum TabActivity: Equatable {
    /// Nothing is running and the last run left nothing to answer.
    case idle
    /// A turn is running. The strip shows a spinner.
    case running
    /// The run is held at a turn boundary by Pause. Still a live run, but
    /// nothing is progressing until someone presses Resume.
    case paused
    /// The run cannot go on without a person: an approval card, a question
    /// card or a form is on screen in that conversation.
    case waiting
    /// The last run ended with an error the user has not looked at yet.
    case failed

    /// Whether this tab is running something the user asked for.
    ///
    /// A paused or waiting run is still live — `isGenerating` stays true for
    /// both — so a tab that reported neither as live would look like the work
    /// had vanished.
    var isLive: Bool { self != .idle && self != .failed }

    /// A run is progressing, so a spinner tells the truth.
    var isProgressing: Bool { self == .running }

    /// The glyph for the states a spinner would misrepresent. `nil` when the
    /// tab draws a spinner or nothing.
    var symbolName: String? {
        switch self {
        case .idle, .running: return nil
        case .paused: return "pause.circle.fill"
        case .waiting: return "questionmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// What the tab's tooltip says beyond the conversation name. `nil` for a
    /// tab with nothing to report, so an idle tab keeps its plain title.
    var helpText: String? {
        switch self {
        case .idle: return nil
        case .running: return "Running"
        case .paused: return "Paused — resume it to carry on"
        case .waiting: return "Waiting for your answer"
        case .failed: return "The last run stopped with an error"
        }
    }

    /// The glyph's colour. Red means read this, orange means someone has to
    /// act — the same two colours the rest of the window uses for those.
    var tint: Color {
        switch self {
        case .idle, .running: return .secondary
        case .paused, .waiting: return .orange
        case .failed: return .red
        }
    }
}

extension TabActivity {
    /// The run-level signals one conversation reports.
    ///
    /// A value rather than six reads of the agent, because `@Published` emits
    /// in `willSet`: a subscriber handed the new `isGenerating` that then reads
    /// `agent.isGenerating` gets the *old* one, so a monitor built by re-reading
    /// the agent would draw every state one change late — the spinner would
    /// appear when the run ended and clear when the next began.
    struct Inputs: Equatable {
        var isGenerating = false
        var isPaused = false
        var hasApproval = false
        var hasQuestion = false
        var hasSurface = false
        var error: String?

        init(
            isGenerating: Bool = false,
            isPaused: Bool = false,
            hasApproval: Bool = false,
            hasQuestion: Bool = false,
            hasSurface: Bool = false,
            error: String? = nil
        ) {
            self.isGenerating = isGenerating
            self.isPaused = isPaused
            self.hasApproval = hasApproval
            self.hasQuestion = hasQuestion
            self.hasSurface = hasSurface
            self.error = error
        }

        /// Reads the agent as it stands. Correct once, on demand (at init, on a
        /// tab switch); the live path takes the published values instead.
        @MainActor
        init(of agent: AIChatManager) {
            self.init(
                isGenerating: agent.isGenerating,
                isPaused: agent.isPaused,
                hasApproval: agent.pendingApproval != nil,
                hasQuestion: agent.pendingQuestion != nil,
                hasSurface: agent.pendingSurfaceUI != nil,
                error: agent.errorMessage
            )
        }
    }

    /// Derives a tab's state from its conversation's signals.
    ///
    /// `isFront` matters twice, and both are the "look here" rule:
    ///
    /// - A failure is news only *elsewhere*. The front chat already draws the
    ///   error row, and the marker has to clear the moment the user looks at
    ///   it, or it would be a permanent warning light on a chat they have read.
    /// - A waiting run is likewise the front tab's own business: its card is on
    ///   screen, so the strip keeps the ordinary spinner (the run is live) and
    ///   the glyph is reserved for the tabs nobody is looking at.
    ///
    /// `paused` is reported for the front tab too: it is a property of the run,
    /// not a request for attention, and a spinner over a parked run is a lie.
    static func of(_ inputs: Inputs, isFront: Bool) -> TabActivity {
        if inputs.isPaused { return .paused }
        if inputs.isGenerating {
            guard !isFront else { return .running }
            if inputs.hasApproval || inputs.hasQuestion || inputs.hasSurface { return .waiting }
            return .running
        }
        if !isFront, let error = inputs.error, !error.isEmpty { return .failed }
        return .idle
    }
}



/// The session list's own observable state: what each open conversation is
/// doing.
///
/// A separate `ObservableObject` from the session store, observed by the
/// session UI alone, and that is the whole point. Forwarding a background
/// conversation's busy flag through the store would repaint the entire chat
/// panel on every change. Here a background run finishing redraws the
/// session rows and nothing else.
///
/// It is fed by six run-level publishers per conversation (busy, paused, the
/// three cards, the error), all of which change a handful of times per turn.
/// Nothing about a streamed token reaches this type.
@MainActor
final class TabActivityMonitor: ObservableObject {

    /// The state of every conversation the store holds an agent for.
    /// Published so the session list redraws when one of them moves.
    @Published private(set) var states: [UUID: TabActivity] = [:]

    /// The latest signals per conversation, kept so a switch can recompute
    /// every conversation without going back to the agents.
    private var inputs: [UUID: TabActivity.Inputs] = [:]

    /// The conversation in front. Owned here because it is an input to the
    /// state of *every* row, not just the front one.
    private var frontID: UUID?

    /// The state to draw for a conversation. An unknown id is idle: a
    /// conversation whose agent was unloaded has nothing running by
    /// construction.
    func state(for id: UUID) -> TabActivity { states[id] ?? .idle }

    /// Forgets a conversation whose agent was unloaded.
    func forget(_ id: UUID) {
        guard inputs.removeValue(forKey: id) != nil else { return }
        recompute()
    }

    /// Records one conversation's signals. Called from its publishers, and
    /// once when the agent is built.
    func setInputs(_ next: TabActivity.Inputs, for id: UUID) {
        guard inputs[id] != next else { return }
        inputs[id] = next
        states[id] = TabActivity.of(next, isFront: id == frontID)
    }

    /// Points the monitor at the conversation in front. Both rows' states
    /// change: the one that left can now show a waiting card or an unread
    /// failure, and the one that arrived draws its own card on screen.
    func setFront(_ id: UUID) {
        guard frontID != id else { return }
        frontID = id
        recompute()
    }

    /// Recomputes every conversation, publishing only when something actually
    /// moved.
    ///
    /// A run end sets several of the observed signals in one turn; comparing
    /// the whole map keeps that from costing four redraws for one change.
    private func recompute() {
        var next: [UUID: TabActivity] = [:]
        for (id, value) in inputs {
            next[id] = TabActivity.of(value, isFront: id == frontID)
        }
        guard next != states else { return }
        states = next
    }
}
