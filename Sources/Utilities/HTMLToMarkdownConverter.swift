import Foundation

/// Converts an HTML fragment or document (for example, rich text copied from a
/// web page or word processor) into GitHub-Flavored Markdown.
///
/// The converter is intentionally dependency-free and side-effect-free so it can
/// run on any thread and be unit-tested without a live pasteboard. The produced
/// Markdown is then fed through the existing Markdown→Typst sanitizer when the
/// target document is a `.typ` file, so a single HTML source can land as either
/// Markdown (`.md`/`.note`) or native Typst (`.typ`).
public enum HTMLToMarkdownConverter {

    /// Returns `true` when the string looks like it contains at least one HTML tag.
    /// Used to decide whether a rich `public.html` pasteboard flavor is worth
    /// converting instead of falling back to the plain-text flavor.
    public static func looksLikeHTML(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        return string.range(of: "<[a-zA-Z!/][^>]*>", options: .regularExpression) != nil
    }

    /// Converts HTML into Markdown. Never throws; malformed markup is recovered
    /// as best as possible.
    public static func convert(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        let nodes = HTMLParser.parse(html)
        let body = HTMLRenderer.renderBlocks(nodes)
        return normalize(body)
    }

    /// Collapses runs of blank lines, trims edge whitespace, and guarantees a
    /// single trailing newline so the result composes cleanly with the rest of
    /// the paste pipeline.
    private static func normalize(_ markdown: String) -> String {
        var out = markdown.replacingOccurrences(
            of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed + "\n"
    }
}

// MARK: - DOM

/// A minimal HTML tree node. Text nodes carry `text`; element nodes carry a tag,
/// attributes, and children.
private final class HTMLNode {
    enum Kind { case element, text }

    let kind: Kind
    var tag: String
    var attributes: [String: String]
    var children: [HTMLNode]
    var text: String

    init(element tag: String, attributes: [String: String]) {
        self.kind = .element
        self.tag = tag
        self.attributes = attributes
        self.children = []
        self.text = ""
    }

    init(text: String) {
        self.kind = .text
        self.tag = ""
        self.attributes = [:]
        self.children = []
        self.text = text
    }

    var isElement: Bool { kind == .element }
}

// MARK: - Parser

private enum HTMLParser {

    /// Elements whose content is raw text and must be skipped entirely (never
    /// surfaced as document content).
    private static let skippedContentTags: Set<String> = [
        "script", "style", "head", "title", "noscript", "template",
        "svg", "iframe", "object", "canvas", "audio", "video", "map"
    ]

    /// Void (self-closing) elements that never have children.
    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    private static let attributeRegex = try! NSRegularExpression(
        pattern: "([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*(?:=\\s*(\"[^\"]*\"|'[^']*'|[^\\s\"'>]+))?")

    static func parse(_ html: String) -> [HTMLNode] {
        let chars = Array(html)
        let count = chars.count
        var index = 0

        let root = HTMLNode(element: "#root", attributes: [:])
        var stack: [HTMLNode] = [root]

        while index < count {
            if chars[index] == "<" {
                // Comment: <!-- ... -->
                if matches(chars, at: index, "<!--") {
                    if let end = find(chars, from: index + 4, sequence: "-->") {
                        index = end + 3
                    } else {
                        break
                    }
                    continue
                }
                // Doctype / processing instruction: <! ... > / <? ... ?>
                if index + 1 < count && (chars[index + 1] == "!" || chars[index + 1] == "?") {
                    if let end = find(chars, from: index, sequence: ">") {
                        index = end + 1
                    } else {
                        break
                    }
                    continue
                }

                guard let close = endOfTag(chars, from: index) else {
                    // Unterminated tag: treat the remainder as text.
                    stack[stack.count - 1].children.append(HTMLNode(text: String(chars[index...])))
                    break
                }

                let rawTag = String(chars[index...close])
                index = close + 1

                let tag = parseTag(rawTag)

                if !tag.closing, skippedContentTags.contains(tag.name), !tag.selfClosing {
                    let closer = "</" + tag.name
                    if let end = find(chars, from: index, sequence: closer, caseInsensitive: true) {
                        if let gt = find(chars, from: end, sequence: ">") {
                            index = gt + 1
                        } else {
                            index = count
                        }
                    } else {
                        index = count
                    }
                    continue
                }

                if tag.closing {
                    if let position = stack.lastIndex(where: { $0.isElement && $0.tag == tag.name }), position > 0 {
                        stack.removeSubrange(position...)
                    }
                } else {
                    let node = HTMLNode(element: tag.name, attributes: tag.attributes)
                    stack[stack.count - 1].children.append(node)
                    if !tag.selfClosing && !voidTags.contains(tag.name) {
                        stack.append(node)
                    }
                }
            } else {
                var end = index
                while end < count && chars[end] != "<" { end += 1 }
                stack[stack.count - 1].children.append(HTMLNode(text: String(chars[index..<end])))
                index = end
            }
        }

        return root.children
    }

