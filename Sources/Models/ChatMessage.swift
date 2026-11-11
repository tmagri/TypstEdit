import Foundation

/// One entry in an AI Chat transcript. Persisted verbatim (see
/// `AIChatManager`), so this is deliberately a plain `Codable` value rather
/// than something tied to the live tool-calling loop's internal types.
struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        /// A tool the model called mid-conversation. Rendered as a compact
        /// activity line rather than a normal chat bubble.
        case toolCall
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

    /// The attachments, without the optional. Read-only convenience for the
    /// places that don't care whether the field was ever written.
    var attachments: [ChatImage] { images ?? [] }

    /// True when this row carries anything an image-capable model will read.
    var hasImages: Bool { !(images?.isEmpty ?? true) }

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
}

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
enum PendingApprovalKind {
    case fileWrite(relativePath: String, oldContent: String, newContent: String, isNewFile: Bool)
    /// A precise `edit_file` replacement: the snippets that matched, not the
    /// whole file, so the diff preview stays readable on a huge document.
    case fileEdit(relativePath: String, oldSnippet: String, newSnippet: String, occurrences: Int)
    /// A Python tool run. `wantsElevation` is the executor's detection of
    /// sudo / administrator-privilege use in the code — it drives the red
    /// elevated-privileges warning on the approval card, and it keeps these
    /// runs out of YOLO auto-approval: typing the password in the dialog is
    /// a human decision, and so is approving the code that asks for it.
    /// `sudoAuthentication` says how this Mac's sudo will authenticate an
    /// elevated run (probed before the card is shown), so the card never
    /// promises a password dialog that won't appear.
    case runPython(code: String, wantsElevation: Bool, sudoAuthentication: SudoAuthentication = .passwordDialog)
    /// A `web_fetch` request. The full URL is shown for approval — worth
    /// glancing at the query string, since a fetch is also a request the
    /// destination server sees (a compromised page could try to exfiltrate
    /// project secrets by encoding them into URL parameters).
    case webFetch(url: String)
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

    /// Publishing always requires a human review. YOLO can automate local
    /// commits or permitted pulls, but it must never auto-approve a push.
    /// The same holds for an elevated Python run: YOLO may auto-approve an
    /// ordinary script, but never one the user will have to authorize with
    /// their administrator password.
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
        return yoloMode
    }
}

struct PendingApproval: Identifiable {
    let id = UUID()
    let kind: PendingApprovalKind
    let toolCallName: String
}
