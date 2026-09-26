import Foundation

// MARK: - TypstMarkupParser.swift
// The markup-side scanner (hybrid .note dialect): headings, *bold*, backtick code
// spans (passed through untouched — Markdown understands them natively), $math$,
// backslash escapes, and `#`-regions handed to TypstCodeParser over the SAME
// scanner so both layers stay in lockstep. Only a markup-layer failure (not a bad
// snippet) throws out of parse(); a snippet that fails to PARSE leaks its raw
// source line as text so the document survives.

internal final class TypstParser {
    private let scanner: TypstScanner
    // lazy so the injected closures can capture self after initialization.
    private lazy var codeParser = TypstCodeParser(
        scanner: scanner,
        parseMarkupBracketBlock: { [unowned self] in try parseBracketBlock() },
        parseMarkupBracedBlock: { [unowned self] in try parseBracedBlock() }
    )

    init(input: String) {
        self.scanner = TypstScanner(input)
    }

    /// Parses a whole document. Throws only on markup-layer corruption, which the
    /// public API converts to "return the original source unchanged".
    func parse() throws -> TypstMarkupNode {
        var nodes: [TypstMarkupNode] = []
        while !scanner.isAtEnd {
            let startIndex = scanner.index
            if let node = try parseNext() {
                nodes.append(node)
            }
            // Guarantee progress if a stopping character (], }, )) is left unconsumed.
            if scanner.index == startIndex {
                nodes.append(.text(String(scanner.advance())))
            }
        }
        return .document(nodes)
    }

    // MARK: Node dispatch

    private func parseNext() throws -> TypstMarkupNode? {
        guard let character = scanner.peek() else { return nil }

        switch character {
        case "\\":
            _ = scanner.advance()
            if !scanner.isAtEnd { return .text(String(scanner.advance())) }
            return .text("\\")
        case "`":
            return parseCode()
        case "#":
            return try parseHashExpression()
        case "=":
            // A heading only starts at the beginning of a line; a mid-line `=`
            // (`a = b`) is plain text.
            if isAtLineStart() { return parseHeading() }
            return parseText()
        case "*":
            return parseBold()
        case "$":
            return parseMath()
        default:
            return parseText()
        }
    }

    // MARK: Hash regions

    private func parseHashExpression() -> TypstMarkupNode {
        let hashStart = scanner.index
        _ = scanner.advance()  // consume '#'
        do {
            let expr = try codeParser.parseHashRegion(context: .markupEmbed)
            return .code(expr: expr, rawSource: String(scanner.input[hashStart..<scanner.index]))
        } catch {
            // Snippet failed to parse: leak the rest of its line as raw text and
            // carry on — the document survives, matching the per-snippet policy.
            // The newline itself stays markup text.
            let raw = String(scanner.input[hashStart..<lineEnd(after: hashStart)])
                .trimmingCharacters(in: .whitespaces)
            scanner.index = lineEnd(after: hashStart)
            return .text(raw)
        }
    }

    private func lineEnd(after index: String.Index) -> String.Index {
        var cursor = index
        while cursor < scanner.input.endIndex,
              scanner.input[cursor] != "\n", scanner.input[cursor] != "\r" {
            cursor = scanner.input.index(after: cursor)
        }
        return cursor
    }

    private func consumeNewline() {
        if scanner.peek() == "\r" { _ = scanner.advance() }
        if scanner.peek() == "\n" { _ = scanner.advance() }
    }

    // MARK: Content blocks (injected into the code parser)

    /// `[ ... ]` — brackets consumed; the inner source re-parses as markup.
    private func parseBracketBlock() throws -> [TypstMarkupNode] {
        guard scanner.peek() == "[" else { return [] }
        let inner = captureBalanced(open: "[", close: "]")
        return try subparse(inner)
    }

    /// `{ ... }` as a statement body. Prose bodies stay markup (app dialect:
    /// `#if big { Big }` → "Big"), but bodies containing code punctuation are
    /// real-Typst code (`#if x { text(...) [#t] }`) and parse as a code block,
    /// falling back to markup when that fails.
    private func parseBracedBlock() throws -> [TypstMarkupNode] {
        guard scanner.peek() == "{" else { return [] }
        if bracedInnerLooksLikeCode {
            let start = scanner.index
            do {
                let statements = try codeParser.parseCodeBlock(consumingBrace: true)
                return [.code(expr: .codeBlock(statements),
                              rawSource: String(scanner.input[start..<scanner.index]))]
            } catch {
                scanner.index = start  // not code after all — markup fallback
            }
        }
        let inner = captureBalanced(open: "{", close: "}")
        return try subparse(inner)
    }

