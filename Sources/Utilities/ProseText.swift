import Foundation
import NaturalLanguage

/// The prose of a Typst or Markdown source, with code, raw blocks, comments
/// and markup removed, and every piece still tied to its line number.
///
/// Shared by the writing checker, the repetition finder and the fact check:
/// each needs "the words a reader sees", not the source. Pure and
/// deterministic; the sentence split uses Apple's on-device `NLTokenizer`.
enum ProseText {

    enum Kind: Equatable, Sendable {
        case paragraph
        case heading
        /// A list item or a table cell: its own sentence unit.
        case item
    }

    struct Line: Equatable, Sendable {
        /// 1-based line in the source.
        let number: Int
        let text: String
        let kind: Kind
    }

    /// How inline code and math appear in the cleaned text.
    enum Inline: Sendable {
        /// One placeholder word each (`CODE`, `MATH`) — for counting
        /// sentence length, where a formula is one unit.
        case placeholder
        /// Their content kept — for the fact check, where `$x = 2$` holds
        /// a fact.
        case keep
    }

    // MARK: Lines

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
    private static let labelRegex = regex("<[\\p{L}\\p{N}_][\\p{L}\\p{N}_\\-:.]*>")
    private static let inlineRawRegex = regex("`([^`]*)`")
    private static let mathRegex = regex("\\$([^$]*)\\$")
    /// `#name(args)` / `#name` inline code; a `[content]` after it survives.
    private static let inlineCodeRegex = regex("#[A-Za-z][\\w.-]*(?:\\((?:[^()]|\\([^()]*\\))*\\))?")
    private static let emphasisRegex = regex("(?<![\\p{L}\\p{N}])_([^_\\n]+)_(?![\\p{L}\\p{N}])")
    private static let listMarkerRegex = regex("^(?:[-+*]|\\d+[.)])\\s+")
    private static let termMarkerRegex = regex("^/\\s+([^:]+):\\s*")

