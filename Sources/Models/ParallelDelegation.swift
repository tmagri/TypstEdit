import Foundation

/// Concurrent read-only delegation: several `delegate_task` briefs run at once
/// instead of one after another.
///
/// ## Why this is a separate tool, not a wider `delegate_task`
///
/// `delegate_task` is deliberately *not* in `ParallelToolCalls.safeToolNames`,
/// so four of them in one reply run one at a time. That is right for reads
/// (which are cheap and must keep the model's order) but wrong for delegation:
/// a subagent is a whole conversation with its own requests, so serialising
/// them wastes every slot but one. A local server that can run four sessions
/// should be running four.
///
/// Widening the batch rule instead would have been the smaller diff and the
/// wrong one: `groups(for:)` splits on a *contiguous* run, so four delegations
/// separated by any other call would still serialise, and the model could not
/// tell when overlapping was safe. A tool that takes a list says it outright —
/// and the model only uses it when the jobs are actually independent, which is
/// the one thing a harness cannot infer for it.
///
/// ## What keeps it from overrunning the provider
///
/// The whole point of a slot count is that it is finite. A local server with
/// four slots answers four requests and *queues* the fifth, and a queued
/// request emits no bytes — indistinguishable from a dead one, so
/// `stallTimeoutSeconds` (90 s, and 10 s is enough to call it a stall) turns a
/// healthy run into "the model stopped responding".
///
/// Two rules follow, both enforced here rather than in a doc comment:
///
/// 1. **The front chat keeps a slot.** `ParallelDelegation.effectiveWorkers`
///    caps workers at `slots - 1`, because the parent conversation is a
///    session of its own and must stay answerable while its workers run.
/// 2. **A permit is held for a worker's whole life, and admission is before
///    the request.** `ProviderGate` is process-wide, so two tabs delegating at
///    once cannot add up past the same limit. Waiting happens *outside* the
///    request, so nothing is ever in flight without a permit and the stall
///    watchdog never sees a queue.
enum ParallelDelegation {

    /// Hard ceiling on workers, whatever the settings ask for.
    ///
    /// Not a provider limit: it is the point past which a result list stops
    /// being something a model can actually read and reconcile in one round.
    /// A user with an eight-slot server is better served by two rounds of four.
    static let maxWorkers = 8

    /// Most briefs one call may carry. More than `maxWorkers` is fine — the
    /// extras wait for a free worker — but a list this long is no longer
    /// something the parent can reconcile in one reading, so it is refused
    /// with a message rather than silently trimmed.
    static let maxBriefs = 16

    /// How many permits the process-wide gate holds for subagents: the
    /// server's slots minus the one the chat keeps, and `0` (no gate) when the
    /// slot count is unknown. At least one, so a one- or two-slot server can
    /// still delegate, one worker at a time.
    nonisolated static func gateCapacity(slots: Int) -> Int {
        slots > 0 ? max(1, slots - 1) : 0
    }

    /// What one brief in a `delegate_parallel` call asks for.
    struct Brief: Equatable {
        /// The complete stand-alone job, as the subagent will read it.
        var task: String
        /// Relative paths it should look at first. Empty is normal.
        var files: [String]
    }

