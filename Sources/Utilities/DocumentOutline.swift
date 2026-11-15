import Foundation

/// The structure of a Typst or Markdown document, line by line: headings
/// and `#include` lines. Used by `read_file`'s outline mode (map a long
/// document in one small call) and by the chat's elision digests (keep
/// where things are after the text itself is dropped).
enum DocumentOutline {
    struct Entry: Equatable {
        enum Kind: Equatable {
            /// `= Title` / `# Title`, with its level (1 = top).
            case heading(level: Int)
            /// `#include "chapter.typ"` — part of the document lives elsewhere.
            case include
        }
        /// 1-based line number.
        let line: Int
        /// Last line of the section this heading starts (up to the next
        /// heading of the same or a higher level). `nil` for includes.
        let endLine: Int?
        let kind: Kind
        let text: String
    }

    /// Most entries an outline lists before it says how many it left out.
    static let maxEntries = 300

    /// A Typst (`= Title`) or Markdown (`# Title`) heading at the start of a
    /// line. Typst code such as `#set …` (no space after `#`) is not a heading.
    static func isHeadingLine(_ line: String) -> Bool {
        headingLevel(line) != nil
    }

    static func headingLevel(_ line: String) -> Int? {
        guard let first = line.first, first == "=" || first == "#" else { return nil }
        let marks = line.prefix(while: { $0 == first })
        guard marks.count <= 6 else { return nil }
        let rest = line.dropFirst(marks.count)
        guard rest.first == " ", rest.dropFirst().contains(where: { !$0.isWhitespace }) else { return nil }
        return marks.count
    }

