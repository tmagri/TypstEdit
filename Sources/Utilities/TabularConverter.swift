import Foundation

/// Parses Delimiter-Separated Values (TSV, CSV, or custom delimiter)
/// and converts them into Typst `#table(...)` or GitHub Flavored Markdown table syntax.
public struct TabularConverter {

    /// Represents the detected table structure.
    public struct TableData: Equatable {
        public let rows: [[String]]
        public let columnCount: Int

        public init(rows: [[String]]) {
            self.rows = rows
            self.columnCount = rows.reduce(0) { max($0, $1.count) }
        }

        public var isEmpty: Bool {
            rows.isEmpty || columnCount == 0
        }
    }

    /// Tries to parse the text as tabular data (TSV, semicolon-separated, or CSV).
    /// Returns `nil` if the text does not appear to be structured tabular data.
    public static func parse(_ text: String) -> TableData? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Must have at least one line break or tab to qualify as tabular data
        let lines = splitLines(trimmed)
        guard !lines.isEmpty else { return nil }

        // First test for TSV: tabs are unambiguous indicators of tabular data
        if trimmed.contains("\t") {
            let parsed = parseDelimited(lines, delimiter: "\t")
            if isValidTable(parsed, minimumRows: 1, minimumCols: 2) {
                return parsed
            }
        }

        // Only multi-line content makes sense for CSV / semicolon auto-detection
        guard lines.count >= 2 else { return nil }

        // Test for Semicolon-separated values
        if lines.contains(where: { $0.contains(";") }) {
            let parsed = parseDelimited(lines, delimiter: ";")
            if isValidTable(parsed, minimumRows: 2, minimumCols: 2) {
                return parsed
            }
        }

        // Test for Comma-separated values
        if lines.contains(where: { $0.contains(",") }) {
            let parsed = parseDelimited(lines, delimiter: ",")
            if isValidTable(parsed, minimumRows: 2, minimumCols: 2) {
                return parsed
            }
        }

