import Foundation

/// The chat's scratch folder: where the model writes down what it is
/// thinking so the notes outlive the context window.
///
/// ## Why this exists
///
/// A reasoning model's hidden thinking is not addressable. Providers return
/// a *summary* of it (Anthropic's `display: "summarized"`, and `"omitted"` by
/// default on current models; OpenAI returns only `reasoning.summary`), and
/// the block that carries the real reasoning must be echoed back byte-identical
/// or the request is rejected. So a harness cannot dump the model's chain of
/// thought and cannot edit it — but it *can* give the model a place to write
/// its own notes, and it can make those notes survive compaction.
///
/// That is the honest form of "externalised thinking": the model writes, the
/// harness only stores and re-reads. See `agent__think`.
///
/// ## Layout
///
/// ```
/// ~/Library/Application Support/TypstEdit/Scratch/<session id>/
///   notes.md        what `agent__think` appends to
///   findings.md     what a `delegate_task` subagent reported
/// ```
///
/// One folder per conversation, so a chat's scratch can be deleted with the
/// chat and two open chats never write to the same file.
enum Scratchpad {
    /// The file `agent__think` appends to.
    static let notesFileName = "notes.md"
    /// The file a subagent's findings are saved to.
    static let findingsFileName = "findings.md"
    /// The prefix of one report per brief in a `delegate_parallel` round
    /// (`findings-1-….md`). Kept next to `findingsFileName` because the recall
    /// index decides a file's corpus by name, and the two must agree.
    static let parallelFindingsPrefix = "findings-"

    /// The prefix of a background job's saved report (`findings-job-1.md`).
    /// Inside the parallel prefix so recall files it as findings, but its own
    /// prefix so `removeParallelFindings` — which clears the *last round's*
    /// parallel reports — cannot delete a report the model has not collected.
    static let backgroundFindingsPrefix = "findings-job-"

    /// One background job's report file name.
    nonisolated static func backgroundFindingsName(number: Int) -> String {
        "\(backgroundFindingsPrefix)\(number).md"
    }

    /// A note is capped: a model that decides to "think" a whole essay into
    /// the file would otherwise re-embed and re-read it forever. The cap is
    /// on a single entry, not the file.
    static let maxNoteChars = 8_000

    /// Most characters `scratch__read` returns in one call. Line paging
    /// follows `ReferenceFolder.readLineDefault`'s shape so a model that has
    /// already paged a reference file knows what to expect.
    static let readLineDefault = 2_000
    static let readLineMax = 5_000

    /// Scratch is not the reference folder: a file here is a working note,
    /// and anything huge is a bug rather than a document.
    static let maxFileChars = 400_000

    nonisolated static func directory(for sessionID: UUID) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("TypstEdit/Scratch", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    nonisolated static func fileURL(for sessionID: UUID, name: String) -> URL {
        directory(for: sessionID).appendingPathComponent(name, isDirectory: false)
    }

    /// Appends one note under a heading, and returns the file's size after
    /// the write rather than its contents: echoing the whole chain back on
    /// every call is how a scratchpad turns into a token sink.
    ///
    /// The heading is written for the first note on a topic and skipped for
    /// later ones, so a run of related notes reads as one section.
    @discardableResult
    nonisolated static func appendNote(
        _ thought: String,
        topic: String?,
        to sessionID: UUID,
        date: Date = Date()
    ) throws -> (bytes: Int, entries: Int) {
        let trimmed = thought.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScratchpadError.emptyNote
        }
        guard trimmed.count <= maxNoteChars else {
            throw ScratchpadError.noteTooLong(trimmed.count, maxNoteChars)
        }

        let url = fileURL(for: sessionID, name: notesFileName)
        try ensureDirectory(for: sessionID)

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let stamp = Self.timestampFormatter.string(from: date)
        let heading = topic?.trimmingCharacters(in: .whitespacesAndNewlines)

        var entry = ""
        if let heading, !heading.isEmpty, !existing.contains("## \(heading)") {
            entry += "## \(heading)\n\n"
        }
        entry += "### \(stamp)\n\(trimmed)\n\n"

        let updated = existing + entry
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return (
            bytes: updated.utf8.count,
            entries: updated.components(separatedBy: "\n### ").count
        )
    }

