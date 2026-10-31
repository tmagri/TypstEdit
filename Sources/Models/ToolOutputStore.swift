import Foundation

/// Bounds what one tool call can put into a conversation.
///
/// A single chatty tool can otherwise spend the whole context at once: a
/// Python script that prints a loop's worth of output, or an MCP server that
/// returns a whole document from one query. `read_file` has always been paged,
/// but `run` and MCP tools had no cap at all.
///
/// The bound is not a plain truncation, which would lose the part the model
/// needs. Modelled on opencode's `ToolOutput`: the head of the output is
/// returned inline, and the **complete** text is written to a retained file
/// named in the marker. The marker hands the model a path inside its own scope,
/// so it can pull back any missing part with the `read_file` it already knows
/// (which is itself paged), instead of the output being gone for good.
///
/// Retained files live under `.typstedit/`, which `grep_project` and
/// `list_files` already skip and the RAG indexer already excludes, so they
/// never pollute a search or feed back into the conversation as content.
@MainActor
enum ToolOutputStore {

    /// The most lines returned inline.
    static let maxLines = 2_000
    /// The most bytes returned inline. Both limits apply; whichever is hit
    /// first stops the inline copy.
    static let maxBytes = 50 * 1024
    /// Retained files older than this are pruned at launch.
    static let retentionDays = 7

    /// What the bounds did to one output. Pure, so the rules are testable
    /// without a project folder or a disk write.
    struct Summary: Equatable {
        /// The text to hand back, without any marker.
        let kept: String
        /// Lines in the full output.
        let totalLines: Int
        /// Lines kept inline.
        let shownLines: Int
        /// Total bytes in the full output.
        let totalBytes: Int

        var truncated: Bool { shownLines < totalLines || kept.utf8.count != totalBytes }
    }

    /// Applies the bounds to `text`. When nothing is over a limit the whole
    /// text comes back unchanged and `truncated` is false.
    static func summarize(
        _ text: String,
        maxLines: Int = maxLines,
        maxBytes: Int = maxBytes
    ) -> Summary {
        let totalBytes = text.utf8.count
        var lines = text.components(separatedBy: "\n")
        // A trailing newline is the end of the last line, not an extra one.
        if text.hasSuffix("\n") { lines.removeLast() }
        let totalLines = lines.count

        guard totalLines > maxLines || totalBytes > maxBytes else {
            return Summary(kept: text, totalLines: totalLines, shownLines: totalLines, totalBytes: totalBytes)
        }

        var kept: [String] = []
        var bytes = 0
        for line in lines.prefix(maxLines) {
            let size = line.utf8.count + (kept.isEmpty ? 0 : 1)
            if bytes + size > maxBytes { break }
            kept.append(line)
            bytes += size
        }
        return Summary(
            kept: kept.joined(separator: "\n"),
            totalLines: totalLines,
            shownLines: kept.count,
            totalBytes: totalBytes
        )
    }

    /// Applies the bounds and, when the output had to be cut, retains the full
    /// text and appends the marker naming it. Text within the limits (the
    /// overwhelmingly common case) is returned untouched, with no disk write.
    ///
    /// With no scope root there is nowhere the model could read a retained
    /// file back from, so the cut is stated plainly instead of pretending to
    /// save anything.
    static func truncate(
        _ text: String,
        scope: LocalToolExecutor.Scope,
        toolName: String
    ) -> String {
        let summary = summarize(text)
        guard summary.truncated else { return text }

        // The kept head is empty only when a single line alone exceeds the
        // byte cap; say so rather than emitting an empty result.
        let body = summary.shownLines > 0 ? summary.kept : "(the first line alone is over \(maxBytes) bytes)"
        let shown = summary.shownLines > 0 ? "lines 1-\(summary.shownLines)" : "0 lines"

        guard let saved = retain(text, scope: scope, toolName: toolName) else {
            let more = summary.totalLines - summary.shownLines
            return "\(body)\n\n[showing \(shown) of \(summary.totalLines); \(more) more line\(more == 1 ? "" : "s") were dropped because there is nowhere to save the full output in this scope. Rerun the tool with a narrower target to see the rest.]"
        }
        return "\(body)\n\n[showing \(shown) of \(summary.totalLines); the full output is saved at \(saved.reference) — read it with read_file if you need the rest.]"
    }

    /// Where one retained output landed.
    struct Retained {
        /// Absolute path on disk.
        let url: URL
        /// What the model is told, relative to its scope root so `read_file`
        /// resolves it the same way as any other path.
        let reference: String
    }

    /// Writes `text` to a fresh retained file and returns it, or `nil` when
    /// there is no scope to write into or the write fails.
    static func retain(
        _ text: String,
        scope: LocalToolExecutor.Scope,
        toolName: String
    ) -> Retained? {
        guard let root = scope.root, let directory = directory(for: root) else { return nil }
        let name = fileStem(toolName: toolName) + "-" + UUID().uuidString.prefix(8) + ".txt"
        let url = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let reference = filePath.hasPrefix(rootPath + "/")
            ? String(filePath.dropFirst(rootPath.count + 1))
            : filePath
        return Retained(url: url, reference: reference)
    }

    /// `<scope>/.typstedit/chat/tool-output` — inside the same `.typstedit/`
    /// folder the saved conversations use, so a project keeps all of its chat
    /// state in one place. `read_file` can open these (they are inside the
    /// scope), while `grep_project` and `list_files` skip `.typstedit`, so a
    /// retained dump never shows up in a search or a listing.
    static func directory(for scopeRoot: URL) -> URL? {
        ProjectSettingsManager.dotFolderURL(for: scopeRoot)
            .appendingPathComponent("chat/tool-output", isDirectory: true)
    }

    /// A filename-safe fragment naming the tool that produced the output, so
    /// a retained file is identifiable at a glance.
    static func fileStem(toolName: String) -> String {
        let allowed = toolName.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return "tool_" + (collapsed.isEmpty ? "output" : String(collapsed.prefix(40)))
    }

    /// Deletes retained outputs older than `retentionDays`. Called at launch:
    /// nothing else will, since these files are outside the scope of the
    /// compiler's and the vector cache's own cleanup.
    static func pruneStale(scopeRoots: [URL], olderThanDays days: Int = retentionDays) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for root in scopeRoots {
            guard let directory = directory(for: root),
                  let entries = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }
            for entry in entries {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if modified < cutoff {
                    try? FileManager.default.removeItem(at: entry)
                }
            }
        }
    }
}
