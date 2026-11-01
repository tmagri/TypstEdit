import Foundation

/// Parses and applies opencode's batch patch format, so a restructure that
/// touches several files costs one approval instead of one per file.
///
/// The format is deliberately line-oriented and easy for a model to write:
///
/// ```
/// *** Begin Patch
/// *** Add File: chapters/new.typ
/// += New chapter
/// +Body text.
/// *** Update File: main.typ
/// *** Move to: book.typ
/// @@ = Contents
/// -= Old heading
/// += New heading
/// *** Delete File: obsolete.typ
/// *** End Patch
/// ```
///
/// `*** Move to:` is the only way to rename a file here — the tool set has no
/// rename of its own — so it earns its place beyond the batching.
///
/// Parsing is pure and separate from applying, because a patch that is wrong
/// halfway through must not leave the project half-renamed: the caller parses
/// and validates everything before writing anything.
enum BatchPatch {

    // MARK: - Model

    struct Line: Equatable {
        enum Kind: Equatable { case context, removed, added }
        var kind: Kind
        var text: String
    }

    struct Hunk: Equatable {
        /// The text after `@@`, when the model used it as an anchor or label.
        var context: String?
        var lines: [Line]

        var oldLines: [String] { lines.filter { $0.kind != .added }.map(\.text) }
        var newLines: [String] { lines.filter { $0.kind != .removed }.map(\.text) }
    }

    enum Operation: Equatable {
        case add(path: String, content: String)
        case delete(path: String)
        case update(path: String, moveTo: String?, hunks: [Hunk])

        var path: String {
            switch self {
            case .add(let path, _): return path
            case .delete(let path): return path
            case .update(let path, _, _): return path
            }
        }
    }

    enum PatchError: LocalizedError, Equatable {
        case missingBegin
        case missingEnd
        case empty
        case malformedHeader(String)
        case contentOutsideFile(String)
        case addWithoutContent(String)
        case updateWithoutHunks(String)
        case notFound(String, hunk: String)
        case ambiguous(String, hunk: String, count: Int)
        case unanchoredHunk(String)
        case duplicatePath(String)

        var errorDescription: String? {
            switch self {
            case .missingBegin:
                return "The patch must start with a \"*** Begin Patch\" line."
            case .missingEnd:
                return "The patch is missing its closing \"*** End Patch\" line."
            case .empty:
                return "The patch contains no file operations."
            case .malformedHeader(let line):
                return "Unrecognized patch header: \"\(line)\". Use \"*** Add File:\", \"*** Update File:\", \"*** Delete File:\" or \"*** Move to:\"."
            case .contentOutsideFile(let line):
                return "Line \"\(line)\" is outside any file operation. Every line in a patch must belong to an Add, Update or Delete block."
            case .addWithoutContent(let path):
                return "Add File '\(path)' has no content — every line after it must start with \"+\"."
            case .updateWithoutHunks(let path):
                return "Update File '\(path)' has no hunks. Add the changed lines under an \"@@\" line, prefixing kept lines with a space, removed lines with \"-\" and new lines with \"+\"."
            case .notFound(let path, let hunk):
                return "The hunk starting \"\(hunk)\" doesn't match anything in '\(path)'. Read the file again and copy the lines exactly, including their leading whitespace."
            case .ambiguous(let path, let hunk, let count):
                return "The hunk starting \"\(hunk)\" matches \(count) places in '\(path)'. Include more surrounding context lines so it identifies one place."
            case .unanchoredHunk(let path):
                return "An update to '\(path)' has only added lines and no context to place them against. Include at least one kept line (starting with a space) so the new text has a position."
            case .duplicatePath(let path):
                return "'\(path)' appears more than once in this patch. Combine the changes into a single block for that file."
            }
        }
    }

    // MARK: - Parsing