    /// Saves a subagent's findings so they can be recalled later. Replaces
    /// the file: the findings for the latest delegation are what matters,
    /// and an old report is exactly the stale evidence a scratchpad must not
    /// quietly keep serving.
    ///
    /// `name` is `findings.md` for a lone `delegate_task`, which is a single
    /// file the newest report replaces by design. A `delegate_parallel` round
    /// passes one name per brief instead: four workers writing the same file
    /// at once would leave one report and three silently lost, and the lost
    /// ones are exactly the evidence the parent asked for.
    nonisolated static func writeFindings(
        _ text: String,
        to sessionID: UUID,
        task: String,
        name: String = findingsFileName
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = fileURL(for: sessionID, name: name)
        try ensureDirectory(for: sessionID)
        let body = "# Subagent findings\n\nTask: \(task)\n\n\(trimmed)\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Deletes the previous `delegate_parallel` round's reports.
    ///
    /// `findings.md` is replaced on every delegation so an old report is never
    /// served as current evidence. A parallel round writes one file per brief,
    /// so "replace" has to be "remove the last round's set first": a 3-brief
    /// round after a 6-brief one would otherwise leave reports 4–6 behind,
    /// and `recall` would quote them as if this round had produced them.
    ///
    /// A background job's report (`findings-job-…`) shares the prefix but not
    /// the lifetime: it ends with the chat, not with the next parallel round,
    /// because the model may not have collected it yet. It is excluded here
    /// and its name comes from `backgroundFindingsName`, so the two rules
    /// cannot drift apart.
    nonisolated static func removeParallelFindings(for sessionID: UUID) {
        let directory = directory(for: sessionID)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for url in entries where url.lastPathComponent.hasPrefix(parallelFindingsPrefix)
            && !url.lastPathComponent.hasPrefix(backgroundFindingsPrefix)
            && url.pathExtension == "md" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Every scratch file, newest first, for the manifest and the index.
    nonisolated static func listFiles(for sessionID: UUID) -> [ScratchFile] {
        let directory = directory(for: sessionID)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url -> ScratchFile? in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            guard size <= maxFileChars else { return nil }
            return ScratchFile(
                name: url.lastPathComponent,
                size: size,
                modified: values?.contentModificationDate ?? .distantPast
            )
        }
        .sorted { $0.modified > $1.modified }
    }

    /// Reads one scratch file, windowed by line like
    /// `reference__read_file`, so a model can page a long notes file instead
    /// of pulling all of it into the prompt.
    nonisolated static func read(        _ name: String,
        from sessionID: UUID,
        startLine: Int?,
        endLine: Int?
    ) throws -> String {
        let safeName = try resolveName(name, in: sessionID)
        let url = fileURL(for: sessionID, name: safeName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ScratchpadError.notFound(safeName)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ScratchpadError.notReadable(safeName)
        }

        let lines = text.components(separatedBy: "\n")
        let total = lines.count
        let lower = max(0, (startLine ?? 1) - 1)
        let upper = min(total, endLine ?? min(total, lower + readLineMax))
        guard lower < upper else {
            return "[lines \(lower + 1)-\(lower) of \(total)] (empty range)"
        }
        var output = "[\(safeName) lines \(lower + 1)-\(upper) of \(total)]\n"
        output += lines[lower..<upper].enumerated()
            .map { "\($0.offset + lower + 1)\t\($0.element)" }
            .joined(separator: "\n")
        return output
    }

    /// One line per scratch file for the system prompt: path, size, age and
    /// a leading excerpt. The same idea as
    /// `ReferenceFolder.manifestBlock` — the model gets a pointer, not the
    /// contents, and asks for what it needs.
    nonisolated static func manifestBlock(for sessionID: UUID, now: Date = Date()) -> String? {
        let files = listFiles(for: sessionID)
        guard !files.isEmpty else { return nil }

        let rows = files.map { file -> String in
            let url = fileURL(for: sessionID, name: file.name)
            let head = (try? String(contentsOf: url, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first(where: { !$0.hasPrefix("#") })?
                .prefix(excerptChars) ?? ""
            let excerpt = head.isEmpty ? "" : " — \(head)"
            return "- \(file.name) (\(sizeLabel(file.size)), \(ageLabel(file.modified, now: now)))\(excerpt)"
        }
        return """
        SCRATCH NOTES — files you wrote earlier in this chat, on disk so they outlive the context window. They are not in your context; read one with scratch__read, or search them all with scratch__search.
        \(rows.joined(separator: "\n"))
        """
    }

    /// Literal text search across every scratch file for this chat — the tool
    /// the manifest and the think tool have advertised since the scratchpad
    /// shipped. Case-insensitive, like `reference__grep`'s default, and
    /// capped the same way.
    nonisolated static func search(
        _ pattern: String,
        in sessionID: UUID,
        limit: Int = 200
    ) throws -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScratchpadError.notFound(pattern)
        }
        let needle = trimmed.lowercased()
        var matches: [String] = []
        for file in listFiles(for: sessionID) {
            let url = fileURL(for: sessionID, name: file.name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated()
            where matches.count < limit {
                if line.lowercased().contains(needle) {
                    matches.append("\(file.name):\(index + 1): \(String(line.prefix(300)))")
                }
            }
            guard matches.count < limit else { break }
        }
        guard !matches.isEmpty else {
            return "No matches for \"\(trimmed)\" in this chat's scratch notes."
        }
        var result = matches.joined(separator: "\n")
        if matches.count >= limit {
            result += "\n(Stopped at \(limit) matches — narrow the pattern or read the file in pages.)"
        }
        return result
    }

    /// The passages a scratch folder offers to the recall index, oldest
    /// first. Only files that exist contribute; a note is indexed from the
    /// words on disk, so an edit re-embeds exactly the changed passage.
    ///
    /// Capped at `maxScratchPassages`. The transcript's own cap
    /// (`ConversationRecall.maxSources`) does not cover these, and a scratch
    /// file may be up to `maxFileChars`, so without a bound here a chat could
    /// push the vector cache past the size its Settings note promises.
    nonisolated static func recallSources(
        for sessionID: UUID,
        now: Date = Date()
    ) -> [RecallSource] {
        let files = listFiles(for: sessionID)
        var sources: [RecallSource] = []
        for file in files {
            let url = fileURL(for: sessionID, name: file.name)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.utf8.count <= maxFileChars else { continue }
            // A parallel round writes one report per brief
            // (`findings-1-….md`), so the corpus is decided by the prefix. A
            // name test would file three of four reports under "notes" and
            // quietly change what `recall` says they are.
            let corpus: RecallCorpus = file.name == findingsFileName
                || file.name.hasPrefix(Self.parallelFindingsPrefix)
                ? .findings : .notes
            for passage in ConversationRecall.passagesWithLines(in: text) {
                sources.append(RecallSource(
                    key: ConversationRecall.key(
                        for: .file(path: file.name, line: passage.line),
                        text: passage.text
                    ),
                    origin: .file(path: file.name, line: passage.line),
                    corpus: corpus,
                    label: "\(file.name):\(passage.line)",
                    text: passage.text,
                    startLine: passage.line,
                    date: file.modified
                ))
            }
        }
        return Array(sources.suffix(maxScratchPassages))
    }

    /// Most passages the scratch folder contributes to the index. Newest
    /// kept, like the transcript's own cap: the recent notes are the ones a
    /// model is working from.
    nonisolated static let maxScratchPassages = 200

    // MARK: - Helpers

    struct ScratchFile: Equatable {
        let name: String
        let size: Int
        let modified: Date
    }

    /// How much of a file the manifest quotes — enough to say what it is
    /// about without carrying it.
    nonisolated static let excerptChars = 160

    /// A scratch file name, refused if it tries to leave the folder. The
    /// model supplies this string, so `../` and absolute paths have to fail
    /// here rather than at the filesystem's discretion.
    nonisolated static func resolveName(_ requested: String, in sessionID: UUID) throws -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScratchpadError.notFound(requested) }
        guard !trimmed.contains("/"), !trimmed.contains("\\"), trimmed != ".", trimmed != ".." else {
            throw ScratchpadError.outsideFolder(trimmed)
        }
        return trimmed
    }