    /// Code punctuation in the balanced inner source (`(`, `=`, `#`, `"`) marks a
    /// braced body as code; prose (`{ Big }`, `{ Hello world }`) keeps markup
    /// spacing. A false positive only costs a backtracking parse attempt.
    private var bracedInnerLooksLikeCode: Bool {
        guard scanner.peek() == "{" else { return false }
        var cursor = scanner.input.index(after: scanner.index)
        var depth = 0
        while cursor < scanner.input.endIndex {
            let character = scanner.input[cursor]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                if depth == 0 { break }
                depth -= 1
            }
            if depth == 0 && "()=\"#".contains(character) { return true }
            cursor = scanner.input.index(after: cursor)
        }
        return false
    }

    /// Consumes a balanced `open`…`close` region and returns its inner source.
    /// Backtick code spans are raw: brackets inside them (`` `[0, 360)` ``) don't
    /// nest — matching real typst, which likewise ignores them when matching the
    /// closing bracket.
    private func captureBalanced(open: Character, close: Character) -> String {
        guard scanner.peek() == open else { return "" }
        var inner = ""
        _ = scanner.advance()  // consume the opener
        var nesting = 0
        while let character = scanner.peek() {
            if character == "`" {
                inner.append(contentsOf: consumeRawSpan())
            } else if character == open {
                nesting += 1
                inner.append(scanner.advance())
            } else if character == close {
                if nesting == 0 {
                    _ = scanner.advance()
                    break
                }
                nesting -= 1
                inner.append(scanner.advance())
            } else {
                inner.append(scanner.advance())
            }
        }
        return inner
    }

    /// Consumes a backtick code span (delimiter included) and returns it
    /// verbatim. Mirrors `parseCode`'s delimiter rules; an unterminated span
    /// runs to the end of input.
    private func consumeRawSpan() -> String {
        var raw = String(scanner.advance())  // consume the opening backtick
        let isBlock = scanner.hasPrefix("``")
        if isBlock {
            raw.append(scanner.advance())
            raw.append(scanner.advance())
        }
        while !scanner.isAtEnd {
            let current = scanner.advance()
            raw.append(current)
            if current == "`" {
                if isBlock {
                    if scanner.hasPrefix("``") {
                        raw.append(scanner.advance())
                        raw.append(scanner.advance())
                        break
                    }
                } else {
                    break
                }
            }
        }
        return raw
    }

    private func subparse(_ source: String) throws -> [TypstMarkupNode] {
        let inner = TypstParser(input: source)
        guard case .document(let nodes) = try inner.parse() else { return [] }
        return nodes
    }

    // MARK: Headings & bold

    /// True when only spaces/tabs separate the cursor from a newline or the start
    /// of input — the only places where `=` introduces a heading.
    private func isAtLineStart() -> Bool {
        var cursor = scanner.index
        while cursor > scanner.input.startIndex {
            let previous = scanner.input[scanner.input.index(before: cursor)]
            if previous == "\n" || previous == "\r" { return true }
            if previous != " " && previous != "\t" { return false }
            cursor = scanner.input.index(before: cursor)
        }
        return true
    }

    private func parseHeading() -> TypstMarkupNode {
        var level = 0
        while scanner.peek() == "=" {
            _ = scanner.advance()
            level += 1
        }
        // Only spaces and tabs, preserving newlines.
        while let character = scanner.peek(), character == " " || character == "\t" {
            _ = scanner.advance()
        }

        var content: [TypstMarkupNode] = []
        while !scanner.isAtEnd, scanner.peek() != "\n", scanner.peek() != "\r" {
            if scanner.peek() == "#" {
                content.append(parseHashExpression())
            } else if scanner.peek() == "*" {
                content.append(parseBold())
            } else if scanner.peek() == "`" {
                // Dispatched so the text run's backtick stop can't spin the
                // loop in place (`= Title `code` more`).
                content.append(parseCode())
            } else {
                appendTextRun(into: &content, stoppedBy: ["#", "*", "`", "\n", "\r"])
            }
        }
        consumeNewline()
        return .heading(level: level, content: content)
    }

    private func parseBold() -> TypstMarkupNode {
        _ = scanner.advance()  // consume '*'

        // Markdown-pasted strong (`**text**`, as sanitizer-emitted cells contain):
        // a doubled opener closes with a doubled closer, so consume the second
        // `*` and also swallow the closer's second `*` at the end.
        let isDoubled = scanner.peek() == "*"
        if isDoubled {
            _ = scanner.advance()
        }

        var content: [TypstMarkupNode] = []
        while !scanner.isAtEnd, scanner.peek() != "*" {
            if scanner.peek() == "#" {
                content.append(parseHashExpression())
            } else if scanner.peek() == "`" {
                // Dispatched so the text run's backtick stop can't spin the
                // loop in place (`*Target Steps Sequence (`seq0`):*` froze
                // the Markdown export here).
                content.append(parseCode())
            } else {
                // "#" must stop the run so the loop below dispatches it as a
                // snippet — otherwise `*bold #x*` leaks the `#` as text.
                appendTextRun(into: &content, stoppedBy: ["*", "#", "`"])
            }
        }
        if scanner.peek() == "*" {
            _ = scanner.advance()
            if isDoubled && scanner.peek() == "*" {
                _ = scanner.advance()
            }
        }
        return .bold(content: content)
    }

    /// Accumulates plain text until one of `stoppedBy` (or a line comment), then
    /// appends a `.text` node if anything was collected.
    private func appendTextRun(into content: inout [TypstMarkupNode], stoppedBy: Set<Character>) {
        var text = ""
        while let character = scanner.peek(), !stoppedBy.contains(character) {
            if scanner.hasPrefix("//") {
                while !scanner.isAtEnd, scanner.peek() != "\n", scanner.peek() != "\r" {
                    _ = scanner.advance()
                }
                break
            }
            text.append(scanner.advance())
        }
        if !text.isEmpty {
            content.append(.text(text))
        }
    }

    // MARK: Verbatim regions

    /// Backtick code spans/blocks pass through verbatim — Markdown renders them natively.
    private func parseCode() -> TypstMarkupNode {
        var content = String(scanner.advance())
        let isBlock = scanner.hasPrefix("``")
        if isBlock {
            content.append(scanner.advance())
            content.append(scanner.advance())
        }
        while !scanner.isAtEnd {
            let current = scanner.advance()
            content.append(current)
            if current == "`" {
                if isBlock {
                    if scanner.hasPrefix("``") {
                        content.append(scanner.advance())
                        content.append(scanner.advance())
                        break
                    }
                } else {
                    break
                }
            }
        }
        return .text(content)
    }

    private func parseMath() -> TypstMarkupNode {
        var content = String(scanner.advance())  // consume first '$'
        let isDisplay = scanner.peek() == "$"
        if isDisplay {
            content.append(scanner.advance())  // consume second '$'
        }
        while !scanner.isAtEnd {
            let current = scanner.advance()
            content.append(current)
            if current == "$" {
                if isDisplay {
                    if scanner.peek() == "$" {
                        content.append(scanner.advance())
                        break
                    }
                } else {
                    break
                }
            }
        }
        return .math(content)
    }

    // MARK: Plain text

    private func parseText() -> TypstMarkupNode {
        // Legacy behavior: a leading quoted run drops its quotes.
        if scanner.peek() == "\"" {
            _ = scanner.advance()
            var quoted = ""
            while let character = scanner.peek(), character != "\"" {
                quoted.append(scanner.advance())
            }
            if scanner.peek() == "\"" {
                _ = scanner.advance()
            }
            return .text(quoted)
        }

        var content: [TypstMarkupNode] = []
        // "=" is deliberately absent: mid-line `=` is ordinary text, and headings
        // are dispatched from parseNext only at line start. Newlines stop the run
        // so the next line's leading `=` is seen by parseNext at line start.
        appendTextRun(into: &content, stoppedBy: ["#", "*", "$", "`", "}", "]", ")", "\n", "\r"])
        return content.first ?? .text("")
    }
}
