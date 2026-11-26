import Foundation

/// One entry in an AI Chat transcript. Persisted verbatim (see
/// `AIChatManager`), so this is deliberately a plain `Codable` value rather
/// than something tied to the live tool-calling loop's internal types.
///
/// The engine was ported from Clippy, so this is Clippy's shape merged with
/// TypstEdit's: the fields both engines had are identical, TypstEdit's
/// multi-file `fileChanges` replaced Clippy's single `fileChange`, and the
/// mascot-only `animationKey` is kept as an (unused) field so old transcripts
/// keep decoding.
struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        /// A tool the model called mid-conversation. Rendered as a compact
        /// activity line rather than a normal chat bubble.
        case toolCall
        /// A screen capture that was OCR'd. Rendered as its own card with the
        /// recognized text and a thumbnail, so the source of an answer is
        /// never ambiguous.
        case screenCapture
        /// A calculator run — a result, or a drawn chart. Rendered with the
        /// calculator's own styling so math reads like math.
        case calculation
    }

    enum ToolStatus: String, Codable {
        case running
        case succeeded
        case failed
        case denied
        case cancelled
        /// Not run: an identical repeat of a read or search (see
        /// `ToolCallRepeatGuard`), or a call whose arguments were cut off or
        /// invalid. Shown so the refusal isn't invisible.
        case skipped

        /// An unknown status (written by a newer build) reads as `.failed`
        /// instead of making the whole saved transcript undecodable.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = ToolStatus(rawValue: raw) ?? .failed
        }
    }

    var id: UUID = UUID()
    var role: Role
    var text: String = ""
    var timestamp: Date = Date()

    /// Images the user attached to this message (user rows only), sent to the
    /// model with the turn they belong to. Optional so conversations saved
    /// before images existed still decode — a missing key reads as "none".
    var images: [ChatImage]? = nil

    /// Captured reasoning/"thinking" content, when the model and provider
    /// expose it (OpenAI-compatible `reasoning_content`/`reasoning` fields,
    /// or inline `<think>`/`<thought>` tags some local/open models emit).
    /// Shown collapsed under the final answer rather than discarded — only
    /// set on `.assistant` messages, and only when the model actually
    /// returned something.
    var reasoning: String? = nil

    /// True for work done inside a `delegate_task` subagent, so the trace can
    /// be drawn as nested activity instead of the main agent's own steps.
    var isSubagent: Bool = false

    /// Older turns folded into a summary. Kept on disk (so the transcript is
    /// still readable as history) but excluded from the prompt sent to the
    /// model, which sees the summary instead.
    var isCompacted: Bool = false

    /// Marks the message that holds a compaction summary, so it can be
    /// styled distinctly from a normal answer.
    var isSummary: Bool = false

    // Only set when role == .toolCall
    var toolName: String? = nil
    var toolArgumentsJSON: String? = nil
    var toolStatus: ToolStatus? = nil
    var toolOutput: String? = nil
    /// Set when this call changed project files on disk: the metadata that
    /// drives the transcript's "Undo file changes" (the pre-images themselves
    /// live in `FileSnapshotStore`). Nil for calls that wrote nothing; a
    /// batch patch lists every file it touched. (Clippy kept a single
    /// `fileChange` here; TypstEdit's list covers `apply_patch` batches.)
    var fileChanges: [FileChangeRecord]? = nil

    /// Set on `.screenCapture` rows: how sure Vision was, 0…1.
    var ocrConfidence: Float? = nil

    /// Set on `.calculation` rows that produced a chart: the sampled curve.
    var plot: CalculatorPlotSpec? = nil

    /// The token and cost accounting for the turn that produced this reply,
    /// stamped on the turn's final `.assistant` row. A tool-calling turn
    /// makes several provider requests, so this is the turn's sum, not the
    /// last request's. Re-entering a conversation rebuilds its running
    /// totals by summing these rows (`AIChatManager.usageTotal(in:)`), which
    /// is why the stamp belongs on the message and not in a side file: the
    /// transcript is the record. `nil` on older rows and on every other
    /// row kind.
    var usage: TokenUsage? = nil

    /// The message's attachments, empty when it has none. Callers almost
    /// always want the array, not the optional.
    var imageAttachments: [ChatImage] { images ?? [] }

    /// Whether this message carries any attachments.
    var hasImages: Bool { !imageAttachments.isEmpty }

    /// How the message reads in the folded transcript prompt. Attachment rows
    /// keep a marker so an image-only message doesn't fold into a bare
    /// `[USER]`, and the model still knows something was shown earlier in the
    /// conversation (its pixels ride along only on recent turns — see
    /// `retainedImages`).
    var foldedText: String {
        guard hasImages else { return text }
        let marker = imageAttachments.count == 1
            ? "[image attached]"
            : "[\(imageAttachments.count) images attached]"
        return text.isEmpty ? marker : "\(marker)\n\(text)"
    }

    /// One line describing the call for the transcript and the prompt.
    var toolLabel: String {
        let qualified = toolName ?? "tool"
        let name = qualified.range(of: "__").map { String(qualified[$0.upperBound...]) } ?? qualified
        return name
    }

    /// The tool's arguments, cut to what a one-line row can show. A write
    /// call's arguments carry the whole file; a one-line `Text` still lays
    /// out every character of what it is given, so the row gets a prefix.
    var toolArgumentsPreview: String? {
        guard let arguments = toolArgumentsJSON else { return nil }
        // `prefix` and an index check, not `count`: counting walks the
        // whole string.
        let head = arguments.prefix(200)
        return head.endIndex == arguments.endIndex ? arguments : String(head) + "…"
    }

    /// The one line of a tool's output the transcript shows under its call.
    ///
    /// Computed here, not in the row view: a transcript can hold hundreds of
    /// tool calls whose outputs run to tens of kilobytes each, and the row
    /// re-renders with the whole window. Splitting and prefixing in `body`
    /// meant copying megabytes of output per redraw; this does the work once
    /// and keeps the result to 120 characters.
    var toolOutputPreview: String? {
        guard let output = toolOutput, !output.isEmpty else { return nil }
        // `prefix` on the collection, before any split: finding the first line
        // never needs to touch the rest of a 24 KB page.
        let firstLine = output.prefix { $0 != "\n" }.prefix(120)
        return "→ " + firstLine
    }
}

