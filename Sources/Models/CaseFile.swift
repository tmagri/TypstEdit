import Foundation

/// The case file: the goal of a goal-directed chat, held as state outside
/// the transcript.
///
/// ## Why this exists
///
/// The objective of a long job used to live only inside the compaction
/// summary, which the model rewrites every time it compacts. A goal that the
/// model may rewrite drifts quietly, and nothing checked the result against
/// it before the model said "done". LangGraph keeps a typed state object
/// beside the messages for the same reason; the case file is that object,
/// shaped by how courts and philosophers arrive at a conclusion:
///
/// - **Charter** — the question presented: objective, definitions,
///   constraints, what is out of scope. The user ratifies it; the model can
///   propose a change but cannot make one (a "motion to amend").
/// - **Standard** — the standard of proof, agreed before the argument: the
///   criteria the result must meet. A criterion is met only with evidence on
///   the record.
/// - **Settled** — stare decisis. A ruling binds later turns; only the user
///   can overrule one.
/// - **Issues** — open questions. Objections raised by the adversarial review
///   land here and block the verdict until answered.
/// - **Claims** — Toulmin's model of an argument (claim, grounds, warrant,
///   qualifier, rebuttal), with Popper's rule that a claim must say what
///   would refute it.
/// - **Phase** — Peirce's cycle as a small state machine: discovery
///   (Socratic definitions), hypothesis (abduction), build (deduction),
///   verify (induction and the opposing-counsel review), verdict.
///
/// The phases are roles, and a `CaseMethod` names them and picks the gates:
/// the inquiry method above, or the engineering method (requirements, a
/// trade study between `options`, a `risks` register, iteration on failed
/// verification, a budget), or one the user wrote.
///
/// Everything here is pure value logic so the rules are testable without a
/// model. `AIChatManager` owns the gates that need a person (the ratification
/// card) or a model (the review and the drift check).
struct CaseFile: Codable, Equatable {
    /// The five stage roles every method has. A method gives them their
    /// names and guidance (`CaseMethod.stage(_:)`).
    enum Phase: String, Codable, CaseIterable {
        case discovery
        case hypothesis
        case build
        case verify
        case verdict

        var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    struct Charter: Codable, Equatable {
        var objective: String
        var definitions: [String] = []
        var constraints: [String] = []
        var outOfScope: [String] = []
        /// The resources the user grants: finished turns, and rounds of
        /// build → verify. `nil` = no limit. Part of the charter, so raising
        /// it needs the user like any other charter change.
        var turnBudget: Int?
        var iterationBudget: Int?

        init(
            objective: String,
            definitions: [String] = [],
            constraints: [String] = [],
            outOfScope: [String] = [],
            turnBudget: Int? = nil,
            iterationBudget: Int? = nil
        ) {
            self.objective = objective
            self.definitions = definitions
            self.constraints = constraints
            self.outOfScope = outOfScope
            self.turnBudget = turnBudget
            self.iterationBudget = iterationBudget
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            objective = try container.decode(String.self, forKey: .objective)
            definitions = try container.decodeIfPresent([String].self, forKey: .definitions) ?? []
            constraints = try container.decodeIfPresent([String].self, forKey: .constraints) ?? []
            outOfScope = try container.decodeIfPresent([String].self, forKey: .outOfScope) ?? []
            turnBudget = try container.decodeIfPresent(Int.self, forKey: .turnBudget)
            iterationBudget = try container.decodeIfPresent(Int.self, forKey: .iterationBudget)
        }
    }

    /// One alternative in a trade study. Engineering requires at least two
    /// before committing; any method may use them.
    struct Option: Codable, Equatable, Identifiable {
        enum Status: String, Codable, CaseIterable {
            case candidate
            case chosen
            case rejected
        }

        var id: String
        var title: String
        var summary: String = ""
        var pros: [String] = []
        var cons: [String] = []
        /// Criterion id → 0…5. The trade study's scorecard.
        var scores: [String: Int] = [:]
        var status: Status = .candidate

        var total: Int { scores.values.reduce(0, +) }
        var isEvaluated: Bool { !scores.isEmpty || !pros.isEmpty || !cons.isEmpty }
    }

    /// One entry in the risk register.
    struct Risk: Codable, Equatable, Identifiable {
        enum Status: String, Codable, CaseIterable {
            case open
            case mitigated
            /// Accepted as it is. Needs the user when the risk is high.
            case accepted
        }

        var id: String
        var text: String
        /// 1 low, 2 medium, 3 high.
        var likelihood: Int
        var impact: Int
        var mitigation: String?
        var status: Status = .open

        var severity: Int { likelihood * impact }
        /// 6 or more: high × medium or worse.
        var isHigh: Bool { severity >= 6 }
        var isClosed: Bool { status != .open }
    }

    struct Criterion: Codable, Equatable, Identifiable {
        var id: String
        var text: String
        var met: Bool = false
        var evidence: String?
    }

    struct Ruling: Codable, Equatable, Identifiable {
        var id: String
        var text: String
        var reason: String
        /// True when the user decided it (an approved card, or a ruling the
        /// user stated); false for a decision the model recorded.
        var byUser: Bool
        /// Why it was overruled, once the user overrules it. An overruled
        /// ruling is kept so the record shows the reversal.
        var overruled: String?

        var isInForce: Bool { overruled == nil }
    }

    struct Issue: Codable, Equatable, Identifiable {
        var id: String
        var text: String
        var blocking: Bool
        /// Only the user can answer it. While one is open the run waits for
        /// the user instead of continuing by itself.
        var needsUser: Bool
        /// Raised by `agent__review_case` (opposing counsel).
        var fromReview: Bool
        var resolution: String?

        var isOpen: Bool { resolution == nil }
    }

    struct Claim: Codable, Equatable, Identifiable {
        enum Status: String, Codable, CaseIterable {
            case proposed
            case supported
            case refuted
            case withdrawn
        }

        var id: String
        var claim: String
        var grounds: String
        var warrant: String?
        var qualifier: String?
        /// What would show the claim to be false. Required: a claim that
        /// nothing could refute is not a claim the work can be judged by.
        var rebuttal: String
        var status: Status
    }

    struct Review: Codable, Equatable {
        var date: Date
        var objections: Int
        /// The evidence revision the review looked at. A later change to the
        /// evidence makes the review stale.
        var revision: Int
        /// How many checklist items this review actually judged. `0` for a
        /// review recorded before per-item verdicts existed, which is also
        /// what makes `isReviewCurrent` fall back to the revision stamp.
        var checked: Int = 0
    }

    /// One reviewer verdict on one thing in the case.
    ///
    /// The checklist is what stops a re-review from starting over. The
    /// reviewer used to be given the entire case, re-read the evidence and
    /// hand back free-text objections, and every fix anywhere bumped the
    /// single `revision` counter and invalidated all of that work — so a
    /// case that needed four fixes paid for four full reviews. With a verdict
    /// per item, a re-review only re-checks the items whose evidence moved.
    struct ReviewCheck: Codable, Equatable {
        enum Verdict: String, Codable {
            /// The evidence for it holds.
            case passes
            /// It does not: the review also raised an objection, which is
            /// now a blocking issue.
            case fails
        }

        var verdict: Verdict
        /// A digest of what was judged. When the item's evidence changes the
        /// digest changes, and the verdict stops counting — the item is stale
        /// again. Nothing else can make a verdict stale.
        var fingerprint: String
        /// Why it failed, or what the reviewer verified. One line.
        var note: String?
        var date: Date
    }

    /// One thing the reviewer is responsible for, computed from the case and
    /// its recorded verdicts.
    struct ReviewItem: Equatable, Identifiable {
        enum Kind: String, Equatable {
            case criterion
            case claim
            case risk
            case ruling

            /// How the item is named in the reviewer's protocol.
            var label: String {
                switch self {
                case .criterion: return "criterion"
                case .claim: return "claim"
                case .risk: return "risk"
                case .ruling: return "ruling"
                }
            }
        }

        var id: String
        var kind: Kind
        /// One line describing what is judged, for the reviewer's brief.
        var subject: String
        var fingerprint: String
        /// The verdict recorded against an earlier fingerprint, if any.
        var recorded: ReviewCheck?

        /// True when no verdict exists for the item *as it is now*.
        var isStale: Bool { recorded == nil || recorded?.fingerprint != fingerprint }
        /// `.unchecked` collapses "never looked at" and "the evidence moved
        /// since it was last looked at": both mean it needs a look now.
        var verdict: ReviewCheck.Verdict? { isStale ? nil : recorded?.verdict }
        var passed: Bool { verdict == .passes }

        /// Whether the next review must judge this item.
        ///
        /// Stale means "never judged, or the evidence moved". **Failed** means
        /// "judged and rejected": a verdict does exist against the current
        /// evidence, so `isStale` is false — and that was the bug. A failed
        /// item was neither stale (so no re-review asked about it) nor passed
        /// (so `isReviewCurrent` could never be true). The queue came out
        /// empty, every round confirmed "nothing changed", and the case was
        /// stuck forever with a blocking verdict nobody was asked to revisit.
        ///
        /// Re-judging a failure is the point: the work may have been fixed
        /// since. If it still fails, the same objection is not raised twice
        /// (`bankingReview` dedupes it), so this cannot spin on its own.
        var needsJudging: Bool { isStale || recorded?.verdict == .fails }
    }

    var charter: Charter?
    var charterRatified = false
    var criteria: [Criterion] = []
    var settled: [Ruling] = []
    var issues: [Issue] = []
    var claims: [Claim] = []
    var phase: Phase = .discovery
    var lastReview: Review?
    /// Per-item reviewer verdicts, keyed `S1`, `C2`, `R1`… See `ReviewCheck`
    /// and `reviewChecklist`. Empty for a case whose reviews predate the
    /// checklist, which keeps `isReviewCurrent` working off `Revision` alone.
    var reviewChecks: [String: ReviewCheck] = [:]
    /// The drift check's last warning, cleared when it reports on track.
    var drift: String?
    /// Bumps whenever the evidence changes: the charter, a criterion, a
    /// claim. The review and the verdict are judged against it.
    var revision = 0
    var openedAt = Date()
    /// The last number issued per id prefix (`S`, `D`, `Q`, `C`, `O`, `R`).
    var idCounters: [String: Int] = [:]
    /// The method's rules, copied in when the case opened or the user
    /// approved a change of method. A copy, so editing a method file never
    /// changes a case already under way.
    var method: CaseMethod = .inquiry
    var options: [Option] = []
    var risks: [Risk] = []
    /// Rounds of build → verify so far. A failed verification starts a new
    /// one.
    var iteration = 1
    /// Finished turns of this case, counted against the charter's budget.
    var turnsUsed = 0

