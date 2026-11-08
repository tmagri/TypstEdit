import Foundation

/// One passage of a file, as the semantic index stores it.
struct TextChunk: Equatable {
    let text: String
    /// First and last line of the passage, 1-based and inclusive, so a hit
    /// maps straight onto `read_file` offset/limit. 0 when the source has no
    /// lines (passages extracted from JSON).
    let startLine: Int
    let endLine: Int
    /// The headings the passage sits under, outermost first.
    let headings: [String]

    var headingPath: String { headings.joined(separator: " > ") }

    /// The text that is embedded: the passage under its file and section.
    /// A paragraph that only makes sense in context ("It defaults to 30
    /// seconds") then still lands near queries about its section.
    func embeddingInput(path: String) -> String {
        var header = "File: \(path)"
        if !headings.isEmpty { header += "\nSection: \(headingPath)" }
        return "\(header)\n\n\(text)"
    }
}

/// Splits a file into passages for the semantic index.
///
/// Passages follow the document's own structure: a heading always starts a
/// new passage, paragraphs are packed together up to `targetChars`, and a
/// paragraph longer than `maxChars` is split at line boundaries. Splitting
/// at every blank line instead dropped short paragraphs entirely and cut
/// sections loose from their headings.
enum DocumentChunker {
    static let targetChars = 1_200
    static let maxChars = 2_000

    enum HeadingStyle {
        case typst
        case markdown
        case none

        init(fileExtension: String) {
            switch fileExtension.lowercased() {
            case "typ", "note": self = .typst
            case "md", "markdown": self = .markdown
            default: self = .none
            }
        }
    }

    private typealias Line = (number: Int, text: String)

    static func chunks(in text: String, fileExtension: String) -> [TextChunk] {
        chunks(in: text, style: HeadingStyle(fileExtension: fileExtension))
    }

    static func chunks(in text: String, style: HeadingStyle) -> [TextChunk] {
        var output: [TextChunk] = []
        var headings: [(level: Int, title: String)] = []
        var pendingBlocks: [[Line]] = []
        var pendingChars = 0
        var block: [Line] = []
        var inFence = false

        func currentHeadings() -> [String] { headings.map(\.title) }

        func emit(_ blocks: [[Line]]) {
            let lines = blocks.flatMap { $0 }
            guard let first = lines.first, let last = lines.last else { return }
            let body = blocks.map { $0.map(\.text).joined(separator: "\n") }.joined(separator: "\n\n")
            let visible = body.filter { !$0.isWhitespace }.count
            // A short passage is still worth keeping under a heading ("Due:
            // March 3"); on its own it is noise like a lone closing brace.
            guard visible >= (headings.isEmpty ? 20 : 3) else { return }
            output.append(TextChunk(text: body, startLine: first.number, endLine: last.number, headings: currentHeadings()))
        }

        func flushPending() {
            emit(pendingBlocks)
            pendingBlocks = []
            pendingChars = 0
        }

        func closeBlock() {
            guard !block.isEmpty else { return }
            defer { block = [] }
            let size = block.reduce(0) { $0 + $1.text.count + 1 }
            if size > maxChars {
                flushPending()
                for piece in split(block) { emit([piece]) }
                return
            }
            if pendingChars > 0, pendingChars + size > targetChars {
                flushPending()
            }
            pendingBlocks.append(block)
            pendingChars += size + 1
        }

        let lines = text.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if style != .none, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
            }
            if !inFence, let heading = heading(in: trimmed, style: style) {
                closeBlock()
                flushPending()
                while let last = headings.last, last.level >= heading.level { headings.removeLast() }
                headings.append(heading)
                continue
            }
            if trimmed.isEmpty, !inFence {
                closeBlock()
            } else {
                block.append((index + 1, line))
            }
        }
        closeBlock()
        flushPending()
        return output
    }

    /// Passages for text that has no lines of its own (JSON extraction),
    /// capped at `maxChars` like any other passage.
    static func unlinedChunks(_ texts: [String]) -> [TextChunk] {
        texts.flatMap { text -> [TextChunk] in
            stride(from: 0, to: text.count, by: maxChars).map { offset in
                let start = text.index(text.startIndex, offsetBy: offset)
                let end = text.index(start, offsetBy: maxChars, limitedBy: text.endIndex) ?? text.endIndex
                return TextChunk(text: String(text[start..<end]), startLine: 0, endLine: 0, headings: [])
            }
        }
    }

    /// Splits an over-long block into pieces of at most `maxChars`, at line
    /// boundaries where possible and inside a single over-long line otherwise.
    private static func split(_ block: [Line]) -> [[Line]] {
        var pieces: [[Line]] = []
        var current: [Line] = []
        var size = 0
        for line in block {
            if line.text.count > maxChars {
                if !current.isEmpty { pieces.append(current); current = []; size = 0 }
                var rest = Substring(line.text)
                while !rest.isEmpty {
                    pieces.append([(line.number, String(rest.prefix(maxChars)))])
                    rest = rest.dropFirst(maxChars)
                }
                continue
            }
            if size + line.text.count + 1 > maxChars, !current.isEmpty {
                pieces.append(current)
                current = []
                size = 0
            }
            current.append(line)
            size += line.text.count + 1
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static let typstHeading = try! NSRegularExpression(pattern: #"^(=+)\s+(.+?)\s*(<[^>]*>)?\s*$"#)
    private static let markdownHeading = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.+?)\s*#*\s*$"#)

    private static func heading(in line: String, style: HeadingStyle) -> (level: Int, title: String)? {
        let regex: NSRegularExpression
        switch style {
        case .typst: regex = typstHeading
        case .markdown: regex = markdownHeading
        case .none: return nil
        }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let marks = Range(match.range(at: 1), in: line),
              let title = Range(match.range(at: 2), in: line) else { return nil }
        return (line[marks].count, String(line[title].prefix(80)))
    }
}
