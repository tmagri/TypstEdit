import Foundation
import CoreGraphics

/// Renders a `PDFImportedDocument` as Typst, Markdown or JSON.
///
/// The Typst output is meant to compile on the first try: all text is
/// escaped for markup, and anything uncertain (an untranscribed formula, an
/// irregular table) is emitted as its cropped image, with the recovered text
/// kept in a `TODO(import)` comment for the user to finish.
enum PDFImportEmitter {

    // MARK: - Typst

    static func typst(_ document: PDFImportedDocument) -> String {
        var out: [String] = []
        out.append("// Imported from \"\(document.sourceName)\" by TypstEdit.")
        out.append("// Search for TODO(import) to review formulas and tables that need a check.")
        out.append(pageSetup(document))
        // OCR layers can report implausible sizes; keep the default then.
        if (7...16).contains(document.bodyFontSize) {
            out.append("#set text(size: \(formatPoints(document.bodyFontSize)))")
        }
        out.append("#set par(justify: true)")
        // Justified text in narrow cells stretches its spaces.
        out.append("#show table: set par(justify: false)")
        out.append("")

        var outlineEmitted = false
        for page in document.pages {
            let contentWidth = textWidth(of: page)
            var index = 0
            let blocks = page.blocks
            while index < blocks.count {
                let block = blocks[index]
                if block.kind == .contents {
                    // A printed contents page: Typst rebuilds it from the headings.
                    if !outlineEmitted {
                        out.append("#outline()")
                        out.append("")
                        outlineEmitted = true
                    }
                    index += 1
                    continue
                }
                if case .listItem = block.kind {
                    var end = index
                    while end < blocks.count, case .listItem = blocks[end].kind { end += 1 }
                    out.append(typstList(blocks[index..<end]))
                    out.append("")
                    index = end
                    continue
                }
                if let rendered = typstBlock(block, contentWidth: contentWidth) {
                    out.append(rendered)
                    out.append("")
                }
                index += 1
            }
        }
        return out.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func typstBlock(_ block: PDFImportedBlock, contentWidth: CGFloat) -> String? {
        switch (block.kind, block.content) {
        case (.heading(let level), .text(let text)):
            return String(repeating: "=", count: level) + " " + escapeMarkup(text, atLineStart: false)
        case (.paragraph, .text(let text)), (.caption, .text(let text)):
            return escapeMarkup(text, atLineStart: true)
        case (.code(let language), .text(let text)):
            return fenced(text, language: language)
        case (_, .table(let table)):
            return typstTable(table, rect: block.rect, contentWidth: contentWidth)
        case (_, .figure(let figure)):
            return typstFigure(figure, rect: block.rect, contentWidth: contentWidth)
        case (_, .formula(let formula)):
            return typstFormula(formula, rect: block.rect)
        default:
            return nil
        }
    }

    /// One list. Bullets become `- item`. Decimal labels use Typst's explicit
    /// numbering (`3. item`), so a list continued from the previous page
    /// keeps its numbers. Other labels ("(IV)", "(a)") are kept as written
    /// in a list with no marker, so cross-references to them stay valid.
    static func typstList(_ items: ArraySlice<PDFImportedBlock>) -> String {
        let parsed = items.map(listLabel)
        let labelled = parsed.contains { $0?.number == nil && $0 != nil }
        var lines: [String] = []
        for (block, label) in zip(items, parsed) {
            guard case .listItem(let depth, _) = block.kind else { continue }
            let indent = String(repeating: "  ", count: depth)
            if let label, let number = label.number {
                lines.append(indent + "\(number). " + escapeMarkup(label.rest, atLineStart: false))
            } else if let label {
                lines.append(indent + "- " + escapeMarkup(label.label + " " + label.rest, atLineStart: false))
            } else {
                // In a marker-less (labelled) list a bullet item keeps its bullet.
                lines.append(indent + "- " + (labelled ? "• " : "") + escapeMarkup(block.content.plainText, atLineStart: false))
            }
        }
        let body = lines.joined(separator: "\n")
        return labelled ? "#[\n#set list(marker: [])\n\(body)\n]" : body
    }

    /// For an ordered item: its label ("3.", "(IV)"), the number when the
    /// label is plain decimal, and the text after it. `nil` for bullets.
    static func listLabel(_ block: PDFImportedBlock) -> (label: String, number: Int?, rest: String)? {
        guard case .listItem(_, let ordered) = block.kind, ordered else { return nil }
        let text = block.content.plainText
        guard let marker = PDFLayoutAnalyzer.listMarker(in: text) else { return nil }
        let label = String(text.prefix(marker.length)).trimmingCharacters(in: .whitespaces)
        let rest = String(text.dropFirst(marker.length)).trimmingCharacters(in: .whitespaces)
        let decimal = label.range(of: #"^\d+[.)]$"#, options: .regularExpression) != nil
        return (label, decimal ? marker.number : nil, rest)
    }

    static func typstTable(_ table: PDFTableData, rect: CGRect, contentWidth: CGFloat) -> String {
        let caption = table.caption.map { "  caption: [\(escapeMarkup(stripCaptionLabel($0), atLineStart: false))],\n" } ?? ""
        let grid = typstGrid(table)

        // Irregular table nobody fixed: show the original image, keep the
        // recovered cells in a comment, ready to uncomment.
        if table.isComplex && table.source != .ai, let image = table.imagePath {
            let width = widthPercent(rect.width, of: contentWidth)
            var text = "// TODO(import): complex table, shown as an image. Recovered cells below — check, then replace the image.\n"
            text += "#figure(\n  image(\"\(escapeString(image))\", width: \(width)%),\n\(caption)  kind: table,\n)"
            if !grid.isEmpty { text += "\n/*\n\(grid.replacingOccurrences(of: "*/", with: "* /"))\n*/" }
            return text
        }
        guard !grid.isEmpty else { return "" }
        let note = table.source == .ai ? "// TODO(import): table transcribed by AI — check against the PDF.\n" : ""
        if caption.isEmpty { return note + grid }
        // Inside `#figure(...)` we are already in code mode: no `#`.
        return note + "#figure(\n" + indent(String(grid.dropFirst()), by: 2) + ",\n" + caption + ")"
    }

    /// `#table(...)` with the header wrapped in `table.header`, and merged
    /// cells as `table.cell(rowspan:, colspan:)`.
    private static func typstGrid(_ table: PDFTableData) -> String {
        let rows = table.normalizedRows
        guard !rows.isEmpty else { return "" }
        let columns = table.columnCount
        if !table.spans.isEmpty { return typstSpannedGrid(table, rows: rows, columns: columns) }
        var lines = ["#table(", "  columns: \(columnSpec(table, columns: columns)),", "  align: left,"]
        let headerCount = min(table.headerRows, rows.count - 1)
        if headerCount > 0 {
            let cells = rows.prefix(headerCount).flatMap { $0 }.map(cell).joined(separator: ", ")
            lines.append("  table.header(\(cells)),")
        }
        for row in rows.dropFirst(max(headerCount, 0)) {
            lines.append("  " + row.map(cell).joined(separator: ", ") + ",")
        }
        lines.append(")")
        return lines.joined(separator: "\n")
    }

    /// The original column widths as `fr` shares when the rules gave them
    /// (Typst's automatic sizing squeezes wide text columns), else a count.
    private static func columnSpec(_ table: PDFTableData, columns: Int) -> String {
        guard table.columnEdges.count == columns + 1, columns > 1 else { return "\(columns)" }
        let widths = zip(table.columnEdges, table.columnEdges.dropFirst()).map { max(1, Int(($1 - $0).rounded())) }
        return "(" + widths.map { "\($0)fr" }.joined(separator: ", ") + ")"
    }

    /// Cells in row-major order. Typst places each cell in the next free
    /// position, so positions covered by an earlier span are skipped.
    private static func typstSpannedGrid(_ table: PDFTableData, rows: [[String]], columns: Int) -> String {
        var covered = Set<[Int]>()
        var spanAt: [[Int]: PDFCellSpan] = [:]
        for span in table.spans {
            spanAt[[span.row, span.column]] = span
            for r in span.row..<(span.row + span.rowSpan) {
                for c in span.column..<(span.column + span.columnSpan) where !(r == span.row && c == span.column) {
                    covered.insert([r, c])
                }
            }
        }
        // A header row must not be crossed by a span from below it.
        let header = table.headerRows > 0 && !table.spans.contains { $0.row == 0 && $0.rowSpan > 1 } ? 1 : 0
        var lines = ["#table(", "  columns: \(columnSpec(table, columns: columns)),", "  align: left + horizon,"]
        for (r, row) in rows.enumerated() {
            var cells: [String] = []
            for (c, text) in row.enumerated() where !covered.contains([r, c]) {
                if let span = spanAt[[r, c]] {
                    var arguments: [String] = []
                    if span.rowSpan > 1 { arguments.append("rowspan: \(span.rowSpan)") }
                    if span.columnSpan > 1 { arguments.append("colspan: \(span.columnSpan)") }
                    cells.append("table.cell(\(arguments.joined(separator: ", ")))\(cell(text))")
                } else {
                    cells.append(cell(text))
                }
            }
            guard !cells.isEmpty else { continue }
            lines.append(r < header ? "  table.header(\(cells.joined(separator: ", "))),"
                                    : "  " + cells.joined(separator: ", ") + ",")
        }
        lines.append(")")
        return lines.joined(separator: "\n")
    }

    private static func cell(_ text: String) -> String {
        "[\(escapeMarkup(text, atLineStart: false))]"
    }

    private static func typstFigure(_ figure: PDFFigure, rect: CGRect, contentWidth: CGFloat) -> String? {
        guard let path = figure.relativePath else { return nil }
        let width = widthPercent(rect.width, of: contentWidth)
        var text = "#figure(\n  image(\"\(escapeString(path))\", width: \(width)%),\n"
        if let caption = figure.caption {
            text += "  caption: [\(escapeMarkup(stripCaptionLabel(caption), atLineStart: false))],\n"
        }
        return text + ")"
    }

    private static func typstFormula(_ formula: PDFFormula, rect: CGRect) -> String? {
        if let typst = formula.typst, !typst.isEmpty {
            let note = formula.source == .ai ? "// TODO(import): formula transcribed by AI — check against the PDF.\n" : ""
            return note + "$ \(typst) $"
        }
        if let image = formula.imagePath {
            let source = formula.sourceText.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "*/", with: "* /")
            return "// TODO(import): formula shown as an image. Text layer: \(source.prefix(200))\n"
                + "#align(center, image(\"\(escapeString(image))\", width: \(formatPoints(rect.width))))"
        }
        // No crop and no math: keep the text so nothing is lost.
        return escapeMarkup(formula.sourceText.replacingOccurrences(of: "\n", with: " "), atLineStart: true)
    }

    // MARK: - Page Setup

    static func pageSetup(_ document: PDFImportedDocument) -> String {
        guard let size = document.pages.first?.size, size.width > 0 else { return "#set page(paper: \"a4\")" }
        let portrait = CGSize(width: min(size.width, size.height), height: max(size.width, size.height))
        let flipped = size.width > size.height ? ", flipped: true" : ""
        let papers: [(String, CGSize)] = [
            ("a4", CGSize(width: 595.28, height: 841.89)),
            ("us-letter", CGSize(width: 612, height: 792)),
            ("us-legal", CGSize(width: 612, height: 1008)),
            ("a5", CGSize(width: 419.53, height: 595.28)),
            ("a3", CGSize(width: 841.89, height: 1190.55)),
        ]
        if let paper = papers.first(where: { abs($0.1.width - portrait.width) < 4 && abs($0.1.height - portrait.height) < 4 }) {
            return "#set page(paper: \"\(paper.0)\"\(flipped))"
        }
        return "#set page(width: \(formatPoints(size.width)), height: \(formatPoints(size.height)))"
    }

    /// Width of the text block, estimated from where text actually sits.
    private static func textWidth(of page: PDFImportedPage) -> CGFloat {
        let textBlocks = page.blocks.filter { if case .text = $0.content { return true } else { return false } }
        let rects = (textBlocks.isEmpty ? page.blocks : textBlocks).map(\.rect)
        guard let minX = rects.map(\.minX).min(), let maxX = rects.map(\.maxX).max(), maxX - minX > 50 else {
            return max(page.size.width - 144, 100)
        }
        return maxX - minX
    }

    private static func widthPercent(_ width: CGFloat, of total: CGFloat) -> Int {
        let percent = Int((width / max(total, 1) * 100 / 5).rounded()) * 5
        return min(max(percent, 15), 100)
    }

    private static func formatPoints(_ value: CGFloat) -> String {
        let rounded = (value * 2).rounded() / 2
        return rounded == rounded.rounded() ? "\(Int(rounded))pt" : "\(rounded)pt"
    }

    /// "Figure 3: A chart" → "A chart"; Typst numbers figures itself.
    static func stripCaptionLabel(_ caption: String) -> String {
        let stripped = caption.replacingOccurrences(
            of: #"^(figure|fig\.|table|tab\.|chart|exhibit|listing|plate|scheme)\s*[0-9IVX]+[a-z]?\s*[.:|—–-]\s*"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        return stripped.isEmpty ? caption : stripped
    }

    private static func indent(_ text: String, by spaces: Int) -> String {
        let pad = String(repeating: " ", count: spaces)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { pad + $0 }.joined(separator: "\n")
    }

    // MARK: - Escaping

    /// Escapes text for Typst markup so PDF text can never be read as markup.
    static func escapeMarkup(_ text: String, atLineStart: Bool = true) -> String {
        var out = ""
        out.reserveCapacity(text.count + 8)
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        for (index, word) in words.enumerated() {
            if index > 0 { out += " " }
            // URLs stay intact: Typst links them and they contain no markup.
            if word.hasPrefix("http://") || word.hasPrefix("https://") {
                out += word.replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "[", with: "\\[")
                continue
            }
            var previous: Character?
            for character in word {
                switch character {
                case "\\", "#", "$", "*", "_", "`", "<", ">", "@", "[", "]", "~":
                    out += "\\\(character)"
                case "/" where previous == "/":
                    out += "\\/"
                case "*" where previous == "/":
                    out += "\\*"
                default:
                    out.append(character)
                }
                previous = character
            }
        }
        // Line-start markers would turn the text into a heading or list —
        // also inside `[...]` cells, where `[- 5]` is a list. Always escape.
        if let first = out.first {
            if "=-+/".contains(first) {
                out = "\\" + out
            } else if out.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil,
                      let dot = out.firstIndex(of: ".") {
                out.replaceSubrange(dot...dot, with: "\\.")
            }
        }
        return out
    }

    /// A fenced raw block, valid in both Typst and Markdown. The fence is
    /// longer than any backtick run inside, so the content cannot close it.
    static func fenced(_ text: String, language: String?) -> String {
        var longest = 0, current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + (language ?? "") + "\n" + text + "\n" + fence
    }

    static func escapeString(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Markdown

    static func markdown(_ document: PDFImportedDocument) -> String {
        // Each entry is one Markdown block; consecutive list items are joined
        // with a single newline so they stay one list.
        var entries: [(text: String, isListItem: Bool)] = []
        for block in document.blocks {
            switch (block.kind, block.content) {
            case (.heading(let level), .text(let text)):
                entries.append((String(repeating: "#", count: level) + " " + text, false))
            case (.code(let language), .text(let text)):
                entries.append((fenced(text, language: language), false))
            case (.contents, _):
                continue
            case (.listItem(let depth, _), .text(let text)):
                let indent = String(repeating: "  ", count: depth)
                if let label = listLabel(block) {
                    entries.append((indent + (label.number.map { "\($0). " } ?? "- \(label.label) ") + label.rest, true))
                } else {
                    entries.append((indent + "- " + text, true))
                }
            case (_, .text(let text)):
                entries.append((escapeMarkdownLineStart(text), false))
            case (_, .table(let table)):
                var parts: [String] = []
                if let caption = table.caption { parts.append("*\(caption)*\n") }
                if table.isComplex && table.source != .ai, let image = table.imagePath {
                    parts.append("![\(table.caption ?? "Table")](\(image))")
                } else {
                    parts.append(markdownTable(table))
                }
                entries.append((parts.joined(), false))
            case (_, .figure(let figure)):
                guard let path = figure.relativePath else {
                    // No image file (text-only reading): keep a marker.
                    entries.append(("[Figure\(figure.caption.map { ": \($0)" } ?? "")]", false))
                    continue
                }
                var text = "![\(figure.caption ?? "Figure")](\(path))"
                if let caption = figure.caption { text += "\n\n*\(caption)*" }
                entries.append((text, false))
            case (_, .formula(let formula)):
                if let latex = formula.latex {
                    entries.append(("$$\n\(latex)\n$$", false))
                } else if let image = formula.imagePath {
                    entries.append(("![formula](\(image))", false))
                } else {
                    entries.append((formula.sourceText, false))
                }
            }
        }
        var out = ""
        for (index, entry) in entries.enumerated() {
            if index > 0 { out += entry.isListItem && entries[index - 1].isListItem ? "\n" : "\n\n" }
            out += entry.text
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func markdownTable(_ table: PDFTableData) -> String {
        let rows = table.normalizedRows
        guard let first = rows.first else { return "" }
        let clean = { (cell: String) in cell.replacingOccurrences(of: "|", with: "\\|") }
        var lines = ["| " + first.map(clean).joined(separator: " | ") + " |",
                     "|" + String(repeating: " --- |", count: first.count)]
        for row in rows.dropFirst() { lines.append("| " + row.map(clean).joined(separator: " | ") + " |") }
        return lines.joined(separator: "\n")
    }

    private static func escapeMarkdownLineStart(_ text: String) -> String {
        if let first = text.first, "#>-+*".contains(first) { return "\\" + text }
        return text
    }

    // MARK: - JSON

    static func json(_ document: PDFImportedDocument) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(document), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text + "\n"
    }
}
