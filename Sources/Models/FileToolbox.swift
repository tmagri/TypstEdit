import Foundation
import CryptoKit

/// The `file__*` tools: a read-only "grep+" for files anywhere on the Mac.
///
/// Built from the chat-history evidence (2,937 hand-coded shell/python
/// snippets across 15 saved chats): the agent's most-repeated jobs were
/// shell-grep pipelines with flags the built-in `reference__grep` could not
/// express (regex, context lines, counts, invert — ~790 uses), paging files
/// outside the reference folder (`sed -n` / `head` / `tail` — 480+), finding
/// files by property (`find -name/-mtime/-size`, `ls -lat` — 122), and
/// binary work (hexdumps, byte-pattern search, endian-aware reads,
/// `zlib.crc32` — 260+ across the ROM-hacking projects).
///
/// Everything here is read-only. No tool in this file writes, runs, or
/// raises an approval prompt, so all of them are safe for the concurrent
/// read batch, the read-only subagent, and Plan mode.
///
/// All the pure logic is `nonisolated` static so the concurrent batch can
/// run it off the main actor, the same seam `ReferenceFolderManager` uses.
enum FileToolbox {

    // MARK: - Limits

    /// Most matches one search returns. Same value as `reference__grep`, for
    /// the same reason: a search that silently stops tells the model "it is
    /// not there".
    static let searchMatchLimit = 200

    /// Most bytes of one file a search reads. Bigger files are counted and
    /// reported, never silently skipped.
    static let searchMaxFileBytes = 8_000_000

    /// Most files one `file__find` walk visits. A walk that stops says so.
    static let findMaxFiles = 500

    /// Most bytes one `file__hex` dump reads per call.
    static let hexDumpMaxBytes = 16_384

    /// Most byte-pattern hits one `file__hex` find reports.
    static let hexFindLimit = 200

    /// Largest file `file__hash` will read whole.
    static let hashMaxFileBytes = 256_000_000

    /// How long one `file__find` or `file__search` walk may run before it is
    /// abandoned.
    ///
    /// A walk that is merely slow (a big local tree) finishes well inside
    /// this; the cap exists for the case that is not slow but *stuck* — a
    /// network share whose server stopped answering cannot be interrupted
    /// from inside the kernel call, so the only way to keep the turn alive is
    /// to stop waiting. Chosen at 60 s so a legitimate walk over a large
    /// project is never cut short, while a dead share costs one minute
    /// instead of the 739 s that froze the app.
    static let walkTimeoutSeconds: Double = 60

    // MARK: - Path handling

    /// Expands `~`, resolves to a real absolute path, or `nil` when the
    /// string is empty. No containment jail: the whole point is paths outside
    /// the reference folder — which is why the setting gates these tools, and
    /// why every one of them is read-only.
    ///
    /// `relativeTo` is what a *relative* path means, and it is required
    /// (there is no default) because getting it wrong is how the app hung:
    /// `URL(fileURLWithPath: ".")` resolves against the process's current
    /// directory, which for a GUI app launched by launchd is `/`. A model
    /// asking `file__find` for `"root": "."` meant "the folder I am working
    /// in", the answer was the filesystem root, and the walk descended from
    /// there into an SMB share that had stopped answering — 739 seconds of a
    /// frozen main thread (incident `96C6CD0E…`).
    ///
    /// A tool's relative path therefore always means "relative to the chat's
    /// reference folder", never "relative to whatever directory this process
    /// happens to have".
    nonisolated static func resolvePath(_ requested: String, relativeTo base: String) -> String? {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // `~` and an absolute path stand on their own; only a genuinely
        // relative one is joined to the base.
        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
                .standardizedFileURL.path
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(trimmed)
            .standardizedFileURL.path
    }

    // MARK: - Shared search core

    /// How a search reports its hits.
    enum SearchMode: String {
        /// `path:line: text` per hit (the shape `reference__grep` always had).
        case match
        /// `path: N` per file — grep `-l` with counts, so a model can pick
        /// which file to read without a second call.
        case count
        /// Just the paths that matched — grep `-l`.
        case filenames
        /// Only the matched text, one per line — grep `-o` (and the input half
        /// of the `sort | uniq -c` idiom; `frequency` finishes it).
        case matchesOnly
        /// `count value` lines, descending — the `grep -o | sort | uniq -c |
        /// sort -rn` pipeline the histories used ~14 times explicitly and
        /// dozens of times as variants.
        case frequency
    }

    /// The compile-time-validated search parameters — one struct so the
    /// sequential call and the concurrent batch share one search core and
    /// cannot drift apart (the lesson `renderListFiles` learned).
    struct SearchSpec: Sendable {
        var root: String
        var pattern: String
        var regex: Bool
        var caseSensitive: Bool
        var mode: SearchMode
        /// Lines of context around a hit (-A/-B/-C in one knob).
        var contextLines: Int
        var invert: Bool
        var glob: String?
        var limit: Int
    }

