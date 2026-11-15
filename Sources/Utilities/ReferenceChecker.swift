import Foundation

/// Cross-checks a Typst project's labels, references and citations:
/// `@ref`s with no `<label>` or bibliography entry, labels defined twice,
/// labels nothing refers to, and bibliography entries never cited.
///
/// This is the kind of whole-document bookkeeping a model does badly — it
/// would have to hold every label of a long document in mind at once — and a
/// scanner does exactly and for free. Pure: the caller reads the files.
enum ReferenceChecker {

    struct Location: Equatable, Sendable, Comparable {
        let path: String
        let line: Int

        var description: String { "\(path):\(line)" }

        static func < (lhs: Location, rhs: Location) -> Bool {
            lhs.path != rhs.path ? lhs.path < rhs.path : lhs.line < rhs.line
        }
    }

    struct Report: Sendable {
        /// `<label>` definitions (and `label("…")`).
        var labels: [String: [Location]] = [:]
        /// `@key` and `ref(<key>)` / `cite(<key>)` / `link(<key>)` uses.
        var references: [String: [Location]] = [:]
        /// Keys found in the bibliography files that could be read.
        var bibliographyKeys: Set<String> = []
        /// Bibliography files named by `#bibliography(…)`, resolved to
        /// scope-relative paths, with where they were named.
        var bibliographyFiles: [(path: String, from: Location)] = []
        /// Bibliography files that were named but couldn't be read.
        var missingBibliographies: [(path: String, from: Location)] = []
        var filesScanned = 0
    }

    // MARK: Scanning

