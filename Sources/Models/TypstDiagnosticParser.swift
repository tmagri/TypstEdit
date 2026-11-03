import Foundation

/// A diagnostic exactly as the `typst` CLI printed it: paths and line numbers
/// are not yet mapped back to the editor buffer (see `TypstCompiler`).
struct RawTypstDiagnostic: Equatable {
    struct Location: Equatable {
        /// Path as printed (usually relative to `--root`). `<stdin>` for stdin.
        var path: String
        /// 1-based line.
        var line: Int
        /// Column as printed. Not used for navigation: older Typst versions print
        /// it 0-based, newer ones 1-based. `caretColumn` is used instead.
        var column: Int
    }

    /// One call-site frame Typst printed under a diagnostic, e.g.
    /// "while calling `boom`" at the line that called it.
    struct Frame: Equatable {
        var message: String
        var location: Location?
        /// The source line Typst printed under the frame, e.g. `boom(2)`.
        var snippet: String?
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

/// Incremental parser for the diagnostic blocks the `typst` CLI prints.
///
/// Typst 0.13+ (current: 0.15) prints the call chain as its own paragraphs
/// after the primary block:
///
///     error: cannot add integer and string
///       ┌─ nested.typ:1:16
///       │
///     1 │ #let inner(x) = x + "s"
///       │                 ^^^^^^^
///
///       while calling `inner` at nested.typ:2:17
///         inner(y)
///       while calling `outer` at nested.typ:4:1
///         outer(1)
///
/// Older versions printed `help: error occurred in this call of function `x``
/// with its own `┌─` location line. Both shapes are parsed here, because the
/// app ships an updatable compiler and must understand whichever one it finds.
///
/// A blank line ends a diagnostic block. Trace frames that follow a blank line
/// still attach to the diagnostic before them (that is where Typst puts them),
/// which is why the last diagnostic stays addressable after a block ends.
struct TypstDiagnosticParser {
    enum Event: Equatable {
        case none
        /// The primary location of `diagnostics[index]` was just parsed.
        case located(index: Int)
        /// A trace frame was attached to `diagnostics[index]`; the batch should
        /// be republished even though its primary block already ended.
        case updated(index: Int)
        /// A diagnostic block (or a `help:` frame) ended.
        case blockEnded
    }

    private enum Target {
        case none
        /// Inside a diagnostic's own block (`error:` / `warning:`).
        case primary
        /// Inside a legacy `help: …` frame, waiting for its `┌─` line.
        case frame
        /// Inside a 0.13+ `while calling … at …` frame, waiting for its code line.
        case frameSnippet
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
        let text = stripANSI(line)
        return text.hasPrefix("error: ")
            || text.hasPrefix("warning: ")
            || text.hasPrefix("help: ")
            || parseTraceHeader(text) != nil
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
        let text = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        let line = Self.stripANSI(text)

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

        // Typst 0.13+: `while calling `boom` at lib/helper.typ:2:17`, printed
        // after the primary block's blank line, so it is matched before the
        // block-open guard and attaches to the last diagnostic.
        if let frame = Self.parseTraceHeader(line) {
            guard !diagnostics.isEmpty else { return .none }
            let index = diagnostics.count - 1
            diagnostics[index].trace.append(.init(message: frame.message, location: frame.location))
            target = .frameSnippet
            return .updated(index: index)
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
            case .frameSnippet, .none:
                return .none
            }
        }

        if let hint = Self.parseHint(line) {
            diagnostics[index].hints.append(hint)
            return .none
        }

        // The code line printed under a `while calling …` frame.
        if target == .frameSnippet {
            let last = diagnostics[index].trace.count - 1
            if last >= 0, diagnostics[index].trace[last].snippet == nil {
                let code = String(line.drop(while: { $0 == " " }))
                if !code.isEmpty {
                    diagnostics[index].trace[last].snippet = code
                }
            }
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

    /// Removes ANSI SGR sequences, so `--color always` output parses the same
    /// way as the default pipe output.
    static func stripANSI(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        return ansiRegex.stringByReplacingMatches(
            in: line, options: [], range: NSRange(0..<line.utf16.count), withTemplate: "")
    }

    private static let ansiRegex = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")

    /// `  ┌─ temp/h.typ:2:1`
    private static func parseLocation(_ line: String) -> RawTypstDiagnostic.Location? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("┌─") else { return nil }
        let spec = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return parseLocationSpec(String(spec))
    }

    /// `lib/helper.typ:2:17` → location. Split from the right: paths may contain ':'.
    private static func parseLocationSpec(_ spec: String) -> RawTypstDiagnostic.Location? {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let column = Int(parts[parts.count - 1]),
              let lineNumber = Int(parts[parts.count - 2]) else { return nil }
        let path = parts[0..<(parts.count - 2)].joined(separator: ":")
        guard !path.isEmpty else { return nil }
        return .init(path: path, line: lineNumber, column: column)
    }