    /// Compiles a search pattern or throws with a message naming the pattern,
    /// so a cheap model's bad regex fails with something it can fix.
    nonisolated static func compileRegex(
        pattern: String, regex: Bool, caseSensitive: Bool
    ) throws -> NSRegularExpression {
        guard !pattern.isEmpty else {
            throw LocalToolError.invalidArguments("pattern is required")
        }
        let compiled: NSRegularExpression?
        if regex {
            compiled = try? NSRegularExpression(
                pattern: pattern,
                options: caseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive]
            )
        } else {
            compiled = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: pattern),
                options: caseSensitive ? [] : [.caseInsensitive]
            )
        }
        guard let compiled else {
            throw LocalToolError.invalidArguments(
                "Invalid regular expression: \"\(pattern)\". Retry with a simpler pattern, or with regex: false to search for it literally."
            )
        }
        return compiled
    }

    /// The files a search visits. A file `path` that names a single file
    /// searches only it; a folder is walked (bounded, like the reference
    /// walk); a missing path is an error naming the way out.
    nonisolated static func searchTargets(
        root: String, glob: String?, allowNetworkVolumes: Bool = false
    ) throws -> (paths: [String], truncated: Bool, depthLimited: Bool, skippedNetwork: Bool) {
        // Before the existence test: `fileExists` on a dead share blocks.
        if let refusal = FileSystemBounds.networkRefusal(
            for: root, allowNetworkVolumes: allowNetworkVolumes
        ) {
            throw LocalToolError.invalidArguments(refusal)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else {
            throw LocalToolError.invalidArguments(
                "Path not found: \(root). Call file__find to locate it instead of guessing."
            )
        }
        if !isDirectory.boolValue {
            return ([root], false, false, false)
        }

        var collected: [String] = []
        var truncated = false
        var depthLimited = false
        var skippedNetwork = false
        walkFiles(root: root, dir: root, depth: 0, glob: glob,
                  allowNetworkVolumes: allowNetworkVolumes,
                  into: &collected, truncated: &truncated,
                  depthLimited: &depthLimited, skippedNetwork: &skippedNetwork)
        return (collected, truncated, depthLimited, skippedNetwork)
    }

    private nonisolated static func walkFiles(
        root: String, dir: String, depth: Int, glob: String?,
        allowNetworkVolumes: Bool,
        into collected: inout [String], truncated: inout Bool,
        depthLimited: inout Bool, skippedNetwork: inout Bool
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        if depth > ReferenceFolderManager.maxDepth {
            if !entries.isEmpty { depthLimited = true }
            return
        }
        for entry in entries.sorted() {
            if collected.count >= findMaxFiles {
                truncated = true
                return
            }
            // Dotfiles stay visible for arbitrary-path search: a config file
            // (`.env`, `.gitignore`) is exactly what a search outside the
            // reference folder is usually after. The reference-folder walk
            // hides them; this one must not, or the histories' own patterns
            // would fail here.
            let path = (dir as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if entry == "node_modules" { continue }
                if !allowNetworkVolumes,
                   let mount = FileSystemBounds.mount(for: path),
                   mount.isRemote {
                    skippedNetwork = true
                    continue
                }
                walkFiles(root: root, dir: path, depth: depth + 1, glob: glob,
                          allowNetworkVolumes: allowNetworkVolumes,
                          into: &collected, truncated: &truncated,
                          depthLimited: &depthLimited, skippedNetwork: &skippedNetwork)
                continue
            }
            if let glob,
               !globMatches(
                   glob,
                   relativePath: relativePath(path, from: root),
                   fileName: entry
               ) { continue }
            collected.append(path)
        }
    }

    /// Case-insensitive glob: `*.swift`, `bank??.asm`, `Makefile` all work,
    /// and so does a path glob (`data/trace_wram/*`) — see `globMatches`.
    /// Implemented by translating to a regex, which covers `*`, `?`, and
    /// character classes.
    nonisolated static func globMatch(_ glob: String, fileName: String) -> Bool {
        var pattern = "^"
        for character in glob {
            switch character {
            case "*": pattern += "[^/]*"
            case "?": pattern += "."
            default:
                pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        pattern += "$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return fileName.lowercased() == glob.lowercased()
        }
        return regex.firstMatch(
            in: fileName, range: NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
        ) != nil
    }

    /// Whether a walk's glob accepts a file, given its path relative to the
    /// walk's root.
    ///
    /// A glob with no slash is a **name** pattern (`*.asm`, `Makefile`), which
    /// is what `find -name` means. A glob that contains a slash is a **path**
    /// pattern (`data/trace_wram/*`), which is what `find -path` means. Both
    /// are reasonable things for a model to write, and matching only the name
    /// made the second silently return nothing — observed in the chat that
    /// hung: the model asked `file__find` for `"name_glob":
    /// "data/trace_wram/*"`, got an empty answer with no hint that the glob
    /// was the problem, and retried `file__find` 75 times.
    ///
    /// `globMatch` already treats `*` as `[^/]*`, so a path pattern is matched
    /// correctly by handing it the relative path.
    nonisolated static func globMatches(
        _ glob: String, relativePath: String, fileName: String
    ) -> Bool {
        if glob.contains("/") {
            let normalised = relativePath.hasPrefix("/")
                ? String(relativePath.dropFirst())
                : relativePath
            // A leading `*/` or `**/` is common in hand-written patterns; try
            // the path as written first, then without a leading wildcard
            // segment, so both spellings work.
            if globMatch(glob, fileName: normalised) { return true }
            if glob.hasPrefix("*/") {
                return globMatch(String(glob.dropFirst(2)), fileName: normalised)
            }
            return false
        }
        return globMatch(glob, fileName: fileName)
    }

    /// The path of `path` relative to `root`, without a leading slash.
    nonisolated static func relativePath(_ path: String, from root: String) -> String {
        let base = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(base) else { return path }
        return String(path.dropFirst(base.count))
    }

    /// The one search implementation. Used by `file__search`, by the
    /// concurrent batch, and by `reference__grep`'s new options, so a search
    /// through either door answers identically.
    nonisolated static func search(
        _ spec: SearchSpec, allowNetworkVolumes: Bool = false
    ) throws -> String {
        let regex = try compileRegex(
            pattern: spec.pattern, regex: spec.regex, caseSensitive: spec.caseSensitive
        )
        let (paths, truncated, depthLimited, skippedNetwork) = try searchTargets(
            root: spec.root, glob: spec.glob, allowNetworkVolumes: allowNetworkVolumes
        )

        var matchLines: [String] = []
        var perFileCounts: [String: Int] = [:]
        var matchedValues: [String: Int] = [:]   // frequency mode
        var matchOnly: [String] = []
        var skippedLarge = 0
        var searchedFiles = 0
        var totalMatches = 0

        for path in paths {
            guard totalMatches < spec.limit, matchLines.count < spec.limit else { break }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? Int else { continue }
            guard size <= searchMaxFileBytes else {
                skippedLarge += 1
                continue
            }
            guard let data = FileManager.default.contents(atPath: path),
                  let text = ReferenceFolderManager.decodeText(data) else { continue }
            searchedFiles += 1
            let label = displayPath(path, relativeTo: spec.root)

            let lines = text.components(separatedBy: "\n")
            var hitsInFile = 0
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                let hits = regex.matches(in: line, options: [], range: range)
                let lineMatches = !hits.isEmpty
                let keep = spec.invert ? !lineMatches : lineMatches
                guard keep, hitsInFile < spec.limit, matchLines.count < spec.limit else { continue }

                hitsInFile += 1
                totalMatches += 1
                switch spec.mode {
                case .match:
                    if spec.contextLines > 0 {
                        let start = max(0, index - spec.contextLines)
                        let end = min(lines.count - 1, index + spec.contextLines)
                        for offset in start...end where offset != index {
                            matchLines.append("\(label):\(offset + 1): \(preview(lines[offset]))")
                        }
                        matchLines.append("\(label):\(index + 1): \(preview(line))")
                    } else {
                        matchLines.append("\(label):\(index + 1): \(preview(line))")
                    }
                case .count:
                    perFileCounts[label] = (perFileCounts[label] ?? 0) + 1
                case .filenames:
                    perFileCounts[label] = 1
                case .matchesOnly:
                    for hit in hits {
                        if let range = Range(hit.range, in: line) {
                            matchOnly.append(String(line[range]))
                        }
                    }
                case .frequency:
                    for hit in hits {
                        if let range = Range(hit.range, in: line) {
                            matchedValues[String(line[range]), default: 0] += 1
                        }
                    }
                }
            }
        }

        // Assemble per mode.
        var result: [String] = []
        switch spec.mode {
        case .match:
            result = matchLines
        case .count:
            result = perFileCounts
                .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .map { "\($0.key): \($0.value)" }
        case .filenames:
            result = perFileCounts.keys.sorted().map { $0 }
        case .matchesOnly:
            result = matchOnly.prefix(spec.limit).map { $0 }
        case .frequency:
            result = matchedValues
                .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .map { "\($0.value)  \($0.key)" }
        }

        var notes: [String] = []
        if truncated {
            notes.append("the walk stopped at \(findMaxFiles) files — more exist; narrow the root or glob")
        }
        if depthLimited {
            notes.append("folders deeper than \(ReferenceFolderManager.maxDepth) levels were not searched")
        }
        if skippedLarge > 0 {
            notes.append("\(skippedLarge) file\(skippedLarge == 1 ? " is" : "s are") larger than \(searchMaxFileBytes) bytes and not read")
        }
        if skippedNetwork {
            notes.append("a network volume inside this path was not searched, so this answer is partial")
        }

        guard !result.isEmpty else {
            // REA's one transferable discipline for negative results:
            // "No matches" must never read as "not there" unless the tool
            // says what it searched. A quantified negative answer is
            // self-certifying — the model can tell "absent" from "didn't
            // look" without a second call.
            var empty = "No matches for \"\(spec.pattern)\" in \(spec.root) — searched \(searchedFiles) file\(searchedFiles == 1 ? "" : "s")."
            if !notes.isEmpty { empty += "\n(Note: \(notes.joined(separator: "; ")).)" }
            return empty
        }
        var text = result.joined(separator: "\n")
        if totalMatches >= spec.limit && (spec.mode == .match || spec.mode == .matchesOnly) {
            text += "\n(Stopped at \(spec.limit) matches — narrow the pattern, add a glob, or search a specific file.)"
        }
        if !notes.isEmpty {
            text += "\n(Note: \(notes.joined(separator: "; ")).)"
        }
        return text
    }

    /// A path label that is readable: relative to the search root when it is
    /// inside it, else absolute.
    nonisolated static func displayPath(_ path: String, relativeTo root: String) -> String {
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        if path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }
        return path
    }

    private nonisolated static func preview(_ line: String) -> String {
        String(line.prefix(300))
    }

    /// Outline read: the declarations-and-headings map `FileOutline` produces.
    ///
    /// This used to be `DocumentOutline.render`, which only knew Markdown and
    /// Typst headings — so `outline: true` on the Swift, Python or `.asm`
    /// files a chat actually reads answered "No headings or #include lines
    /// found". It now goes through the shared `FileOutline.index`, so
    /// `file__read` and `reference__read_file` map a file identically.
    nonisolated static func readOutline(at path: String, label: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path),
              let text = ReferenceFolderManager.decodeText(data) else {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
            return ReferenceFolderManager.binaryNotice(label: label, bytes: bytes)
        }
        let lines = FileOutline.split(text)
        return FileOutline.render(
            index: FileOutline.index(in: text, path: label),
            label: label,
            totalLines: lines.count
        )
    }

    // MARK: - file__find

    /// What one find walk found.
    struct FindResult: Sendable {
        var entries: [String]
        var truncated: Bool
        var depthLimited: Bool
        /// A network volume was reached and not descended, so the answer is
        /// partial and says so. Silence here would read as "not there".
        var skippedNetwork: Bool = false
    }

    /// One line per hit for `file__find` output: `path (size, mtime)`.
    nonisolated static func renderFind(_ result: FindResult) -> String {
        if result.entries.isEmpty {
            var text = result.skippedNetwork
                ? "No files match on this Mac."
                : "No files match."
            if result.truncated {
                text += "\n[The walk stopped at \(findMaxFiles) files before finishing — narrow the root or pattern.]"
            }
            if result.skippedNetwork {
                text += "\n[\(networkSkipNote)]"
            }
            return text
        }
        let lines = result.entries.map { entry -> String in
            let modified = DateFormatter.localizedString(
                from: modificationDate(entry), dateStyle: .short, timeStyle: .short
            )
            return "\(entry) (\(sizeLabel(entry)), modified \(modified))"
        }
        var text = lines.joined(separator: "\n")
        if result.truncated {
            text += "\n[The walk stopped at \(findMaxFiles) files before finishing — more results exist. Narrow the root or pattern, or sort by date to surface the newest.]"
        }
        if result.depthLimited {
            text += "\n[Some folders are deeper than \(ReferenceFolderManager.maxDepth) levels and were not searched.]"
        }
        if result.skippedNetwork {
            text += "\n[\(networkSkipNote)]"
        }
        return text
    }

    /// Said by every tool that stopped at a network volume. One wording, so
    /// `file__find` and `file__search` cannot describe the same gap two ways.
    nonisolated static let networkSkipNote = """
    A network volume inside this path was not searched, so this answer is partial. \
    Turn on "File tools may read network volumes" in Settings → AI Chat → Tools to include it.
    """

    /// Finds files by property: name glob, extension, size range, mtime.
    ///
    /// The histories' own query shapes drove the parameters: "every
    /// dsp4*.rom anywhere under ~" (`find -iname`), "what did the emulator
    /// write since the last run" (`-newer`), "files bigger than 100 MB"
    /// (`-size +100M`), and the `ls -lat` "what changed recently".
    nonisolated static func find(
        root: String,
        nameGlob: String?,
        extension_: String?,
        minSizeBytes: Int?,
        maxSizeBytes: Int?,
        modifiedAfter: Date?,
        modifiedBefore: Date?,
        sortBy: String?,   // "name" | "size" | "modified"
        maxResults: Int?,
        allowNetworkVolumes: Bool = false
    ) throws -> FindResult {
        // Checked before the existence test, because `fileExists` on a dead
        // share is itself a blocking network call.
        if let refusal = FileSystemBounds.networkRefusal(
            for: root, allowNetworkVolumes: allowNetworkVolumes
        ) {
            throw LocalToolError.invalidArguments(refusal)
        }
        guard FileManager.default.fileExists(atPath: root) else {
            throw LocalToolError.invalidArguments(
                "Path not found: \(root). Start from a folder you know exists — ~ (the home folder), or a path from an earlier tool result."
            )
        }

        var collected: [String] = []
        var truncated = false
        var depthLimited = false
        var skippedNetwork = false
        findWalk(
            root: root, dir: root, depth: 0,
            nameGlob: nameGlob, extension_: extension_,
            minSizeBytes: minSizeBytes, maxSizeBytes: maxSizeBytes,
            modifiedAfter: modifiedAfter, modifiedBefore: modifiedBefore,
            allowNetworkVolumes: allowNetworkVolumes,
            into: &collected, truncated: &truncated,
            depthLimited: &depthLimited, skippedNetwork: &skippedNetwork
        )

        // Sorting: mtime descending is the default (the "what changed
        // recently" question), name for a stable inventory.
        let sort = sortBy ?? "modified"
        let byModification: (String) -> Date = { modificationDate($0) }
        switch sort {
        case "name":
            collected.sort()
        case "size":
            let sizes = collected.map { (path: $0, size: sizeOf($0)) }
            collected = sizes.sorted { $0.size > $1.size }.map(\.path)
        default:   // "modified", and anything unrecognized
            collected.sort { byModification($0) > byModification($1) }
        }

        if let maxResults, maxResults > 0, collected.count > maxResults {
            truncated = true
            collected = Array(collected.prefix(maxResults))
        }
        return FindResult(
            entries: collected, truncated: truncated,
            depthLimited: depthLimited, skippedNetwork: skippedNetwork
        )
    }

    private nonisolated static func findWalk(
        root: String, dir: String, depth: Int,
        nameGlob: String?, extension_: String?,
        minSizeBytes: Int?, maxSizeBytes: Int?,
        modifiedAfter: Date?, modifiedBefore: Date?,
        allowNetworkVolumes: Bool,
        into collected: inout [String], truncated: inout Bool,
        depthLimited: inout Bool, skippedNetwork: inout Bool
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        if depth > ReferenceFolderManager.maxDepth {
            if !entries.isEmpty { depthLimited = true }
            return
        }
        for entry in entries.sorted() {
            if collected.count >= findMaxFiles {
                truncated = true
                return
            }
            let path = (dir as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if entry == "node_modules" { continue }
                // A share mounted *inside* the walk (a local folder holding a
                // network mount) is skipped unless the user allowed network
                // volumes: descending into it is the hang this guard exists
                // to prevent, and the answer says the walk was partial.
                if !allowNetworkVolumes,
                   let mount = FileSystemBounds.mount(for: path),
                   mount.isRemote {
                    skippedNetwork = true
                    continue
                }
                findWalk(
                    root: root, dir: path, depth: depth + 1,
                    nameGlob: nameGlob, extension_: extension_,
                    minSizeBytes: minSizeBytes, maxSizeBytes: maxSizeBytes,
                    modifiedAfter: modifiedAfter, modifiedBefore: modifiedBefore,
                    allowNetworkVolumes: allowNetworkVolumes,
                    into: &collected, truncated: &truncated,
                    depthLimited: &depthLimited, skippedNetwork: &skippedNetwork
                )
                continue
            }
            if let nameGlob,
               !globMatches(
                   nameGlob,
                   relativePath: relativePath(path, from: root),
                   fileName: entry
               ) { continue }
            if let extension_ {
                let ext = (entry as NSString).pathExtension.lowercased()
                let wanted = extension_.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                if ext != wanted { continue }
            }
            let size = sizeOf(path)
            if let minSizeBytes, size < minSizeBytes { continue }
            if let maxSizeBytes, size > maxSizeBytes { continue }
            let modified = modificationDate(path)
            if let modifiedAfter, modified < modifiedAfter { continue }
            if let modifiedBefore, modified > modifiedBefore { continue }
            collected.append(path)
        }
    }

    private nonisolated static func sizeOf(_ path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
    }

    private nonisolated static func modificationDate(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
    }

    private nonisolated static func sizeLabel(_ path: String) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeOf(path)), countStyle: .file)
    }

    /// Parses a model-supplied date: ISO 8601 (with or without time) or
    /// "YYYY-MM-DD", or `nil` for unparseable input. A model that writes a
    /// bad date gets a named error, not silence.
    nonisolated static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        let custom = DateFormatter()
        custom.locale = Locale(identifier: "en_US_POSIX")
        custom.timeZone = TimeZone.current
        custom.dateFormat = "yyyy-MM-dd"
        if let date = custom.date(from: trimmed) { return date }
        return nil
    }

    // MARK: - file__hash

    /// The digest set one call returns. CRC32 leads because the ROM-hacking
    /// chats used `zlib.crc32` for every verify against an expected constant,
    /// and it is the one `shasum` cannot give.
    struct HashResult: Sendable {
        var crc32: String
        var md5: String
        var sha1: String
        var sha256: String
        var bytes: Int
    }

    nonisolated static func hashFile(at path: String) throws -> HashResult {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LocalToolError.invalidArguments("Could not read: \(path)")
        }
        guard data.count <= hashMaxFileBytes else {
            throw LocalToolError.invalidArguments(
                "File is \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)) — larger than the \(ByteCountFormatter.string(fromByteCount: Int64(hashMaxFileBytes), countStyle: .file)) limit for hashing. Read the bytes you need with file__hex instead."
            )
        }
        let crc = crc32(data)
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sha1 = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return HashResult(
            crc32: String(format: "%08X", crc),
            md5: md5,
            sha1: sha1,
            sha256: sha256,
            bytes: data.count
        )
    }

    /// CRC-32 (IEEE 802.3, the zlib/zip/png value). Implemented in Swift so
    /// the tool needs no child process and no Python — the histories show
    /// `python3 -c "import zlib;print(hex(zlib.crc32(open('...','rb').read())))"`
    /// as a recurring one-liner this replaces.
    nonisolated static func crc32(_ data: Data) -> UInt32 {
        var table: [UInt32] = []
        if table.isEmpty {
            for i in 0..<256 {
                var c = UInt32(i)
                for _ in 0..<8 {
                    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
                }
                table.append(c)
            }
        }
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    /// Renders a hash result as one compact block the model can quote.
    nonisolated static func renderHash(_ result: HashResult, label: String) -> String {
        """
        [\(label) — \(result.bytes) bytes]
        crc32:  \(result.crc32)
        md5:    \(result.md5)
        sha1:   \(result.sha1)
        sha256: \(result.sha256)
        """
    }

    // MARK: - file__hex

    /// What the model asked `file__hex` to do.
    enum HexMode: String {
        /// xxd-style dump with ASCII column.
        case dump
        /// Byte-pattern search: hex string or integer, in the bases an
        /// analyst would try.
        case find
        /// Read raw integers at an offset (`struct.unpack`).
        case read
        /// Printable runs (`strings`).
        case strings
    }

    /// A `file__hex` call, fully parsed on the main actor into `Sendable`
    /// data — the same object the sequential path executes, so a batched hex
    /// call cannot behave differently from a lone one.
    struct HexSpec: Sendable {
        var mode: HexMode
        var path: String
        var label: String
        var offset: Int
        var length: Int
        var hex: String?
        var value: Int?
        var widthBytes: Int?
        var endian: String
        var count: Int
        var signed: Bool
        var minLength: Int
        var contextBytes: Int
    }

    /// Parses `file__hex` arguments (as the executor received them from JSON)
    /// into a `HexSpec`, applying defaults and validating so failures reach
    /// the model with named messages. Shared by the sequential path and the
    /// concurrent batch, which is why it lives here and not in the executor.
    nonisolated static func parseHexSpec(
        arguments: [String: Any], defaultPath: String? = nil, relativeTo base: String
    ) throws -> HexSpec {
        guard let requested = arguments["path"] as? String ?? defaultPath,
              !requested.isEmpty,
              let resolved = resolvePath(requested, relativeTo: base) else {
            throw LocalToolError.invalidArguments("path is required")
        }
        let mode = (arguments["mode"] as? String).flatMap(HexMode.init(rawValue:)) ?? .dump

        // Offsets may arrive as 0x-hex or decimal.
        func intArgument(_ key: String) -> Int? {
            if let n = arguments[key] as? Int { return n }
            if let s = arguments[key] as? String {
                return Int(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "", options: .caseInsensitive), radix: 16)
                    ?? Int(s)
            }
            return nil
        }

        let endian = (arguments["endian"] as? String) ?? "both"
        guard ["little", "big", "both"].contains(endian.lowercased()) else {
            throw LocalToolError.invalidArguments("endian must be \"little\", \"big\" or \"both\" — got \"\(endian)\".")
        }

        return HexSpec(
            mode: mode,
            path: resolved,
            label: requested,
            offset: intArgument("offset") ?? 0,
            length: intArgument("length") ?? 256,
            hex: arguments["hex"] as? String,
            value: arguments["value"] as? Int,
            widthBytes: intArgument("width_bytes"),
            endian: endian.lowercased(),
            count: intArgument("count") ?? 1,
            signed: (arguments["signed"] as? Int ?? 0) == 1,
            minLength: intArgument("min_length") ?? 4,
            contextBytes: min(intArgument("context_bytes") ?? 8, 32)
        )
    }

    /// Executes a parsed hex call. Both the sequential executor and the
    /// concurrent batch go through here — one implementation, no drift.
    nonisolated static func runHex(_ spec: HexSpec) throws -> String {
        switch spec.mode {
        case .dump:
            return try hexDump(path: spec.path, offset: spec.offset, length: spec.length)
        case .find:
            if spec.endian == "both" {
                // The multi-base search: both spellings of the value get a
                // chance, side by side.
                let little = try parseBytePattern(hex: spec.hex, value: spec.value, widthBytes: spec.widthBytes, endian: "little")
                let big = try parseBytePattern(hex: spec.hex, value: spec.value, widthBytes: spec.widthBytes, endian: "big")
                if little == big {
                    return try hexFind(path: spec.path, pattern: little, contextBytes: spec.contextBytes, limit: hexFindLimit)
                }
                var out: [String] = []
                out.append("[little-endian spelling]")
                out.append(try hexFind(path: spec.path, pattern: little, contextBytes: spec.contextBytes, limit: hexFindLimit))
                out.append("[big-endian spelling]")
                out.append(try hexFind(path: spec.path, pattern: big, contextBytes: spec.contextBytes, limit: hexFindLimit))
                return out.joined(separator: "\n")
            }
            let pattern = try parseBytePattern(hex: spec.hex, value: spec.value, widthBytes: spec.widthBytes, endian: spec.endian)
            return try hexFind(path: spec.path, pattern: pattern, contextBytes: spec.contextBytes, limit: hexFindLimit)
        case .read:
            let width = spec.widthBytes ?? 0
            guard width == 1 || width == 2 || width == 4 || width == 8 else {
                throw LocalToolError.invalidArguments("width_bytes is required for read mode: 1, 2, 4 or 8.")
            }
            return try hexRead(
                path: spec.path,
                offset: spec.offset,
                count: spec.count,
                widthBytes: width,
                signed: spec.signed,
                bigEndian: spec.endian == "big"
            )
        case .strings:
            return try extractStrings(path: spec.path, minLength: spec.minLength, limit: searchMatchLimit)
        }
    }

    /// A byte pattern, as the model spelled it.
    struct BytePattern: Sendable {
        var bytes: [UInt8]
    }

    /// Parses a byte pattern: hex bytes (`"A4 03"` / `"A403"`), or an integer
    /// with width and endianness ("find the value $A403 as a 16-bit
    /// little-endian word").
    nonisolated static func parseBytePattern(
        hex: String?, value: Int?, widthBytes: Int?, endian: String?
    ) throws -> [UInt8] {
        if let hex, !hex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleaned = hex
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "\n", with: "")
            guard !cleaned.isEmpty else {
                throw LocalToolError.invalidArguments("hex pattern is required")
            }
            // Odd-length hex: refuse rather than guess the missing nibble.
            guard cleaned.count.isMultiple(of: 2) else {
                throw LocalToolError.invalidArguments(
                    "Hex pattern must have an even number of digits (a whole byte count): got \"\(hex)\"."
                )
            }
            var bytes: [UInt8] = []
            var index = cleaned.startIndex
            while index < cleaned.endIndex {
                let next = cleaned.index(index, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
                guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
                    throw LocalToolError.invalidArguments("Invalid hex byte in pattern: \"\(hex)\".")
                }
                bytes.append(byte)
                index = next
            }
            return bytes
        }
        if let value {
            let width = widthBytes ?? 0
            let chosen: Int
            if width > 0 {
                chosen = width
            } else {
                // Infer the narrowest width that holds the value, matching
                // how an analyst would think: 0x1F → 1 byte, 0xA403 → 2,
                // 0x12345678 → 4.
                chosen = value <= 0xFF ? 1 : (value <= 0xFFFF ? 2 : 4)
            }
            guard chosen == 1 || chosen == 2 || chosen == 4 || chosen == 8 else {
                throw LocalToolError.invalidArguments(
                    "width_bytes must be 1, 2, 4 or 8 (got \(chosen))."
                )
            }
            let lowered = (endian ?? "little").lowercased()
            var bytes = [UInt8](repeating: 0, count: chosen)
            var v = UInt64(truncatingIfNeeded: value)
            for i in 0..<chosen {
                bytes[i] = UInt8(truncatingIfNeeded: v)
                v >>= 8
            }
            if lowered == "big" {
                bytes.reverse()
            } else if lowered != "little" {
                throw LocalToolError.invalidArguments(
                    "endian must be \"little\", \"big\" or \"both\" — got \"\(endian ?? "")\"."
                )
            }
            return bytes
        }
        throw LocalToolError.invalidArguments(
            "Pass hex (a hex byte pattern) or value (an integer to search for in the given width and endianness)."
        )
    }

    /// Searches a file for a byte pattern, reporting every offset with a
    /// hex+ASCII context block — the "where is this word referenced" search
    /// the recomp chat hand-wrote with `re.finditer` dozens of times.
    nonisolated static func hexFind(
        path: String, pattern: [UInt8], contextBytes: Int, limit: Int
    ) throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LocalToolError.invalidArguments("Could not read: \(path)")
        }
        let bytes = [UInt8](data)
        guard !pattern.isEmpty, pattern.count <= bytes.count else {
            return "Pattern longer than the file — no matches."
        }

        var offsets: [Int] = []
        let window = pattern.count
        var i = 0
        while i + window <= bytes.count, offsets.count < limit {
            if bytes[i] == pattern.first, matchBytes(bytes, at: i, pattern) {
                offsets.append(i)
                i += window
            } else {
                i += 1
            }
        }
        guard !offsets.isEmpty else {
            return "No matches for \(pattern.map { String(format: "%02X", $0) }.joined(separator: " ")) in \(path)."
        }

        var out = ["[\(offsets.count) match\(offsets.count == 1 ? "" : "es") in \(path)]"]
        for offset in offsets {
            let start = max(0, offset - contextBytes)
            let end = min(bytes.count, offset + window + contextBytes)
            out.append(hexBlock(bytes, from: start, to: end, highlight: (offset, window)))
        }
        if offsets.count >= limit {
            out.append("(Stopped at \(limit) matches — narrow the pattern or read a shorter range.)")
        }
        return out.joined(separator: "\n")
    }

    private nonisolated static func matchBytes(_ bytes: [UInt8], at offset: Int, _ pattern: [UInt8]) -> Bool {
        for (i, p) in pattern.enumerated() where bytes[offset + i] != p { return false }
        return true
    }

    /// xxd-style dump: offset, hex bytes, ASCII column. 16 bytes per row.
    nonisolated static func hexDump(path: String, offset: Int, length: Int) throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LocalToolError.invalidArguments("Could not read: \(path)")
        }
        let bytes = [UInt8](data)
        let start = max(0, offset)
        guard start <= bytes.count else {
            return "[\(path) — offset \(start) is past the end of the file (\(bytes.count) bytes)]"
        }
        let count = min(length, hexDumpMaxBytes, bytes.count - start)
        let lines = hexBlock(bytes, from: start, to: start + count, highlight: nil)
        var out = ["[\(path) — \(bytes.count) bytes total, showing \(count) from offset \(start) (0x\(String(start, radix: 16).uppercased()))]"]
        out.append(lines)
        return out.joined(separator: "\n")
    }

    /// One hex+ASCII block, xxd-style: `offset  hex bytes  |ascii|`.
    /// `highlight` marks a found range with brackets in both columns so the
    /// hit stands out at a glance.
    private nonisolated static func hexBlock(
        _ bytes: [UInt8], from: Int, to: Int, highlight: (offset: Int, length: Int)?
    ) -> String {
        var rows: [String] = []
        let rowSize = 16
        var rowStart = from
        while rowStart < to {
            let rowEnd = min(rowStart + rowSize, to)
            var hexPart = ""
            var asciiPart = ""
            for i in rowStart..<rowEnd {
                let inside = highlight.map { i >= $0.offset && i < $0.offset + $0.length } ?? false
                let hex = String(format: "%02X", bytes[i])
                // Bracket a highlighted byte only when the bracketing cannot
                // be confused with column content: mark in the ASCII column
                // with brackets and in hex by a preceding `>`.
                hexPart += (inside ? ">" + hex : hex) + (i % 16 == 7 ? "  " : " ")
                let ch = bytes[i]
                let ascii: Character = (ch >= 0x20 && ch < 0x7F) ? Character(UnicodeScalar(ch)) : "."
                asciiPart += inside ? "[" + String(ascii) + "]" : String(ascii)
            }
            let offsetField = String(format: "%08X  ", rowStart)
            rows.append("\(offsetField)\(hexPart)  |\(asciiPart)|")
            rowStart = rowEnd
        }
        return rows.joined(separator: "\n")
    }

    /// Reads integers at an offset: `struct.unpack` without Python. Supports
    /// 1/2/4/8-byte little- and big-endian, signed and unsigned.
    nonisolated static func hexRead(
        path: String, offset: Int, count: Int, widthBytes: Int, signed: Bool, bigEndian: Bool
    ) throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LocalToolError.invalidArguments("Could not read: \(path)")
        }
        let bytes = [UInt8](data)
        let start = max(0, offset)
        guard start + widthBytes <= bytes.count else {
            throw LocalToolError.invalidArguments(
                "Offset \(start) + width \(widthBytes) is past the end of the file (\(bytes.count) bytes)."
            )
        }
        let n = max(1, min(count, 256))
        var rows: [String] = []
        var pos = start
        while pos + widthBytes <= bytes.count, rows.count < n {
            var value: UInt64 = 0
            if bigEndian {
                for i in 0..<widthBytes { value = (value << 8) | UInt64(bytes[pos + i]) }
            } else {
                for i in stride(from: widthBytes - 1, through: 0, by: -1) {
                    value = (value << 8) | UInt64(bytes[pos + i])
                }
            }
            var line = String(format: "%08X  ", pos)
            let byteSlice = bytes[pos..<min(pos + widthBytes, bytes.count)]
            line += byteSlice.map { String(format: "%02X ", $0) }.joined()
            if signed {
                line += " = \(signedValue(value, width: widthBytes)) (i\(widthBytes * 8))"
            } else {
                line += " = \(value) (u\(widthBytes * 8))"
            }
            rows.append(line)
            pos += widthBytes
        }
        return "[\(path) — \(bytes.count) bytes]\n" + rows.joined(separator: "\n")
    }

    private nonisolated static func signedValue(_ raw: UInt64, width: Int) -> Int64 {
        switch width {
        case 1: return Int64(Int8(truncatingIfNeeded: raw))
        case 2: return Int64(Int16(truncatingIfNeeded: raw))
        case 4: return Int64(Int32(truncatingIfNeeded: raw))
        default: return Int64(bitPattern: raw)
        }
    }

    /// Printable-ASCII runs, `strings`-style, minimum length 4.
    nonisolated static func extractStrings(path: String, minLength: Int, limit: Int) throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LocalToolError.invalidArguments("Could not read: \(path)")
        }
        let bytes = [UInt8](data)
        var runs: [String] = []
        var current: [UInt8] = []
        for byte in bytes {
            if byte >= 0x20 && byte < 0x7F {
                current.append(byte)
            } else {
                if current.count >= minLength { runs.append(String(decoding: current, as: UTF8.self)) }
                if runs.count >= limit { break }
                current = []
            }
        }
        if current.count >= minLength, runs.count < limit { runs.append(String(decoding: current, as: UTF8.self)) }
        guard !runs.isEmpty else { return "No printable runs of \(minLength)+ characters found." }
        return "[\(runs.count) string\(runs.count == 1 ? "" : "s") in \(path)]\n" + runs.joined(separator: "\n")
    }
}