    /// Reads the `briefs` argument. Tolerant in the same way `parseQuestions`
    /// is: a model that sends one bare string, or omits `files`, still gets a
    /// usable round instead of an error that wastes the call.
    ///
    /// An entirely empty entry is dropped rather than run, because a subagent
    /// with no brief answers nothing and costs a full request to find out.
    nonisolated static func parseBriefs(_ arguments: [String: Any]) -> [Brief] {
        let raw = arguments["briefs"] as? [Any] ?? []
        return raw.compactMap { entry -> Brief? in
            if let text = entry as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : Brief(task: trimmed, files: [])
            }
            guard let object = entry as? [String: Any],
                  let task = (object["task"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !task.isEmpty else { return nil }
            let files = (object["files"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Brief(task: task, files: files)
        }
    }

    /// How many workers to run for a resolved setting.
    ///
    /// This is the one place the slot arithmetic lives. `slots == 0` means the
    /// server's limit is unknown (a paid API, or a local server the user has
    /// not measured), and then the requested worker count is the only bound —
    /// guessing a cap there would silently ignore a setting the user chose.
    ///
    /// With a known slot count the parent takes one, so `slots - 1` is what is
    /// really available; `max(1, …)` keeps a one-slot server able to delegate
    /// at all (sequentially, which is what it can do).
    nonisolated static func effectiveWorkers(requested: Int, slots: Int) -> Int {
        let asked = min(max(requested, 0), maxWorkers)
        guard asked > 0 else { return 0 }
        guard slots > 0 else { return asked }
        return min(asked, max(1, slots - 1))
    }

    /// The worker count a chat request actually runs with: the model's
    /// override, else the global setting, then capped by the server's slots.
    /// `0` = off, which is the default — this feature costs the provider more
    /// requests per turn, so nobody gets it by surprise.
    nonisolated static func workers(for requested: Int?, slots: Int) -> Int {
        effectiveWorkers(requested: requested ?? 0, slots: slots)
    }

    /// A file name for one worker's saved report.
    ///
    /// `findings.md` is a single file that the latest delegation replaces, by
    /// design (`Scratchpad.writeFindings`). Four workers writing it at once
    /// would leave one report and three silently lost — so a parallel round
    /// writes one file per brief instead, and the round's own merge carries
    /// all of them in the reply.
    nonisolated static func findingsName(index: Int, task: String) -> String {
        let words = task
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(3)
        let slug = words.joined(separator: "-")
        let suffix = slug.isEmpty ? "" : "-\(slug.prefix(40))"
        return "findings-\(index + 1)\(suffix).md"
    }

    /// How the round's results are handed back to the model.
    ///
    /// One heading per brief, in the order the briefs were written, so the
    /// parent can cite "brief 2" without re-reading anything. A brief that
    /// failed says so in its own section rather than shortening the list: a
    /// missing section reads as "that job found nothing", which is a different
    /// and much worse claim.
    nonisolated static func merged(
        briefs: [Brief],
        results: [Int: String],
        failures: [Int: String],
        workers: Int
    ) -> String {
        var sections: [String] = []
        for (index, brief) in briefs.enumerated() {
            let heading = "## Brief \(index + 1) — \(oneLine(brief.task))"
            if let failure = failures[index] {
                sections.append("\(heading)\n\nFAILED — this brief produced no findings: \(failure)\nDo not treat this job as done or as empty; run it again or do it yourself.")
            } else if let text = results[index],
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append("\(heading)\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            } else {
                sections.append("\(heading)\n\nNOT RUN — no report came back for this brief.")
            }
        }
        let header = workers > 1
            ? "Ran \(briefs.count) brief\(briefs.count == 1 ? "" : "s") in parallel (\(workers) at a time). Reports follow in the order you wrote them."
            : "Ran \(briefs.count) brief\(briefs.count == 1 ? "" : "s") one after another, because this model is set to one subagent at a time."
        return ([header] + sections).joined(separator: "\n\n")
    }

    /// The brief's first line, clipped for a heading.
    nonisolated static func oneLine(_ text: String) -> String {
        let flat = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? text
        let trimmed = flat.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }
}

/// How one worker ended. An enum rather than `Result`, for the same reason as
/// `ReadOnlyToolResult`: the failure is a message for the model, not an
/// `Error`, and an existential error cannot cross a task-group boundary.
enum WorkerOutcome: Sendable, Equatable {
    case report(String)
    case failed(String)
}

/// What one parallel worker is doing right now, for the live box.
///
/// The front chat has exactly one of everything live — one answer, one
/// reasoning buffer, one status line — because it runs one turn at a time.
/// Four workers at once cannot share those: each round's reasoning would pile
/// into the parent's buffer, which is the same defect `LiveNarration` was
/// written to fix, four times over and with no way to tell whose words were
/// whose. So a worker's stream goes here, keyed by the worker, and the view
/// draws a short row per worker instead of one shared blob.
struct ParallelWorkerState: Identifiable, Equatable {
    let id: UUID
    /// 1-based, matching its `## Brief N` heading in the merged report.
    var index: Int
    /// What it is doing, in its own words or the harness's.
    var status: String
    /// The tail of its reasoning, already clipped for display.
    var reasoning: String
}

/// Counts how many provider requests may be in flight at once.
///
/// Process-wide on purpose: `ChatWorkspace` keeps one agent per open
/// conversation, so two tabs delegating at the same time would each respect
/// their own private limit and together overrun a four-slot server. The
/// provider's limit is a property of the machine, not of a chat.
///
/// Only subagent requests take a permit. The front conversation's own turn is
/// what the reserved slot is *for*, and gating it too would mean a chat
/// waiting behind its own workers.
actor ProviderGate {

    static let shared = ProviderGate()

    /// A waiter, identified so a cancelled one can be removed by name. A plain
    /// continuation cannot be found again, and matching on "some cancelled
    /// waiter" would drop a live request instead.
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Permits available. `0` = unknown, so nothing is counted and every
    /// caller is admitted immediately. Changing it drops the queue, because a
    /// user raising the limit while requests are parked should not have to
    /// wait for a release that is now unnecessary.
    private var capacity = 0
    private var inUse = 0
    private var waiters: [Waiter] = []

    /// Sets the capacity. Called before a round admits any work.
    func setCapacity(_ newCapacity: Int) {
        let clamped = max(0, newCapacity)
        guard clamped != capacity else { return }
        capacity = clamped
        guard clamped > 0 else {
            // Unlimited now: everyone who was waiting may go without a permit.
            let parked = waiters
            waiters = []
            for waiter in parked { waiter.continuation.resume(returning: false) }
            return
        }
        admitWaiters()
    }

    /// Waits for a permit.
    ///
    /// Returns `true` when a permit is held and must be given back, `false`
    /// when the caller may proceed ungated — either because the limit is
    /// unknown, or because it was parked and then cancelled. The caller checks
    /// `Task.isCancelled` right afterwards, so a cancelled worker never runs
    /// for a conversation that is already over.
    func acquire() async -> Bool {
        guard capacity > 0 else { return false }
        if inUse < capacity {
            inUse += 1
            return true
        }
        let id = UUID()
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // Cancelled while it was on its way here: never queue.
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            // `self`, not `.shared`: a test's private gate must cancel its own
            // waiter, not look for it in the app's.
            Task { await self.cancelWaiter(id) }
        }
        return admitted
    }

    /// Removes one parked waiter and lets it through ungated. Called from the
    /// cancellation handler, which cannot touch actor state itself.
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    /// Releases a permit, admitting the next waiter if there is one.
    func release() {
        guard capacity > 0, inUse > 0 else { return }
        if !waiters.isEmpty {
            // Hand the permit straight over rather than decrementing and
            // re-incrementing, so `inUse` never dips between the two.
            let next = waiters.removeFirst()
            next.continuation.resume(returning: true)
            return
        }
        inUse -= 1
    }

    /// Admits as many waiters as there is room for.
    private func admitWaiters() {
        while inUse < capacity, !waiters.isEmpty {
            let next = waiters.removeFirst()
            inUse += 1
            next.continuation.resume(returning: true)
        }
    }

    /// Current state, for tests and for the Tools menu's status line.
    func snapshot() -> (capacity: Int, inUse: Int, waiting: Int) {
        (capacity, inUse, waiters.count)
    }

    /// Test-only reset: a leaked permit would silently shrink every later
    /// round in the same process.
    func reset() {
        capacity = 0
        inUse = 0
        let parked = waiters
        waiters = []
        for waiter in parked { waiter.continuation.resume(returning: false) }
    }
}