    init() {}

    init(method: CaseMethod) {
        self.method = method
    }

    /// Every key is optional on the way in, so a case saved before a field
    /// existed still opens instead of failing the whole conversation file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        charter = try container.decodeIfPresent(Charter.self, forKey: .charter)
        charterRatified = try container.decodeIfPresent(Bool.self, forKey: .charterRatified) ?? false
        criteria = try container.decodeIfPresent([Criterion].self, forKey: .criteria) ?? []
        settled = try container.decodeIfPresent([Ruling].self, forKey: .settled) ?? []
        issues = try container.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        claims = try container.decodeIfPresent([Claim].self, forKey: .claims) ?? []
        phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .discovery
        lastReview = try container.decodeIfPresent(Review.self, forKey: .lastReview)
        reviewChecks = try container.decodeIfPresent([String: ReviewCheck].self, forKey: .reviewChecks) ?? [:]
        drift = try container.decodeIfPresent(String.self, forKey: .drift)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        openedAt = try container.decodeIfPresent(Date.self, forKey: .openedAt) ?? Date()
        idCounters = try container.decodeIfPresent([String: Int].self, forKey: .idCounters) ?? [:]
        method = try container.decodeIfPresent(CaseMethod.self, forKey: .method) ?? .inquiry
        options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
        risks = try container.decodeIfPresent([Risk].self, forKey: .risks) ?? []
        iteration = try container.decodeIfPresent(Int.self, forKey: .iteration) ?? 1
        turnsUsed = try container.decodeIfPresent(Int.self, forKey: .turnsUsed) ?? 0
    }

    // MARK: - Derived state

    var metCount: Int { criteria.filter(\.met).count }
    var openIssues: [Issue] { issues.filter(\.isOpen) }
    var hasOpenUserIssue: Bool { openIssues.contains(where: \.needsUser) }
    /// A review is current when the reviewer has judged every item that
    /// exists now, against the evidence as it is now.
    ///
    /// This replaces "the revision stamp matches", which a single fix
    /// anywhere invalidated wholesale. The revision stamp is still the answer
    /// for a case reviewed before the checklist existed — that is,
    /// `reviewChecks` is empty because no round ever recorded per-item
    /// verdicts. Testing the *recorded verdicts* and not the checklist is
    /// what makes that fallback work: an old case still has criteria, so a
    /// checklist-shaped test would report it stale forever and it could never
    /// reach a verdict.
    var isReviewCurrent: Bool {
        guard let lastReview else { return false }
        guard !reviewChecks.isEmpty else { return lastReview.revision == revision }
        return reviewChecklist.allSatisfy(\.passed)
    }
    var chosenOption: Option? { options.first { $0.status == .chosen } }
    var openHighRisks: [Risk] { risks.filter { $0.isHigh && !$0.isClosed } }

    func title(for phase: Phase) -> String { method.title(for: phase) }
    var phaseTitle: String { title(for: phase) }

    /// Whether the user's budget is spent. Spent means stop and ask: the
    /// model may finish the turn, not start another one on its own.
    var budgetExhausted: Bool {
        if let turns = charter?.turnBudget, turns > 0, turnsUsed >= turns { return true }
        if let rounds = charter?.iterationBudget, rounds > 0, iteration > rounds { return true }
        return false
    }

    /// Why the case cannot leave the proposal stage yet: the method's trade
    /// study. Empty means it can.
    var designBlockers: [String] {
        let needed = method.gates.minimumOptions
        guard needed > 0 else { return [] }
        var blockers: [String] = []
        let evaluated = options.filter(\.isEvaluated).count
        if evaluated < needed {
            blockers.append("the trade study needs at least \(needed) evaluated options (\(evaluated) so far)")
        }
        if chosenOption == nil {
            blockers.append("no option chosen yet (choose_option)")
        }
        return blockers
    }

    /// Why the case cannot reach a verdict yet. Empty means it can.
    func verdictBlockers(reviewRequired: Bool) -> [String] {
        var blockers: [String] = []
        if charter == nil {
            blockers.append("there is no charter")
        } else if !charterRatified {
            blockers.append("the user has not ratified the charter")
        }
        if criteria.isEmpty {
            blockers.append("there is no standard (no done-when criteria)")
        }
        let unmet = criteria.filter { !$0.met }.map(\.id)
        if !unmet.isEmpty {
            blockers.append("criteria not met: \(unmet.joined(separator: ", "))")
        }
        let blocking = openIssues.filter(\.blocking).map(\.id)
        if !blocking.isEmpty {
            blockers.append("blocking issues open: \(blocking.joined(separator: ", "))")
        }
        let untested = claims.filter { $0.status == .proposed }.map(\.id)
        if method.gates.claimsMustBeTested, !untested.isEmpty {
            blockers.append("claims still untested (supported, refuted or withdrawn needed): \(untested.joined(separator: ", "))")
        }
        blockers.append(contentsOf: designBlockers)
        if method.gates.highRisksMustBeClosed {
            let high = openHighRisks.map(\.id)
            if !high.isEmpty {
                blockers.append("high risks still open (mitigate, or the user accepts): \(high.joined(separator: ", "))")
            }
        }
        if reviewRequired, !isReviewCurrent {
            blockers.append(lastReview == nil
                ? "no adversarial review yet (run agent__review_case)"
                : "the evidence changed since the last review (run agent__review_case again)")
        }
        return blockers
    }

    /// Whether the model has work it can do without the user. Drives the
    /// case-aware auto-proceed: a ratified case in a working phase with
    /// unmet criteria, open blocking issues or a stale review, and no open
    /// question that only the user can answer.
    func agentCanContinue(reviewRequired: Bool) -> Bool {
        guard charterRatified, phase != .discovery, phase != .verdict else { return false }
        guard !hasOpenUserIssue, !budgetExhausted else { return false }
        if phase == .hypothesis, !designBlockers.isEmpty { return true }
        if criteria.contains(where: { !$0.met }) { return true }
        if method.gates.highRisksMustBeClosed, !openHighRisks.isEmpty { return true }
        if openIssues.contains(where: \.blocking) { return true }
        if reviewRequired, !criteria.isEmpty, !isReviewCurrent { return true }
        return false
    }

    /// One line on what is still open, for the continuation message.
    func outstandingSummary(reviewRequired: Bool) -> String {
        let blockers = verdictBlockers(reviewRequired: reviewRequired)
        return blockers.isEmpty ? "nothing — the case can reach a verdict" : blockers.joined(separator: "; ")
    }

    // MARK: - The review checklist

    /// Everything the reviewer is responsible for, each with the verdict it
    /// last recorded — or none when the item is new or its evidence moved.
    ///
    /// Derived, never stored as a list: criteria, claims, risks and rulings
    /// are already the case's state, and a second copy of them would be a
    /// second truth. What *is* stored is the verdict per item
    /// (`reviewChecks`), keyed by the item's id.
    ///
    /// Order is deliberate and matches `nextCheck`: the standard first (it is
    /// what the work is judged by), then claims, then risks, then the rulings
    /// a change must not break.
    var reviewChecklist: [ReviewItem] {
        var items: [ReviewItem] = []

        for criterion in criteria {
            items.append(ReviewItem(
                id: criterion.id,
                kind: .criterion,
                subject: "\(criterion.id) \(Self.oneLine(criterion.text, max: Self.promptLineLimit))"
                    + (criterion.met ? " — claimed met; evidence: \(criterion.evidence ?? "none given")" : " — not claimed met"),
                fingerprint: Self.fingerprint(criterion),
                recorded: reviewChecks[criterion.id]
            ))
        }

        for claim in claims where claim.status != .withdrawn {
            items.append(ReviewItem(
                id: claim.id,
                kind: .claim,
                subject: "\(claim.id) [\(claim.status.rawValue)] \(Self.oneLine(claim.claim, max: Self.promptLineLimit)) — refuted if: \(Self.oneLine(claim.rebuttal, max: 120))",
                fingerprint: Self.fingerprint(claim),
                recorded: reviewChecks[claim.id]
            ))
        }

        // Only risks that still matter: a closed, non-high risk is not
        // something to spend a review on, and re-checking it every round is
        // exactly the waste the checklist exists to remove.
        for risk in risks where !risk.isClosed || risk.isHigh {
            items.append(ReviewItem(
                id: risk.id,
                kind: .risk,
                subject: "\(risk.id) [\(risk.status.rawValue)\(risk.isHigh ? ", HIGH" : "")] \(Self.oneLine(risk.text, max: Self.promptLineLimit)) — \(risk.likelihood)×\(risk.impact)\(risk.mitigation.map { "; mitigation: \(Self.oneLine($0, max: 120))" } ?? "")",
                fingerprint: Self.fingerprint(risk),
                recorded: reviewChecks[risk.id]
            ))
        }

        for ruling in settled where ruling.isInForce {
            items.append(ReviewItem(
                id: ruling.id,
                kind: .ruling,
                subject: "\(ruling.id) \(Self.oneLine(ruling.text, max: Self.promptLineLimit)) — \(Self.oneLine(ruling.reason, max: 120))",
                fingerprint: Self.fingerprint(ruling),
                recorded: reviewChecks[ruling.id]
            ))
        }

        return items
    }

    /// The items a re-review must look at: new, the evidence moved, or the
    /// last look rejected it.
    ///
    /// The failed ones matter as much as the stale ones. A failure has a
    /// verdict against the current evidence, so it is not stale — but it is
    /// not passed either, so leaving it out of the queue is what made a case
    /// unreachable: `isReviewCurrent` stayed false (correctly, D2 had failed)
    /// while every round was told to check nothing and confirmed nothing had
    /// changed. Naming a failed item here is what lets a fix be re-judged.
    var staleReviewItems: [ReviewItem] { reviewChecklist.filter(\.needsJudging) }

    /// What each kind of item's fingerprint covers. The rule throughout is
    /// **the evidence and nothing else**: a criterion's fingerprint does not
    /// include its id (never reused, never rewritten), and no item's includes
    /// anything from another item, so one fix cannot invalidate the rest.
    static func fingerprint(_ criterion: Criterion) -> String {
        // What is judged is the claim plus the evidence offered for it, so
        // re-marking with new evidence is a new thing to check and re-marking
        // with the same evidence is not.
        "S|\(criterion.met ? "met" : "unmet")|\(criterion.text)|\(criterion.evidence ?? "")"
    }

    static func fingerprint(_ claim: Claim) -> String {
        "C|\(claim.status.rawValue)|\(claim.claim)|\(claim.grounds)|\(claim.rebuttal)"
    }

