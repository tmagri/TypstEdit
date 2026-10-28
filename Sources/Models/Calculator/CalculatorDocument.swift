import Foundation

/// The on-disk format for saved calculator sessions (`.tcalc` files).
/// Versioned JSON: session modes, cached results (so reopening a file never
/// re-evaluates anything), and the stored variables as text — replayed
/// through the CAS when the file is opened so later entries keep working.
struct CalculatorDocument: Codable, Equatable, Sendable {
    /// Identifies the file type, mirroring how `.note` files self-describe.
    var kind: String = Self.documentKind
    var version: Int = Self.currentVersion
    var angle: CASAngleMode = .radians
    var exactMode: CASExactMode = .auto
    var displayDigits: Int = 12
    var variables: [CalculatorStoredVariable] = []
    var entries: [CalculatorEntry] = []

    static let documentKind = "typstedit.calculator.session"
    static let currentVersion = 1
    static let fileExtension = "tcalc"

    // MARK: - Disk I/O

    static func save(_ document: CalculatorDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Milliseconds, not ISO8601: opening a saved file must reproduce the
        // exact session, sub-second timestamps included.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            // timeIntervalSinceReferenceDate round-trips exactly; the 1970
            // offset loses bits to floating addition.
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> CalculatorDocument {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let interval = try container.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: interval)
        }
        do {
            return try decoder.decode(CalculatorDocument.self, from: data)
        } catch {
            // Tolerate files without the `kind` tag (future-proofing: older
            // or hand-edited documents).
            if let untagged = try? decoder.decode(UntaggedDocument.self, from: data) {
                return untagged.document
            }
            throw error
        }
    }

    /// Decode shim for documents missing `kind`/`version`.
    private struct UntaggedDocument: Codable {
        var angle: CASAngleMode?
        var exactMode: CASExactMode?
        var displayDigits: Int?
        var variables: [CalculatorStoredVariable]?
        var entries: [CalculatorEntry]?

        var document: CalculatorDocument {
            CalculatorDocument(
                angle: angle ?? .radians,
                exactMode: exactMode ?? .auto,
                displayDigits: displayDigits ?? 12,
                variables: variables ?? [],
                entries: entries ?? [])
        }
    }
}

/// Builds the Typst document for "Export as .typ": one display equation per
/// evaluated line, input and result joined by `=`, errors skipped (they have
/// nothing to show).
enum CalculatorExport {

    static func typst(sessionName: String, document: CalculatorDocument) -> String {
        var lines: [String] = []
        lines.append("// Exported by TypstEdit Calculator")
        lines.append("// Open the .tcalc file in TypstEdit to continue this calculation.")
        lines.append("")
        let title = sessionName.isEmpty ? "Calculator" : sessionName
        lines.append("= \(escapeText(title))")
        lines.append("")
        for entry in document.entries {
            if entry.isError { continue }
            // AI-fallback answers are prose (plus an exact result when the
            // model's interpretation was computable), not plain math.
            if let answer = entry.aiAnswer, !answer.isEmpty {
                lines.append("*\(escapeText(entry.input))*")
                lines.append("")
                if !entry.resultTypst.isEmpty {
                    lines.append("$ \(entry.resultTypst) $")
                }
                lines.append(escapeText(answer))
                lines.append("")
                continue
            }
            if !entry.inputTypst.isEmpty && !entry.resultTypst.isEmpty {
                lines.append("$ \(entry.inputTypst) = \(entry.resultTypst) $")
            } else if !entry.resultTypst.isEmpty {
                lines.append("$ \(entry.resultTypst) $")
            } else if !entry.inputTypst.isEmpty {
                lines.append("$ \(entry.inputTypst) $")
            } else if !entry.resultPlain.isEmpty {
                lines.append("$ \(escapeMathText(entry.resultPlain)) $")
            }
        }
        if !document.variables.isEmpty {
            lines.append("")
            lines.append("== Stored variables")
            lines.append("")
            for variable in document.variables {
                lines.append("$ \"\(escapeMathText(variable.name))\" := \(escapeMathText(variable.value)) $")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Titles go into markup text, so escape Typst's special characters.
    private static func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "*", with: "\\*")
    }

    private static func escapeMathText(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