/// A saved conversation — one JSON file on disk, plus a summary in the
/// session index. This is Clippy's `ChatSession` unified with TypstEdit's
/// `ChatSessionRecord`: every TypstEdit field is kept under its persisted
/// name (`titleIsAutoGenerated`, `goal`) so existing saved chats decode, and
/// the new-engine fields (`caseFile`, checkpoints, model pin, strategy) are
/// optional so old files decode without them.
struct ChatSession: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String = "New chat"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var messages: [ChatMessage] = []
    /// True while the title came from the fallback/LLM naming rather than a
    /// user rename — only auto-generated titles get replaced by the model.
    /// (Clippy stored the inverse as `titleIsCustom`; TypstEdit's on-disk
    /// name is kept.)
    var titleIsAutoGenerated: Bool = true
    /// The task checklist as last shown in the panel (the `update_plan`
    /// tool). Stored so a plan survives a restart; `nil` in older files,
    /// where it is rebuilt from the last `update_plan` row instead.
    var plan: [AgentPlanItem]? = nil
    /// Whether the conversation is in Plan mode (read-only tools only).
    /// `nil` in older files, decoded as off — a mode the user switched on
    /// should survive a restart, the same way the checklist does.
    var planMode: Bool? = nil
    /// The armed goal loop of the previous engine, if one was running when
    /// the chat was saved. Kept for decoding old transcripts; the new engine
    /// drives continuations through auto-proceed and the case file instead.
    var goal: ChatGoal? = nil
    /// The case file of a goal-directed chat (see `CaseFile`): the ratified
    /// charter, the standard, rulings, issues, claims and phase. `nil` for an
    /// ordinary chat and in older files.
    var caseFile: CaseFile? = nil
    /// Saved moments of the case, oldest first (see `CaseCheckpoint`).
    var caseCheckpoints: [CaseCheckpoint]? = nil
    /// The user's labels for this conversation ("Work", "Writing", "🎮").
    /// Optional so chats saved before labels existed still decode. Normalized
    /// through `ChatLabel.normalize` when set, so writing a duplicate or a
    /// blank label is a no-op rather than a second chip.
    var labels: [String]? = nil
    /// The saved model profile this conversation uses, pinned at the moment
    /// the user picked one in the model menu. The outer optional is the
    /// stored key (`nil` = the field was never written); the inner one is the
    /// user's explicit "no pin". `nil` = follow the app's chat-defaults
    /// selection, exactly how a chat behaved before the field existed.
    var modelProfileID: UUID?? = nil
    /// How this conversation should be worked (`StrategicStance.id`), from
    /// the picker beside the composer. `nil` reads as `general`, which is
    /// exactly how older chats behaved. Per conversation, like the model pin
    /// and Plan mode: a critique in one chat must not turn another chat
    /// adversarial.
    var strategyID: String? = nil
    /// The reference folder this conversation reads, when it has picked one
    /// of its own. Unused in TypstEdit for now (the project is the folder);
    /// kept because the ported read machinery reads it.
    var referenceFolderPath: String? = nil

    /// The labels as the UI reads them: never nil, already cleaned.
    var labelList: [String] { labels ?? [] }
}

/// The on-disk form is the same value — the historical TypstEdit name for
/// the persisted conversation (one JSON file per session, next to an
/// `index.json` listing the summaries). The alias keeps the session store
/// and its import/export code reading exactly as before.
typealias ChatSessionRecord = ChatSession

