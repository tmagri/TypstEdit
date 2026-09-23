import Foundation

// MARK: - TypstToMarkdownConverter
//
// Converts a Typst (.typ) source string into a reasonable Markdown approximation.
// The conversion is intentionally conservative: constructs not recognised are kept
// as-is so the output stays readable rather than corrupted.
//
// For .md / .note files the content is already Markdown and this converter is a
// near-passthrough (it just strips any stray Typst-only syntax).

enum TypstToMarkdownRegex {
    static let numberedList = try! NSRegularExpression(pattern: "^[0-9]+\\. ")
    static let displayMath = try! NSRegularExpression(pattern: #"\$\s+([^$]+?)\s+\$"#)
    static let inlineMath = try! NSRegularExpression(pattern: #"\$([^$\n]+?)\$"#)
    static let bold = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)([^*\n]+?)(?<!\*)\*(?!\*)"#)
    static let underline = try! NSRegularExpression(pattern: #"#underline\[([^\]]*)\]"#)
    static let strike = try! NSRegularExpression(pattern: #"#strike\[([^\]]*)\]"#)
    static let highlight = try! NSRegularExpression(pattern: #"#highlight\[([^\]]*)\]"#)
    static let superscript = try! NSRegularExpression(pattern: #"#super\[([^\]]*)\]"#)
    static let `subscript` = try! NSRegularExpression(pattern: #"#sub\[([^\]]*)\]"#)
    static let linkWithText = try! NSRegularExpression(pattern: #"#link\("([^"]+)"\)\[([^\]]*)\]"#)
    static let linkBare = try! NSRegularExpression(pattern: #"#link\("([^"]+)"\)"#)
    static let labelRef = try! NSRegularExpression(pattern: #"@([A-Za-z0-9_:.-]+)"#)
    static let footnote = try! NSRegularExpression(pattern: #"#footnote\[([^\]]*)\]"#)
    static let vSpace = try! NSRegularExpression(pattern: #"#v\([^)]*\)"#)
    static let customFuncArgsBody = try! NSRegularExpression(pattern: #"#[A-Za-z0-9_.-]+\([^)]*\)\[([^\]]*)\]"#)
    static let customFuncBody = try! NSRegularExpression(pattern: #"#[A-Za-z0-9_.-]+\[([^\]]*)\]"#)
    static let customFuncArgsOnly = try! NSRegularExpression(pattern: #"#[A-Za-z0-9_.-]+\([^)]*\)"#)
    static let nonBreakingSpace = try! NSRegularExpression(pattern: #"(\w)~(\w)"#)
    static let consecutiveNewlines = try! NSRegularExpression(pattern: "\n\n\n+")
}

struct TypstToMarkdownConverter {

    // MARK: - Public entry point

    /// Convert `typstSource` to a Markdown string.
    /// - Parameter isAlreadyMarkdown: Pass `true` for `.md` / `.note` files — the
    ///   converter will skip Typst-specific transforms and only do minimal cleanup.
    static func convert(_ typstSource: String, isAlreadyMarkdown: Bool = false) -> String {
        if isAlreadyMarkdown {
            return minimalMarkdownCleanup(typstSource)
        }
        return convertTypstToMarkdown(typstSource)
    }

    // MARK: - Full Typst → Markdown pipeline

    private static func convertTypstToMarkdown(_ source: String) -> String {
        // Work line by line for block-level transforms, then do inline transforms.
        let lines = source.components(separatedBy: "\n")
        var output: [String] = []
        var i = 0

        func isDirective(_ text: String) -> Bool {
            text.hasPrefix("#set ") || text.hasPrefix("#show ") ||
            text.hasPrefix("#import ") || text.hasPrefix("#include ") ||
            text.hasPrefix("#let ")
        }

        // Consume the preamble (#set / #show rules, #import, #let) silently.
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if isDirective(trimmed) {
                var depth = 0
                repeat {
                    if i < lines.count {
                        let currentLine = lines[i]
                        depth += currentLine.reduce(0) {
                            if $1 == "{" || $1 == "(" || $1 == "[" { return $0 + 1 }
                            if $1 == "}" || $1 == ")" || $1 == "]" { return $0 - 1 }
                            return $0
                        }
                    }
                    i += 1
                } while i < lines.count && depth > 0
                continue
            }
            if trimmed.hasPrefix("//") || trimmed.isEmpty {
                i += 1
                continue
            }
            break
        }

        // Process the body
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // --- Skip pure Typst directives (including multi-line #let) ---
            if isDirective(trimmed) {
                var depth = 0
                repeat {
                    if i < lines.count {
                        let currentLine = lines[i]
                        depth += currentLine.reduce(0) {
                            if $1 == "{" || $1 == "(" || $1 == "[" { return $0 + 1 }
                            if $1 == "}" || $1 == ")" || $1 == "]" { return $0 - 1 }
                            return $0
                        }
                    }
                    i += 1
                } while i < lines.count && depth > 0
                continue
            }

            if trimmed.hasPrefix("// ") || trimmed == "//" {
                i += 1
                continue
            }

            // --- Fenced code blocks (``` ... ```) — pass through verbatim ---
            if trimmed.hasPrefix("```") {
                output.append(raw)
                i += 1
                while i < lines.count {
                    output.append(lines[i])
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```")
                        && lines[i].trimmingCharacters(in: .whitespaces) != trimmed {
                        i += 1
                        break
                    }
                    i += 1
                }
                continue
            }

            // --- Display math ($ ... $ spanning multiple lines) ---
            if trimmed == "$" || (trimmed.hasPrefix("$") && !trimmed.hasPrefix("$[") && trimmed.count == 1) {
                output.append("$$")
                i += 1
                while i < lines.count {
                    let ml = lines[i].trimmingCharacters(in: .whitespaces)
                    if ml == "$" {
                        output.append("$$")
                        i += 1
                        break
                    }
                    output.append(lines[i])
                    i += 1
                }
                continue
            }

            // --- Headings: = H1, == H2, === H3, etc. ---
            if let (level, text) = parseHeading(trimmed) {
                let hashes = String(repeating: "#", count: level)
                output.append("\(hashes) \(convertInline(text))")
                i += 1
                continue
            }

            // --- #pagebreak() → horizontal rule ---
            if trimmed == "#pagebreak()" || trimmed == "#pagebreak(weak: true)" {
                output.append("---")
                i += 1
                continue
            }

            // --- #line(length: ...) horizontal rule ---
            if trimmed.hasPrefix("#line(") {
                output.append("---")
                i += 1
                continue
            }

            // --- Vertical Space: #v(...) → <br> ---
            if trimmed.hasPrefix("#v(") {
                output.append("<br>")
                i += 1
                continue
            }

            // --- Bullet list item ---
            if trimmed.hasPrefix("- ") {
                let content = String(trimmed.dropFirst(2))
                output.append("- \(convertInline(content))")
                i += 1
                continue
            }

            // --- Numbered list: + item ---
            if trimmed.hasPrefix("+ ") {
                let content = String(trimmed.dropFirst(2))
                output.append("1. \(convertInline(content))")
                i += 1
                continue
            }

            // --- Numbered list: 1. item (already Markdown-compatible) ---
            if TypstToMarkdownRegex.numberedList.firstMatch(in: trimmed, options: [], range: NSRange(0..<trimmed.utf16.count)) != nil {
                output.append(convertInline(trimmed))
                i += 1
                continue
            }

            // --- Block quote ---
            if trimmed.hasPrefix("#quote[") || trimmed.hasPrefix("> ") {
                let inner = trimmed.hasPrefix("#quote[")
                    ? String(trimmed.dropFirst(7).dropLast(trimmed.hasSuffix("]") ? 1 : 0))
                    : String(trimmed.dropFirst(2))
                output.append("> \(convertInline(inner))")
                i += 1
                continue
            }

            // --- #table(...), #grid(...), or #figure(...) versions — multi-line block ---
            let isTableBlock = trimmed.hasPrefix("#table(") || trimmed.hasPrefix("#grid(") ||
                               trimmed.hasPrefix("#figure(table(") || trimmed.hasPrefix("#figure(grid(")
            if isTableBlock {
                // Collect all lines of the block by tracking parenthesis depth.
                var blockLines: [String] = [trimmed]
                var depth = trimmed.reduce(0) { $0 + ($1 == "(" ? 1 : $1 == ")" ? -1 : 0) }
                i += 1
                while i < lines.count && depth > 0 {
                    let bl = lines[i].trimmingCharacters(in: .whitespaces)
                    depth += bl.reduce(0) { $0 + ($1 == "(" ? 1 : $1 == ")" ? -1 : 0) }
                    blockLines.append(bl)
                    i += 1
                }
                let block = blockLines.joined(separator: " ")
                if let mdTable = parseTable(block) {
                    output.append("")
                    output.append(contentsOf: mdTable)
                    output.append("")
                }
                continue
            }

            // --- #figure(...) — extract image path & caption ---
            if trimmed.hasPrefix("#figure(") {
                if let mdFigure = parseFigure(trimmed) {
                    output.append(mdFigure)
                }
                i += 1
                // consume multi-line figure bodies
                if !trimmed.hasSuffix(")") {
                    while i < lines.count {
                        let fl = lines[i].trimmingCharacters(in: .whitespaces)
                        i += 1
                        if fl.hasSuffix(")") { break }
                    }
                }
                continue
            }

            // --- #image("path") standalone ---
            if trimmed.hasPrefix("#image(") {
                if let path = extractStringArg(from: trimmed, after: "#image(") {
                    output.append("![](\(path))")
                }
                i += 1
                continue
            }

            // --- Empty line ---
            if trimmed.isEmpty {
                output.append("")
                i += 1
                continue
            }

            // --- Regular paragraph — apply inline transforms ---
            output.append(convertInline(raw))
            i += 1
        }

        let rawResult = output.joined(separator: "\n")
        return TypstToMarkdownRegex.consecutiveNewlines.stringByReplacingMatches(
            in: rawResult,
            options: [],
            range: NSRange(0..<rawResult.utf16.count),
            withTemplate: "\n\n"
        )
    }

    // MARK: - Inline transforms

    /// Convert Typst inline markup within a single paragraph/line to Markdown.
    static func convertInline(_ text: String) -> String {
        var s = text

        // Strip Typst line comments
        if let range = s.range(of: " //") {
            s = String(s[s.startIndex..<range.lowerBound])
        }

        // Display math on a single line:  $ ... $
        s = replacePattern(s, regex: TypstToMarkdownRegex.displayMath) { m in "$$\(m[1])$$" }

        // Inline math: $expr$
        s = replacePattern(s, regex: TypstToMarkdownRegex.inlineMath) { m in "$\(m[1])$" }

        // Bold: *text*  (Typst) → **text** (Markdown)
        s = replacePattern(s, regex: TypstToMarkdownRegex.bold) { m in "**\(m[1])**" }

        // Underline: #underline[text] → text
        s = replacePattern(s, regex: TypstToMarkdownRegex.underline) { m in m[1] }

        // Strikethrough: #strike[text] → ~~text~~
        s = replacePattern(s, regex: TypstToMarkdownRegex.strike) { m in "~~\(m[1])~~" }

        // Highlight: #highlight[text] → ==text==
        s = replacePattern(s, regex: TypstToMarkdownRegex.highlight) { m in "==\(m[1])==" }

        // Superscript: #super[text] → <sup>text</sup>
        s = replacePattern(s, regex: TypstToMarkdownRegex.superscript) { m in "<sup>\(m[1])</sup>" }

        // Subscript: #sub[text] → <sub>text</sub>
        s = replacePattern(s, regex: TypstToMarkdownRegex.subscript) { m in "<sub>\(m[1])</sub>" }

        // Links: #link("url")[text] → [text](url)
        s = replacePattern(s, regex: TypstToMarkdownRegex.linkWithText) { m in "[\(m[2])](\(m[1]))" }
        
        // #link("url") with no label → <url>
        s = replacePattern(s, regex: TypstToMarkdownRegex.linkBare) { m in "<\(m[1])>" }

        // Refs: @label → *(ref: label)*
        s = replacePattern(s, regex: TypstToMarkdownRegex.labelRef) { m in "*[\(m[1])]*" }

        // Footnote: #footnote[text] → (text)
        s = replacePattern(s, regex: TypstToMarkdownRegex.footnote) { m in " (\(m[1]))" }

        // Vertical space: #v(1em) -> <br>
        s = replacePattern(s, regex: TypstToMarkdownRegex.vSpace) { _ in "<br>" }

        // Generic #func(args)[content] fallback — preserve content, strip function wrapper
        s = replacePattern(s, regex: TypstToMarkdownRegex.customFuncArgsBody) { m in m[1] }

        // Generic #func[content] fallback — preserve content, strip function wrapper
        s = replacePattern(s, regex: TypstToMarkdownRegex.customFuncBody) { m in m[1] }

        // Generic #func(args) fallback — remove completely unsupported standalone functions 
        // (Must run after specific ones like #link are processed)
        s = replacePattern(s, regex: TypstToMarkdownRegex.customFuncArgsOnly) { _ in "" }

        // Typst non-breaking space: ~  →  regular space
        s = replacePattern(s, regex: TypstToMarkdownRegex.nonBreakingSpace) { m in "\(m[1]) \(m[2])" }

        return s
    }

    // MARK: - Heading parser

    private static func parseHeading(_ trimmed: String) -> (Int, String)? {
        guard trimmed.hasPrefix("=") else { return nil }
        var level = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex && trimmed[idx] == "=" {
            level += 1
            idx = trimmed.index(after: idx)
        }
        guard level > 0, level <= 6, idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
        let text = String(trimmed[trimmed.index(after: idx)...])
        return (level, text)
    }

    // MARK: - Figure parser

    private static func parseFigure(_ line: String) -> String? {
        if let imagePath = extractStringArg(from: line, after: "image(") {
            var caption = ""
            if let capRange = line.range(of: "caption: [") {
                let after = line[capRange.upperBound...]
                if let endBracket = after.firstIndex(of: "]") {
                    caption = String(after[after.startIndex..<endBracket])
                }
            }
            return "![\(caption)](\(imagePath))"
        }
        return nil
    }

    // MARK: - Table / Grid parser

    private static func parseTable(_ block: String) -> [String]? {
        var src = block
        if src.hasPrefix("#figure(") {
            if let targetRange = src.range(of: "table(") ?? src.range(of: "grid(") {
                let fromTarget = String(src[targetRange.lowerBound...])
                src = "#" + fromTarget
                var depth = 0
                var endIdx = src.endIndex
                for idx in src.indices {
                    let ch = src[idx]
                    if ch == "(" { depth += 1 }
                    else if ch == ")" {
                        depth -= 1
                        if depth == 0 {
                            endIdx = src.index(after: idx)
                            break
                        }
                    }
                }
                src = String(src[src.startIndex..<endIdx])
            }
        }

        var columnCount = 0
        if let colRange = src.range(of: "columns:") {
            let after = src[colRange.upperBound...].trimmingCharacters(in: .whitespaces)
            if after.hasPrefix("(") {
                if let close = after.firstIndex(of: ")") {
                    let inner = String(after[after.index(after: after.startIndex)..<close])
                    columnCount = inner.components(separatedBy: ",").count
                }
            } else if let numEnd = after.firstIndex(where: { !$0.isNumber }) {
                columnCount = Int(String(after[after.startIndex..<numEnd])) ?? 0
            } else {
                columnCount = Int(after.trimmingCharacters(in: CharacterSet(charactersIn: ",) "))) ?? 0
            }
        }

        var cells: [String] = []
        var headerCells: [String]? = nil

        // table.header doesn't exist for grid, but checking for it is safe.
        if let headerRange = src.range(of: "table.header") {
            let afterHeader = src[headerRange.upperBound...]
            let hCells = extractBracketCells(from: String(afterHeader), stopAt: ",\n", maxUntilNonBracket: true)
            if !hCells.isEmpty {
                headerCells = hCells
                if columnCount == 0 { columnCount = hCells.count }
            }
        }

        cells = extractBracketCells(from: src, stopAt: nil, maxUntilNonBracket: false)

        if let hc = headerCells, !cells.isEmpty {
            let skip = min(hc.count, cells.count)
            cells = Array(cells.dropFirst(skip))
        }

        if columnCount == 0 {
            guard !cells.isEmpty else { return nil }
            columnCount = max(1, Int(Double(cells.count).squareRoot()))
        }

        var rows: [String] = []

        func makeRow(_ rowCells: [String]) -> String {
            let padded = (0..<columnCount).map { rowCells.indices.contains($0) ? convertInline(rowCells[$0]) : "" }
            return "| " + padded.joined(separator: " | ") + " |"
        }

        let separator = "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |"

        if let hc = headerCells {
            rows.append(makeRow(hc))
            rows.append(separator)
        }

        var cellIdx = 0
        while cellIdx < cells.count {
            let slice = Array(cells[cellIdx..<min(cellIdx + columnCount, cells.count)])
            if headerCells == nil && rows.isEmpty {
                // If it's a grid with no defined header, the first row acts as the Markdown table header anyway
                rows.append(makeRow(slice))
                rows.append(separator)
            } else {
                rows.append(makeRow(slice))
            }
            cellIdx += columnCount
        }

        return rows.isEmpty ? nil : rows
    }

    private static func extractBracketCells(
        from src: String,
        stopAt _: String?,
        maxUntilNonBracket: Bool
    ) -> [String] {
        var cells: [String] = []
        var i = src.startIndex
        while i < src.endIndex {
            let ch = src[i]
            if ch == "[" {
                var depth = 1
                var j = src.index(after: i)
                while j < src.endIndex && depth > 0 {
                    if src[j] == "[" { depth += 1 }
                    else if src[j] == "]" { depth -= 1 }
                    if depth > 0 { j = src.index(after: j) }
                }
                let inner = String(src[src.index(after: i)..<j])
                cells.append(inner)
                i = src.index(after: j)
            } else if maxUntilNonBracket && !ch.isWhitespace && ch != "," {
                break
            } else {
                i = src.index(after: i)
            }
        }
        return cells
    }

    // MARK: - Helpers

    private static func extractStringArg(from s: String, after prefix: String) -> String? {
        guard let start = s.range(of: prefix) else { return nil }
        let rest = s[start.upperBound...]
        guard let q1 = rest.firstIndex(of: "\"") else { return nil }
        let afterQ1 = rest.index(after: q1)
        guard let q2 = rest[afterQ1...].firstIndex(of: "\"") else { return nil }
        return String(rest[afterQ1..<q2])
    }

    private static func minimalMarkdownCleanup(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        lines = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !(t.hasPrefix("#set ") || t.hasPrefix("#show ") || t.hasPrefix("#import ") || t.hasPrefix("#let "))
        }
        lines = lines.map { convertInline($0) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Regex helper

    private static func replacePattern(
        _ s: String,
        regex: NSRegularExpression,
        replacement: ([String]) -> String
    ) -> String {
        let nsString = s as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var result = s
        var offset = 0

        let matches = regex.matches(in: s, options: [], range: fullRange)
        for match in matches {
            var groups: [String] = []
            for g in 0..<match.numberOfRanges {
                let r = match.range(at: g)
                if r.location != NSNotFound,
                   let swiftRange = Range(r, in: s) {
                    groups.append(String(s[swiftRange]))
                } else {
                    groups.append("")
                }
            }
            let rep = replacement(groups)
            let adjustedRange = NSRange(location: match.range.location + offset,
                                        length: match.range.length)
            let resultNS = result as NSString
            result = resultNS.replacingCharacters(in: adjustedRange, with: rep)
            offset += rep.utf16.count - match.range.length
        }
        return result
    }
}