    static func fingerprint(_ risk: Risk) -> String {
        "R|\(risk.status.rawValue)|\(risk.text)|\(risk.likelihood)×\(risk.impact)|\(risk.mitigation ?? "")"
    }

    static func fingerprint(_ ruling: Ruling) -> String {
        "D|\(ruling.text)|\(ruling.reason)"
    }

    /// Records the reviewer's per-item verdicts from one review round.
    ///
    /// `verdicts` is id → verdict plus its note. An item the reply does not
    /// mention keeps any earlier verdict it had — but since a stale item has
    /// no valid earlier verdict, "not mentioned" means "still stale", and the
    /// next `nextCheck` asks for it again. That is the safe direction: a
    /// reviewer that forgot something costs one more round, while a reviewer
    /// that silently approved something it never read would cost the verdict.
    func recordingVerdicts(
        _ verdicts: [String: (verdict: ReviewCheck.Verdict, note: String?)],
        at date: Date = Date()
    ) -> CaseFile {
        var file = self
        for item in reviewChecklist {
            guard let entry = verdicts[item.id] else { continue }
            file.reviewChecks[item.id] = ReviewCheck(
                verdict: entry.verdict,
                fingerprint: item.fingerprint,
                note: entry.note,
                date: date
            )
        }
        // Drop verdicts for items that no longer exist, so a deleted
        // criterion cannot come back to life with an old "passes" if an id
        // is ever reused (`issueID` prevents that, but not across a restore
        // from a checkpoint).
        let live = Set(reviewChecklist.map(\.id))
        file.reviewChecks = file.reviewChecks.filter { live.contains($0.key) }
        return file
    }

    // MARK: - The next check

    /// The one check to take next, written as an instruction, or `nil` when
    /// nothing the model can do alone is outstanding.
    ///
    /// This is what makes an unattended run converge instead of circling.
    /// `outstandingSummary` says what is wrong; this says what to do about
    /// it, one step at a time. The auto-proceed loop quotes it verbatim as
    /// well as drawing it in the prompt block, so a continuation reads
    /// "produce the evidence for S1" instead of "continue the work".
    ///
    /// Ordered by the method's own gates, so an engineering case is asked
    /// for its trade study before its build, and for the review before its
    /// release. A custom method gets the same order for free: it is the
    /// gates, not the method's name, that decide.
    func nextCheck(reviewRequired: Bool) -> String? {
        // A spent budget is the user's call, not another step. Saying so in
        // the same breath as an instruction would contradict `budgetLine`.
        guard !budgetExhausted else { return nil }
        guard charterRatified else {
            return "Propose the charter with agent__update_case so the user can ratify it."
        }

        // 1. The trade study closes before the build opens.
        if phase == .hypothesis, !designBlockers.isEmpty {
            let needed = method.gates.minimumOptions
            let evaluated = options.filter(\.isEvaluated).count
            if options.count < needed {
                let missing = needed - options.count
                return "The trade study needs at least \(needed) genuinely different options and has \(options.count). Add \(missing), then compare each against the criteria (scores 0–5, pros and cons) before choosing one."
            }
            if evaluated < needed {
                let pending = options.filter { !$0.isEvaluated }.map(\.id)
                return "The trade study needs at least \(needed) evaluated options and has \(evaluated). Evaluate \(pending.joined(separator: ", ")) against the criteria (scores 0–5, pros and cons), then choose one."
            }
            return "No option is chosen yet. Call choose_option and say why it beats the others."
        }

        // 2. The standard. Name the first unmet criterion by id, so the step
        // is one the model can start rather than a list to work through.
        if let unmet = criteria.first(where: { !$0.met }) {
            return "\(unmet.id) is not met: \(Self.oneLine(unmet.text, max: 120)). Produce the evidence — a test result, a measurement, a tool output — and mark \(unmet.id) met with it."
        }

        // 3. Objections and other blocking issues, newest last so the
        // reviewer's objection is not starved by older ones.
        if let issue = openIssues.first(where: \.blocking) {
            let kind = issue.fromReview ? " (the reviewer's objection)" : ""
            return "Answer \(issue.id)\(kind): \(Self.oneLine(issue.text, max: 120)). Fix the work and resolve it, or record what makes it moot."
        }

        // 4. Risks the method requires closed before a verdict.
        if method.gates.highRisksMustBeClosed, let risk = openHighRisks.first {
            return "High risk \(risk.id) is open: \(Self.oneLine(risk.text, max: 120)). Mitigate it and record how, or ask the user to accept it."
        }

        // 5. Claims the method requires tested.
        if method.gates.claimsMustBeTested, let claim = claims.first(where: { $0.status == .proposed }) {
            return "Claim \(claim.id) is still proposed: test it and mark it supported or refuted, or withdraw it."
        }

        // 6. The adversarial review, last because it judges the evidence the
        // steps above produce. A re-review names the items that are actually
        // new or changed, so the run does not pay for a full review to check
        // one criterion.
        if reviewRequired, !criteria.isEmpty, !isReviewCurrent {
            let stale = staleReviewItems
            if lastReview == nil {
                return "Run agent__review_case so the reviewer can object before a verdict. It will check \(stale.count) item\(stale.count == 1 ? "" : "s")."
            }
            if stale.isEmpty {
                // Every item has a verdict; the review is stale only because
                // no round has been recorded against the new state yet.
                return "Run agent__review_case to close out the review: the evidence changed since the last round."
            }
            // Name the checks, not "the case": the reviewer is given exactly
            // these, so the instruction says what the round will cost.
            let named = stale.prefix(4).map { "\($0.id) (\($0.kind.label))" }.joined(separator: ", ")
            let more = stale.count > 4 ? " and \(stale.count - 4) more" : ""
            // A failed item is re-judged because the work may have been fixed
            // since. Saying so stops the model from reading the instruction as
            // "re-read what already passed" and skipping the one that matters.
            let failed = stale.filter { $0.recorded?.verdict == .fails }.map(\.id)
            let why = failed.isEmpty
                ? ""
                : " These failed last round (\(failed.joined(separator: ", "))) and must be judged again now that the work has moved."
            return "Run agent__review_case to re-check \(stale.count) item\(stale.count == 1 ? "" : "s") the evidence moved under: \(named)\(more).\(why) The items already passed stay passed."
        }
        return nil
    }

    /// A fingerprint of everything the loop's guidance depends on. Two turns
    /// with the same signature left the case exactly where it was, which is
    /// the only durable evidence available that an unattended run is
    /// circling: a reply can restate the same next step in fresh words and
    /// look like progress, while the case file cannot.
    var progressSignature: String {
        var parts = [phase.rawValue, "i\(iteration)", "r\(revision)"]
        parts.append("s" + criteria.map { "\($0.id)\($0.met ? "+" : "-")" }.joined())
        parts.append("q" + openIssues.map(\.id).sorted().joined(separator: ","))
        parts.append("o" + options.map { "\($0.id):\($0.status.rawValue)" }.joined(separator: ","))
        parts.append("k" + risks.map { "\($0.id):\($0.status.rawValue)" }.joined(separator: ","))
        parts.append("c" + claims.map { "\($0.id):\($0.status.rawValue)" }.joined(separator: ","))
        // The passed checks, not the verdict count: a review that re-checked
        // one item and passed it *is* progress, and it must not read as the
        // stall rule's "nothing changed".
        //
        // A review recorded before the checklist existed has no verdicts, and
        // falls back to the old currency bit — otherwise that review would
        // never register as progress and a legacy case would stall.
        if reviewChecks.isEmpty {
            parts.append(isReviewCurrent ? "L1" : "L0")
        } else {
            parts.append("v" + reviewChecklist.filter(\.passed).map(\.id).sorted().joined(separator: ","))
        }
        return parts.joined(separator: "|")
    }

    // MARK: - Applying an update

    enum GateDecision: Equatable {
        /// No gated change in the update.
        case notNeeded
        /// The user approved the gated change on the card.
        case approved
        /// The user rejected it, or answered with an amendment instead.
        case rejected
        /// The card was dismissed, or no one is there to answer it (a
        /// background run). A charter is kept as a proposal; overrules and
        /// removals are not applied.
        case dismissed
    }

    struct ApplyResult: Equatable {
        var file: CaseFile
        var applied: [String] = []
        var refused: [String] = []
        var phaseChange: (from: Phase, to: Phase)?
        var charterRatified = false

        static func == (lhs: ApplyResult, rhs: ApplyResult) -> Bool {
            lhs.file == rhs.file && lhs.applied == rhs.applied && lhs.refused == rhs.refused
                && lhs.phaseChange?.from == rhs.phaseChange?.from && lhs.phaseChange?.to == rhs.phaseChange?.to
                && lhs.charterRatified == rhs.charterRatified
        }
    }

