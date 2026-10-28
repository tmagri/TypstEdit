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

    /// The text `read_file` returns in outline mode.
    static func render(_ text: String, label: String) -> String {
        let totalLines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").count
        let all = entries(in: text)
        let headingCount = all.filter { if case .heading = $0.kind { return true } else { return false } }.count
        var output = "[outline of '\(label)' — \(totalLines) line\(totalLines == 1 ? "" : "s"), \(headingCount) heading\(headingCount == 1 ? "" : "s")]"
        guard !all.isEmpty else {
            return output + "\nNo headings or #include lines found. Read it with offset/limit instead."
        }
        for entry in all.prefix(maxEntries) {
            if let end = entry.endLine {
                output += "\n\(entry.line)-\(end): \(entry.text)"
            } else {
                output += "\n\(entry.line): \(entry.text)"
            }
        }
        if all.count > maxEntries {
            output += "\n… \(all.count - maxEntries) more entries not shown"
        }
        if let example = all.first(where: { $0.endLine != nil }), let end = example.endLine {
            output += "\nRead one section with read_file offset/limit from its line range — e.g. lines \(example.line)-\(end) are offset: \(example.line), limit: \(end - example.line + 1)."
        } else {
            output += "\nRead the parts you need with read_file offset/limit."
        }
        return output
    }

    private static func clipped(_ line: String) -> String {
        line.count > 100 ? String(line.prefix(100)) + "…" : line
    }
}