    private struct Tag {
        let closing: Bool
        let selfClosing: Bool
        let name: String
        let attributes: [String: String]
    }

    private static func parseTag(_ raw: String) -> Tag {
        var body = raw
        if body.hasPrefix("<") { body.removeFirst() }
        if body.hasSuffix(">") { body.removeLast() }

        var closing = false
        if body.hasPrefix("/") {
            closing = true
            body.removeFirst()
        }

        var selfClosing = false
        let trimmedEnd = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEnd.hasSuffix("/") {
            selfClosing = true
        }

        let nameEnd = body.firstIndex(where: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" || $0 == "_") })
            ?? body.endIndex
        let name = String(body[body.startIndex..<nameEnd]).lowercased()
        let rest = nameEnd == body.endIndex ? "" : String(body[nameEnd...])

        var attributes: [String: String] = [:]
        let ns = rest as NSString
        for match in attributeRegex.matches(in: rest, options: [], range: NSRange(0..<ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            var value = ""
            let valueRange = match.range(at: 2)
            if valueRange.location != NSNotFound {
                value = ns.substring(with: valueRange)
                if value.count >= 2,
                   (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value.removeFirst()
                    value.removeLast()
                }
            }
            attributes[key] = HTMLRenderer.decodeEntities(value)
        }

        return Tag(closing: closing, selfClosing: selfClosing, name: name, attributes: attributes)
    }

    // MARK: Character helpers

    private static func matches(_ chars: [Character], at index: Int, _ needle: String) -> Bool {
        let needleChars = Array(needle)
        guard index + needleChars.count <= chars.count else { return false }
        for offset in 0..<needleChars.count where chars[index + offset] != needleChars[offset] {
            return false
        }
        return true
    }

    /// Returns the index of the `>` that closes the tag starting at `start`,
    /// respecting quoted attribute values.
    private static func endOfTag(_ chars: [Character], from start: Int) -> Int? {
        var index = start + 1
        var quote: Character?
        while index < chars.count {
            let c = chars[index]
            if let active = quote {
                if c == active { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func find(_ chars: [Character], from start: Int, sequence: String, caseInsensitive: Bool = false) -> Int? {
        let needle = Array(caseInsensitive ? sequence.lowercased() : sequence)
        guard !needle.isEmpty else { return start }
        var index = start
        while index + needle.count <= chars.count {
            var matched = true
            for offset in 0..<needle.count {
                let c = chars[index + offset]
                let normalized = caseInsensitive ? Character(String(c).lowercased()) : c
                if normalized != needle[offset] {
                    matched = false
                    break
                }
            }
            if matched { return index }
            index += 1
        }
        return nil
    }
}

// MARK: - Renderer

private enum HTMLRenderer {

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "caption", "dd",
        "details", "dialog", "div", "dl", "dt", "fieldset", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hgroup", "hr", "html", "li", "main", "nav", "ol", "p",
        "pre", "section", "summary", "table", "tbody", "td", "tfoot", "th",
        "thead", "tr", "ul"
    ]

    /// Tags with no Markdown equivalent that the downstream Typst sanitizer
    /// understands as raw HTML. Keeping them verbatim preserves underline,
    /// highlight, subscript and superscript instead of silently dropping them.
    private static let preservedHTMLTags: Set<String> = ["u", "mark", "sub", "sup"]

    // MARK: Block layout

    static func renderBlocks(_ nodes: [HTMLNode]) -> String {
        renderFlow(nodes).joined(separator: "\n\n")
    }

    /// Groups a sequence of nodes into block strings: inline runs collapse into
    /// paragraphs, block elements render on their own.
    static func renderFlow(_ nodes: [HTMLNode]) -> [String] {
        var blocks: [String] = []
        var paragraph = ""

        func flush() {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(trimmed) }
            paragraph = ""
        }

        for node in nodes {
            if isBlock(node) {
                flush()
                let block = renderBlock(node)
                if !block.isEmpty { blocks.append(block) }
            } else {
                paragraph += renderInline(node)
            }
        }
        flush()
        return blocks
    }

    private static func isBlock(_ node: HTMLNode) -> Bool {
        node.isElement && blockTags.contains(node.tag)
    }

    private static func renderBlock(_ node: HTMLNode) -> String {
        switch node.tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(node.tag.last!)) ?? 1
            let content = renderInlineChildren(node).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? "" : String(repeating: "#", count: level) + " " + content

        case "p":
            return renderFlow(node.children).joined(separator: "\n\n")

        case "hr":
            return "---"

        case "pre":
            return renderPre(node)

        case "blockquote":
            let inner = renderBlocks(node.children)
            guard !inner.isEmpty else { return "" }
            return inner
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> " + $0 }
                .joined(separator: "\n")

        case "ul", "ol":
            return renderList(node)

        case "table":
            return renderTable(node)

        case "dl":
            return renderDefinitionList(node)

        case "li":
            return renderFlow(node.children).joined(separator: "\n\n")

        default:
            return renderBlocks(node.children)
        }
    }

    private static func renderPre(_ node: HTMLNode) -> String {
        var language = ""
        let codeNode = node.children.first(where: { $0.isElement && $0.tag == "code" })

        if let codeNode, let className = codeNode.attributes["class"] {
            for token in className.split(separator: " ") {
                if token.hasPrefix("language-") { language = String(token.dropFirst(9)); break }
                if token.hasPrefix("lang-") { language = String(token.dropFirst(5)); break }
            }
        }

        var code = rawText(codeNode ?? node)
        code = decodeEntities(code)
        if code.hasSuffix("\n") { code.removeLast() }
        return "```\(language)\n\(code)\n```"
    }

    private static func renderList(_ node: HTMLNode) -> String {
        let ordered = node.tag == "ol"
        var index = 0
        var items: [String] = []

        for child in node.children where child.isElement && child.tag == "li" {
            index += 1
            let marker = ordered ? "\(index). " : "- "
            let indent = String(repeating: " ", count: marker.count)
            let blocks = renderFlow(child.children)

            if blocks.isEmpty {
                items.append(marker.trimmingCharacters(in: .whitespaces))
                continue
            }

            // A list item that leads with a nested block (e.g. a sublist) gets the
            // marker on its own line so the nested content stays indented.
            let leadsWithBlock = child.children.first.map { isBlock($0) } ?? false
            if leadsWithBlock {
                var item = marker.trimmingCharacters(in: .whitespaces)
                for block in blocks {
                    for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                        item += "\n" + indent + line
                    }
                }
                items.append(item)
                continue
            }

            var item = marker + blocks[0]
            for block in blocks.dropFirst() {
                for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                    item += "\n" + indent + line
                }
            }
            items.append(item)
        }

        return items.joined(separator: "\n")
    }

