import Foundation

/// A diagnostic exactly as the `typst` CLI printed it: paths and line numbers
/// are not yet mapped back to the editor buffer (see `TypstCompiler`).
struct RawTypstDiagnostic: Equatable {
    struct Location: Equatable {
        /// Path as printed (usually relative to `--root`).
        var path: String
        /// 1-based line.
        var line: Int
        /// Column as printed. Not used for navigation: older Typst versions print
        /// it 0-based, newer ones 1-based. `caretColumn` is used instead.
        var column: Int
    }

    /// A `help: …` frame, e.g. "error occurred in this call of function `boom`".
    struct Frame: Equatable {
        var message: String
        var location: Location?
    }

    var severity: TypstError.Severity
    var message: String
    var location: Location?
    /// The first source line shown under the location.
    var snippet: String?
    /// 0-based character offset of the first `^` relative to `snippet`.
    var caretColumn: Int?
    var caretLength: Int?
    var hints: [String] = []
    var trace: [Frame] = []
}

/// Incremental parser for the diagnostic blocks the `typst` CLI prints:
///
///     error: unknown variable: a-b
///       ┌─ temp/h.typ:2:1
///       │
///     2 │ #a-b
///       │  ^^^
///       │
///       = hint: if you meant to use subtraction, try adding spaces …
///
///     help: error occurred in this call of function `boom`
///       ┌─ temp/main.typ:3:1
///       …
///
/// A blank line ends a block. A `help:` block that follows attaches to the
/// diagnostic before it as a trace frame. A diagnostic without a location line
/// (for example "source file must be contained in project root") is kept.
struct TypstDiagnosticParser {
    enum Event: Equatable {
        case none
        /// The primary location of `diagnostics[index]` was just parsed.
        case located(index: Int)
        /// A diagnostic block (or a `help:` frame) ended.
        case blockEnded
    }

    private enum Target {
        case none
        case primary
        case frame
    }

    private(set) var diagnostics: [RawTypstDiagnostic] = []
    private var target: Target = .none

    /// True while a diagnostic block is open (its lines belong to the parser).
    var isInsideBlock: Bool { target != .none }

    mutating func reset() {
        diagnostics = []
        target = .none
    }

    /// True when `line` opens a diagnostic block or a trace frame.
    static func startsBlock(_ line: String) -> Bool {
        line.hasPrefix("error: ") || line.hasPrefix("warning: ") || line.hasPrefix("help: ")
    }

    /// Parses complete compiler output in one pass (one-shot `typst compile`).
    static func parse(_ output: String) -> [RawTypstDiagnostic] {
        var parser = TypstDiagnosticParser()
        for line in output.components(separatedBy: "\n") {
            _ = parser.consume(line)
        }
        return parser.diagnostics
    }

    mutating func consume(_ rawLine: String) -> Event {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

        if line.hasPrefix("error: ") {
            diagnostics.append(RawTypstDiagnostic(severity: .error, message: String(line.dropFirst(7))))
            target = .primary
            return .none
        }
        if line.hasPrefix("warning: ") {
            diagnostics.append(RawTypstDiagnostic(severity: .warning, message: String(line.dropFirst(9))))
            target = .primary
            return .none
        }
        if line.hasPrefix("help: ") {
            guard !diagnostics.isEmpty else { return .none }
            diagnostics[diagnostics.count - 1].trace.append(.init(message: String(line.dropFirst(6))))
            target = .frame
            return .none
        }

        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard target != .none else { return .none }
            target = .none
            return .blockEnded
        }

        guard target != .none, !diagnostics.isEmpty else { return .none }
        let index = diagnostics.count - 1

        if let location = Self.parseLocation(line) {
            switch target {
            case .primary:
                guard diagnostics[index].location == nil else { return .none }
                diagnostics[index].location = location
                return .located(index: index)
            case .frame:
                let last = diagnostics[index].trace.count - 1
                if last >= 0, diagnostics[index].trace[last].location == nil {
                    diagnostics[index].trace[last].location = location
                }
                return .none
            case .none:
                return .none
            }
        }

        if let hint = Self.parseHint(line) {
            diagnostics[index].hints.append(hint)
            return .none
        }

        // Code and caret lines are only kept for the primary location.
        guard target == .primary else { return .none }

        if diagnostics[index].snippet == nil, let code = Self.parseCodeLine(line) {
            diagnostics[index].snippet = code
            return .none
        }
        if diagnostics[index].snippet != nil, diagnostics[index].caretColumn == nil,
           let caret = Self.parseCaretLine(line) {
            diagnostics[index].caretColumn = caret.column
            diagnostics[index].caretLength = caret.length
        }
        return .none
    }

    // MARK: - Line Parsers

    /// `  ┌─ temp/h.typ:2:1`
    private static func parseLocation(_ line: String) -> RawTypstDiagnostic.Location? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("┌─") else { return nil }
        let spec = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        // Split from the right: the path itself may contain ':'.
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let column = Int(parts[parts.count - 1]),
              let lineNumber = Int(parts[parts.count - 2]) else { return nil }
        let path = parts[0..<(parts.count - 2)].joined(separator: ":")
        return .init(path: path, line: lineNumber, column: column)
    }

    /// `  = hint: try adding spaces` (also accepts `= note:` / `= help:`).
    private static func parseHint(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("= ") else { return nil }
        let body = trimmed.dropFirst(2)
        for label in ["hint: ", "note: ", "help: "] where body.hasPrefix(label) {
            return String(body.dropFirst(label.count))
        }
        return String(body)
    }

    /// `53 │ - That reimplementation …` → the code after the gutter.
    private static func parseCodeLine(_ line: String) -> String? {
        guard let bar = line.firstIndex(of: "│") else { return nil }
        let gutter = line[..<bar].trimmingCharacters(in: .whitespaces)
        guard !gutter.isEmpty, gutter.allSatisfy(\.isNumber) else { return nil }
        var code = line[line.index(after: bar)...]
        if code.hasPrefix(" ") { code = code.dropFirst() }
        return String(code)
    }

    /// `   │      ^^^` → column of the first `^` (relative to the code) and span length.
    private static func parseCaretLine(_ line: String) -> (column: Int, length: Int)? {
        guard let bar = line.firstIndex(of: "│") else { return nil }
        guard line[..<bar].allSatisfy({ $0 == " " }) else { return nil }
        var rest = line[line.index(after: bar)...]
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        guard let caret = rest.firstIndex(of: "^") else { return nil }
        let leading = rest[..<caret]
        guard leading.allSatisfy({ $0 == " " }) else { return nil }
        let length = rest[caret...].prefix(while: { $0 == "^" }).count
        return (leading.count, length)
    }
}
