import Foundation

/// A subagent that keeps working after the tool call that started it returns.
///
/// ## Why this exists
///
/// `agent__delegate_task` blocks the turn for the child's whole life: the parent
/// asked a question, and until the answer arrives the model cannot read, edit or
/// answer the user. That is right when the next step depends on the finding —
/// and wrong when it does not. A job like "check these twelve files for the
/// same bug" has an answer the model needs *eventually*, and making the user
/// wait through it is time spent on nothing.
///
/// OpenCode starts a subagent as a background job and reports back when the
/// child goes idle (`session/subagent-job.ts`). This is the same shape, reduced
/// to what a chat that runs one turn at a time can honour: a job is started,
/// polled by `agent__job_status`, and its report lands in the transcript as a
/// tool row when it finishes.
///
/// ## What is deliberately *not* here
///
/// There is no push. OpenCode's client can receive a message mid-turn because
/// its session is a durable stream; TypstEdit's is a `@MainActor` model that one
/// turn at a time drives, and a background child appending to a transcript the
/// user is currently typing into is a race with no upside over the next turn
/// reading a finished row. So the model polls once per turn — a cheap call that
/// costs nothing when the job has not finished — and the report is waiting when
/// it has.
enum BackgroundDelegation {

    /// Where a job has got to.
    enum State: String, Equatable {
        /// Running; no report yet.
        case running
        /// Finished and wrote its report.
        case finished
        /// Ended without a report: a stall, a provider error, or a refusal.
        case failed
        /// The user stopped the chat, or the job was cancelled.
        case cancelled
    }

    /// One job, as the model and the UI see it.
    struct Job: Identifiable, Equatable {
        let id: UUID
        /// The brief, kept whole so the status answer and the report can quote
        /// it — a job's id alone would force the model to remember what it
        /// asked for across a compaction.
        let task: String
        /// Files the child was told to start with.
        let files: [String]
        /// 1-based, so the report reads "Job 2 — …" the way `delegate_parallel`
        /// numbers its briefs.
        let number: Int
        var state: State = .running
        /// The report, once one exists. Nil while running or on failure.
        var report: String?
        /// Why it ended, when it ended without a report.
        var failure: String?
        let startedAt: Date
        var finishedAt: Date?

        /// Whether the model has already been handed this job's result.
        ///
        /// A finished job reports once. Without this the status tool would
        /// re-print the whole report on every poll, which is the token sink the
        /// report exists to avoid.
        var delivered: Bool = false

        var isTerminal: Bool { state != .running }

        /// How long it ran, for the status line.
        func duration(now: Date = Date()) -> TimeInterval {
            (finishedAt ?? now).timeIntervalSince(startedAt)
        }
    }

    /// Most jobs one chat may have running at once.
    ///
    /// Not a provider limit: it is the point past which the parent cannot keep
    /// track of what it asked for, and every extra job is a request the chat's
    /// own turn has to queue behind.
    static let maxConcurrentJobs = 4

    /// Most jobs one chat may have listed at once, finished ones included.
    static let maxTrackedJobs = 12

    /// Whether one more job may start.
    static func canStart(jobs: [Job]) -> Bool {
        runningCount(jobs) < maxConcurrentJobs
    }

    static func runningCount(_ jobs: [Job]) -> Int {
        jobs.filter { $0.state == .running }.count
    }

    /// The next job number, so numbering survives a finished job being pruned.
    static func nextNumber(_ jobs: [Job]) -> Int {
        (jobs.map(\.number).max() ?? 0) + 1
    }

    /// Drops old finished jobs so the list cannot grow without bound, keeping
    /// every running one and the newest finished ones.
    ///
    /// Undelivered results are kept longest: a report the model has not read is
    /// the one thing here it still needs.
    ///
    /// `limit` is a floor, not a hard cap: live work is never dropped to meet
    /// it. A chat with more running jobs than `limit` keeps them all, because
    /// the alternative is a running child writing into a job the parent can no
    /// longer see.
    static func pruned(_ jobs: [Job], keeping limit: Int = maxTrackedJobs) -> [Job] {
        guard jobs.count > limit else { return jobs }
        let running = jobs.filter { $0.state == .running }
        let undelivered = jobs.filter { $0.isTerminal && !$0.delivered }
        let delivered = jobs.filter { $0.isTerminal && $0.delivered }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
        let room = max(0, limit - running.count - undelivered.count)
        return (running + undelivered + delivered.prefix(room)).sorted { $0.number < $1.number }
    }

    /// The status answer for a job, or for every job when `number` is nil.
    ///
    /// A finished, undelivered job hands back its whole report — that is the
    /// point of asking. A finished, already-delivered one says so and does not
    /// repeat it: re-printing a report on every poll would undo the savings
    /// that made the job worth running in the background.
    static func statusText(
        jobs: [Job],
        number: Int? = nil,
        markDelivered: ((UUID) -> Void)? = nil
    ) -> String {
        let selected: [Job]
        if let number {
            selected = jobs.filter { $0.number == number }
            guard !selected.isEmpty else {
                let known = jobs.map { String($0.number) }.joined(separator: ", ")
                return known.isEmpty
                    ? "No background jobs have been started in this chat."
                    : "No job numbered \(number). Jobs in this chat: \(known)."
            }
        } else {
            guard !jobs.isEmpty else { return "No background jobs have been started in this chat." }
            selected = jobs.sorted { $0.number < $1.number }
        }

        let lines = selected.map { job -> String in
            let heading = "Job \(job.number) — \(oneLine(job.task))"
            switch job.state {
            case .running:
                return "\(heading)\nRUNNING — started \(Int(job.duration().rounded()))s ago. Nothing to read yet; check again later instead of waiting."
            case .finished:
                if job.delivered {
                    return "\(heading)\nFINISHED — its report was already given to you. Do not ask again for the same words; the findings are also saved on disk."
                }
                markDelivered?(job.id)
                let body = job.report?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(the report was empty)"
                return "\(heading)\nFINISHED — report follows.\n\n\(body)"
            case .failed:
                return "\(heading)\nFAILED — \(job.failure ?? "no reason was recorded"). Do not treat this job as done or as empty; run it again or do the work yourself."
            case .cancelled:
                return "\(heading)\nCANCELLED — \(job.failure ?? "the run was stopped"). Its findings are lost; run it again if you still need them."
            }
        }
        let header = selected.count == 1
            ? ""
            : "\(selected.count) background job\(selected.count == 1 ? "" : "s"):\n\n"
        return header + lines.joined(separator: "\n\n")
    }

    /// The brief's first line, clipped for a heading.
    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = flat.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }
}