    private static let namePattern = "[\\p{L}\\p{N}_][\\p{L}\\p{N}_\\-:.]*"
    private static let labelRegex = try! NSRegularExpression(pattern: "<(\(namePattern))>")
    private static let labelCallRegex = try! NSRegularExpression(pattern: "\\blabel\\(\\s*\"(\(namePattern))\"\\s*\\)")
    private static let refCallRegex = try! NSRegularExpression(pattern: "\\b(?:ref|cite|link|query|locate)\\(\\s*<(\(namePattern))>")
    /// `@key` not glued to a word, path or string (excludes e-mail addresses
    /// and `"@preview/…"` package imports).
    private static let atRefRegex = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_.@/\"'\\\\])@(\(namePattern))")
    private static let stringRegex = try! NSRegularExpression(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"")
    private static let inlineRawRegex = try! NSRegularExpression(pattern: "`[^`]*`")
    private static let bibliographyRegex = try! NSRegularExpression(pattern: "\\bbibliography\\(")
    private static let bibFileRegex = try! NSRegularExpression(pattern: "\"([^\"]+\\.(?:bib|ya?ml))\"", options: [.caseInsensitive])

    /// Records the labels, references and bibliography files in one `.typ`
    /// file. Skips fenced raw blocks, inline raw, and comments.
    static func scanTypst(_ text: String, path: String, into report: inout Report) {
        report.filesScanned += 1
        var inRawBlock = false
        var inBlockComment = false
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let location = Location(path: path, line: index + 1)
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inRawBlock.toggle()
                continue
            }
            guard !inRawBlock else { continue }
            let line = stripComments(rawLine, inBlockComment: &inBlockComment)
            guard !line.isEmpty else { continue }

            // Bibliography files, before strings are blanked out.
            if matches(bibliographyRegex, in: line) {
                let directory = (path as NSString).deletingLastPathComponent
                for name in captures(bibFileRegex, in: line) {
                    let resolved = name.hasPrefix("/")
                        ? String(name.dropFirst())
                        : (directory.isEmpty ? name : (directory as NSString).appendingPathComponent(name))
                    report.bibliographyFiles.append(((resolved as NSString).standardizingPath, location))
                }
            }
            for name in captures(labelCallRegex, in: line) {
                report.labels[name, default: []].append(location)
            }

            var scrubbed = replace(inlineRawRegex, in: line)
            // `ref(<x>)` / `cite(<x>)` are uses, not definitions: record
            // them and blank them out before looking for `<label>`s.
            for name in captures(refCallRegex, in: scrubbed) {
                report.references[name, default: []].append(location)
            }
            scrubbed = replace(refCallRegex, in: scrubbed)
            scrubbed = replace(stringRegex, in: scrubbed)

            for name in captures(labelRegex, in: scrubbed) {
                report.labels[name, default: []].append(location)
            }
            for raw in captures(atRefRegex, in: scrubbed) {
                // A sentence-ending "see @fig." — the dot is punctuation.
                let name = String(raw.reversed().drop(while: { ".:-".contains($0) }).reversed())
                guard !name.isEmpty else { continue }
                report.references[name, default: []].append(location)
            }
        }
    }

    /// `line` without `//` line comments and `/* */` block comments. A `//`
    /// right after `:` is a URL, not a comment.
    private static func stripComments(_ line: String, inBlockComment: inout Bool) -> String {
        var output = ""
        var previous: Character?
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if inBlockComment {
                if character == "*", next == "/" { inBlockComment = false; index += 2; continue }
                index += 1
                continue
            }
            if character == "/", next == "*" { inBlockComment = true; index += 2; continue }
            if character == "/", next == "/", previous != ":" { break }
            output.append(character)
            previous = character
            index += 1
        }
        return output
    }

    /// Entry keys of a BibTeX (`@article{key, …`) or Hayagriva YAML
    /// (`key:` at the start of a line) bibliography.
    static func bibliographyKeys(in text: String, isYAML: Bool) -> Set<String> {
        // BibTeX's @comment / @preamble / @string blocks aren't entries.
        let pattern = isYAML
            ? "(?m)^([\\p{L}\\p{N}_][^:\\s]*)\\s*:"
            : "@(?!(?:comment|preamble|string)\\b)[A-Za-z]+\\s*[{(]\\s*([^,\\s{}()]+)\\s*,"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: isYAML ? [] : [.caseInsensitive]) else { return [] }
        return Set(captures(regex, in: text))
    }

    // MARK: Rendering

    /// Most entries listed per category before "… N more".
    static let maxListed = 40

    static func render(_ report: Report, scopeLabel: String) -> String {
        let referenceCount = report.references.values.reduce(0) { $0 + $1.count }
        var output = "[reference check of \(scopeLabel) — \(report.filesScanned) .typ file\(report.filesScanned == 1 ? "" : "s"), \(report.labels.count) label\(report.labels.count == 1 ? "" : "s"), \(referenceCount) reference\(referenceCount == 1 ? "" : "s"), \(report.bibliographyKeys.count) bibliography entr\(report.bibliographyKeys.count == 1 ? "y" : "ies")]"
        var problems = 0

        let undefined = report.references
            .filter { report.labels[$0.key] == nil && !report.bibliographyKeys.contains($0.key) }
            .sorted { ($0.value.min() ?? Location(path: "", line: 0)) < ($1.value.min() ?? Location(path: "", line: 0)) }
        if !undefined.isEmpty {
            problems += undefined.count
            output += "\n\nUndefined references (\(undefined.count)) — no <label> or bibliography entry with this name; Typst fails to compile these:"
            let known = Array(report.labels.keys) + Array(report.bibliographyKeys)
            for (name, locations) in undefined.prefix(maxListed) {
                var line = "\n  @\(name) at \(listed(locations))"
                if let guess = closest(to: name, in: known) { line += " — did you mean @\(guess)?" }
                output += line
            }
            if undefined.count > maxListed { output += "\n  … \(undefined.count - maxListed) more" }
            if !report.missingBibliographies.isEmpty {
                output += "\n  (Some may be citations: a bibliography file couldn't be read — see below.)"
            }
        }

        let duplicates = report.labels.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
        if !duplicates.isEmpty {
            problems += duplicates.count
            output += "\n\nDuplicate labels (\(duplicates.count)) — a label must be unique; references to it are ambiguous:"
            for (name, locations) in duplicates.prefix(maxListed) {
                output += "\n  <\(name)> at \(listed(locations))"
            }
            if duplicates.count > maxListed { output += "\n  … \(duplicates.count - maxListed) more" }
        }

        if !report.missingBibliographies.isEmpty {
            problems += report.missingBibliographies.count
            output += "\n\nMissing bibliography files (\(report.missingBibliographies.count)):"
            for missing in report.missingBibliographies.prefix(maxListed) {
                output += "\n  \(missing.path) (named at \(missing.from.description))"
            }
        }

        let unused = report.labels.filter { report.references[$0.key] == nil }.sorted { $0.key < $1.key }
        if !unused.isEmpty {
            output += "\n\nUnused labels (\(unused.count)) — defined but never referenced; often fine, but a typo'd reference shows up here too:"
            for (name, locations) in unused.prefix(maxListed) {
                output += "\n  <\(name)> at \(listed(locations))"
            }
            if unused.count > maxListed { output += "\n  … \(unused.count - maxListed) more" }
        }

        let uncited = report.bibliographyKeys.subtracting(report.references.keys).sorted()
        if !uncited.isEmpty {
            output += "\n\nBibliography entries never cited (\(uncited.count)) — Typst leaves them out of the reference list unless the bibliography uses full: true:"
            output += "\n  " + uncited.prefix(maxListed).joined(separator: ", ")
            if uncited.count > maxListed { output += ", … \(uncited.count - maxListed) more" }
        }

        if problems == 0 {
            output += "\n\nNo undefined references, duplicate labels or missing bibliography files."
        } else {
            output += "\n\nFix each problem at the file:line shown (read_file there first). Rename the reference to an existing label, add the missing <label> after the element it names, or add the entry to the bibliography."
        }
        return output
    }

    private static func listed(_ locations: [Location]) -> String {
        let sorted = locations.sorted()
        let shown = sorted.prefix(4).map(\.description).joined(separator: ", ")
        return sorted.count > 4 ? shown + ", … (\(sorted.count) uses)" : shown
    }

    /// The known name closest to `name` by edit distance, when it is close
    /// enough to be a plausible typo.
    static func closest(to name: String, in candidates: [String]) -> String? {
        let limit = max(1, min(3, name.count / 4))
        var best: (name: String, distance: Int)?
        for candidate in candidates where candidate != name {
            let distance = editDistance(name.lowercased(), candidate.lowercased(), cap: limit + 1)
            if distance <= limit, distance < (best?.distance ?? Int.max) {
                best = (candidate, distance)
            }
        }
        return best?.name
    }

    /// Levenshtein distance, giving up (returning `cap`) once every path
    /// exceeds `cap`.
    static func editDistance(_ a: String, _ b: String, cap: Int) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) >= cap { return cap }
        if a.isEmpty || b.isEmpty { return min(max(a.count, b.count), cap) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            var rowMin = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin >= cap { return cap }
            previous = current
        }
        return min(previous[b.count], cap)
    }

    // MARK: Regex helpers

    private static func nsRange(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: nsRange(text)) != nil
    }

    private static func captures(_ regex: NSRegularExpression, in text: String) -> [String] {
        regex.matches(in: text, range: nsRange(text)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    /// `text` with every match blanked to spaces, so later patterns can't
    /// see inside it.
    private static func replace(_ regex: NSRegularExpression, in text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: nsRange(text), withTemplate: " ")
    }
}