    private static func renderDefinitionList(_ node: HTMLNode) -> String {
        var lines: [String] = []
        for child in node.children where child.isElement {
            switch child.tag {
            case "dt":
                let term = renderInlineChildren(child).trimmingCharacters(in: .whitespacesAndNewlines)
                if !term.isEmpty { lines.append(term) }
            case "dd":
                let definition = renderBlocks(child.children)
                if !definition.isEmpty {
                    let body = definition
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map { ": " + $0 }
                        .joined(separator: "\n")
                    lines.append(body)
                }
            default:
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func renderTable(_ node: HTMLNode) -> String {
        var rows: [[String]] = []

        func collect(_ element: HTMLNode) {
            for child in element.children where child.isElement {
                switch child.tag {
                case "tr":
                    var cells: [String] = []
                    for cell in child.children where cell.isElement && (cell.tag == "td" || cell.tag == "th") {
                        cells.append(renderInlineChildren(cell).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    if !cells.isEmpty { rows.append(cells) }
                case "thead", "tbody", "tfoot":
                    collect(child)
                default:
                    break
                }
            }
        }
        collect(node)

        guard !rows.isEmpty else { return "" }
        let columns = rows.map { $0.count }.max() ?? 0
        guard columns > 0 else { return "" }

        func pad(_ row: [String]) -> [String] {
            var padded = row
            while padded.count < columns { padded.append("") }
            return padded
        }

        var lines: [String] = []
        lines.append("| " + pad(rows[0]).map(sanitizeCell).joined(separator: " | ") + " |")
        lines.append("| " + (0..<columns).map { _ in "---" }.joined(separator: " | ") + " |")
        for row in rows.dropFirst() {
            lines.append("| " + pad(row).map(sanitizeCell).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private static func sanitizeCell(_ content: String) -> String {
        let collapsed = content.replacingOccurrences(of: "\n", with: " ")
        return collapsed.replacingOccurrences(of: "|", with: "\\|")
    }

    // MARK: Inline layout

    static func renderInlineChildren(_ node: HTMLNode) -> String {
        node.children.map(renderInline).joined()
    }

    private static func renderInline(_ node: HTMLNode) -> String {
        if !node.isElement {
            return escapeInlineText(collapseWhitespace(decodeEntities(node.text)))
        }

        switch node.tag {
        case "br":
            // Backslash hard break survives the whitespace cleanup in `normalize`
            // (a two-space break would have its trailing spaces stripped).
            return "\\\n"
        case "wbr":
            return ""
        case "img":
            return renderImage(node)
        case "a":
            return renderLink(node)
        case "strong", "b":
            return wrap("**", node)
        case "em", "i":
            return wrap("*", node)
        case "del", "s", "strike":
            return wrap("~~", node)
        case "code":
            return renderInlineCode(node)
        default:
            if preservedHTMLTags.contains(node.tag) {
                let inner = renderInlineChildren(node)
                return "<\(node.tag)>\(inner)</\(node.tag)>"
            }
            return renderInlineChildren(node)
        }
    }

    private static func wrap(_ marker: String, _ node: HTMLNode) -> String {
        let inner = renderInlineChildren(node).trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? "" : marker + inner + marker
    }

    private static func renderImage(_ node: HTMLNode) -> String {
        guard let src = node.attributes["src"], !src.isEmpty else { return "" }
        let alt = (node.attributes["alt"] ?? "").replacingOccurrences(of: "\n", with: " ")
        return "![\(escapeInlineText(alt))](\(escapeURL(src)))"
    }

    private static func renderLink(_ node: HTMLNode) -> String {
        let inner = renderInlineChildren(node).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let href = node.attributes["href"], !href.isEmpty else { return inner }
        if href.lowercased().hasPrefix("javascript:") { return inner }
        let label = inner.isEmpty ? escapeInlineText(href) : inner
        return "[\(label)](\(escapeURL(href)))"
    }

    private static func renderInlineCode(_ node: HTMLNode) -> String {
        var code = decodeEntities(rawText(node)).trimmingCharacters(in: .whitespacesAndNewlines)
        if code.isEmpty { return "" }
        var fence = "`"
        while code.contains(fence) { fence += "`" }
        let pad = (code.hasPrefix("`") || code.hasSuffix("`")) ? " " : ""
        code = code.replacingOccurrences(of: "\n", with: " ")
        return fence + pad + code + pad + fence
    }

    // MARK: Text helpers

    private static func rawText(_ node: HTMLNode) -> String {
        if !node.isElement { return node.text }
        return node.children.map(rawText).joined()
    }

    private static func collapseWhitespace(_ string: String) -> String {
        string.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Escapes the characters that would otherwise be interpreted as Markdown so
    /// literal text survives the round-trip through the parser.
    private static func escapeInlineText(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        var isLineStart = true
        for character in string {
            switch character {
            case "\\", "`", "*", "_", "[", "]", "~", "<":
                out.append("\\")
                out.append(character)
            case "#" where isLineStart:
                out.append("\\#")
            default:
                out.append(character)
            }
            isLineStart = (character == "\n")
        }
        return out
    }

    private static func escapeURL(_ url: String) -> String {
        var out = url.replacingOccurrences(of: " ", with: "%20")
        out = out.replacingOccurrences(of: "(", with: "%28")
        out = out.replacingOccurrences(of: ")", with: "%29")
        return out
    }

    // MARK: Entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}", "lsquo": "\u{2018}",
        "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "bull": "\u{2022}", "middot": "\u{00B7}", "deg": "\u{00B0}",
        "plusmn": "\u{00B1}", "times": "\u{00D7}", "divide": "\u{00F7}",
        "frac12": "\u{00BD}", "frac14": "\u{00BC}", "frac34": "\u{00BE}",
        "sup2": "\u{00B2}", "sup3": "\u{00B3}", "euro": "\u{20AC}",
        "pound": "\u{00A3}", "cent": "\u{00A2}", "yen": "\u{00A5}",
        "sect": "\u{00A7}", "para": "\u{00B6}", "dagger": "\u{2020}",
        "Dagger": "\u{2021}", "permil": "\u{2030}", "larr": "\u{2190}",
        "rarr": "\u{2192}", "harr": "\u{2194}", "infin": "\u{221E}",
        "ne": "\u{2260}", "le": "\u{2264}", "ge": "\u{2265}", "micro": "\u{00B5}"
    ]

    static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        let ns = string as NSString
        let matches = entityRegex.matches(in: string, options: [], range: NSRange(0..<ns.length))
        guard !matches.isEmpty else { return string }

        var out = ""
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                out += ns.substring(with: NSRange(cursor..<match.range.location))
            }
            let body = ns.substring(with: match.range(at: 1))
            out += decodeEntityBody(body) ?? ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            out += ns.substring(from: cursor)
        }
        return out
    }

    private static let entityRegex = try! NSRegularExpression(pattern: "&(#?[a-zA-Z0-9]+);")

    private static func decodeEntityBody(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = String(body.dropFirst())
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            if let value, let scalar = Unicode.Scalar(value) {
                return String(Character(scalar))
            }
            return nil
        }
        return namedEntities[body]
    }
}
