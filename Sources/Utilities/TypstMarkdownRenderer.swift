import Foundation

// MARK: - TypstMarkdownRenderer.swift
// Serializes TypstContent into Markdown, translating known Typst functions
// (table/grid, link, image, strike, quote, …) natively. Everything else leaks as
// visible `#name(args)` source, matching the long-standing behavior. Args are
// TYPED here (TypstArg), replacing the old string-scraping of rendered output.

final class MarkdownRenderer {
    func render(content: TypstContent) -> String {
        switch content {
        case .sequence(let children):
            return children.map { render(content: $0) }.joined()

        case .text(let text):
            var rendered = text
            rendered = MarkdownRegex.nonBreakingSpace.stringByReplacingMatches(
                in: rendered, options: [], range: NSRange(0..<rendered.utf16.count), withTemplate: " ")
            rendered = MarkdownRegex.labelRef.stringByReplacingMatches(
                in: rendered, options: [], range: NSRange(0..<rendered.utf16.count), withTemplate: "*[$1]*")
            rendered = MarkdownRegex.numberedListStart.stringByReplacingMatches(
                in: rendered, options: [], range: NSRange(0..<rendered.utf16.count), withTemplate: "1. ")
            rendered = MarkdownRegex.numberedListNewline.stringByReplacingMatches(
                in: rendered, options: [], range: NSRange(0..<rendered.utf16.count), withTemplate: "\n1. ")
            return rendered

        case .code(let code):
            // Code-style reprs render as inline code; double-backtick fence when the
            // payload itself contains a backtick (CommonMark rules).
            if code.contains("`") {
                return "`` \(code) ``"
            }
            return "`\(code)`"

        case .heading(let level, let children):
            let prefix = String(repeating: "#", count: level)
            let renderedContent = children.map { render(content: $0) }.joined()
            return "\(prefix) \(renderedContent)\n"

        case .bold(let children):
            return "**\(children.map { render(content: $0) }.joined())**"

        case .italic(let children):
            return "*\(children.map { render(content: $0) }.joined())*"

        case .math(let equation):
            return equation

        case .function(let name, let args):
            return renderFunction(name: name, args: args)
        }
    }

    // MARK: Function dispatch

    private func renderFunction(name: String, args: [TypstArg]) -> String {
        switch name {
        case "table", "grid":
            return renderTable(name: name, args: args)
        case "v":
            return "\n\n"
        case "pagebreak", "line":
            return "\n---\n\n"
        case "outline":
            return "\n[TOC]\n\n"
        case "link":
            return renderLink(args: args)
        case "image":
            return renderImage(args: args)
        case "strike":
            return "~~\(payload(args))~~"
        case "highlight":
            return "==\(payload(args))=="
        case "super":
            return "<sup>\(payload(args))</sup>"
        case "sub":
            return "<sub>\(payload(args))</sub>"
        case "underline":
            return "<u>\(payload(args))</u>"
        case "footnote":
            // Standard Markdown inline footnote extension.
            return "^[\(payload(args))]"
        case "quote":
            let quoted = payload(args)
                .components(separatedBy: .newlines)
                .map { "> \($0)" }
                .joined(separator: "\n")
            return "\n\(quoted)\n\n"
        case "align", "center":
            // Alignment words (`center`, `center + horizon`) have no Markdown
            // meaning; only the wrapped content renders.
            return payload(args.filter { !isAlignmentValue($0.value) })
        case "text":
            // Weight is the one text styling Markdown can express; sizes and
            // fills cannot survive the conversion. Only content-block
            // positionals are text — `#text(26pt, weight: "bold")[…]` must not
            // leak its size argument into the output.
            let body = args.filter { $0.name == nil }
                .filter { arg in
                    if case .content = arg.value { return true }
                    return false
                }
            if isBoldWeight(args) { return "**\(payload(body))**" }
            return payload(body)
        case "box", "block", "pad", "rect", "stack":
            return payload(args)
        default:
            let renderedArgs = args.map { argument in
                if let label = argument.name {
                    return "\(label): \(render(content: argument.value.display()))"
                }
                return render(content: argument.value.display())
            }.joined(separator: ", ")
            return "#\(name)(\(renderedArgs))"
        }
    }

    private func renderLink(args: [TypstArg]) -> String {
        let positional = args.filter { $0.name == nil }
        guard let first = positional.first else { return "" }
        let url = render(content: first.value.display()).replacingOccurrences(of: "\"", with: "")
        if positional.count > 1 {
            let label = render(content: positional[1].value.display())
            return "[\(label)](\(url))"
        }
        return "<\(url)>"
    }

