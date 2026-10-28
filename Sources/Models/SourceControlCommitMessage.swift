import Foundation

/// AI commit messages: the sparkles button in the commit box sends the staged
/// diff — or all changes when nothing is staged — to the configured chat
/// model and puts the reply in the message field. Nothing is committed
/// automatically; the message lands in the box for review, like any typed one.
extension SourceControlManager {

    /// Character cap for the diff sent to the model. A commit message needs
    /// shape, not every line; huge diffs are truncated per file boundary
    /// (the status list still names every file).
    static let commitMessageDiffCharLimit = 50_000

    /// Generates a commit message and returns it, or `nil` after setting
    /// `errorMessage`. Reads the staged diff when the index has anything in
    /// it, otherwise every change relative to HEAD (including untracked
    /// files, which a diff can't show).
    func generateCommitMessage() async -> String? {
        guard let root = repositoryRoot else {
            errorMessage = "No repository is open."
            return nil
        }
        guard isGeneratingCommitMessage == false else { return nil }
        isGeneratingCommitMessage = true
        defer { isGeneratingCommitMessage = false }

        do {
            let context = try await Self.commitContext(root: root, runner: runner, charLimit: Self.commitMessageDiffCharLimit)
            guard context != nil else {
                errorMessage = "There are no changes to describe."
                return nil
            }
            let (system, user) = Self.commitMessagePrompt(context: context!)

            let raw = try await AICompletionService.shared.fetchCompletion(
                prompt: user,
                systemPrompt: system,
                maxTokens: 1_024,
                purpose: .chat,
                sanitize: false
            )
            guard let message = Self.cleanedCommitMessage(raw) else {
                errorMessage = "The model returned no commit message. Try again, or pick a different Chat model."
                return nil
            }
            return message
        } catch {
            errorMessage = "Couldn't generate a commit message: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Context gathering

    /// What the model sees: the status list and one diff. `nil` when the
    /// working tree matches HEAD and the index is empty.
    nonisolated static func commitContext(root: URL, runner: GitRunner, charLimit: Int) async throws -> (status: String, diff: String, scope: String)? {
        let base = GitRunner.literalPathArguments
            + ["diff", "--no-color", "--no-ext-diff", "--find-renames"]
        let status = try await runner.run(["status", "--porcelain"], in: root).stdoutString
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Staged first; fall back to everything. `--cached` works on an
        // unborn HEAD (it compares the index to the empty tree).
        let staged = try await runner.run(base + ["--cached"], in: root, acceptedExitCodes: [0, 1]).stdoutString
        if !staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (status, capped(staged, charLimit: charLimit), "staged changes")
        }
        let everything: String
        if try await Self.headExists(root: root, runner: runner) {
            everything = try await runner.run(base + ["HEAD"], in: root).stdoutString
        } else {
            // No commit yet: the diff of everything is the staged diff, which
            // is empty here, so describe the status alone.
            everything = ""
        }
        return (status, capped(everything, charLimit: charLimit), "all changes (nothing is staged)")
    }

    private nonisolated static func capped(_ text: String, charLimit: Int) -> String {
        guard text.count > charLimit else { return text }
        let head = String(text.prefix(charLimit))
        return head + "\n… diff truncated to the first \(charLimit) characters (\(text.count) total). File names are in the status list.\n"
    }

    // MARK: - Prompt

    nonisolated static func commitMessagePrompt(context: (status: String, diff: String, scope: String)) -> (system: String, user: String) {
        let system = """
        You write git commit messages. Reply with only the message, in this shape:
        - One subject line: imperative mood, at most 72 characters, no trailing period, no quotes, no "Commit:" prefix, no markdown fences.
        - Then, only when the change has more than one part, a blank line and 1-4 body lines, each starting with "- ", explaining why or grouping what changed.
        Use the repository's own language for the subject if the changed content or its existing file history clearly shows one; otherwise use English.
        Never invent changes that are not in the status or diff.
        """
        let user: String
        if context.diff.isEmpty {
            user = """
            Nothing is staged and there is no commit yet, so describe the new files from their status and paths.

            git status:
            \(context.status)
            """
        } else {
            user = """
            Write a commit message for the \(context.scope).

            git status:
            \(context.status)

            diff:
            \(context.diff)
            """
        }
        return (system, user)
    }

    // MARK: - Cleanup

    /// Turns a model reply into a safe commit message: fences, markdown
    /// headers, quotes and chatty prefixes are stripped; a hard-wrapped
    /// subject is joined; more than one blank line collapses. `nil` when
    /// nothing usable is left.
    nonisolated static func cleanedCommitMessage(_ raw: String) -> String? {
        var lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        // Drop markdown fences and an LLM-style first/last filler line.
        lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        while let first = lines.first, Self.isFillerLine(first) { lines.removeFirst() }
        // A filler line is often followed by a blank one.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return nil }

        // The subject: the first line, unwrapped (a model that hard-wraps a
        // long subject at ~72 chars gets its lines joined back together).
        var subject = lines.removeFirst()
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'*#"))
        while !lines.isEmpty, !lines[0].trimmingCharacters(in: .whitespaces).isEmpty,
              lines[0].trimmingCharacters(in: .whitespaces).first != "-",
              subject.count < 72 {
            subject += " " + lines.removeFirst().trimmingCharacters(in: .whitespaces)
        }
        // Drop a "Commit message: …" style prefix the model may add.
        if let colon = subject.firstIndex(of: ":") {
            let head = subject[subject.startIndex..<colon].lowercased()
            if head.count <= 40, head.contains("commit") || head.contains("subject") || head.contains("message") {
                subject = String(subject[subject.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !subject.isEmpty else { return nil }

        // Body: keep non-empty lines, collapse repeated blanks.
        var body: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if let last = body.last, last.isEmpty { continue }
                body.append("")
            } else {
                body.append(trimmed)
            }
        }
        while body.first?.isEmpty == true { body.removeFirst() }
        while body.last?.isEmpty == true { body.removeLast() }

        return body.isEmpty ? subject : subject + "\n\n" + body.joined(separator: "\n")
    }

    /// A line that is only chatter before the real subject.
    private nonisolated static func isFillerLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        return lowered.hasPrefix("here is") || lowered.hasPrefix("here's")
            || lowered.hasPrefix("sure,") || lowered.hasPrefix("certainly")
            || lowered.hasPrefix("okay,") || lowered.hasPrefix("the commit message")
    }
}