/// Typed actions keep publishing approval independent of the displayed label.
enum GitNetworkAction: String, CaseIterable {
    case fetch = "Fetch"
    case pull = "Pull (fast-forward only)"
    case push = "Push"
}

/// How `sudo` will authenticate an elevated Python run on this Mac.
enum SudoAuthentication: Equatable {
    /// The askpass helper's password dialog (the default setup).
    case passwordDialog
    /// PAM is set up for Touch ID / Apple Watch: sudo may ask for that first,
    /// with the password dialog as the fallback.
    case biometric
    /// sudo needs no password at all (`NOPASSWD` in sudoers): approving the
    /// run gives it root with no further prompt.
    case noPassword

    /// The red warning on the elevated approval card.
    var approvalWarning: String {
        switch self {
        case .passwordDialog:
            return "Elevated run: sudo will pop a macOS password dialog. Typing your password gives this script full root access — approve only if you understand every line."
        case .biometric:
            return "Elevated run: sudo will ask for Touch ID (or your password in a macOS dialog). Confirming gives this script full root access — approve only if you understand every line."
        case .noPassword:
            return "Elevated run with NO password prompt: sudo on this Mac is set up not to ask for a password (NOPASSWD), so approving runs every sudo command in this script as root immediately. Approve only if you understand every line."
        }
    }
}

/// What's being asked of the user before a tool call is allowed to proceed.
/// The chat's agentic loop blocks on this — see `AIChatManager.pendingApproval`.
///
/// TypstEdit's editor-tool kinds are merged with the new engine's
/// machine-tool kinds (`runShell`, skill authoring, MCP authoring). The
/// macOS personal-data kinds (mail, notes, calendar, shortcuts, scheduled
/// tasks) are not ported — those tools don't exist here.
enum PendingApprovalKind {
    case fileWrite(relativePath: String, oldContent: String, newContent: String, isNewFile: Bool)
    /// A precise `edit_file` replacement: the snippets that matched, not the
    /// whole file, so the diff preview stays readable on a huge document.
    case fileEdit(relativePath: String, oldSnippet: String, newSnippet: String, occurrences: Int)
    /// A block of lines moved within the same file by `move_lines`. Shows the
    /// lines being moved and where they are placed, keeping the approval card
    /// fast on large documents without diffing the whole file.
    case fileMoveLines(relativePath: String, startLine: Int, endLine: Int, beforeLine: Int, movedSnippet: String)
    /// A Python tool run. `wantsElevation` is the executor's detection of
    /// sudo / administrator-privilege use in the code — it drives the red
    /// elevated-privileges warning on the approval card, and it keeps these
    /// runs out of YOLO auto-approval: typing the password in the dialog is
    /// a human decision, and so is approving the code that asks for it.
    /// `sudoAuthentication` says how this Mac's sudo will authenticate an
    /// elevated run (probed before the card is shown), so the card never
    /// promises a password dialog that won't appear.
    case runPython(code: String, wantsElevation: Bool, sudoAuthentication: SudoAuthentication = .passwordDialog)
    /// A shell tool run (`shell__run`). `command` is the command line exactly
    /// as the model wrote it, which is also what the approval card shows and
    /// what a saved permission rule matches.
    ///
    /// Unlike a script, a command line is opaque: `ls` and `rm -rf ~/…` are
    /// the same length on a card. That is why a shell run never auto-approves
    /// in YOLO mode (`canAutoApprove` refuses it), and why the only way to
    /// skip the card is a saved allow rule for that exact command — which the
    /// user wrote down themselves.
    case runShell(command: String)
    /// A `web_fetch` request. The full URL is shown for approval — worth
    /// glancing at the query string, since a fetch is also a request the
    /// destination server sees (a compromised page could try to exfiltrate
    /// project secrets by encoding them into URL parameters).
    /// `savedSignInHost` names the site whose saved sign-in cookies would be
    /// replayed, so the card never sends a session silently.
    case webFetch(url: String, savedSignInHost: String? = nil)
    /// Compiling a document to PDF/PNG/SVG. The output is binary (or several
    /// page files), so there's no text diff to show — the destination and
    /// format are the useful details.
    case documentExport(relativePath: String, format: String, destination: String, existingFile: Bool)
    /// Converting a PDF to Typst (`import_pdf`). Shown with the pages and,
    /// when AI is used, the model that will receive cropped page images.
    case pdfImport(source: String, destination: String, pages: String, aiModel: String?, existingFile: Bool)
    /// Copying files or folders into a delivery/evidence folder. Listed as a
    /// batch so a multi-file handoff needs one approval, not one per copy.
    case fileCopy(sources: [String], destination: String, overwrite: Bool)
    /// Creating a folder (for an empty delivery/evidence folder, or before
    /// copying into it).
    case createFolder(relativePath: String)
    /// A multi-file `apply_patch`. Reviewed as one batch — that is the whole
    /// point — so the user sees every file's change and approves once, instead
    /// of approving a six-file restructure six times.
    case batchPatch(changes: [PatchChange])
    /// Staging or unstaging files through `git_stage`. Contents never change,
    /// but the index does, so the exact paths are shown.
    case gitStage(paths: [String], stage: Bool)
    /// A `git_commit` request: the message that will be recorded, the files
    /// that go into the commit, and the branch. `stageAll` means the listed
    /// files are also staged first (they include untracked files).
    case gitCommit(message: String, files: [String], branch: String, stageAll: Bool)
    /// A network Git action (`git_fetch`/`git_pull`/`git_push`). Shown with
    /// the branch and upstream so a push is never a surprise.
    case gitNetwork(operation: GitNetworkAction, branch: String, upstream: String?)
    /// A screen capture read by OCR (the `project__look` tool). Always needs
    /// a human, YOLO included: pointing the agent's eyes at the desktop is a
    /// privacy decision, not a file edit.
    case screenCapture(scope: String, purpose: String)
    /// Creating a new skill (`skill__create`). The full SKILL.md is shown,
    /// like a project-file write: it is the same class of change — a new
    /// text file in a folder the user owns — so YOLO treats it alike.
    case skillCreate(name: String, description: String, bodyPreview: String)
    /// Writing a file inside a skill's folder (`skill__add_attachment` or a
    /// `skill__update`'s SKILL.md rewrite). `isSKILLFile` says whether the
    /// shown content is the whole SKILL.md or an attachment.
    case skillWriteFile(skillName: String, relativePath: String, oldContent: String, newContent: String, isNewFile: Bool, isSKILLFile: Bool)
    /// Deleting a whole skill (`skill__delete`) — folder and attachments
    /// included. Always manual: unlike a project-file write there is no
    /// other copy, so YOLO never wipes a skill the user may have authored.
    case skillDelete(skillName: String, fileCount: Int)
    /// Adding an MCP server (`mcp__add_server`), or changing one. The exact
    /// entry is shown because it is a standing grant: every future chat gets
    /// whatever tools that server advertises, and a local one runs a command
    /// on this Mac. Always manual — YOLO never adds one.
    case mcpServerAdd(name: String, transportLabel: String, target: String, summary: String, replacesExisting: Bool)
    /// Deleting an MCP server, with everything it contributed.
    case mcpServerDelete(name: String, toolCount: Int)

