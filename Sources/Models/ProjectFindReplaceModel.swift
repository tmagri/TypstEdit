import Foundation
import Combine

/// Search-and-replace across every file of a project.
///
/// The AI chat's `grep_project` is built for one-line lookups the model
/// asks for; this engine is built for the editor's "Find in Project":
/// case/whole-word/regex options, results grouped by file with the match
/// highlighted in its line, per-match or per-file selection, and a
/// **replace** step that rewrites each file with editor semantics.
///
/// Everything heavy runs off the main actor. Both find and replace read
/// each file at most once with `LossyFileReader` — no locks, lossy on a
/// mid-write read — and skip the same generated folders the project tree
/// ignores, plus any file a window shows with unsaved edits (replacing
/// under an editor would be silently undone by its next save).
@MainActor
final class ProjectFindReplaceModel: ObservableObject {
    // MARK: - Options

    struct Options: Equatable {
        var caseSensitive = false
        var wholeWord = false
        var regex = false
        /// Diacritic-insensitive matching (dé == de), like the editor find.
        var ignoreDiacritics = true
        /// Optional filename filter, e.g. `*.typ` or `chapters/**/*.typ`.
        var includeGlob: String?
    }

    // MARK: - Results

    struct Match: Identifiable, Equatable {
        let id: Int
        /// Absolute file URL.
        let url: URL
        /// 1-based line of the match start.
        let line: Int
        /// The full line, without its newline.
        let lineText: String
        /// UTF-16 range of the match within `lineText`.
        let rangeInLine: NSRange
        /// The matched text (differs from the search term for regex).
        let matchedText: String
        /// Whether the replace step should touch this match. Defaults to
        /// true: replace-all is the common case, and deselecting is one
        /// explicit action per match.
        var selectedForReplace = true
    }

    struct FileResult: Identifiable, Equatable {
        let id: Int
        let url: URL
        /// Path relative to the project root, for display.
        let relativePath: String
        var matches: [Match]

        var selectedCount: Int { matches.filter(\.selectedForReplace).count }
        var allSelected: Bool { !matches.isEmpty && matches.allSatisfy(\.selectedForReplace) }
        var noneSelected: Bool { !matches.isEmpty && matches.allSatisfy { !$0.selectedForReplace } }
    }

    @Published private(set) var results: [FileResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isReplacing = false
    /// Bumped on every completed search, so views can react (scroll reset).
    @Published private(set) var searchGeneration = 0
    /// "12 matches in 3 files" for the panel header.
    @Published private(set) var summary: String = ""
    /// Set when the search text is a regex that does not compile.
    @Published private(set) var patternError: String?

    private var searchTask: Task<Void, Never>?
    private var lastQuery: String?
    private var lastOptions: Options?

    init() {}

    deinit {
        searchTask?.cancel()
    }

    // MARK: - Which files are searched

    /// Text files search opens. Mirrors the sidebar/AI-index extension set:
    /// typ/note/markdown, the code grammars, and plain text.
    private nonisolated static let searchableExtensions: Set<String> = {
        var set = Set<String>()
        set.formUnion(EditorFileTypes.typstExtensions)
        set.formUnion(EditorFileTypes.noteExtensions)
        set.formUnion(EditorFileTypes.markdownExtensions)
        set.formUnion(EditorFileTypes.pythonExtensions)
        set.formUnion(EditorFileTypes.plainTextExtensions)
        // Code files, resolved the same way the editor resolves them, so a
        // grammar added in EditorFileTypes is searchable here too.
        for ext in EditorFileTypes.searchableCodeExtensions {
            set.insert(ext)
        }
        return set
    }()

    private nonisolated static let extensionlessTextNames: Set<String> = [
        ".gitignore", ".gitattributes", ".gitmodules", ".editorconfig", ".env",
        ".npmrc", ".prettierrc", ".zshrc", ".zshenv", ".zprofile", ".zlogin",
        ".bashrc", ".bash_profile", ".bash_login", ".profile",
    ]

    nonisolated static func isSearchableText(_ url: URL) -> Bool {
        if extensionlessTextNames.contains(url.lastPathComponent) { return true }
        return searchableExtensions.contains(url.pathExtension.lowercased())
    }

    /// Folders never entered: generated output, backups, the embedding
    /// index itself, and version-control internals. Hidden entries are
    /// already excluded by the enumerator options; `.typstedit` and
    /// `.git` are hidden but listed so the intent stays explicit.
    private nonisolated static let ignoredFolderNames: Set<String> =
        ProjectTreeLoader.ignoredFolderNames.union([".git", ".typstedit", "node_modules", "target", "dist"])

    private nonisolated static let maxFileBytes = 4 * 1024 * 1024
    private nonisolated static let maxFiles = 5000
    private nonisolated static let maxMatches = 2000

    // MARK: - Searching

    /// Searches `root` for `query`. A running search is cancelled first:
    /// typing in the field re-runs this, and a slow stale pass must never
    /// overwrite a newer result.
    func search(query: String, options: Options, root: URL?) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            summary = ""
            patternError = nil
            lastQuery = nil
            return
        }
        guard let root else {
            results = []
            summary = "No project folder is open."
            patternError = nil
            return
        }