    /// Applies an update. Gated parts (charter, criterion removal, overrule)
    /// follow `gate`; everything else is validated and applied. The phase is
    /// applied last, so its checks see the rest of the update.
    func applying(_ update: CaseUpdate, gate: GateDecision, reviewRequired: Bool) -> ApplyResult {
        var file = self
        var result = ApplyResult(file: self)
        var evidenceChanged = false
        let gatedAllowed = gate == .approved

        if let charter = update.charter {
            switch gate {
            case .approved:
                file.charter = charter
                file.charterRatified = true
                result.charterRatified = true
                evidenceChanged = true
                result.applied.append("charter ratified by the user")
            case .dismissed:
                if file.charterRatified {
                    result.refused.append("charter change not applied: the user did not approve it, so the ratified charter stands")
                } else {
                    file.charter = charter
                    evidenceChanged = true
                    result.applied.append("charter recorded as a PROPOSAL — the user has not ratified it; treat it as a working assumption")
                }
            case .rejected, .notNeeded:
                result.refused.append("charter change rejected by the user")
            }
        }

        // The method is part of what the user ratifies: it decides the gates
        // the work is held to.
        if let method = update.method, method != file.method {
            switch gate {
            case .approved:
                file.method = method
                result.applied.append("method set to \(method.name)")
            case .dismissed where !file.charterRatified:
                file.method = method
                result.applied.append("method \(method.name) recorded as part of the proposal")
            default:
                result.refused.append("method not changed to \(method.name): the user did not approve it")
            }
        }

        for text in update.addCriteria {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let id = file.issueID("S")
            file.criteria.append(Criterion(id: id, text: trimmed))
            evidenceChanged = true
            result.applied.append("added criterion \(id)")
        }

        for id in update.removeCriteria {
            guard let index = file.criteria.firstIndex(where: { $0.id == id }) else {
                result.refused.append("no criterion \(id)")
                continue
            }
            guard gatedAllowed else {
                result.refused.append("criterion \(id) not removed: lowering the standard needs the user's approval")
                continue
            }
            file.criteria.remove(at: index)
            evidenceChanged = true
            result.applied.append("removed criterion \(id)")
        }

        for mark in update.markCriteria {
            guard let index = file.criteria.firstIndex(where: { $0.id == mark.id }) else {
                result.refused.append("no criterion \(mark.id)")
                continue
            }
            let evidence = mark.evidence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if mark.met, evidence.isEmpty {
                result.refused.append("\(mark.id) not marked met: evidence is required (a path and lines, a test result, a tool output)")
                continue
            }
            file.criteria[index].met = mark.met
            file.criteria[index].evidence = mark.met ? evidence : (evidence.isEmpty ? nil : evidence)
            evidenceChanged = true
            result.applied.append("\(mark.id) \(mark.met ? "met" : "not met")")
        }

        for ruling in update.settle {
            let text = ruling.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = ruling.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard !reason.isEmpty else {
                result.refused.append("ruling \"\(Self.oneLine(text, max: 60))\" not settled: a ruling needs its reason")
                continue
            }
            let id = file.issueID("D")
            file.settled.append(Ruling(id: id, text: text, reason: reason, byUser: false))
            result.applied.append("settled \(id)")
        }

        for overrule in update.overrule {
            guard let index = file.settled.firstIndex(where: { $0.id == overrule.id }) else {
                result.refused.append("no ruling \(overrule.id)")
                continue
            }
            guard file.settled[index].isInForce else {
                result.refused.append("\(overrule.id) is already overruled")
                continue
            }
            guard gatedAllowed else {
                result.refused.append("\(overrule.id) not overruled: a settled ruling binds until the user overrules it")
                continue
            }
            let reason = overrule.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            file.settled[index].overruled = reason.isEmpty ? "overruled by the user" : reason
            result.applied.append("overruled \(overrule.id)")
        }

        for issue in update.addIssues {
            let text = issue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let id = file.issueID("Q")
            file.issues.append(Issue(id: id, text: text, blocking: issue.blocking, needsUser: issue.needsUser, fromReview: false))
            result.applied.append("opened issue \(id)")
        }

        for resolve in update.resolveIssues {
            guard let index = file.issues.firstIndex(where: { $0.id == resolve.id }) else {
                result.refused.append("no issue \(resolve.id)")
                continue
            }
            let resolution = resolve.resolution.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolution.isEmpty else {
                result.refused.append("\(resolve.id) not resolved: say how it was answered")
                continue
            }
            file.issues[index].resolution = resolution
            result.applied.append("resolved \(resolve.id)")
        }

        for input in update.claims {
            if let id = input.id, let index = file.claims.firstIndex(where: { $0.id == id }) {
                var claim = file.claims[index]
                if let text = input.claim, !text.isEmpty { claim.claim = text }
                if let grounds = input.grounds { claim.grounds = grounds }
                if let warrant = input.warrant { claim.warrant = warrant }
                if let qualifier = input.qualifier { claim.qualifier = qualifier }
                if let rebuttal = input.rebuttal, !rebuttal.isEmpty { claim.rebuttal = rebuttal }
                if let status = input.status { claim.status = status }
                if claim.status == .supported, claim.grounds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.refused.append("\(id) not supported: a supported claim needs its grounds")
                    continue
                }
                if claim != file.claims[index] {
                    file.claims[index] = claim
                    evidenceChanged = true
                    result.applied.append("\(id) \(claim.status.rawValue)")
                }
                continue
            }
            if let id = input.id, !id.isEmpty {
                result.refused.append("no claim \(id) — omit id to add a new claim")
                continue
            }
            let text = input.claim?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rebuttal = input.rebuttal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            guard !rebuttal.isEmpty else {
                result.refused.append("claim \"\(Self.oneLine(text, max: 60))\" not added: say what would refute it (rebuttal)")
                continue
            }
            let status = input.status ?? .proposed
            let grounds = input.grounds ?? ""
            if status == .supported, grounds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.refused.append("claim \"\(Self.oneLine(text, max: 60))\" not added as supported: a supported claim needs its grounds")
                continue
            }
            let id = file.issueID("C")
            file.claims.append(Claim(
                id: id, claim: text, grounds: grounds,
                warrant: input.warrant, qualifier: input.qualifier,
                rebuttal: rebuttal, status: status
            ))
            evidenceChanged = true
            result.applied.append("added claim \(id)")
        }

        let criterionIDs = Set(file.criteria.map(\.id))
        for input in update.options {
            var option: Option
            let existingIndex = input.id.flatMap { id in file.options.firstIndex { $0.id == id } }
            if let existingIndex {
                option = file.options[existingIndex]
            } else if let id = input.id, !id.isEmpty {
                result.refused.append("no option \(id) — omit id to add a new option")
                continue
            } else {
                let title = input.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty else {
                    result.refused.append("an option needs a title")
                    continue
                }
                option = Option(id: "", title: title)
            }
            if let title = input.title, !title.isEmpty { option.title = title }
            if let summary = input.summary { option.summary = summary }
            if let pros = input.pros { option.pros = pros }
            if let cons = input.cons { option.cons = cons }
            if let scores = input.scores {
                let unknown = scores.keys.filter { !criterionIDs.contains($0) }.sorted()
                let outOfRange = scores.filter { !(0...5).contains($0.value) }.keys.sorted()
                if !unknown.isEmpty || !outOfRange.isEmpty {
                    var why: [String] = []
                    if !unknown.isEmpty { why.append("unknown criteria \(unknown.joined(separator: ", "))") }
                    if !outOfRange.isEmpty { why.append("scores must be 0–5 (\(outOfRange.joined(separator: ", ")))") }
                    result.refused.append("scores for \(option.title) not recorded: " + why.joined(separator: "; "))
                } else {
                    option.scores.merge(scores) { _, new in new }
                }
            }
            if let status = input.status {
                if option.status == .chosen, status != .chosen {
                    result.refused.append("\(option.id) is the chosen option; choose another one instead of rejecting it")
                } else {
                    option.status = status
                }
            }
            if let existingIndex {
                if option != file.options[existingIndex] {
                    file.options[existingIndex] = option
                    evidenceChanged = true
                    result.applied.append("updated option \(option.id)")
                }
            } else {
                option.id = file.issueID("O")
                file.options.append(option)
                evidenceChanged = true
                result.applied.append("added option \(option.id)")
            }
        }

        if let choice = update.chooseOption {
            let reason = choice.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = file.options.firstIndex(where: { $0.id == choice.id }) {
                let previous = file.chosenOption
                if previous?.id == choice.id {
                    // Already chosen: nothing to do.
                } else if reason.isEmpty {
                    result.refused.append("\(choice.id) not chosen: say why it beats the others")
                } else if !file.options[index].isEvaluated {
                    result.refused.append("\(choice.id) not chosen: evaluate it first (scores, pros or cons)")
                } else if previous != nil, !gatedAllowed {
                    // The first choice is the model's design decision. Changing
                    // it reverses a settled ruling, which only the user may do.
                    result.refused.append("\(choice.id) not chosen: \(previous!.id) is already the settled choice, and changing it needs the user's approval")
                } else {
                    if let previous, let previousIndex = file.options.firstIndex(where: { $0.id == previous.id }) {
                        file.options[previousIndex].status = .rejected
                        for rulingIndex in file.settled.indices where file.settled[rulingIndex].isInForce
                            && file.settled[rulingIndex].text.hasPrefix("Chose \(previous.id) ") {
                            file.settled[rulingIndex].overruled = "replaced by \(choice.id), approved by the user"
                        }
                    }
                    file.options[index].status = .chosen
                    let others = file.options.filter { $0.id != choice.id && $0.status != .rejected }
                    for other in others {
                        if let otherIndex = file.options.firstIndex(where: { $0.id == other.id }) {
                            file.options[otherIndex].status = .rejected
                        }
                    }
                    let over = file.options.filter { $0.id != choice.id }.map(\.id)
                    let id = file.issueID("D")
                    let chosenTitle = file.options[index].title
                    let text = "Chose \(choice.id) (\(chosenTitle))" + (over.isEmpty ? "" : " over \(over.joined(separator: ", "))")
                    file.settled.append(Ruling(id: id, text: text, reason: reason, byUser: previous != nil))
                    evidenceChanged = true
                    result.applied.append("chose \(choice.id), settled as \(id)")
                }
            } else {
                result.refused.append("no option \(choice.id)")
            }
        }

        for input in update.risks {
            var risk: Risk
            let existingIndex = input.id.flatMap { id in file.risks.firstIndex { $0.id == id } }
            if let existingIndex {
                risk = file.risks[existingIndex]
            } else if let id = input.id, !id.isEmpty {
                result.refused.append("no risk \(id) — omit id to add a new risk")
                continue
            } else {
                let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty, let likelihood = input.likelihood, let impact = input.impact else {
                    result.refused.append("a new risk needs text, likelihood and impact")
                    continue
                }
                risk = Risk(id: "", text: text, likelihood: likelihood, impact: impact)
            }
            if let text = input.text, !text.isEmpty { risk.text = text }
            if let likelihood = input.likelihood { risk.likelihood = likelihood }
            if let impact = input.impact { risk.impact = impact }
            if let mitigation = input.mitigation { risk.mitigation = mitigation }
            if let status = input.status {
                let mitigation = risk.mitigation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                switch status {
                case .mitigated where mitigation.isEmpty:
                    result.refused.append("\(risk.id.isEmpty ? "risk" : risk.id) not mitigated: say what the mitigation is")
                case .accepted where risk.isHigh && !gatedAllowed:
                    result.refused.append("\(risk.id.isEmpty ? "risk" : risk.id) not accepted: accepting a high risk as it is needs the user's approval")
                default:
                    risk.status = status
                }
            }
            if let existingIndex {
                if risk != file.risks[existingIndex] {
                    file.risks[existingIndex] = risk
                    evidenceChanged = true
                    result.applied.append("updated risk \(risk.id)")
                }
            } else {
                risk.id = file.issueID("R")
                file.risks.append(risk)
                evidenceChanged = true
                result.applied.append("added risk \(risk.id)\(risk.isHigh ? " (high)" : "")")
            }
        }

        if let failure = update.failedVerification {
            if file.phase == .verify || file.phase == .verdict {
                let back = file.method.gates.failedVerificationReturnsTo
                let id = file.issueID("Q")
                file.issues.append(Issue(
                    id: id, text: "Verification failed (iteration \(file.iteration)): \(failure)",
                    blocking: true, needsUser: false, fromReview: false
                ))
                file.iteration += 1
                file.phase = back
                evidenceChanged = true
                result.applied.append("verification failure recorded as \(id); iteration \(file.iteration) starts in \(file.title(for: back))")
            } else {
                result.refused.append("failed_verification only applies in \(file.title(for: .verify)) — the case is in \(file.phaseTitle)")
            }
        }

        if evidenceChanged {
            file.revision += 1
        }

        let before = self.phase
        if let target = update.phase, target != file.phase, update.failedVerification == nil {
            if target.index > Phase.discovery.index, file.charter == nil || file.criteria.isEmpty {
                result.refused.append("phase not changed to \(target.rawValue): leave \(file.title(for: .discovery)) only once there is a charter and at least one criterion")
            } else if target.index > Phase.hypothesis.index, !file.designBlockers.isEmpty {
                result.refused.append("phase not changed to \(target.rawValue): " + file.designBlockers.joined(separator: "; "))
            } else if target == .verdict {
                let blockers = file.verdictBlockers(reviewRequired: reviewRequired)
                if blockers.isEmpty {
                    file.phase = .verdict
                } else {
                    result.refused.append("verdict refused: " + blockers.joined(separator: "; "))
                }
            } else {
                file.phase = target
            }
        } else if file.phase == .verdict, evidenceChanged {
            // The verdict rested on the evidence as it was. New evidence
            // reopens the case rather than leaving a stale verdict standing.
            file.phase = .verify
            result.applied.append("case reopened: the evidence changed after the verdict")
        }
        if file.phase != before {
            result.phaseChange = (before, file.phase)
            result.applied.append("phase \(before.rawValue) → \(file.phase.rawValue)")
        }

        result.file = file
        return result
    }

    /// The tool result for an update: what changed, what did not, and where
    /// the case stands.
    static func resultText(_ result: ApplyResult, reviewRequired: Bool, amendment: String? = nil) -> String {
        let file = result.file
        var lines: [String] = []
        lines.append("Case \(file.phaseTitle) (\(file.method.name), iteration \(file.iteration)): standard \(file.metCount)/\(file.criteria.count) met, \(file.openIssues.count) open issue\(file.openIssues.count == 1 ? "" : "s").")
        if !result.applied.isEmpty {
            lines.append("Applied: " + result.applied.joined(separator: "; ") + ".")
        }
        if !result.refused.isEmpty {
            lines.append("Not applied: " + result.refused.joined(separator: "; ") + ".")
        }
        if let amendment, !amendment.isEmpty {
            lines.append("The user answered with an amendment instead of approving: \"\(amendment)\". Revise the proposal to incorporate it and propose again.")
        }
        if file.phase != .verdict {
            let blockers = file.verdictBlockers(reviewRequired: reviewRequired)
            if !blockers.isEmpty {
                lines.append("Before a verdict: " + blockers.joined(separator: "; ") + ".")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Prompt block

    /// Caps for the prompt block. The block rides the volatile half on every
    /// turn, so a long case must not grow it without bound.
    static let promptItemLimit = 12
    static let promptLineLimit = 220

    /// The case file as a system-prompt block. Rebuilt every turn, so it
    /// survives compaction for the same reason the plan block does: the
    /// summary replaces transcript rows, and this is not a transcript row.
    func promptBlock(reviewRequired: Bool) -> String {
        var lines: [String] = []
        lines.append("CASE FILE — the goal of this chat and the standard the result is judged by. It outranks the conversation summary. Change it only with agent__update_case; never act against a ratified charter or a settled ruling.")
        let path = Phase.allCases.map { stage -> String in
            let name = "\(title(for: stage)) (\(stage.rawValue))"
            return stage == phase ? "[\(name)]" : name
        }.joined(separator: " → ")
        lines.append("METHOD: \(method.name)\(iteration > 1 ? " — iteration \(iteration)" : "")")
        lines.append("  \(method.guidance)")
        lines.append("PHASE: \(path)")
        lines.append("  \(method.stage(phase).guidance)")
        if let budget = budgetLine {
            lines.append(budget)
        }

        if let charter {
            lines.append(charterRatified ? "CHARTER (ratified by the user):" : "CHARTER (PROPOSED — the user has not ratified it; treat it as a working assumption):")
            lines.append("  Objective: \(Self.oneLine(charter.objective, max: Self.promptLineLimit * 2))")
            if !charter.definitions.isEmpty {
                lines.append("  Definitions: " + charter.definitions.map { Self.oneLine($0, max: Self.promptLineLimit) }.joined(separator: "; "))
            }
            if !charter.constraints.isEmpty {
                lines.append("  Constraints: " + charter.constraints.map { Self.oneLine($0, max: Self.promptLineLimit) }.joined(separator: "; "))
            }
            if !charter.outOfScope.isEmpty {
                lines.append("  Out of scope: " + charter.outOfScope.map { Self.oneLine($0, max: Self.promptLineLimit) }.joined(separator: "; "))
            }
        } else {
            lines.append("CHARTER: none yet. Agree the objective, definitions, constraints and done-when criteria with the user, then propose them with agent__update_case.")
        }

        if !criteria.isEmpty {
            lines.append("STANDARD (\(metCount)/\(criteria.count) met):")
            for criterion in criteria {
                var line = "  [\(criterion.met ? "x" : " ")] \(criterion.id) \(Self.oneLine(criterion.text, max: Self.promptLineLimit))"
                if criterion.met, let evidence = criterion.evidence {
                    line += " — evidence: \(Self.oneLine(evidence, max: 120))"
                }
                lines.append(line)
            }
        }

        let inForce = settled.filter(\.isInForce)
        if !inForce.isEmpty {
            lines.append("SETTLED (binding; only the user can overrule):")
            lines.append(contentsOf: Self.capped(inForce.map { ruling in
                "  \(ruling.id) \(Self.oneLine(ruling.text, max: Self.promptLineLimit)) — \(Self.oneLine(ruling.reason, max: 120))\(ruling.byUser ? " (user)" : "")"
            }))
        }

        let open = openIssues
        if !open.isEmpty {
            lines.append("OPEN ISSUES:")
            lines.append(contentsOf: Self.capped(open.map { issue in
                var tags: [String] = []
                if issue.fromReview { tags.append("objection") }
                if issue.blocking { tags.append("blocking") }
                if issue.needsUser { tags.append("needs the user") }
                let suffix = tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))"
                return "  \(issue.id) \(Self.oneLine(issue.text, max: Self.promptLineLimit))\(suffix)"
            }))
        }

        let liveClaims = claims.filter { $0.status != .withdrawn }
        if !liveClaims.isEmpty {
            lines.append("CLAIMS:")
            lines.append(contentsOf: Self.capped(liveClaims.map { claim in
                var line = "  \(claim.id) [\(claim.status.rawValue)] \(Self.oneLine(claim.claim, max: Self.promptLineLimit))"
                if !claim.grounds.isEmpty { line += " — grounds: \(Self.oneLine(claim.grounds, max: 120))" }
                line += " — refuted if: \(Self.oneLine(claim.rebuttal, max: 120))"
                return line
            }))
        }

        if !options.isEmpty {
            lines.append("OPTIONS (trade study):")
            lines.append(contentsOf: Self.capped(options.map { option in
                var line = "  \(option.id) [\(option.status.rawValue)] \(Self.oneLine(option.title, max: 120))"
                if !option.scores.isEmpty {
                    let scores = option.scores.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                    line += " — scores \(scores), total \(option.total)"
                }
                if !option.cons.isEmpty { line += " — cons: \(Self.oneLine(option.cons.joined(separator: "; "), max: 120))" }
                return line
            }))
        }
        let liveRisks = risks.filter { !$0.isClosed || $0.isHigh }
        if !liveRisks.isEmpty {
            lines.append("RISKS (likelihood × impact):")
            lines.append(contentsOf: Self.capped(liveRisks.map { risk in
                var line = "  \(risk.id) [\(risk.status.rawValue)\(risk.isHigh ? ", HIGH" : "")] \(Self.oneLine(risk.text, max: Self.promptLineLimit)) — \(risk.likelihood)×\(risk.impact)"
                if let mitigation = risk.mitigation, !mitigation.isEmpty { line += " — mitigation: \(Self.oneLine(mitigation, max: 120))" }
                return line
            }))
        }

        if let lastReview {
            let checklist = reviewChecklist
            if checklist.isEmpty {
                lines.append("REVIEW: last review raised \(lastReview.objections) objection\(lastReview.objections == 1 ? "" : "s")\(isReviewCurrent ? "" : " — stale, the evidence changed since").")
            } else {
                let passed = checklist.filter(\.passed).count
                let stale = checklist.count - passed
                var line = "REVIEW (\(passed)/\(checklist.count) checked): last round raised \(lastReview.objections) objection\(lastReview.objections == 1 ? "" : "s")"
                if stale > 0 {
                    let named = checklist.filter(\.isStale).prefix(4).map(\.id).joined(separator: ", ")
                    line += " — \(stale) item\(stale == 1 ? "" : "s") still to check (\(named)\(stale > 4 ? ", …" : ""))"
                } else {
                    line += " — every item checked, none stale"
                }
                lines.append(line + ".")
            }
        }
        if let drift {
            lines.append("DRIFT WARNING: \(Self.oneLine(drift, max: Self.promptLineLimit)) Steer back to the objective, or propose a charter change if the goal itself moved.")
        }
        if phase != .verdict {
            let blockers = verdictBlockers(reviewRequired: reviewRequired)
            if !blockers.isEmpty {
                lines.append("VERDICT BLOCKED BY: " + blockers.joined(separator: "; "))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Adversarial review

    /// The opposing counsel's brief. The reviewer cannot see the chat, so
    /// everything it judges by is written out here.
    ///
    /// Only the **stale** items get a full brief. A verdict already recorded
    /// against unchanged evidence is listed as settled-and-verified, one line
    /// each: re-reading it would be the cost this checklist exists to remove,
    /// and asking the reviewer to re-judge it invites it to invent a new
    /// objection to justify the trip. `fullBrief` overrides for the first
    /// review, or when the user wants everything re-read.
    ///
    /// `checking` is the batch this request judges: a round covers every
    /// stale item but asks about `reviewBatchSize` of them at a time. Pass
    /// `nil` for "all of them", which is what one request used to do and what
    /// a caller wanting a single brief still gets. `judgedAlready` names the
    /// items earlier batches of *this round* have settled since the case was
    /// last saved, so the reviewer does not object twice to the same thing
    /// while the round is still running.
    func reviewBrief(
        artifact: String,
        fullBrief: Bool = false,
        checking: [ReviewItem]? = nil,
        judgedAlready: [ReviewItem] = []
    ) -> String {
        var lines: [String] = []
        if let charter {
            lines.append("OBJECTIVE: \(charter.objective)")
            if !charter.definitions.isEmpty { lines.append("DEFINITIONS: " + charter.definitions.joined(separator: "; ")) }
            if !charter.constraints.isEmpty { lines.append("CONSTRAINTS: " + charter.constraints.joined(separator: "; ")) }
            if !charter.outOfScope.isEmpty { lines.append("OUT OF SCOPE: " + charter.outOfScope.joined(separator: "; ")) }
        }

        let checklist = reviewChecklist
        // The batch this request judges. `nil` = every stale item, which is
        // what one request used to cover and what a caller asking for a single
        // brief still gets.
        let batch: [ReviewItem]
        if let checking {
            batch = checking
        } else if fullBrief {
            batch = checklist
        } else {
            batch = checklist.filter(\.isStale)
        }
        let verified = checklist.filter(\.passed)

        if fullBrief {
            if !criteria.isEmpty {
                lines.append("STANDARD — the result must meet every one:")
                for criterion in criteria {
                    lines.append("- \(criterion.id) \(criterion.text)\(criterion.met ? " (claimed met; evidence: \(criterion.evidence ?? "none"))" : " (not yet claimed)")")
                }
            }
            let inForce = settled.filter(\.isInForce)
            if !inForce.isEmpty {
                lines.append("SETTLED DECISIONS (binding, do not object to the decision itself, only to work that breaks it):")
                for ruling in inForce { lines.append("- \(ruling.id) \(ruling.text) — \(ruling.reason)") }
            }
            let liveClaims = claims.filter { $0.status != .withdrawn }
            if !liveClaims.isEmpty {
                lines.append("CLAIMS made by the assistant:")
                for claim in liveClaims {
                    lines.append("- \(claim.id) [\(claim.status.rawValue)] \(claim.claim). Grounds: \(claim.grounds.isEmpty ? "none given" : claim.grounds). Refuted if: \(claim.rebuttal)")
                }
            }
            if let chosen = chosenOption {
                let others = options.filter { $0.id != chosen.id }.map { "\($0.id) \($0.title)" }
                lines.append("CHOSEN DESIGN: \(chosen.id) \(chosen.title)\(others.isEmpty ? "" : " (over: \(others.joined(separator: "; ")))")")
            }
            if !risks.isEmpty {
                lines.append("RISKS:")
                for risk in risks {
                    lines.append("- \(risk.id) [\(risk.status.rawValue)] \(risk.text) (\(risk.likelihood)×\(risk.impact))\(risk.mitigation.map { "; mitigation: \($0)" } ?? "")")
                }
            }
        } else if let chosen = chosenOption {
            let others = options.filter { $0.id != chosen.id }.map { "\($0.id) \($0.title)" }
            lines.append("CHOSEN DESIGN: \(chosen.id) \(chosen.title)\(others.isEmpty ? "" : " (over: \(others.joined(separator: "; ")))")")
        }

        // The rubric is the same in both briefs: the batch, with the detail a
        // judgement needs. A full brief adds background above; it never asks
        // for more reading than the batch, because the batch is what bounds
        // one request's work (see `reviewBatchSize`).
        let remaining = checklist.filter { item in
            item.isStale && !batch.contains(where: { $0.id == item.id })
        }
        if batch.isEmpty {
            lines.append("TO CHECK: nothing changed since the last round — confirm the artifact still exists as described and say so.")
        } else {
            lines.append("TO CHECK NOW — \(batch.count) item\(batch.count == 1 ? "" : "s"). Judge exactly these and nothing else:")
            for item in batch {
                // A failed item is re-judged, not judged for the first time.
                // Saying which it is decides whether the reviewer looks for
                // new evidence or confirms the old failure still stands.
                let again = item.recorded?.verdict == .fails ? " — FAILED last round; judge it again" : ""
                lines.append("- \(item.id) (\(item.kind.label)) \(item.subject)\(again)")
            }
        }

        if !judgedAlready.isEmpty {
            lines.append("ALREADY JUDGED THIS ROUND — do not re-check, and do not object again to these:")
            lines.append(contentsOf: judgedAlready.map { item in
                "  \(item.id) \(item.kind.label)\(item.recorded?.note.map { ": \(Self.oneLine($0, max: 120))" } ?? "")"
            })
        }
        if !remaining.isEmpty {
            // Named so the reviewer does not go looking: the rest of the case
            // is a later batch of this same round, not its job.
            let named = remaining.prefix(12).map(\.id).joined(separator: ", ")
            lines.append("NOT THIS BATCH (\(remaining.count)): \(named)\(remaining.count > 12 ? ", …" : "") — another request in this round judges them.")
        }

        if !verified.isEmpty {
            lines.append("ALREADY VERIFIED — do not re-check, and do not object to these without new evidence:")
            lines.append(contentsOf: verified.prefix(40).map { item in
                "  \(item.id) \(item.kind.label)\(item.recorded?.note.map { ": \(Self.oneLine($0, max: 120))" } ?? "")"
            })
            if verified.count > 40 {
                lines.append("  … and \(verified.count - 40) more")
            }
        }

        lines.append("WHAT TO REVIEW: \(artifact)")
        return lines.joined(separator: "\n")
    }

    /// How many checklist items one reviewer request judges.
    ///
    /// A round used to be **one** request over every item it covered, so a
    /// case with sixteen items asked a read-only subagent to read and judge
    /// sixteen things before answering once — the slowest step of a long
    /// engineering chat — and a failure anywhere in it (a stall, a cut-off, a
    /// provider error) threw away every verdict it had reached. Judging four
    /// at a time bounds one request's reading work, and each finished batch is
    /// banked before the next starts, so a failure costs one batch instead of
    /// the whole round.
    static let reviewBatchSize = 4

    /// How many batches one `agent__review_case` call runs before returning.
    ///
    /// Batching bounds one *request*; this bounds one *call*, so a tool call
    /// the model is waiting on cannot run for longer than six requests. What
    /// is left is named in the result and the case-aware loop asks again — a
    /// case that grows past 24 items converges over two rounds instead of
    /// parking one call for as long as it likes.
    static let reviewRoundBatchLimit = 6

    /// How many tool-calling turns one review request may use.
    ///
    /// The global `chatSubagentMaxTurns` can be unlimited (`0`), which is right
    /// for a research subagent that does not know how much reading a brief
    /// needs — and wrong for a review, whose brief names at most
    /// `reviewBatchSize` items and says the rest belong to another batch. There
    /// is no amount of extra searching that makes those four items more judged;
    /// there is only reading the same files again. Observed on a small local
    /// model: one review round spent 237 tool calls over six hours re-grepping
    /// four files it had already read, and never wrote a verdict.
    ///
    /// Generous enough for a batch of four plus the citations a `CHECK:` line
    /// needs, tight enough that a spinning reviewer stops and answers.
    static let reviewTurnLimit = 16

    /// The budget as a prompt line, or `nil` when the charter sets none.
    var budgetLine: String? {
        var parts: [String] = []
        if let turns = charter?.turnBudget, turns > 0 { parts.append("turns \(turnsUsed)/\(turns)") }
        if let rounds = charter?.iterationBudget, rounds > 0 { parts.append("iterations \(min(iteration, rounds))/\(rounds)") }
        guard !parts.isEmpty else { return nil }
        if budgetExhausted {
            return "BUDGET SPENT (\(parts.joined(separator: ", "))): stop here. Report what is done and what is left, and ask the user to extend the budget (a charter change) or narrow the scope. Do not start new work."
        }
        return "BUDGET: \(parts.joined(separator: ", "))"
    }

    /// The reviewer's system prompt: the method's brief, then the fixed
    /// output format the parser reads. The format is not the method's to
    /// change, so a custom method cannot break the review by omitting it.
    var reviewSystemPrompt: String {
        method.review + "\n\n" + Self.reviewProtocol
    }

    static let reviewProtocol = """
    You work read-only inside TypstEdit. Read the evidence yourself with the tools (the files, the pages); do not trust a claim because it is stated. Your job is to find failures — not to praise the work, not to fix it.

    Your tools are read-only: list/read/search files under the reference folder, fetch a web page, evaluate arithmetic, read a skill. You cannot write files, and you cannot run shell commands, Python, or a build — so a criterion whose evidence is "make passes" is judged from the recorded output, the gate's wiring and the committed artifacts, not by running it. Say that plainly in the CHECK line ("wired at Makefile:97, not executed here") instead of spending turns trying, and do not narrow a PASS to "mechanism only" as if that were a failure: the evidence you can read is the evidence you were asked to judge. If that genuinely cannot settle an item, say so in one line and raise no objection.

    Read only what the item needs. When you have enough to write its CHECK line, write it; re-reading a file you have already read does not make the verdict stronger.

    Judge **only** the items under TO CHECK NOW. Anything under ALREADY VERIFIED was judged against this same evidence in an earlier round: do not re-check it, and do not raise a new objection about it unless you can point at new evidence in WHAT TO REVIEW.

    Write one line per item you judge, exactly in this form:
    CHECK: <item id> PASS — <one line: what you verified, where>
    CHECK: <item id> FAIL — <what fails, and where — a path and lines when you have them>
    Every item under TO CHECK NOW needs a CHECK line. Use the item id exactly as given (S1, C2, R1, D1).

    Then, for each FAIL, also write:
    OBJECTION: <what fails, and where> [<item id>]
    Object only to real failures with a reason you can point at; a style preference is not an objection.

    End with exactly one line: VERDICT: SUSTAINED (you raised objections) or VERDICT: NO OBJECTIONS.
    """

    /// The reviewer's per-item verdicts.
    ///
    /// Tolerant of the decoration models add to a line they were told to keep
    /// plain, for the same reason `parseObjections` is: a stray `**` must not
    /// cost a whole review round. An item with no `CHECK:` line is simply
    /// left out, which leaves it stale and gets it asked for again.
    static func parseVerdicts(_ reply: String) -> [String: (verdict: ReviewCheck.Verdict, note: String?)] {
        var verdicts: [String: (verdict: ReviewCheck.Verdict, note: String?)] = [:]
        for raw in reply.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // The same decoration `parseObjections` tolerates, and the same
            // set: an ordered list marker (`2. CHECK: …`) is as likely as a
            // bullet, so the digits and the full stop have to go too.
            while let first = line.first, "-*•>#0123456789. ".contains(first) {
                line.removeFirst()
            }
            line = line.replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("check") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // `<id> PASS — note` / `<id> FAIL: note`. The id is the first
            // word; the verdict is the next, which is also what keeps
            // "PASSED" and "FAILED" working.
            let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard let rawID = parts.first else { continue }
            let id = rawID.trimmingCharacters(in: CharacterSet(charactersIn: "[]()*_`"))
            guard let rawVerdict = parts.dropFirst().first else { continue }
            let word = rawVerdict
                .uppercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ":*_`.,—–-"))
            guard !id.isEmpty else { continue }
            let verdict: ReviewCheck.Verdict
            if word.hasPrefix("PASS") { verdict = .passes }
            else if word.hasPrefix("FAIL") { verdict = .fails }
            else { continue }
            let note = parts.count > 2
                ? parts[2].trimmingCharacters(in: CharacterSet(charactersIn: " —-:\t"))
                : ""
            verdicts[id] = (verdict, note.isEmpty ? nil : note)
        }
        return verdicts
    }

    /// The objections in a reviewer's reply. Tolerant of list markers and
    /// bold markers, since models decorate lines they were told to keep
    /// plain.
    static func parseObjections(_ reply: String) -> [String] {
        reply.components(separatedBy: .newlines).compactMap { raw -> String? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "-*•>#0123456789. ".contains(first) {
                line.removeFirst()
            }
            line = line.replacingOccurrences(of: "**", with: "")
            guard line.lowercased().hasPrefix("objection") else { return nil }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
    }

    /// Records a finished review: each objection becomes a blocking issue,
    /// each per-item verdict is stamped, and the review is dated.
    ///
    /// An objection already raised and still open is not re-opened as a
    /// second issue. A reviewer that judges a stale item FAIL again would
    /// otherwise add a duplicate every round, and the case would look like it
    /// was going backwards while nothing had changed.
    ///
    /// `checking` is the batch this reply judged. `nil` = the whole stale set,
    /// which is what a single-request round used to judge. Pass the batch
    /// explicitly for a batched round, or the legacy fallback below would take
    /// every stale item as passed on the strength of one batch's reply — the
    /// silent approval the checklist exists to prevent.
    func recordingReview(
        objections: [String],
        verdicts: [String: (verdict: ReviewCheck.Verdict, note: String?)] = [:],
        checking: [ReviewItem]? = nil,
        at date: Date = Date()
    ) -> CaseFile {
        let file = bankingReview(
            objections: objections, verdicts: verdicts, checking: checking, at: date
        )
        return file.stampingReview(objections: objections.count, at: date)
    }

    /// Banks one batch's verdicts and objections **without** dating a review.
    ///
    /// This is what makes a long round survivable: each batch's work is
    /// written into `reviewChecks` and `issues` as soon as it arrives, so a
    /// failure in a later batch costs that batch and not the round. The
    /// review itself is dated by `stampingReview` once the round is over —
    /// `isReviewCurrent` stays false until then, because the case is not
    /// reviewed while one request in the round is still unrun.
    ///
    /// The legacy fallback lives here, not in `recordingReview`, so a reply
    /// with no `CHECK:` lines behaves the same whether it arrived as the whole
    /// round or as one batch of it.
    func bankingReview(
        objections: [String],
        verdicts: [String: (verdict: ReviewCheck.Verdict, note: String?)],
        checking: [ReviewItem]? = nil,
        at date: Date = Date()
    ) -> CaseFile {
        // A reviewer that answered in the older format — objections and a
        // verdict line, no CHECK lines — still gets a working review, or a
        // case under a model that ignores the protocol could never reach a
        // verdict at all. Its objections name the item in brackets; every
        // other item it was asked about is taken as passed, which is what a
        // whole-case review meant before the checklist existed.
        var effective = verdicts
        if effective.isEmpty {
            let named = Set(objections.flatMap(Self.bracketedIDs))
            for item in (checking ?? staleReviewItems) where effective[item.id] == nil {
                effective[item.id] = (named.contains(item.id) ? .fails : .passes, nil)
            }
        }

        var file = recordingVerdicts(effective, at: date)
        let alreadyOpen = Set(file.openIssues.map { Self.oneLine($0.text, max: 120) })
        for objection in objections {
            guard !alreadyOpen.contains(Self.oneLine(objection, max: 120)) else { continue }
            let id = file.issueID("Q")
            file.issues.append(Issue(id: id, text: objection, blocking: true, needsUser: false, fromReview: true))
        }
        return file
    }

    /// Dates a review against the case as it stands now. Called once every
    /// batch of a round has been banked — or after a round that failed part
    /// way, so what did get judged is not thrown away.
    ///
    /// `checked` is how many items this round actually judged, not the size of
    /// the checklist. It used to be the checklist size, which was true only
    /// while a round was one request over everything; a partial round that
    /// recorded "10 checked" after judging four would be a lie in the record.
    func stampingReview(objections: Int, checked: Int? = nil, at date: Date = Date()) -> CaseFile {
        var file = self
        file.lastReview = Review(
            date: date,
            objections: objections,
            revision: file.revision,
            checked: checked ?? file.reviewChecklist.count
        )
        return file
    }

    /// The `[S2]` / `[C1]` ids an objection line names.
    static func bracketedIDs(_ text: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "["),
              let close = rest[open...].firstIndex(of: "]") {
            let inner = rest[rest.index(after: open)..<close]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A bracket may hold several ids: `[S1, S2]`.
            ids.append(contentsOf: inner
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .map(String.init)
                .filter { !$0.isEmpty })
            rest = rest[rest.index(after: close)...]
        }
        return ids
    }

    // MARK: - Drift check

    static let driftSystemPrompt = "You audit whether an assistant's recent work serves the user's stated objective. Answer in one line only."

    /// The drift check's prompt: the objective and standard, then the
    /// recent turns.
    func driftPrompt(recentTranscript: String) -> String {
        var lines: [String] = []
        lines.append("OBJECTIVE: \(charter?.objective ?? "(none)")")
        if let constraints = charter?.constraints, !constraints.isEmpty {
            lines.append("CONSTRAINTS: " + constraints.joined(separator: "; "))
        }
        if let outOfScope = charter?.outOfScope, !outOfScope.isEmpty {
            lines.append("OUT OF SCOPE: " + outOfScope.joined(separator: "; "))
        }
        if !criteria.isEmpty {
            lines.append("DONE WHEN: " + criteria.map { "\($0.id) \($0.text)" }.joined(separator: "; "))
        }
        lines.append("")
        lines.append("RECENT TURNS:")
        lines.append(recentTranscript)
        lines.append("")
        lines.append("Is the recent work still aimed at the objective and inside the constraints? Reply exactly `ON TRACK`, or `DRIFT: <one sentence naming what drifted>`.")
        return lines.joined(separator: "\n")
    }

    /// Reads the drift check's reply. `nil` = on track; a string = the
    /// warning. An unreadable reply counts as on track: a false alarm costs
    /// the user's trust in the warning, a missed one costs one more check.
    static func parseDriftVerdict(_ reply: String) -> String? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
        guard let range = trimmed.range(of: "DRIFT:", options: .caseInsensitive) else { return nil }
        let text = trimmed[range.upperBound...]
            .split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: - Ratification card

    /// The card text for an update's gated changes, or `nil` when nothing in
    /// it needs the user.
    func ratificationQuestion(for update: CaseUpdate) -> AgentQuestion? {
        var parts: [String] = []
        if let charter = update.charter {
            var text = "Objective: \(charter.objective)"
            if !charter.definitions.isEmpty { text += "\nDefinitions: " + charter.definitions.joined(separator: "; ") }
            if !charter.constraints.isEmpty { text += "\nConstraints: " + charter.constraints.joined(separator: "; ") }
            if !charter.outOfScope.isEmpty { text += "\nOut of scope: " + charter.outOfScope.joined(separator: "; ") }
            let standard = criteria.map(\.text) + update.addCriteria
            if !standard.isEmpty { text += "\nDone when: " + standard.joined(separator: "; ") }
            var budget: [String] = []
            if let turns = charter.turnBudget { budget.append("\(turns) turns") }
            if let rounds = charter.iterationBudget { budget.append("\(rounds) iterations") }
            if !budget.isEmpty { text += "\nBudget: " + budget.joined(separator: ", ") }
            let proposed = update.method ?? method
            text += "\nMethod: \(proposed.name)"
            parts.append(text)
        } else if let proposed = update.method, proposed != method {
            parts.append("Work this case by the \(proposed.name) method instead of \(method.name): \(proposed.summary)")
        }
        if let choice = update.chooseOption, let previous = chosenOption, previous.id != choice.id,
           let next = options.first(where: { $0.id == choice.id }) {
            parts.append("Replace the chosen design \(previous.id) (\(previous.title)) with \(next.id) (\(next.title)) because: \(choice.reason)")
        }
        for input in update.risks where input.status == .accepted {
            if let id = input.id, let risk = risks.first(where: { $0.id == id }) {
                var probe = risk
                if let likelihood = input.likelihood { probe.likelihood = likelihood }
                if let impact = input.impact { probe.impact = impact }
                if probe.isHigh {
                    parts.append("Accept high risk \(risk.id) as it is, without mitigation: \(risk.text)")
                }
            }
        }
        for id in update.removeCriteria {
            if let criterion = criteria.first(where: { $0.id == id }) {
                parts.append("Drop criterion \(id): \(criterion.text)")
            }
        }
        for overrule in update.overrule {
            if let ruling = settled.first(where: { $0.id == overrule.id && $0.isInForce }) {
                parts.append("Overrule \(ruling.id) (\(ruling.text)) because: \(overrule.reason)")
            }
        }
        guard !parts.isEmpty else { return nil }
        let question = update.charter != nil
            ? (charterRatified ? "Amend the charter for this chat?" : "Ratify this charter for this chat?")
            : "Approve this change to the case?"
        return AgentQuestion(
            question: question + "\n\n" + parts.joined(separator: "\n\n"),
            header: "Case file",
            options: [
                AgentQuestionOption(label: "Approve (Recommended)", detail: "It becomes binding: the work is judged against it."),
                AgentQuestionOption(label: "Reject", detail: "Nothing changes. Type an answer instead to amend it."),
            ],
            multiple: false
        )
    }

    /// Turns the card's answer into a gate decision. Typed text without a
    /// pick is an amendment: the proposal is not applied, and the model gets
    /// the user's words to revise it with.
    static func gateDecision(from answer: AgentQuestionAnswer?) -> (decision: GateDecision, amendment: String?) {
        guard let answer, !answer.isSkipped else { return (.dismissed, nil) }
        let custom = answer.custom?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (custom?.isEmpty ?? true) ? nil : custom
        if answer.selections.contains(where: { $0.lowercased().hasPrefix("approve") }) {
            return (.approved, nil)
        }
        if answer.selections.contains(where: { $0.lowercased().hasPrefix("reject") }) {
            return (.rejected, note)
        }
        return (.rejected, note)
    }

    // MARK: - Helpers

    /// `S3` after `S1, S2`: one past the highest id with this prefix.
    static func nextID(_ prefix: String, in existing: [String]) -> String {
        "\(prefix)\(highestNumber(prefix, in: existing) + 1)"
    }

    private static func highestNumber(_ prefix: String, in existing: [String]) -> Int {
        existing.compactMap { id -> Int? in
            guard id.hasPrefix(prefix) else { return nil }
            return Int(id.dropFirst(prefix.count))
        }.max() ?? 0
    }

    /// Issues the next id for a prefix and remembers it. Numbering never
    /// reuses an id, even after a removal, so a ruling that cites `S2` never
    /// silently points at a different criterion.
    mutating func issueID(_ prefix: String) -> String {
        let existing = criteria.map(\.id) + settled.map(\.id) + issues.map(\.id) + claims.map(\.id)
            + options.map(\.id) + risks.map(\.id)
        let number = max(idCounters[prefix] ?? 0, Self.highestNumber(prefix, in: existing)) + 1
        idCounters[prefix] = number
        return "\(prefix)\(number)"
    }

    static func oneLine(_ text: String, max: Int) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    /// The newest `promptItemLimit` lines, with a count of the rest.
    private static func capped(_ lines: [String]) -> [String] {
        guard lines.count > promptItemLimit else { return lines }
        let omitted = lines.count - promptItemLimit
        return ["  (\(omitted) earlier not shown)"] + lines.suffix(promptItemLimit)
    }
}