    static func parse(_ text: String) throws -> [Operation] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "*** Begin Patch" }) else {
            throw PatchError.missingBegin
        }
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "*** End Patch" }) else {
            throw PatchError.missingEnd
        }

        var operations: [Operation] = []
        var seenPaths: Set<String> = []
        var index = 0
        // Anything before "*** Begin Patch" is tolerated (models often add a
        // sentence of explanation), but content after "*** End Patch" is not
        // read at all.
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "*** Begin Patch" {
            index += 1
        }
        index += 1

        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { index += 1; continue }
            if line == "*** End Patch" { break }

            if let path = headerPath(raw, prefix: "*** Add File:") {
                index += 1
                var content: [String] = []
                while index < lines.count, !isHeader(lines[index]) {
                    let body = lines[index]
                    guard body.hasPrefix("+") else {
                        throw PatchError.malformedHeader(body)
                    }
                    content.append(String(body.dropFirst()))
                    index += 1
                }
                guard !content.isEmpty else { throw PatchError.addWithoutContent(path) }
                try record(path, in: &seenPaths)
                operations.append(.add(path: path, content: content.joined(separator: "\n")))
                continue
            }

            if let path = headerPath(raw, prefix: "*** Delete File:") {
                index += 1
                try record(path, in: &seenPaths)
                operations.append(.delete(path: path))
                continue
            }

            if let path = headerPath(raw, prefix: "*** Update File:") {
                index += 1
                var moveTo: String?
                if index < lines.count, let target = headerPath(lines[index], prefix: "*** Move to:") {
                    moveTo = target
                    index += 1
                }
                var hunks: [Hunk] = []
                var current: Hunk?
                while index < lines.count {
                    let body = lines[index]
                    let trimmed = body.trimmingCharacters(in: .whitespaces)
                    if isHeader(body) { break }
                    if trimmed.hasPrefix("@@") {
                        if let current { hunks.append(current) }
                        let context = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        current = Hunk(context: context.isEmpty ? nil : context, lines: [])
                        index += 1
                        continue
                    }
                    guard let first = body.first else { index += 1; continue }
                    switch first {
                    case " ", "-", "+":
                        // A hunk may follow the header directly, with no `@@`
                        // line: the marker is a label, not a requirement, and
                        // demanding it would reject otherwise valid patches.
                        if current == nil {
                            current = Hunk(context: nil, lines: [])
                        }
                        let kind: Line.Kind = first == " " ? .context : (first == "-" ? .removed : .added)
                        current?.lines.append(Line(kind: kind, text: String(body.dropFirst())))
                        index += 1
                    case "\\":
                        // "\ No newline at end of file" markers are accepted
                        // and ignored: the app normalizes endings itself.
                        index += 1
                    default:
                        throw PatchError.contentOutsideFile(body)
                    }
                }
                if let current { hunks.append(current) }
                guard !hunks.isEmpty else { throw PatchError.updateWithoutHunks(path) }
                try record(path, in: &seenPaths)
                operations.append(.update(path: path, moveTo: moveTo, hunks: hunks))
                continue
            }

            guard line.hasPrefix("***") else {
                throw PatchError.contentOutsideFile(raw)
            }
            throw PatchError.malformedHeader(raw)
        }

        guard !operations.isEmpty else { throw PatchError.empty }
        return operations
    }

    private static func headerPath(_ line: String, prefix: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let path = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    private static func isHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("*** Add File:")
            || trimmed.hasPrefix("*** Delete File:")
            || trimmed.hasPrefix("*** Update File:")
            || trimmed.hasPrefix("*** Move to:")
            || trimmed == "*** End Patch"
    }

    private static func record(_ path: String, in seen: inout Set<String>) throws {
        guard seen.insert(path).inserted else { throw PatchError.duplicatePath(path) }
    }

    // MARK: - Applying

    /// Applies `hunks` to `content`, returning the new text.
    ///
    /// Each hunk must match exactly one place, with trailing whitespace and
    /// typographic punctuation ignored — a model copying lines out of a
    /// rendered document supplies curly quotes where the source has ASCII.
    /// Ambiguity is an error rather than a guess: silently patching the wrong
    /// paragraph is far worse than asking for more context.
    static func apply(hunks: [Hunk], to content: String, path: String) throws -> String {
        let hadTrailingNewline = content.hasSuffix("\n")
        var lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }

        for hunk in hunks {
            let oldLines = hunk.oldLines
            guard !oldLines.isEmpty else { throw PatchError.unanchoredHunk(path) }
            let newLines = hunk.newLines
            let key = oldLines.map(normalized)
            let haystack = lines.map(normalized)

            var matches: [Int] = []
            if haystack.count >= key.count {
                for start in 0...(haystack.count - key.count) where Array(haystack[start..<(start + key.count)]) == key {
                    matches.append(start)
                }
            }
            guard !matches.isEmpty else {
                throw PatchError.notFound(path, hunk: String(oldLines.first ?? ""))
            }
            guard matches.count == 1 else {
                throw PatchError.ambiguous(path, hunk: String(oldLines.first ?? ""), count: matches.count)
            }
            let start = matches[0]
            lines.replaceSubrange(start..<(start + oldLines.count), with: newLines)
        }

        return lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
    }

    /// Trailing whitespace removed, then typographic variants folded — the
    /// same rule the tolerant `edit_file` matcher uses.
    private static func normalized(_ line: String) -> String {
        var out = String()
        for character in line {
            switch character {
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}": out.append("'")
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}": out.append("\"")
            case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}": out.append("-")
            default: out.append(character)
            }
        }
        while out.hasSuffix(" ") || out.hasSuffix("\t") || out.hasSuffix("\r") { out.removeLast() }
        return out
    }

    /// The result line the model reads back, in the shape it has seen before.
    static func resultText(_ changes: [PatchChange]) -> String {
        let listing = changes.map { change in
            let letter: String
            switch change.kind {
            case .added: letter = "A"
            case .deleted: letter = "D"
            case .modified, .moved: letter = "M"
            }
            return "\(letter) \(change.path)"
        }
        return "Success. Updated the following files:\n" + listing.joined(separator: "\n")
    }
}

/// One file's before/after in a batch patch. Carried into the approval so the
/// user reviews every change at once.
struct PatchChange: Identifiable, Equatable {
    enum Kind: Equatable {
        case added
        case modified
        case deleted
        case moved
    }

    var id = UUID()
    var path: String
    var oldContent: String
    var newContent: String
    var kind: Kind
    /// For a moved file, the path it is being moved away from.
    var fromPath: String?
}