        return nil
    }

    /// Force parses the text as TSV or CSV (best effort with auto-detected delimiter).
    public static func parseForced(_ text: String, preferredDelimiter: Character? = nil) -> TableData? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lines = splitLines(trimmed)
        guard !lines.isEmpty else { return nil }

        let delim: Character
        if let preferred = preferredDelimiter {
            delim = preferred
        } else if trimmed.contains("\t") {
            delim = "\t"
        } else if lines.filter({ $0.contains(";") }).count > lines.filter({ $0.contains(",") }).count {
            delim = ";"
        } else {
            delim = ","
        }

        let parsed = parseDelimited(lines, delimiter: delim)
        guard !parsed.rows.isEmpty, parsed.columnCount >= 1 else { return nil }
        return parsed
    }

    /// Converts parsed tabular data into a Typst `#table(...)` expression.
    public static func toTypstTable(_ data: TableData, hasHeader: Bool = true) -> String {
        guard !data.rows.isEmpty, data.columnCount > 0 else { return "" }
        let cols = data.columnCount

        var out = "#table(\n"
        out += "  columns: \(cols),\n"

        var remainingRows = data.rows
        if hasHeader, let firstRow = remainingRows.first {
            var padded = firstRow
            while padded.count < cols { padded.append("") }
            out += "  table.header(\n"
            for cell in padded {
                out += "    \(cellBlock(cell)),\n"
            }
            out += "  ),\n"
            remainingRows.removeFirst()
        }

        for row in remainingRows {
            var padded = row
            while padded.count < cols { padded.append("") }
            var rowContent = "  "
            for cell in padded {
                rowContent += "\(cellBlock(cell)), "
            }
            out += rowContent.trimmingCharacters(in: CharacterSet(charactersIn: ", ")) + ",\n"
        }

        out += ")"
        return out
    }

    /// Converts parsed tabular data into a GitHub-Flavored Markdown table.
    public static func toMarkdownTable(_ data: TableData, hasHeader: Bool = true) -> String {
        guard !data.rows.isEmpty, data.columnCount > 0 else { return "" }
        let cols = data.columnCount

        var lines: [String] = []

        var headerRow: [String]
        var dataRows = data.rows

        if hasHeader, let first = dataRows.first {
            headerRow = first
            while headerRow.count < cols { headerRow.append("") }
            dataRows.removeFirst()
        } else {
            headerRow = (1...cols).map { "Column \($0)" }
        }

        // Header line
        let headerLine = "| " + headerRow.map { sanitizeMarkdownCell($0) }.joined(separator: " | ") + " |"
        lines.append(headerLine)

        // Separator line
        let separatorLine = "| " + (0..<cols).map { _ in "---" }.joined(separator: " | ") + " |"
        lines.append(separatorLine)

        // Data rows
        for row in dataRows {
            var padded = row
            while padded.count < cols { padded.append("") }
            let line = "| " + padded.map { sanitizeMarkdownCell($0) }.joined(separator: " | ") + " |"
            lines.append(line)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Private Helpers

    private static func cellBlock(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "[]" }
        // If already content bracketed
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return trimmed
        }
        var escaped = trimmed
        // Typst tracks [...] depth; double trailing backslash to prevent escaping ]
        while escaped.hasSuffix("\\") && !escaped.hasSuffix("\\\\") {
            escaped += "\\"
        }
        return "[" + escaped + "]"
    }

    private static func sanitizeMarkdownCell(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return " " }
        // In GFM tables, pipe characters must be escaped: \|
        let escapedPipes = trimmed.replacingOccurrences(of: "|", with: "\\|")
        // Also newlines within cells are not allowed in basic Markdown tables, replace with space or <br>
        return escapedPipes.replacingOccurrences(of: "\n", with: " ")
    }

    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    /// RFC 4180 style parser for a given delimiter supporting quoted fields with embedded newlines/quotes/delimiters.
    private static func parseDelimited(_ rawLines: [String], delimiter: Character) -> TableData {
        let fullText = rawLines.joined(separator: "\n")
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var insideQuotes = false

        var iterator = fullText.makeIterator()
        var char = iterator.next()

        while let c = char {
            if insideQuotes {
                if c == "\"" {
                    // Peek ahead for doubled quote
                    let next = iterator.next()
                    if next == "\"" {
                        currentField.append("\"")
                    } else {
                        insideQuotes = false
                        char = next
                        continue
                    }
                } else {
                    currentField.append(c)
                }
            } else {
                if c == "\"" {
                    insideQuotes = true
                } else if c == delimiter {
                    currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                    currentField = ""
                } else if c == "\r" {
                    // Handle CRLF
                    let next = iterator.next()
                    if next != "\n" {
                        char = next
                        currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                        currentField = ""
                        if !currentRow.isEmpty {
                            rows.append(currentRow)
                            currentRow = []
                        }
                        continue
                    }
                    currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                    currentField = ""
                    if !currentRow.isEmpty {
                        rows.append(currentRow)
                        currentRow = []
                    }
                } else if c == "\n" {
                    currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                    currentField = ""
                    if !currentRow.isEmpty {
                        rows.append(currentRow)
                        currentRow = []
                    }
                } else {
                    currentField.append(c)
                }
            }
            char = iterator.next()
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
            rows.append(currentRow)
        }

        // Filter out completely empty trailing rows
        let nonEmptyRows = rows.filter { row in
            row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        }

        return TableData(rows: nonEmptyRows)
    }

    private static func isValidTable(_ table: TableData, minimumRows: Int, minimumCols: Int) -> Bool {
        guard table.rows.count >= minimumRows, table.columnCount >= minimumCols else { return false }
        // Check for consistency: at least 70% of rows should match the max column count, or all have > 1 col
        let colCounts = table.rows.map { $0.count }
        let matching = colCounts.filter { $0 == table.columnCount }.count
        if matching >= max(1, table.rows.count * 7 / 10) {
            return true
        }
        // Alternatively, all rows have >= minimumCols
        return colCounts.allSatisfy { $0 >= minimumCols }
    }
}