    /// `while calling `boom` at lib/helper.typ:2:17`
    private static func parseTraceHeader(_ line: String) -> (message: String, location: RawTypstDiagnostic.Location)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = "while calling `"
        guard trimmed.hasPrefix(prefix),
              let separator = trimmed.range(of: "` at ", options: .backwards) else { return nil }
        let nameStart = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        guard nameStart <= separator.lowerBound else { return nil }
        let name = String(trimmed[nameStart..<separator.lowerBound])
        let spec = String(trimmed[separator.upperBound...])
        guard let location = parseLocationSpec(spec) else { return nil }
        return ("while calling `\(name)`", location)
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

// MARK: - Stable Diagnostic Codes

/// Turns Typst's prose messages into a stable slug an agent can branch on.
///
/// Typst has no diagnostic codes in its CLI output (see typst/typst#6059, still
/// open), and the wording changes between releases ("cannot add integer and
/// string" → "cannot add string and integer" depending on operand order). A
/// slug derived from the leading phrase survives rewording of the details, so
/// tooling can match "this is an unknown-variable error" without string games.
enum TypstDiagnosticCode {
    /// Ordered: the first matching prefix wins.
    private static let rules: [(prefix: String, code: String, docs: String?)] = [
        ("unknown variable", "unknown-variable", "scripting/#bindings"),
        ("unknown font family", "unknown-font", "text/#parameters_font"),
        ("unknown argument", "unknown-argument", nil),
        ("unexpected argument", "unexpected-argument", nil),
        ("missing argument", "missing-argument", nil),
        ("expected expression", "expected-expression", nil),
        ("expected comma", "expected-comma", nil),
        ("expected semicolon or line break", "expected-semicolon", nil),
        ("expected pattern", "expected-pattern", nil),
        ("expected ", "type-mismatch", nil),
        ("unclosed delimiter", "unclosed-delimiter", nil),
        ("unclosed raw text", "unclosed-raw", nil),
        ("unclosed string", "unclosed-string", nil),
        ("unclosed block comment", "unclosed-comment", nil),
        ("unmatched closing", "unmatched-closing", nil),
        ("cannot add", "incompatible-operands", "scripting/operators/#addition"),
        ("cannot subtract", "incompatible-operands", "scripting/operators/#subtraction"),
        ("cannot multiply", "incompatible-operands", "scripting/operators/#multiplication"),
        ("cannot divide", "incompatible-operands", "scripting/operators/#division"),
        ("cannot join", "incompatible-operands", nil),
        ("cannot compare", "incompatible-operands", nil),
        ("cannot convert", "incompatible-operands", nil),
        ("cannot access", "invalid-access", nil),
        ("file not found", "file-not-found", nil),
        ("package not found", "package-not-found", "packages"),
        ("failed to download", "package-not-found", "packages"),
        ("failed to load", "file-load-failed", nil),
        ("label", "label-problem", "model/#labels"),
        ("reference", "reference-problem", "model/reference"),
        ("dictionary does not contain key", "missing-key", "scripting/types/#dictionary"),
        ("array index out of bounds", "index-out-of-bounds", "scripting/types/#array"),
        ("index out of bounds", "index-out-of-bounds", "scripting/types/#array"),
        ("element does not exist", "missing-element", nil),
        ("the character `", "invalid-character", "syntax"),
        ("source file must be contained in project root", "outside-root", nil),
        ("no text within underscores", "empty-emphasis", "syntax/#markup"),
        ("no text within stars", "empty-strong", "syntax/#markup"),
        ("text is too long", "text-too-long", nil),
        ("maximum function call depth", "recursion-depth", nil),
        ("number too large", "number-range", nil),
        ("module is not", "module-problem", nil),
        ("only functions", "not-a-function", nil),
        ("this is not a function", "not-a-function", nil),
        ("variable is not", "type-mismatch", nil),
        ("type mismatch", "type-mismatch", nil),
    ]

    /// A slug such as `unknown-variable`, or `nil` when the message is not
    /// recognised (agents then fall back to `message`).
    static func slug(for message: String) -> String? {
        let lower = message.lowercased()
        for rule in rules where lower.hasPrefix(rule.prefix) {
            return rule.code
        }
        return nil
    }

    /// `<https://typst.app/docs/reference/…>` for a slug, when one is known.
    static func docsURL(for message: String) -> String? {
        let lower = message.lowercased()
        for rule in rules where lower.hasPrefix(rule.prefix) {
            guard let path = rule.docs else { return nil }
            return "https://typst.app/docs/reference/\(path)"
        }
        return nil
    }
}