    /// Which approvals are never automated. Publishing always requires a
    /// human review: YOLO can automate local edits and ordinary scripts, but
    /// it must never auto-approve a push, an elevated Python run, a shell
    /// command (opaque on a card), a screen capture, a skill deletion, or an
    /// MCP server change (a standing grant of new tools).
    func canAutoApprove(yoloMode: Bool) -> Bool {
        if case .gitNetwork(let operation, _, _) = self {
            switch operation {
            case .push: return false
            case .fetch, .pull: return yoloMode
            }
        }
        if case .runPython(_, let wantsElevation, _) = self, wantsElevation {
            return false
        }
        switch self {
        case .screenCapture, .skillDelete, .mcpServerAdd, .mcpServerDelete, .runShell:
            return false
        default:
            return yoloMode
        }
    }

    /// Whether a saved "Always allow" rule may skip this kind's card.
    ///
    /// Wider than `canAutoApprove`: a shell command is never automated by
    /// YOLO — the mode is a blanket switch, and a blanket switch over
    /// opaque command lines is YOLO-for-root — but a rule the user wrote
    /// for one specific command is a decision about that command. Everything
    /// YOLO automates is covered too, so the two never disagree.
    var canBeAllowedByRule: Bool {
        if case .runShell = self { return true }
        return canAutoApprove(yoloMode: true)
    }

    /// The "Always allow…" rules that could cover this kind of call. Empty
    /// for the kinds YOLO always sends back to a human, because a saved rule
    /// may never be broader than what YOLO can automate.
    @MainActor
    var permissionSuggestions: [PermissionSuggestion] {
        PermissionRules.suggestions(for: self)
    }
}

struct PendingApproval: Identifiable, Hashable {
    let id = UUID()
    let kind: PendingApprovalKind
    let toolCallName: String
    /// Safety rules that fired for this call. Non-empty only when the monitor
    /// held back a card YOLO would otherwise have skipped, so the card can
    /// say why it is being asked instead of looking like YOLO forgot.
    var safetyHits: [TraceSafetyRule] = []

    /// Identity is the id only: the kind carries associated values that
    /// don't need hashing (the card renders from them, comparisons don't).
    static func == (lhs: PendingApproval, rhs: PendingApproval) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