/// One `agent__update_case` call, parsed. Every field is optional, so a call
/// carries only what changed.
struct CaseUpdate: Equatable {
    struct Mark: Equatable { var id: String; var met: Bool; var evidence: String? }
    struct NewRuling: Equatable { var text: String; var reason: String }
    struct Overrule: Equatable { var id: String; var reason: String }
    struct NewIssue: Equatable { var text: String; var blocking: Bool; var needsUser: Bool }
    struct Resolve: Equatable { var id: String; var resolution: String }
    struct ClaimInput: Equatable {
        var id: String?
        var claim: String?
        var grounds: String?
        var warrant: String?
        var qualifier: String?
        var rebuttal: String?
        var status: CaseFile.Claim.Status?
    }
    struct OptionInput: Equatable {
        var id: String?
        var title: String?
        var summary: String?
        var pros: [String]?
        var cons: [String]?
        var scores: [String: Int]?
        var status: CaseFile.Option.Status?
    }
    struct Choice: Equatable { var id: String; var reason: String }
    struct RiskInput: Equatable {
        var id: String?
        var text: String?
        var likelihood: Int?
        var impact: Int?
        var mitigation: String?
        var status: CaseFile.Risk.Status?
    }

    /// The method the model asked for, by id. `AIChatManager` resolves it
    /// against the library into `method` before applying.
    var methodID: String?
    var method: CaseMethod?
    var charter: CaseFile.Charter?
    var addCriteria: [String] = []
    var removeCriteria: [String] = []
    var markCriteria: [Mark] = []
    var settle: [NewRuling] = []
    var overrule: [Overrule] = []
    var addIssues: [NewIssue] = []
    var resolveIssues: [Resolve] = []
    var claims: [ClaimInput] = []
    var options: [OptionInput] = []
    var chooseOption: Choice?
    var risks: [RiskInput] = []
    /// Verification failed for this reason: the case goes back to the
    /// method's rework stage and a new iteration starts.
    var failedVerification: String?
    var phase: CaseFile.Phase?