    /// Prose lines of `source`. `isMarkdown` switches heading/code rules:
    /// in Markdown `# Title` is a heading; in Typst a line starting with
    /// `#name` is code.
    static func lines(in source: String, isMarkdown: Bool = false, inline: Inline = .placeholder) -> [Line] {
        let rawLines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [Line] = []
        var inFence = false
        var inBlockComment = false
        var inHTMLComment = false
        var codeDepth = 0 // open brackets of a multi-line `#code(…)` line

        for (index, raw) in rawLines.enumerated() {
            let number = index + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            if isMarkdown {
                if inHTMLComment { if trimmed.contains("-->") { inHTMLComment = false }; continue }
                if trimmed.hasPrefix("<!--") { inHTMLComment = !trimmed.contains("-->"); continue }
            }

            var line = stripComments(raw, inBlockComment: &inBlockComment)
            var stripped = line.trimmingCharacters(in: .whitespaces)

            // The rest of a multi-line code call (`#figure(\n…\n)`).
            if codeDepth > 0 {
                codeDepth = max(0, codeDepth + bracketBalance(stripped))
                continue
            }
            guard !stripped.isEmpty else { continue }

            // Headings.
            if DocumentOutline.headingLevel(line) != nil {
                let title = clean(DocumentOutline.title(of: line), inline: inline)
                if !title.isEmpty { result.append(Line(number: number, text: title, kind: .heading)) }
                continue
            }
            // Typst code lines: `#set …`, `#let …`, `#figure(…)`.
            if !isMarkdown, stripped.hasPrefix("#"), stripped.dropFirst().first?.isLetter == true {
                codeDepth = max(0, bracketBalance(stripped))
                continue
            }
            if stripped.allSatisfy({ ")]}".contains($0) || $0 == " " }) { continue }

            // Markdown tables: every cell is its own unit.
            if isMarkdown, stripped.hasPrefix("|") {
                let cells = stripped.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue } // separator row
                for cell in cells where !cell.isEmpty {
                    let text = clean(cell, inline: inline)
                    if !text.isEmpty { result.append(Line(number: number, text: text, kind: .item)) }
                }
                continue
            }

            // List and term items.
            var kind = Kind.paragraph
            let range = NSRange(location: 0, length: (stripped as NSString).length)
            if let match = listMarkerRegex.firstMatch(in: stripped, range: range) {
                stripped = (stripped as NSString).substring(from: match.range.upperBound)
                kind = .item
            } else if !isMarkdown, let match = termMarkerRegex.firstMatch(in: stripped, range: range),
                      let termRange = Range(match.range(at: 1), in: stripped) {
                stripped = String(stripped[termRange]) + ": " + (stripped as NSString).substring(from: match.range.upperBound)
                kind = .item
            }
            line = stripped
            let text = clean(line, inline: inline, isMarkdown: isMarkdown)
            if !text.isEmpty { result.append(Line(number: number, text: text, kind: kind)) }
        }
        return result
    }

    /// Markup removed from one line of prose.
    static func clean(_ line: String, inline: Inline, isMarkdown: Bool = false) -> String {
        var text = line
        func replace(_ regex: NSRegularExpression, with template: String) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
        }
        switch inline {
        case .placeholder:
            replace(inlineRawRegex, with: "CODE")
            replace(mathRegex, with: "MATH")
        case .keep:
            replace(inlineRawRegex, with: "$1")
            replace(mathRegex, with: "$1")
        }
        replace(labelRegex, with: "")
        if !isMarkdown {
            replace(inlineCodeRegex, with: "")
            // Typst dash shorthands, so dash rules see real dashes.
            text = text.replacingOccurrences(of: "---", with: "—").replacingOccurrences(of: "--", with: "–")
            text = text.replacingOccurrences(of: "~", with: " ")
            if text.hasSuffix("\\") { text.removeLast() }
        }
        replace(emphasisRegex, with: "$1")
        text = text.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `line` without `//` and `/* */` comments. `//` after `:` is a URL.
    static func stripComments(_ line: String, inBlockComment: inout Bool) -> String {
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

    /// Opened minus closed brackets, ignoring those inside strings.
    private static func bracketBalance(_ text: String) -> Int {
        var balance = 0
        var inString = false
        var previous: Character?
        for character in text {
            if character == "\"", previous != "\\" { inString.toggle() }
            if !inString {
                if "([{".contains(character) { balance += 1 }
                if ")]}".contains(character) { balance -= 1 }
            }
            previous = character
        }
        return balance
    }

    // MARK: Paragraphs and sentences

    /// Consecutive paragraph lines joined, with a map back to line numbers.
    /// Headings and items are paragraphs of their own.
    struct Paragraph: Equatable, Sendable {
        let kind: Kind
        let text: String
        /// (character offset in `text`, source line), ascending.
        let lineStarts: [Int: Int]
        let startLine: Int
        let endLine: Int

        /// The source line holding the character at `offset`.
        func line(at offset: Int) -> Int {
            var best = startLine
            for (start, line) in lineStarts where start <= offset && line > best { best = line }
            return best
        }
    }

    static func paragraphs(from lines: [Line]) -> [Paragraph] {
        var result: [Paragraph] = []
        var text = ""
        var starts: [Int: Int] = [:]
        var first = 0
        var last = 0
        func flush() {
            guard !text.isEmpty else { return }
            result.append(Paragraph(kind: .paragraph, text: text, lineStarts: starts, startLine: first, endLine: last))
            text = ""
            starts = [:]
        }
        for line in lines {
            if line.kind != .paragraph {
                flush()
                result.append(Paragraph(kind: line.kind, text: line.text, lineStarts: [0: line.number],
                                        startLine: line.number, endLine: line.number))
                continue
            }
            // A gap (blank or code line) ends the paragraph.
            if !text.isEmpty, line.number > last + 1 { flush() }
            if text.isEmpty { first = line.number } else { text += " " }
            starts[(text as NSString).length] = line.number
            text += line.text
            last = line.number
        }
        flush()
        return result
    }

    struct Sentence: Equatable, Sendable {
        let text: String
        let line: Int
        let kind: Kind
    }

    /// Sentences of every paragraph, in order. Items and headings are one
    /// sentence each unless they contain several.
    static func sentences(in paragraphs: [Paragraph]) -> [Sentence] {
        let tokenizer = NLTokenizer(unit: .sentence)
        var result: [Sentence] = []
        for paragraph in paragraphs {
            tokenizer.string = paragraph.text
            tokenizer.enumerateTokens(in: paragraph.text.startIndex..<paragraph.text.endIndex) { range, _ in
                let sentence = paragraph.text[range].trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty {
                    let offset = NSRange(range, in: paragraph.text).location
                    result.append(Sentence(text: sentence, line: paragraph.line(at: offset), kind: paragraph.kind))
                }
                return true
            }
        }
        return result
    }

    /// Whitespace words that contain a letter or digit.
    static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    /// Number of words, also for scripts written without spaces (Chinese,
    /// Japanese, Thai), where `NLTokenizer` finds the word boundaries.
    static func wordCount(_ text: String) -> Int {
        ProseLanguage.needsTokenizer(text) ? ProseLanguage.words(text).count : words(text).count
    }

    /// Prose files the writing tools read.
    static func isProseFile(_ path: String) -> Bool {
        ["typ", "md", "markdown", "txt"].contains((path as NSString).pathExtension.lowercased())
    }

    static func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }
}