    nonisolated static func ensureDirectory(for sessionID: UUID) throws {
        try FileManager.default.createDirectory(
            at: directory(for: sessionID),
            withIntermediateDirectories: true
        )
    }

    /// Removes a conversation's scratch folder. Called when the chat is
    /// deleted, so a deleted conversation leaves nothing of itself behind.
    nonisolated static func delete(for sessionID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: sessionID))
    }

    nonisolated private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    nonisolated static func sizeLabel(_ bytes: Int) -> String {
        if bytes < 1_024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1_024
        if kb < 1_024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1_024)
    }

    nonisolated static func ageLabel(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}

enum ScratchpadError: LocalizedError {
    case emptyNote
    case noteTooLong(Int, Int)
    case notFound(String)
    case notReadable(String)
    case outsideFolder(String)

    var errorDescription: String? {
        switch self {
        case .emptyNote:
            return "The note is empty. Write the thought you want to keep."
        case .noteTooLong(let count, let limit):
            return "That note is \(count) characters; one note is limited to \(limit). Split it into a few notes — shorter notes are also easier to find again."
        case .notFound(let name):
            return "No scratch file named '\(name)' in this chat. Check the file list in your context."
        case .notReadable(let name):
            return "'\(name)' could not be read as text."
        case .outsideFolder(let name):
            return "'\(name)' is not a scratch file name. Pass a plain name from the file list, with no path."
        }
    }
}