    var isEmpty: Bool { self == CaseUpdate() }

    enum ParseError: Error, Equatable {
        case invalid(String)
    }

    /// Reads the tool's arguments. Tolerant where a model is likely to
    /// differ (a criterion as a bare string or as `{text}`), strict where a
    /// wrong guess would change the case (an unknown phase).
    static func parse(_ arguments: [String: Any]) throws -> CaseUpdate {
        var update = CaseUpdate()

        if let charter = arguments["charter"] as? [String: Any] {
            let objective = (charter["objective"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !objective.isEmpty else {
                throw ParseError.invalid("charter.objective is required — state the goal in the user's terms.")
            }
            update.charter = CaseFile.Charter(
                objective: objective,
                definitions: strings(charter["definitions"]),
                constraints: strings(charter["constraints"]),
                outOfScope: strings(charter["out_of_scope"]),
                turnBudget: positiveInt(charter["turn_budget"]),
                iterationBudget: positiveInt(charter["iteration_budget"])
            )
        }
        if let raw = arguments["method"] as? String {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !id.isEmpty { update.methodID = id }
        }
        update.options = try objects(arguments["options"]).map { object in
            var status: CaseFile.Option.Status?
            if let raw = object["status"] as? String {
                guard let parsed = CaseFile.Option.Status(rawValue: raw.lowercased()), parsed != .chosen else {
                    throw ParseError.invalid("option status may be candidate or rejected; choose one with choose_option.")
                }
                status = parsed
            }
            var scores: [String: Int]?
            if let raw = object["scores"] as? [String: Any] {
                scores = raw.compactMapValues { ($0 as? NSNumber)?.intValue }
            }
            return OptionInput(
                id: object["id"] as? String,
                title: object["title"] as? String,
                summary: object["summary"] as? String,
                pros: object["pros"] == nil ? nil : strings(object["pros"]),
                cons: object["cons"] == nil ? nil : strings(object["cons"]),
                scores: scores,
                status: status
            )
        }
        if let choice = arguments["choose_option"] as? [String: Any], let id = choice["id"] as? String {
            update.chooseOption = Choice(id: id, reason: choice["reason"] as? String ?? "")
        }
        update.risks = try objects(arguments["risks"]).map { object in
            var status: CaseFile.Risk.Status?
            if let raw = object["status"] as? String {
                guard let parsed = CaseFile.Risk.Status(rawValue: raw.lowercased()) else {
                    throw ParseError.invalid("risk status must be one of: \(CaseFile.Risk.Status.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                status = parsed
            }
            return RiskInput(
                id: object["id"] as? String,
                text: object["text"] as? String,
                likelihood: try level(object["likelihood"], field: "likelihood"),
                impact: try level(object["impact"], field: "impact"),
                mitigation: object["mitigation"] as? String,
                status: status
            )
        }
        if let reason = (arguments["failed_verification"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            update.failedVerification = reason
        }
        update.addCriteria = strings(arguments["add_criteria"])
        update.removeCriteria = strings(arguments["remove_criteria"])
        update.markCriteria = objects(arguments["mark_criteria"]).compactMap { object in
            guard let id = object["id"] as? String else { return nil }
            return Mark(id: id, met: (object["met"] as? Bool) ?? true, evidence: object["evidence"] as? String)
        }
        update.settle = objects(arguments["settle"]).compactMap { object in
            guard let text = object["text"] as? String else { return nil }
            return NewRuling(text: text, reason: object["reason"] as? String ?? "")
        }
        update.overrule = objects(arguments["overrule"]).compactMap { object in
            guard let id = object["id"] as? String else { return nil }
            return Overrule(id: id, reason: object["reason"] as? String ?? "")
        }
        update.addIssues = (arguments["add_issues"] as? [Any] ?? []).compactMap { entry in
            if let text = entry as? String { return NewIssue(text: text, blocking: true, needsUser: false) }
            guard let object = entry as? [String: Any], let text = object["text"] as? String else { return nil }
            return NewIssue(
                text: text,
                blocking: (object["blocking"] as? Bool) ?? true,
                needsUser: (object["needs_user"] as? Bool) ?? false
            )
        }
        update.resolveIssues = objects(arguments["resolve_issues"]).compactMap { object in
            guard let id = object["id"] as? String else { return nil }
            return Resolve(id: id, resolution: object["resolution"] as? String ?? "")
        }
        update.claims = try objects(arguments["claims"]).map { object in
            var status: CaseFile.Claim.Status?
            if let raw = object["status"] as? String {
                guard let parsed = CaseFile.Claim.Status(rawValue: raw.lowercased()) else {
                    throw ParseError.invalid("claim status must be one of: \(CaseFile.Claim.Status.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                status = parsed
            }
            return ClaimInput(
                id: object["id"] as? String,
                claim: object["claim"] as? String,
                grounds: object["grounds"] as? String,
                warrant: object["warrant"] as? String,
                qualifier: object["qualifier"] as? String,
                rebuttal: object["rebuttal"] as? String,
                status: status
            )
        }
        if let raw = arguments["phase"] as? String {
            guard let phase = CaseFile.Phase(rawValue: raw.lowercased()) else {
                throw ParseError.invalid("phase must be one of: \(CaseFile.Phase.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            update.phase = phase
        }
        return update
    }

    private static func strings(_ value: Any?) -> [String] {
        if let single = value as? String {
            let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        return (value as? [Any] ?? []).compactMap { entry in
            let text = (entry as? String) ?? ((entry as? [String: Any])?["text"] as? String)
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func objects(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let number = (value as? NSNumber)?.intValue, number > 0 else { return nil }
        return number
    }

    /// A likelihood or impact: 1–3, or low / medium / high.
    private static func level(_ value: Any?, field: String) throws -> Int? {
        guard let value else { return nil }
        if let number = (value as? NSNumber)?.intValue, (1...3).contains(number) { return number }
        switch (value as? String)?.lowercased() {
        case "low", "1": return 1
        case "medium", "med", "2": return 2
        case "high", "3": return 3
        default: throw ParseError.invalid("\(field) must be low, medium or high (or 1–3).")
        }
    }
}

/// A saved moment of the case: taken automatically at every phase change
/// and at ratification, so the user can go back to "before we chose
/// approach B" — restore the case in place, or branch a new chat from the
/// transcript as it was then.
///
/// It records the case and the transcript length, not the user's files.
/// File edits already have their own per-call undo (`FileSnapshots`).
struct CaseCheckpoint: Codable, Equatable, Identifiable {
    var id = UUID()
    var label: String
    var date = Date()
    /// How many transcript rows existed when it was taken.
    var messageCount: Int
    var snapshot: CaseFile

    /// Most checkpoints kept per chat; the oldest go first.
    static let limit = 20

    static func appending(_ checkpoint: CaseCheckpoint, to list: [CaseCheckpoint]) -> [CaseCheckpoint] {
        Array((list + [checkpoint]).suffix(limit))
    }
}
