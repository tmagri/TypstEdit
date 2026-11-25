import Foundation

/// What the session list and the History picker need from a saved
/// conversation: its name, its age, how long it is — never its transcript.
///
/// The split follows TypstEdit's `ChatSessionSummary` (this IS that type):
/// the session list is kept in memory as these small values, and a
/// transcript is read back from disk only when its conversation is opened.
/// A user who has stepped through a hundred long chats pays for a hundred
/// short lines, not for a hundred full transcripts.
///
/// (`ChatTabState` from the Clippy original is not ported: TypstEdit's chat
/// panel shows one conversation at a time from the session menu, so there is
/// no tab strip state to persist.)

/// Persists chat sessions as JSON files, following TypstEdit's storage
/// layout pattern (one folder per scope, plain Codable files, no database).
///
/// `index.json` holds one `ChatSessionSummary` per conversation — the only
/// per-chat state that stays resident. Each transcript lives in its own
/// `<id>.json`, read on demand (see `loadSession(id:)`) and written by
/// `save(_:)`.
///
/// The directory is chosen by the session store to match the scope:
/// project `<root>/.typstedit/chat/sessions/`, notebook
/// `~/Library/Application Support/TypstEdit/ChatHistory/<hash>/sessions/`.
struct ChatHistoryStore {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    private func sessionURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private var indexURL: URL {
        directory.appendingPathComponent("index.json")
    }

    // MARK: - Session List (metadata only)

    /// The conversation list, newest activity first. Only the index is read;
    /// transcripts are not decoded, let alone kept.
    func loadSummaries() -> [ChatSessionSummary] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let summaries = readIndex() {
            return summaries.sorted { $0.updatedAt > $1.updatedAt }
        }
        if let data = try? Data(contentsOf: indexURL) {
            // An index written by the build before summaries existed: a bare
            // id list. Upgrading it costs one read of each transcript, once.
            if let ids = try? JSONDecoder().decode([UUID].self, from: data) {
                let migrated = ids.compactMap { summary(for: $0) }
                saveSummaries(migrated)
                return migrated.sorted { $0.updatedAt > $1.updatedAt }
            }
        }