    /// Headings and includes in `text`, skipping anything inside ``` raw /
    /// code blocks (a `# comment` in a shell snippet is not a heading).
    static func entries(in text: String) -> [Entry] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var found: [(line: Int, kind: Entry.Kind, text: String)] = []
        var inRawBlock = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inRawBlock.toggle()
                continue
            }
            guard !inRawBlock else { continue }
            if let level = headingLevel(line) {
                found.append((index + 1, .heading(level: level), clipped(line)))
            } else if trimmed.hasPrefix("#include ") || trimmed.hasPrefix("#include(") {
                found.append((index + 1, .include, clipped(trimmed)))
            }
        }

        let totalLines = lines.count
        return found.enumerated().map { position, item in
            guard case .heading(let level) = item.kind else {
                return Entry(line: item.line, endLine: nil, kind: item.kind, text: item.text)
            }
            let next = found[(position + 1)...].first { candidate in
                if case .heading(let otherLevel) = candidate.kind { return otherLevel <= level }
                return false
            }
            let end = next.map { $0.line - 1 } ?? totalLines
            return Entry(line: item.line, endLine: max(item.line, end), kind: item.kind, text: item.text)
        }
    }

    /// The text `read_file` or `get_outline` returns in outline mode.
    static func render(_ text: String, label: String, startLine: Int? = nil, endLine: Int? = nil) -> String {
        let totalLines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").count
        let all = entries(in: text)
        let filtered: [Entry]
        let rangeLabel: String
        if startLine != nil || endLine != nil {
            let start = startLine ?? 1
            let end = endLine ?? totalLines
            rangeLabel = " (lines \(start)–\(end))"
            filtered = all.filter { entry in
                let entryStart = entry.line
                let entryEnd = entry.endLine ?? entry.line
                return entryStart <= end && entryEnd >= start
            }
        } else {
            rangeLabel = ""
            filtered = all
        }

        let headingCount = filtered.filter { if case .heading = $0.kind { return true } else { return false } }.count
        let headerCountSuffix = (startLine != nil || endLine != nil) ? "total " : ""
        var output = "[outline of '\(label)'\(rangeLabel) — \(totalLines) \(headerCountSuffix)line\(totalLines == 1 ? "" : "s"), \(headingCount) heading\(headingCount == 1 ? "" : "s")]"
        guard !filtered.isEmpty else {
            let note = (startLine != nil || endLine != nil) ? " in this range" : ""
            return output + "\nNo headings or #include lines found\(note). Read it with offset/limit instead."
        }
        for entry in filtered.prefix(maxEntries) {
            if let end = entry.endLine {
                output += "\n\(entry.line)-\(end): \(entry.text)"
            } else {
                output += "\n\(entry.line): \(entry.text)"
            }
        }
        if filtered.count > maxEntries {
            output += "\n… \(filtered.count - maxEntries) more entries not shown"
        }
        if let example = filtered.first(where: { $0.endLine != nil }), let end = example.endLine {
            output += "\nRead one section with read_file offset/limit from its line range — e.g. lines \(example.line)-\(end) are offset: \(example.line), limit: \(end - example.line + 1)."
            output += "\nMove a section with move_lines — e.g. start_line: \(example.line), end_line: \(end), start_text: \"\(example.text)\"."
        } else {
            output += "\nRead the parts you need with read_file offset/limit."
        }
        return output
    }

    /// Formats an outline with a compressed preview of each section's contents.
    static func renderSkim(
        _ text: String,
        label: String,
        startLine: Int? = nil,
        endLine: Int? = nil,
        maxWordsPerSection: Int = 50,
        compress: (@Sendable (String) async -> String)? = nil
    ) async -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let totalLines = lines.count
        let all = entries(in: text)
        let filtered: [Entry]
        let rangeLabel: String
        if startLine != nil || endLine != nil {
            let start = startLine ?? 1
            let end = endLine ?? totalLines
            rangeLabel = " (lines \(start)–\(end))"
            filtered = all.filter { entry in
                let entryStart = entry.line
                let entryEnd = entry.endLine ?? entry.line
                return entryStart <= end && entryEnd >= start
            }
        } else {
            rangeLabel = ""
            filtered = all
        }

        let headingCount = filtered.filter { if case .heading = $0.kind { return true } else { return false } }.count
        let headerCountSuffix = (startLine != nil || endLine != nil) ? "total " : ""
        var output = "[skim of '\(label)'\(rangeLabel) — \(totalLines) \(headerCountSuffix)line\(totalLines == 1 ? "" : "s"), \(headingCount) heading\(headingCount == 1 ? "" : "s")]"
        guard !filtered.isEmpty else {
            let note = (startLine != nil || endLine != nil) ? " in this range" : ""
            return output + "\nNo headings or #include lines found\(note). Read it with offset/limit instead."
        }

        for entry in filtered.prefix(maxEntries) {
            let lineSpan: String
            let nextSectionStart = entry.endLine ?? totalLines
            if let end = entry.endLine {
                let count = end - entry.line + 1
                lineSpan = "\(entry.line)-\(end) (\(count) line\(count == 1 ? "" : "s"))"
            } else {
                lineSpan = "\(entry.line)"
            }
            output += "\n\(lineSpan): \(entry.text)"

            // Extract section lead lines
            let bodyStart = entry.line // 1-based line of next line
            let bodyEnd = min(nextSectionStart, entry.line + 35)
            if bodyStart < bodyEnd && bodyStart <= totalLines {
                var bodyLines: [String] = []
                for i in bodyStart..<min(bodyEnd, totalLines) {
                    let line = lines[i].trimmingCharacters(in: .whitespaces)
                    if !line.isEmpty && !line.hasPrefix("```") && !isHeadingLine(line) {
                        bodyLines.append(line)
                        if bodyLines.count >= 20 { break }
                    }
                }
                let rawBody = bodyLines.joined(separator: " ")
                if !rawBody.isEmpty {
                    let preview: String
                    if let compress {
                        let compressed = await compress(rawBody)
                        let words = compressed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                        if words.count > maxWordsPerSection {
                            preview = words.prefix(maxWordsPerSection).joined(separator: " ") + " …"
                        } else {
                            preview = compressed
                        }
                    } else {
                        let words = rawBody.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                        preview = words.prefix(maxWordsPerSection).joined(separator: " ") + (words.count > maxWordsPerSection ? " …" : "")
                    }
                    output += "\n  Preview: \(preview)"
                }
            }
        }

        if filtered.count > maxEntries {
            output += "\n… \(filtered.count - maxEntries) more entries not shown"
        }
        if let example = filtered.first(where: { $0.endLine != nil }), let end = example.endLine {
            output += "\nTo move a section, use move_lines with start_line, end_line, and start_text (e.g. lines \(example.line)-\(end): start_line: \(example.line), end_line: \(end), start_text: \"\(example.text)\")."
            output += "\nTo read the full text of a section, use read_file with offset: \(example.line), limit: \(end - example.line + 1)."
        }
        return output
    }

    private static func clipped(_ line: String) -> String {
        line.count > 100 ? String(line.prefix(100)) + "…" : line
    }
}
