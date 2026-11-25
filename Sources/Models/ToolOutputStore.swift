import Foundation

/// Keeps the full text of an output that was too large to hand the model, and
/// answers with where it went.
///
/// ## Why a file rather than a shorter answer
///
/// A tool result used to be cut at a character cap with `[... output truncated
/// ...]` and nothing else. That loses the data twice: the model cannot see what
/// was cut, and the only way to get it is to re-run the command — which is why
/// long transcripts are full of the same `grep` run with narrower arguments
/// each time. A `grep` that produced 200 KB over a big tree, a `dd` progress
/// log, a compiler's full warning list: all of it existed for a moment and then
/// was thrown away.
///
/// OpenCode answers this by writing the whole thing to a retained file and
/// putting the path in the marker the model reads (`tool-output.ts`). The same
/// shape works here, and TypstEdit already has the tool that pages it back:
/// `read_file`, with `start_line`/`end_line` to page through it.
///
/// ## Where it goes, and why there
///
/// `~/Library/Logs/TypstEdit/Outputs`, beside the shell jobs' logs, for the same
/// reason those live there: a person should be able to find it in Console.app
/// without knowing TypstEdit's internals, and a file that a chat may still cite
/// has to outlive the call that wrote it. It is **not** the scratch folder —
/// that one is per-chat and is deleted with the chat, while an output can be
/// cited by a later turn of the same chat and by a subagent's report.
///
/// Retention is `retention`, pruned opportunistically on write so nothing has
/// to run a timer for it. Nothing here is a backup: these are working files.
enum ToolOutputStore {

    /// One saved output.
    struct Saved: Equatable {
        /// Absolute path, for the marker and for `read_file`.
        let path: String
        /// How much of it there was, in characters.
        let totalChars: Int

        /// The marker that replaces the cut text. Stated as a fact about the
        /// call, never as a suggestion to retry: the data is here, the model
        /// should read it rather than produce it again.
        func marker(shown: Int) -> String {
            "[showing the first \(shown) of \(totalChars) characters — the full output was saved to \(path). Read it with read_file (start_line/end_line to page), or narrow the command. Do not re-run it just to see more.]"
        }
    }

    /// Most characters one saved output may hold. A runaway command (`yes`,
    /// `cat /dev/urandom | xxd`, a 2 GB log) must not fill the disk in one
    /// call, and past this size the file stops being something a model can
    /// page usefully anyway.
    nonisolated static let maxSavedChars = 8_000_000

    /// How long a saved output survives. Long enough for a chat to cite it in
    /// a later turn, short enough that the folder does not grow forever.
    nonisolated static let retention: TimeInterval = 7 * 24 * 60 * 60

    /// `~/Library/Logs/TypstEdit/Outputs`.
    nonisolated static func directory() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library")
        return base.appendingPathComponent("Logs/TypstEdit/Outputs", isDirectory: true)
    }

    /// Clips `text` to `cap`, saving the whole thing when it does not fit.
    ///
    /// A cut that fits is returned untouched, so every caller behaves exactly
    /// as before for ordinary output. When the text is too long:
    ///
    /// - it is written to a file under `label`, which is a tool name, so the
    ///   file is recognisable a week later;
    /// - the head is returned (the first lines are what a person reads); the
    ///   tail is not, because unlike a middle clip there is a whole file to
    ///   page and a head-plus-tail answer invites the model to assume it has
    ///   everything;
    /// - if the write fails, the marker says so and stays honest about the
    ///   data being gone rather than claiming a path that is not there.
    ///
    /// `label` is sanitised to a safe path component, exactly as MCP downloads
    /// are: a tool name from a server is data, not a filename.
    nonisolated static func clip(_ text: String, to cap: Int, label: String) -> String {
        guard text.count > cap else { return text }
        guard let saved = save(text, label: label) else {
            // No file, so the only honest thing is to say the rest is lost.
            return String(text.prefix(cap))
                + "\n[... output truncated at \(cap) characters — the full text could not be saved to disk, so it is not recoverable. Re-run with a narrower filter if you need the rest ...]"
        }
        return String(text.prefix(cap)) + "\n" + saved.marker(shown: cap)
    }

    /// Writes `text` to a new file and describes it. `nil` when the disk
    /// refused or the text is past `maxSavedChars`.
    nonisolated static func save(_ text: String, label: String) -> Saved? {
        guard text.count <= maxSavedChars else { return nil }
        let folder = directory()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        pruneOld(in: folder)
        let safe = safeComponent(label)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("\(stamp)-\(safe)-\(UUID().uuidString.prefix(8)).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return Saved(path: url.path, totalChars: text.count)
    }

    /// A tool name, `a/b`, or a server's arbitrary string, reduced to one safe
    /// path component. Same rule as a downloaded file's name.
    nonisolated static func safeComponent(_ raw: String) -> String {
        let allowed = raw.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character : "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "output" : String(collapsed.prefix(60))
    }

    /// Deletes saved outputs past `retention`. Best effort and silent: this runs
    /// behind a tool call the user is waiting on.
    nonisolated static func pruneOld(in folder: URL, now: Date = Date()) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries where entry.pathExtension == "txt" {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate)
            guard let modified, now.timeIntervalSince(modified) > retention else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Removes one saved output, for a chat being deleted.
    nonisolated static func remove(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