        // No usable index (lost, or first launch): rebuild it from the
        // transcript files themselves.
        let scanned = scanSummaries()
        if !scanned.isEmpty || !FileManager.default.fileExists(atPath: indexURL.path) {
            saveSummaries(scanned)
        }
        return scanned
    }

    /// One conversation's metadata, read from its transcript without keeping
    /// the transcript.
    private func summary(for id: UUID) -> ChatSessionSummary? {
        loadSession(id: id).map { ChatSessionSummary(record: $0) }
    }

    /// The index as written, or `nil` when it is missing or not the summary
    /// format. Decoding only — no transcript is touched, so this is the cheap
    /// way for callers (the save path, the enrichment check) to look at the
    /// list.
    private func readIndex() -> [ChatSessionSummary]? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? JSONDecoder().decode([ChatSessionSummary].self, from: data)
    }

    /// Rebuilds the summary list by reading the session folder — the recovery
    /// path when `index.json` is missing or unreadable.
    private func scanSummaries() -> [ChatSessionSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let reserved: Set<String> = ["index", "labels"]
        var summaries: [ChatSessionSummary] = []
        for file in files where file.pathExtension == "json" && !reserved.contains(file.deletingPathExtension().lastPathComponent) {
            if let data = try? Data(contentsOf: file),
               let session = try? JSONDecoder().decode(ChatSession.self, from: data) {
                summaries.append(ChatSessionSummary(record: session))
            }
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func saveSummaries(_ summaries: [ChatSessionSummary]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(summaries) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// Adds or replaces one conversation in the index, leaving the others
    /// untouched. Called on every save, so it must stay cheap: it decodes the
    /// index only, never the transcripts.
    private func updateIndex(with summary: ChatSessionSummary) {
        var summaries = readIndex() ?? loadSummaries()
        summaries.removeAll { $0.id == summary.id }
        summaries.insert(summary, at: 0)
        saveSummaries(summaries)
    }

    // MARK: - Transcripts

    /// Every saved transcript, newest activity first. Only for callers that
    /// genuinely need the message bodies (the History picker's full-text
    /// search); the chat itself reads one transcript at a time with
    /// `loadSession(id:)`.
    func loadSessions() -> [ChatSession] {
        loadSummaries().compactMap { loadSession(id: $0.id) }
    }

    func loadSession(id: UUID) -> ChatSession? {
        guard let data = try? Data(contentsOf: sessionURL(id)) else { return nil }
        return try? JSONDecoder().decode(ChatSession.self, from: data)
    }

    /// Writes one transcript. Returns a description of what went wrong, or
    /// `nil` when it landed.
    ///
    /// It answers rather than throws because it is called from a `didSet` and
    /// from inside a run loop that cannot abort: the turn has already happened,
    /// so the only thing left to do with a failure is to report it. Swallowing
    /// it — the old `try?` — made a full disk, a read-only volume or a revoked
    /// permission look exactly like a saved chat: the panel kept working and
    /// the conversation was gone at the next launch with nothing saying why.
    @discardableResult
    func save(_ session: ChatSession) -> String? {
        var failure: String?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(session)
            try data.write(to: sessionURL(session.id), options: .atomic)
        } catch {
            failure = error.localizedDescription
        }
        // The index still moves on a failed transcript write, deliberately: the
        // session list and History must keep showing what the chat holds, and
        // the error row is what says it is not on disk. Hiding the row too
        // would leave the failure with no trace at all.
        updateIndex(with: ChatSessionSummary(record: session))
        return failure
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: sessionURL(id))
        saveSummaries((readIndex() ?? loadSummaries()).filter { $0.id != id })
    }

    /// Renames a saved conversation without keeping its transcript: read the
    /// file, change the title fields, write it back. The caller (a session
    /// that is not active) never holds the messages. A blank name is
    /// refused rather than written, matching `AIChatManager.renameSession`.
    @discardableResult
    func rename(id: UUID, to rawTitle: String) -> ChatSessionSummary? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var session = loadSession(id: id) else { return nil }
        session.title = title
        session.titleIsAutoGenerated = false
        save(session)
        return ChatSessionSummary(record: session)
    }

    /// Replaces a saved conversation's labels, again without keeping its
    /// transcript. Same shape as `rename`: read the one file, change the one
    /// field, write it back — so tagging a closed chat costs one read, not a
    /// resident transcript. The labels are cleaned by `ChatLabel.normalize`
    /// before they are stored, so a blank one never reaches a file.
    @discardableResult
    func setLabels(_ labels: [String], for id: UUID) -> ChatSessionSummary? {
        guard var session = loadSession(id: id) else { return nil }
        session.labels = ChatLabel.normalize(labels)
        save(session)
        return ChatSessionSummary(record: session)
    }

    // MARK: - Label vocabulary

    private var labelsURL: URL {
        directory.appendingPathComponent("labels.json")
    }

    /// The label suggestions the user has accumulated (seed plus anything
    /// they typed). A missing file returns the seed list, so the first visit
    /// to the label page already has something to click.
    func loadLabels() -> ChatLabelCatalog {
        guard let data = try? Data(contentsOf: labelsURL),
              let catalog = try? JSONDecoder().decode(ChatLabelCatalog.self, from: data) else {
            return ChatLabelCatalog()
        }
        return ChatLabelCatalog(labels: catalog.labels)
    }

    func saveLabels(_ catalog: ChatLabelCatalog) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(catalog) {
            try? data.write(to: labelsURL, options: .atomic)
        }
    }

    /// Full-text search across the saved conversations, reading one
    /// transcript at a time and dropping it before the next. The History
    /// picker keeps its message search without keeping every transcript in
    /// memory; only the metadata list is resident.
    func sessionMatches(
        for query: String,
        in summaries: [ChatSessionSummary]
    ) -> [UUID: ConversationSearch.SessionMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [:] }
        var results: [UUID: ConversationSearch.SessionMatch] = [:]
        for summary in summaries {
            if let session = loadSession(id: summary.id) {
                results.merge(ConversationSearch.sessionMatches(for: needle, in: [session])) { first, _ in first }
            } else if summary.title.localizedCaseInsensitiveContains(needle) {
                results[summary.id] = ConversationSearch.SessionMatch(sessionID: summary.id, snippet: "", hitCount: 0)
            }
        }
        return results
    }
}