        lastQuery = trimmed
        lastOptions = options

        // Compile before touching state: an invalid regex reports, and
        // nothing else changes.
        guard let pattern = ProjectSearchPattern(
            query: trimmed,
            caseSensitive: options.caseSensitive,
            wholeWord: options.wholeWord,
            regex: options.regex,
            ignoreDiacritics: options.ignoreDiacritics
        ) else {
            results = []
            summary = ""
            patternError = "The search text is not a valid regular expression."
            searchGeneration += 1
            return
        }
        patternError = nil

        isSearching = true
        searchGeneration += 1
        results = []
        summary = "Searching…"
        let generation = searchGeneration

        searchTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                await Self.scan(root: root, pattern: pattern, glob: options.includeGlob)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.searchGeneration == generation else { return }
                self.results = outcome.files
                self.summary = outcome.summary
                self.isSearching = false
            }
        }
    }

    /// Re-runs the last search (after a replace, a save, or any project
    /// change the user wants picked up).
    func refresh(root: URL?) {
        guard let query = lastQuery, let options = lastOptions else { return }
        lastQuery = nil // force the search to actually run
        search(query: query, options: options, root: root)
    }

    /// Drops results for files that no longer exist, without a rescan —
    /// the project watcher calls this as files change so the panel never
    /// offers to open or rewrite a deleted file.
    func pruneDeletedFiles() {
        let live = results.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if live.count != results.count {
            results = live
            recountSummary()
        }
    }

    private func recountSummary() {
        let matchCount = results.reduce(0) { $0 + $1.matches.count }
        if matchCount == 0 {
            summary = results.isEmpty ? "No matches" : "No matches"
        } else {
            summary = "\(matchCount) match\(matchCount == 1 ? "" : "es") in \(results.count) file\(results.count == 1 ? "" : "s")"
        }
    }

    // MARK: - The scan (off the main actor)

    private struct ScanOutcome {
        var files: [FileResult]
        var summary: String
    }

    private nonisolated static func scan(root: URL, pattern: ProjectSearchPattern, glob: String?) async -> ScanOutcome {
        let rootCanonical = ProjectTreeLoader.canonical(root)
        let globRegex = glob.flatMap { LocalToolExecutor.globToRegex($0) }
        let files = collectFiles(root: rootCanonical, globRegex: globRegex)

        // Files some window shows with unsaved edits: their disk bytes are
        // stale, so matches against them would be wrong the moment they are
        // opened (and replace would silently lose the edits).
        let dirty = await MainActor.run { OpenDocumentRegistry.shared.dirtyFiles }

        var collected: [FileResult] = []
        var totalMatches = 0
        var skippedDirty = 0
        var nextMatchID = 0
        var nextFileID = 0

        for file in files {
            guard totalMatches < maxMatches else { break }
            if dirty.contains(file.url.resolvingSymlinksInPath().standardizedFileURL) {
                skippedDirty += 1
                continue
            }
            guard let reading = LossyFileReader.read(file.url, maxBytes: maxFileBytes) else { continue }
            let decoded = TextFileEncoding.decode(reading.data)
            // Diacritic-insensitive matching runs over a folded copy whose
            // ranges map back onto the original text; when folding changes
            // the length (decomposed input), ranges would not map and the
            // file is skipped rather than misreported.
            let matchText: String
            if pattern.foldsText {
                guard let folded = pattern.foldedText(decoded.text) else { continue }
                matchText = folded as String
            } else {
                matchText = decoded.text
            }
            let nsText = matchText as NSString
            // The original (unfolded) text: its UTF-16 length equals the
            // folded copy's, so match ranges and line numbers map 1:1.
            // Displayed text (line and match) comes from the original, so
            // the user sees the file as it is on disk.
            let originalText = decoded.text as NSString
            let useOriginal = pattern.foldsText

            var matches: [Match] = []
            for result in pattern.matches(in: matchText) {
                let range = result.range
                guard range.length > 0 || pattern.isRegex else { continue }
                guard let (line, lineText, rangeInLine) = lineContext(nsText, range: range) else { continue }

                let displayLineText: String
                if useOriginal, let originalRange = lineRange(ofLine: line, in: originalText) {
                    displayLineText = originalText.substring(with: originalRange)
                } else {
                    displayLineText = lineText
                }

                matches.append(Match(
                    id: nextMatchID,
                    url: file.url,
                    line: line,
                    lineText: displayLineText,
                    rangeInLine: rangeInLine,
                    matchedText: originalText.substring(with: range)
                ))
                nextMatchID += 1
                if totalMatches + matches.count >= maxMatches { break }
            }
            if !matches.isEmpty {
                collected.append(FileResult(
                    id: nextFileID,
                    url: file.url,
                    relativePath: file.relative,
                    matches: matches
                ))
                nextFileID += 1
                totalMatches += matches.count
            }
        }

        var summary: String
        if totalMatches == 0 {
            summary = skippedDirty > 0 ? "No matches (files with unsaved editor edits were skipped)" : "No matches"
        } else {
            summary = "\(totalMatches) match\(totalMatches == 1 ? "" : "es") in \(collected.count) file\(collected.count == 1 ? "" : "s")"
            if totalMatches >= maxMatches { summary += " · stopped at \(maxMatches)" }
            if skippedDirty > 0 { summary += " · \(skippedDirty) file\(skippedDirty == 1 ? "" : "s") with unsaved edits skipped" }
        }
        return ScanOutcome(files: collected, summary: summary)
    }

    /// The 1-based line number, the line's text without its newline, and
    /// the match's UTF-16 range within that line.
    /// Synchronous directory walk. `NSEnumerator` iteration cannot run in an
    /// async function, so this runs inside the detached scan task.
    private nonisolated static func collectFiles(root: URL, globRegex: NSRegularExpression?) -> [(url: URL, relative: String)] {
        var files: [(url: URL, relative: String)] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return files }

        for case let url as URL in enumerator {
            if files.count >= maxFiles { break }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                let name = url.lastPathComponent
                if ignoredFolderNames.contains(name) || name.hasPrefix(".") {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard isSearchableText(url),
                  (values?.fileSize ?? 0) <= maxFileBytes else { continue }
            let relative = RAGManager.relativePath(of: url, in: root)
            if let globRegex, firstMatch(of: globRegex, in: relative) == nil { continue }
            files.append((url, relative))
        }
        return files
    }

    /// The full line range (including its newline) of 1-based `line`, the
    /// way `lineContext` counts lines.
    private nonisolated static func lineRange(ofLine line: Int, in nsText: NSString) -> NSRange? {
        guard line >= 1 else { return nil }
        var index = 0
        var current = 1
        while index < nsText.length {
            let range = nsText.lineRange(for: NSRange(location: index, length: 0))
            if current == line { return range }
            current += 1
            index = NSMaxRange(range)
        }
        return nil
    }

    private nonisolated static func lineContext(_ nsText: NSString, range: NSRange) -> (line: Int, lineText: String, rangeInLine: NSRange)? {
        guard range.location != NSNotFound,
              range.location + range.length <= nsText.length else { return nil }
        let caretRange = NSRange(location: range.location, length: 0)
        let fullLineRange = nsText.lineRange(for: caretRange)
        var lineText = nsText.substring(with: fullLineRange)
        if lineText.hasSuffix("\r\n") { lineText.removeLast(2) }
        else if lineText.hasSuffix("\n") || lineText.hasSuffix("\r") { lineText.removeLast() }
        let line = lineNumber(of: range.location, in: nsText)
        let rangeInLine = NSRange(
            location: range.location - fullLineRange.location,
            length: range.length
        )
        return (line, lineText, rangeInLine)
    }

    /// 1-based line number of a UTF-16 offset, like the editor counts them.
    private nonisolated static func lineNumber(of location: Int, in nsText: NSString) -> Int {
        var line = 1
        var index = 0
        while index < location {
            if nsText.character(at: index) == 0x0A { line += 1 }
            index += 1
        }
        return line
    }

    private nonisolated static func firstMatch(of regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))
    }

    // MARK: - Selection

    func setSelected(_ selected: Bool, matchID: Int) {
        update { match in
            guard match.id == matchID else { return match }
            var updated = match
            updated.selectedForReplace = selected
            return updated
        }
    }

    func setSelectedForFile(_ selected: Bool, fileID: Int) {
        update(fileID: fileID) { match in
            var updated = match
            updated.selectedForReplace = selected
            return updated
        }
    }

    func selectAll(_ selected: Bool) {
        update { match in
            var updated = match
            updated.selectedForReplace = selected
            return updated
        }
    }

    private func update(_ transform: (Match) -> Match) {
        results = results.map { file in
            var file = file
            file.matches = file.matches.map(transform)
            return file
        }
    }

    private func update(fileID: Int, _ transform: (Match) -> Match) {
        results = results.map { file in
            guard file.id == fileID else { return file }
            var file = file
            file.matches = file.matches.map(transform)
            return file
        }
    }

    var selectedMatchCount: Int {
        results.reduce(0) { $0 + $1.selectedCount }
    }

    // MARK: - Replacing

    struct ReplaceOutcome: Equatable {
        var filesChanged: Int
        var replacements: Int
        /// Relative paths of files skipped because a window shows them with
        /// unsaved edits (replacing would be silently undone by its save).
        var skippedDirty: [String]
        /// Relative paths of files whose content changed since the scan.
        var skippedChanged: [String]
        /// Relative paths of files that could not be written.
        var failed: [String]

        static let empty = ReplaceOutcome(filesChanged: 0, replacements: 0, skippedDirty: [], skippedChanged: [], failed: [])

        /// True when every selected match was replaced and nothing was
        /// skipped or failed.
        var complete: Bool {
            skippedDirty.isEmpty && skippedChanged.isEmpty && failed.isEmpty
        }

        var message: String {
            var parts = ["\(replacements) replacement\(replacements == 1 ? "" : "s") in \(filesChanged) file\(filesChanged == 1 ? "" : "s")"]
            if !skippedDirty.isEmpty {
                parts.append("skipped \(skippedDirty.count) file\(skippedDirty.count == 1 ? "" : "s") with unsaved editor edits")
            }
            if !skippedChanged.isEmpty {
                parts.append("\(skippedChanged.count) changed since the search")
            }
            if !failed.isEmpty {
                parts.append("could not write \(failed.count)")
            }
            return parts.joined(separator: ", ")
        }
    }

    /// Replaces every selected match. Matches are re-located in the current
    /// file content before anything is written: a file that changed since
    /// the scan (line numbers moved, the match text gone) is skipped whole
    /// rather than spliced with stale ranges.
    ///
    /// Returns the outcome so the caller can refresh and report. After a
    /// replace, call `refresh(root:)` to re-scan what is now on disk.
    func replace(with template: String, root: URL?) async -> ReplaceOutcome {
        // Selected matches per file, in scan order.
        var selections: [(url: URL, relative: String, matches: [Match])] = []
        for file in results {
            let selected = file.matches.filter(\.selectedForReplace)
            if !selected.isEmpty { selections.append((file.url, file.relativePath, selected)) }
        }
        guard !selections.isEmpty else { return .empty }

        guard let query = lastQuery, let options = lastOptions,
              let pattern = ProjectSearchPattern(
                  query: query, caseSensitive: options.caseSensitive,
                  wholeWord: options.wholeWord, regex: options.regex,
                  ignoreDiacritics: options.ignoreDiacritics
              ) else { return .empty }

        isReplacing = true
        defer { isReplacing = false }

        return await Task.detached(priority: .userInitiated) { () -> ReplaceOutcome in
            let dirty = await MainActor.run { OpenDocumentRegistry.shared.dirtyFiles }
            var filesChanged = 0
            var replacements = 0
            var skippedDirty: [String] = []
            var skippedChanged: [String] = []
            var failed: [String] = []

            for entry in selections {
                if dirty.contains(entry.url.resolvingSymlinksInPath().standardizedFileURL) {
                    skippedDirty.append(entry.relative)
                    continue
                }
                guard let reading = LossyFileReader.read(entry.url, maxBytes: Self.maxFileBytes),
                      !reading.truncated else {
                    failed.append(entry.relative)
                    continue
                }
                let decoded = TextFileEncoding.decode(reading.data)
                let text = decoded.text
                let nsText = text as NSString

                // Diacritic-insensitive matching locates matches in a folded
                // copy whose ranges map 1:1 onto the original (lengths are
                // equal — files whose folding changes length were skipped
                // at scan time and cannot appear in the results).
                let locateText: NSString
                if pattern.foldsText {
                    guard let folded = pattern.foldedText(text) else {
                        skippedChanged.append(entry.relative)
                        continue
                    }
                    locateText = folded
                } else {
                    locateText = nsText
                }

                // Re-locate each selected match in the current text: same
                // matched text on the same line. Anything that cannot be
                // located marks the file changed; it is skipped whole.
                // With diacritic-insensitive matching the locate text is a
                // folded copy, so the stored (original) matched text is
                // compared after folding.
                var ranges: [NSRange] = []
                var locatedAll = true
                for match in entry.matches {
                    let expected = pattern.foldsText
                        ? match.matchedText.folding(options: [.diacriticInsensitive], locale: nil)
                        : match.matchedText
                    guard let range = Self.locate(match, expecting: expected, in: locateText) else {
                        locatedAll = false
                        break
                    }
                    ranges.append(range)
                }
                if !locatedAll {
                    skippedChanged.append(entry.relative)
                    continue
                }

                let mutable = NSMutableString(string: text)
                // From the end backwards, so earlier ranges stay valid.
                for index in entry.matches.indices.reversed() {
                    let replacement = pattern.replacementText(
                        template: template,
                        matchedText: locateText.substring(with: ranges[index]),
                        in: text
                    )
                    mutable.replaceCharacters(in: ranges[index], with: replacement)
                }
                replacements += entry.matches.count

                do {
                    try (mutable as String).write(to: entry.url, atomically: false, encoding: .utf8)
                    filesChanged += 1
                } catch {
                    failed.append(entry.relative)
                }
            }
            return ReplaceOutcome(
                filesChanged: filesChanged, replacements: replacements,
                skippedDirty: skippedDirty, skippedChanged: skippedChanged, failed: failed
            )
        }.value
    }

    /// Where a match with `matchedText == expected` sits in the current
    /// text: the same expected text on the same (1-based) line, or nil when
    /// the file moved too much to say.
    private nonisolated static func locate(
        _ match: Match, expecting expected: String, in nsText: NSString
    ) -> NSRange? {
        guard match.line >= 1 else { return nil }
        // Walk to the start of the match's line, the same way the editor
        // resolves a line number.
        var index = 0
        var line = 1
        while index < nsText.length, line < match.line {
            if nsText.character(at: index) == 0x0A { line += 1 }
            index += 1
        }
        guard line == match.line else { return nil }
        let lineStart = index
        let candidate = NSRange(
            location: lineStart + match.rangeInLine.location,
            length: match.rangeInLine.length
        )
        guard candidate.location >= 0,
              candidate.location + candidate.length <= nsText.length,
              nsText.substring(with: candidate) == expected else { return nil }
        return candidate
    }
}