    private func renderImage(args: [TypstArg]) -> String {
        var imagePath = ""
        for arg in args where arg.name == nil {
            if case .str(let path) = arg.value {
                imagePath = path
                break
            }
        }
        return "![image](\(imagePath))\n\n"
    }

    // MARK: Payload extraction

    /// Rendered positional arguments only — named arguments (stroke:, fill:, …)
    /// carry styling Markdown cannot express.
    private func payload(_ args: [TypstArg]) -> String {
        args.filter { $0.name == nil }
            .map { render(content: $0.value.display()) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `center`, `left + horizon`, `(top, right)` — layout alignment values that
    /// no Markdown construct can express. Sums degrade to concatenated strings
    /// (`centerhorizon`), so detection strips known words and separators.
    private func isAlignmentValue(_ value: TypstValue) -> Bool {
        switch value {
        case .str(let text):
            var remaining = Substring(text)
            var changed = true
            while changed {
                changed = false
                for word in ["left", "right", "top", "bottom", "center", "horizon", "start", "end"] {
                    if let range = remaining.range(of: word) {
                        remaining.removeSubrange(range)
                        changed = true
                    }
                }
            }
            return remaining.allSatisfy { "+ \t".contains($0) }
        case .array(let items):
            return !items.isEmpty && items.allSatisfy { isAlignmentValue($0) }
        default:
            return false
        }
    }

    /// `weight: "bold"` (or a heavier weight) on a `text` call.
    private func isBoldWeight(_ args: [TypstArg]) -> Bool {
        for arg in args where arg.name == "weight" {
            if case .str(let weight) = arg.value {
                return ["bold", "semibold", "black", "heavy", "extrabold"].contains(weight.lowercased())
            }
        }
        return false
    }

    // MARK: Tables

    private func renderTable(name: String, args: [TypstArg]) -> String {
        var columnCount = 1
        var cells: [TypstContent] = []

        func appendCells(from arguments: [TypstArg]) {
            for argument in arguments where argument.name == nil {
                cells.append(argument.value.display())
            }
        }

        for arg in args {
            if let label = arg.name {
                if label == "columns" {
                    switch arg.value {
                    case .int(let count): columnCount = max(1, Int(count))
                    case .array(let tracks): columnCount = max(1, tracks.count)
                    default: break
                    }
                }
                continue  // fill/stroke/inset/align have no Markdown meaning
            }

            switch arg.value {
            case .content(.function(let subName, let subArgs))
                where subName == "\(name).header" || subName == "table.header" || subName == "grid.header":
                appendCells(from: subArgs)
            case .content(.function(let subName, let subArgs))
                where subName == "\(name).row" || subName == "table.row" || subName == "grid.row"
                    || subName == "\(name).footer" || subName == "table.footer" || subName == "grid.footer":
                // Row/footer wrappers group cells — flatten their positionals in.
                appendCells(from: subArgs)
            case .content(.function(let subName, _))
                where subName == "\(name).hline" || subName == "table.hline" || subName == "grid.hline"
                    || subName == "\(name).vline" || subName == "table.vline" || subName == "grid.vline":
                continue  // rule lines carry no cells — skipping keeps columns aligned
            case .content(.function(let subName, let subArgs))
                where subName == "\(name).cell" || subName == "table.cell" || subName == "grid.cell":
                // table.cell(x, y, payload): the last positional is the payload.
                if let last = subArgs.last(where: { $0.name == nil }) {
                    cells.append(last.value.display())
                }
            case .array(let rowItems):
                cells.append(contentsOf: rowItems.map { $0.display() })
            default:
                cells.append(arg.value.display())
            }
        }

        guard !cells.isEmpty else { return "" }

        var markdown = ""
        var row: [String] = []
        var isHeader = true

        for (index, cell) in cells.enumerated() {
            var cellText = render(content: cell)
            cellText = cellText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            row.append(cellText)

            if row.count == columnCount || index == cells.count - 1 {
                while row.count < columnCount {
                    row.append("")
                }
                markdown += "| " + row.joined(separator: " | ") + " |\n"
                if isHeader {
                    let separator = Array(repeating: "---", count: columnCount).joined(separator: " | ")
                    markdown += "| " + separator + " |\n"
                    isHeader = false
                }
                row = []
            }
        }

        return markdown + "\n"
    }
}
