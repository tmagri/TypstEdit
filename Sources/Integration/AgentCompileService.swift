import Foundation

// MARK: - Request / Result Types

/// Output formats the headless compiler can produce.
enum AgentOutputFormat: String, CaseIterable, Sendable {
    case pdf, png, svg
}

/// One compile (or check) request from an external tool: the `typstedit` CLI
/// or an AI agent talking to the MCP server.
///
/// Exactly one of `inputPath` / `source` must be set.
struct AgentCompileRequest: Sendable {
    /// Path to a `.typ`, `.md` or `.note` file. Relative paths resolve against `workingDirectory`.
    var inputPath: String? = nil
    /// Inline document text (used when there is no file on disk).
    var source: String? = nil
    /// Syntax of `source`: `typ`, `md` or `note`.
    var sourceKind: String = "typ"
    /// Output file. Defaults to the input file with the format's extension.
    var outputPath: String? = nil
    /// Output format. Inferred from `outputPath` when nil, else PDF.
    var format: AgentOutputFormat? = nil
    /// Typst project root (for absolute paths / imports above the file's folder).
    var root: String? = nil
    /// Page selection, Typst syntax (e.g. "1", "2,4-6").
    var pages: String? = nil
    /// Pixels per inch for PNG output.
    var ppi: Int? = nil
    /// `sys.inputs` key/value pairs.
    var inputs: [String: String] = [:]
    /// Extra font directories.
    var fontPaths: [String] = []
    /// Only report diagnostics; the output is written to a scratch folder and deleted.
    var checkOnly = false
    /// Base for relative paths (the shell's cwd for the CLI).
    var workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

/// A compiler diagnostic in a stable, machine-readable shape. Paths are absolute
/// and line/column numbers are 1-based and refer to the user's original file
/// (Markdown/Note conversions are mapped back).
struct AgentDiagnostic: Codable, Sendable {
    struct Frame: Codable, Sendable {
        var message: String
        var file: String?
        var line: Int?
        /// The code Typst printed under the frame, e.g. `boom(2)`.
        var snippet: String?
    }

    /// A one-line fix the caller can apply, from TypstEdit's suggestion engine.
    struct Fix: Codable, Sendable {
        var title: String
        var replacement: String
    }

    var severity: String
    var message: String
    /// Stable slug for branching, e.g. `unknown-variable`, `incompatible-operands`.
    /// Typst's CLI has no diagnostic codes (typst/typst#6059), so this is derived
    /// from the message's leading phrase and survives rewording of the details.
    var code: String?
    /// Plain-English "how to fix" guidance for common diagnostics.
    var explanation: String?
    /// Reference page for the feature the diagnostic is about, when known.
    var docs: String?
    var file: String?
    var line: Int?
    var column: Int?
    /// 1-based column one past the end of the highlighted span.
    var endColumn: Int?
    var length: Int?
    var snippet: String?
    var hints: [String] = []
    /// Where the failing value was used: the `while calling …` chain.
    var trace: [Frame] = []
    var fixes: [Fix] = []

    /// Compiler-style text: `file:line:col: error: message`, plus hints and trace.
    var humanReadable: String {
        var location = file ?? "<document>"
        if let line {
            location += ":\(line)"
            if let column { location += ":\(column)" }
        }
        var lines = ["\(location): \(severity): \(message)"]
        if let code { lines[0] += " [\(code)]" }
        if let snippet, !snippet.isEmpty {
            lines.append("    \(snippet)")
            if let column, column >= 1 {
                lines.append("    " + String(repeating: " ", count: column - 1) + String(repeating: "^", count: max(1, length ?? 1)))
            }
        }
        lines += hints.map { "  hint: \($0)" }
        for frame in trace {
            var frameLocation = ""
            if let file = frame.file {
                frameLocation = " (\(file)\(frame.line.map { ":\($0)" } ?? ""))"
            }
            lines.append("  \(frame.message)\(frameLocation)")
            if let code = frame.snippet { lines.append("    \(code)") }
        }
        if let explanation { lines.append("  how to fix: \(explanation)") }
        if !fixes.isEmpty {
            lines.append("  suggested edit\(fixes.count == 1 ? "" : "s") (apply to the line above):")
            lines += fixes.map { "    - \($0.title): \($0.replacement)" }
        }
        if let docs { lines.append("  docs: \(docs)") }
        return lines.joined(separator: "\n")
    }
}

struct AgentCompileResult: Codable, Sendable {
    /// Bumped when the JSON shape changes in a way a client could notice.
    var schemaVersion = 1
    var success: Bool
    var checkOnly: Bool
    /// `ok` or `errors` — a single field to branch on instead of `success`.
    var status: String = "errors"
    var input: String?
    var format: String
    /// Files written (one per page for PNG/SVG). Empty for checks and failures.
    var outputs: [String] = []
    var root: String?
    var typstPath: String?
    var typstVersion: String?
    var errorCount = 0
    var warningCount = 0
    var diagnostics: [AgentDiagnostic] = []
    /// Diagnostics found but not listed, split so each count stays honest.
    var suppressedCount = 0
    var suppressedWarningCount = 0
    /// Every file the compilation read, from `typst --deps`. Use it to tell
    /// whether a diagnostic belongs to the file that was edited or to an
    /// imported module.
    var deps: [String] = []
    /// Informational notes about what TypstEdit did (conversions, fallbacks).
    var notes: [String] = []
    /// Raw compiler output. Only populated when it could not be turned into
    /// diagnostics, so the token cost stays low on the normal path.
    var log: String = ""
    var durationMs = 0

    func jsonString(pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Short report for people and agents that read plain text.
    var summary: String {
        let name = input.map { ($0 as NSString).lastPathComponent } ?? "inline source"
        var counts = "\(errorCount) error\(errorCount == 1 ? "" : "s"), \(warningCount) warning\(warningCount == 1 ? "" : "s")"
        if suppressedCount > 0 {
            counts += "; \(suppressedCount) similar error\(suppressedCount == 1 ? "" : "s") not listed"
        }
        if suppressedWarningCount > 0 {
            counts += "; \(suppressedWarningCount) similar warning\(suppressedWarningCount == 1 ? "" : "s") not listed"
        }
        var lines: [String] = []
        if success {
            if checkOnly {
                lines.append("OK: \(name) compiles (\(counts)) in \(durationMs) ms.")
            } else {
                lines.append("OK: compiled \(name) to \(format.uppercased()) (\(counts)) in \(durationMs) ms.")
                lines += outputs.map { "  output: \($0)" }
            }
        } else {
            lines.append("FAILED: \(name) did not compile (\(counts)).")
        }
        lines += notes.map { "  note: \($0)" }
        if !diagnostics.isEmpty {
            lines.append("")
            lines += diagnostics.map(\.humanReadable)
        } else if !success, !log.isEmpty {
            lines.append("")
            lines.append(log)
        }
        return lines.joined(separator: "\n")
    }

    /// True when a diagnostic points at a file other than `input` — the caller
    /// edited the wrong file, or the fix belongs upstream in an import.
    var hasDiagnosticsOutsideInput: Bool {
        guard let input else { return false }
        return diagnostics.contains { $0.file != nil && $0.file != input }
    }
}


// MARK: - Service

/// Headless, window-free compiler used by the `typstedit` CLI and the MCP
/// server. It reuses the editor's own pipeline so external agents get the same
/// result as TypstEdit's preview/export: the active (bundled or custom) Typst
/// binary, Markdown/Note conversion with lenient fallbacks, missing-font
/// substitution, and web-image downloads.
@MainActor
final class AgentCompileService {
    static let shared = AgentCompileService()

    /// Used only for its shared helpers (web images, lenient fallback fixer).
    private let helper = TypstCompiler()

    private init() {}

    /// The editor's active compiler (custom → bundled → common locations), then
    /// `TYPSTEDIT_TYPST`, `typst` on PATH, and the repo-local binary of a dev build.
    var typstPath: String? {
        let fm = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["TYPSTEDIT_TYPST"], fm.isExecutableFile(atPath: override) {
            return override
        }
        if let active = TypstUpdater.shared.resolveActiveTypstPath() { return active }
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in pathDirs where fm.isExecutableFile(atPath: "\(dir)/typst") {
            return "\(dir)/typst"
        }
        let arch = Self.isAppleSilicon ? "aarch64" : "x86_64"
        let devBinary = URL(fileURLWithPath: Bundle.main.executablePath ?? "")
            .deletingLastPathComponent()           // debug/
            .deletingLastPathComponent()           // .build/ (or arch-build/<arch>/…)
            .deletingLastPathComponent()           // repo
            .appendingPathComponent("typst-\(arch)-apple-darwin/typst").path
        return fm.isExecutableFile(atPath: devBinary) ? devBinary : nil
    }

    private nonisolated static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    func compile(_ request: AgentCompileRequest) async -> AgentCompileResult {
        let started = Date()
        let fm = FileManager.default
        let runID = String(UUID().uuidString.prefix(8)).lowercased()

        var result = AgentCompileResult(success: false, checkOnly: request.checkOnly, input: request.inputPath, format: (request.format ?? .pdf).rawValue)
        var cleanup: [URL] = []
        defer { cleanup.forEach { try? fm.removeItem(at: $0) } }

        func finish(_ result: AgentCompileResult) -> AgentCompileResult {
            var final = result
            final.errorCount = final.diagnostics.filter { $0.severity == "error" }.count + final.suppressedCount
            final.warningCount = final.diagnostics.filter { $0.severity == "warning" }.count + final.suppressedWarningCount
            final.status = final.success ? "ok" : "errors"
            final.durationMs = Int(Date().timeIntervalSince(started) * 1000)
            return final
        }
        func fail(_ message: String) -> AgentCompileResult {
            result.success = false
            result.diagnostics.append(AgentDiagnostic(severity: "error", message: message))
            return finish(result)
        }

        guard let typstPath else {
            return fail("Could not locate the Typst compiler. Open TypstEdit > Settings > Typst Compiler to install one or set a custom path.")
        }
        result.typstPath = typstPath
        result.typstVersion = await Self.cachedVersion(of: typstPath)

        // 1. Resolve the document.
        let originalText: String
        let kind: String
        let sourceDirectory: URL
        var realFileURL: URL? = nil
        var needsShadow = false

        let requestedRoot = request.root.flatMap { $0.isEmpty ? nil : Self.resolve($0, relativeTo: request.workingDirectory) }

        if let path = request.inputPath, !path.isEmpty {
            let url = Self.resolve(path, relativeTo: request.workingDirectory)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return fail("Input file not found: \(url.path)")
            }
            guard !isDirectory.boolValue else {
                return fail("Input is a folder, not a file: \(url.path). Pass the main .typ file of the project.")
            }
            guard let decoded = try? TextFileEncoding.string(from: url) else {
                return fail("Could not read \(url.path).")
            }
            originalText = decoded.text
            needsShadow = decoded.encoding != .utf8
            kind = Self.kind(forExtension: url.pathExtension)
            sourceDirectory = url.deletingLastPathComponent()
            realFileURL = url
            result.input = url.path
        } else if let source = request.source {
            originalText = source
            kind = Self.kind(forExtension: request.sourceKind)
            needsShadow = true
            if let requestedRoot {
                // Inline source that refers to project files: compile it from inside the root.
                sourceDirectory = requestedRoot
            } else {
                let scratch = fm.temporaryDirectory.appendingPathComponent("typstedit-agent-\(runID)", isDirectory: true)
                try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
                cleanup.append(scratch)
                sourceDirectory = scratch
            }
        } else {
            return fail("Nothing to compile: pass a file path or inline source.")
        }

        let rootURL = (requestedRoot ?? sourceDirectory).standardizedFileURL
        result.root = rootURL.path
        guard sourceDirectory.standardizedFileURL.path.hasPrefix(rootURL.path) else {
            return fail("The document (\(sourceDirectory.path)) is not inside the project root (\(rootURL.path)). Use a root that contains the file.")
        }

        // 2. Apply TypstEdit's source pipeline (same steps as preview/export).
        var text = originalText
        var lineMap: [Int: Int]? = nil
        var preambleLines = 0
        if kind == "md" || kind == "note" {
            let isHybrid = (kind == "note")
            let prepared = isHybrid ? TypstCompiler.autoFixBrokenNoteSyntax(text) : text
            let delimited = isHybrid ? TypstCompiler.delimitImproperOperators(prepared).output : prepared
            text = AICompletionService.shared.sanitizeMarkdownToTypst(delimited, isHybrid: isHybrid)
            lineMap = TypstCompiler.buildLineMap(source: originalText, output: text)
            if isHybrid {
                text = TypstCompiler.notePreamble + text
                preambleLines = TypstCompiler.notePreamble.filter { $0 == "\n" }.count
            }
            result.notes.append("Converted \(kind == "md" ? "Markdown" : "Note") to Typst with TypstEdit's converter before compiling.")
        }
        text = TypstCompiler.substituteMissingFonts(text)

        // TypstEdit calculator features: resolve #calc calls and inject the
        // plugin bridge exactly like the live preview, so a headless
        // `typstedit compile` produces the same output as the app.
        let calcSummary = CalcFeatureScanner.scan(text)
        if calcSummary.needsResolution {
            let outcome = await CalcResolutionPass.resolve(
                text,
                fileExtension: kind,
                settings: CalcResolutionSettings.fromDefaults(),
                cache: [:],
                storedParameters: [])
            let linesBefore = text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            text = outcome.outcome.output
            needsShadow = true
            for diagnostic in outcome.outcome.diagnostics {
                result.notes.append("calculator, line \(diagnostic.line.map(String.init) ?? "?"): \(diagnostic.message)")
            }
            // Loop specialisation repeats bodies; realign diagnostics.
            if text.reduce(0, { $0 + ($1 == "\n" ? 1 : 0) }) != linesBefore {
                lineMap = TypstCompiler.buildLineMap(source: originalText, output: text)
            }
        }
        if calcSummary.needsBridge {
            if CalcPlugin.install(into: sourceDirectory) {
                text = CalcPlugin.importStatement + text
                preambleLines += 1
                needsShadow = true
                result.notes.append(kind == "note"
                    ? "Injected the TypstEdit calculator bridge."
                    : "Injected the TypstEdit calculator bridge (non-portable Typst).")
            } else {
                result.notes.append("Calculator features were used, but TypstEditCalc.wasm is not built — run Tools/calc-plugin/build_calc_plugin.sh.")
            }
        }

        if Self.containsWebImage(text) {
            let tempDir = SafeDirectoryManager.safeTempDirectory(in: rootURL)
            let existed = fm.fileExists(atPath: tempDir.path)
            text = await helper.resolveWebImages(in: text, projectRoot: rootURL)
            if !existed, tempDir.path != rootURL.path { cleanup.append(tempDir) }
            result.notes.append("Downloaded web images referenced by #image(\"http…\").")
        }
        if text != originalText { needsShadow = true }

        // 3. Pick the file Typst compiles. A hidden sibling keeps relative paths working.
        let compileURL: URL
        let shadowName: String?
        if needsShadow {
            let base = realFileURL?.deletingPathExtension().lastPathComponent ?? "inline"
            let name = ".\(base).typstedit-\(runID).typ"
            let url = sourceDirectory.appendingPathComponent(name)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return fail("Could not write a temporary file next to the document: \(error.localizedDescription)")
            }
            cleanup.append(url)
            compileURL = url
            shadowName = name
        } else {
            compileURL = realFileURL!
            shadowName = nil
        }

        // 4. Output location.
        let format = request.format
            ?? request.outputPath.flatMap { AgentOutputFormat(rawValue: ($0 as NSString).pathExtension.lowercased()) }
            ?? .pdf
        result.format = format.rawValue

        var outputURL: URL
        if request.checkOnly {
            let scratch = fm.temporaryDirectory.appendingPathComponent("typstedit-check-\(runID)", isDirectory: true)
            try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            cleanup.append(scratch)
            outputURL = scratch.appendingPathComponent("check.\(format.rawValue)")
        } else if let out = request.outputPath, !out.isEmpty {
            outputURL = Self.resolve(out, relativeTo: request.workingDirectory)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: outputURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let base = realFileURL?.deletingPathExtension().lastPathComponent ?? "document"
                outputURL = outputURL.appendingPathComponent("\(base).\(format.rawValue)")
            }
        } else if let realFileURL {
            outputURL = realFileURL.deletingPathExtension().appendingPathExtension(format.rawValue)
        } else {
            let dir = fm.temporaryDirectory.appendingPathComponent("typstedit-agent-output", isDirectory: true)
            outputURL = dir.appendingPathComponent("inline-\(runID).\(format.rawValue)")
        }
        outputURL = TypstCompiler.exportDestinationURL(for: format.rawValue, requested: outputURL)
        try? fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 5. Run Typst. Markdown/Note files get the editor's lenient fallback retries.
        // `human` is the only format carrying snippets, hints and the call chain,
        // so it is the primary channel; `short` is the fallback when a version
        // prints something `human` parsing does not recognise.
        let depsURL = fm.temporaryDirectory.appendingPathComponent("typstedit-deps-\(runID).json")
        cleanup.append(depsURL)

        func typstArguments(diagnosticFormat: String) -> [String] {
            var arguments = ["compile", compileURL.path, outputURL.path,
                             "--root", rootURL.path,
                             "--format", format.rawValue,
                             "--diagnostic-format", diagnosticFormat,
                             "--deps", depsURL.path]
            if let pages = request.pages, !pages.isEmpty { arguments += ["--pages", pages] }
            if format == .png, let ppi = request.ppi { arguments += ["--ppi", String(ppi)] }
            for (key, value) in request.inputs.sorted(by: { $0.key < $1.key }) { arguments += ["--input", "\(key)=\(value)"] }
            for fontPath in request.fontPaths { arguments += ["--font-path", Self.resolve(fontPath, relativeTo: request.workingDirectory).path] }
            return arguments
        }

        var fallbackAttempts: [Int: Int] = [:]
        var status: Int32 = -1
        var output = ""
        for attempt in 0..<4 {
            (status, output) = await Self.run(typstPath, arguments: typstArguments(diagnosticFormat: "human"), in: rootURL)
            guard status != 0, attempt < 3, kind == "md" || kind == "note", shadowName != nil else { break }
            // Only lines Typst blamed on the shadow file itself may be repaired.
            // An error inside an imported module carries *that* file's line
            // numbers, and rewriting the shadow with them would corrupt an
            // unrelated line.
            let rawLines = TypstCompiler.parseRawErrorLines(
                from: output, onlyInFile: compileURL.lastPathComponent)
            guard !rawLines.isEmpty,
                  helper.applyFallbackFix(to: compileURL, rawErrorLines: rawLines, attempts: &fallbackAttempts, isHybrid: kind == "note")
            else { break }
            if attempt == 0 {
                result.notes.append("Some lines failed to compile and were rendered as plain text (TypstEdit's lenient Markdown mode).")
            }
        }
        result.success = (status == 0)

        // 6. Diagnostics, mapped back to the user's file.
        let displayPath = realFileURL?.path ?? "<inline source>"
        func mapLine(_ line: Int) -> Int {
            guard let lineMap else { return line }
            let out = line - preambleLines
            return lineMap[out] ?? max(1, out)
        }
        func mapLocation(_ path: String, _ line: Int) -> (String, Int) {
            if let shadowName, (path as NSString).lastPathComponent == shadowName {
                return (displayPath, mapLine(line))
            }
            if path.hasPrefix("/") || path.hasPrefix("@") { return (path, line) }
            if path == "<stdin>" { return (displayPath, line) }
            return (rootURL.appendingPathComponent(path).standardizedFileURL.path, line)
        }

        var parsed = TypstDiagnosticParser.parse(output)
        if parsed.isEmpty, !result.success {
            // Nothing recognised (a newer/older output shape, or a message
            // printed without a code frame). `short` is the stable
            // `file:line:col: error: message` format, so re-run in it rather
            // than handing the caller raw box art.
            let (_, shortOutput) = await Self.run(
                typstPath, arguments: typstArguments(diagnosticFormat: "short"), in: rootURL)
            let shortParsed = TypstDiagnosticParser.parse(shortOutput)
            if !shortParsed.isEmpty {
                parsed = shortParsed
                output = shortOutput
            }
        }

        var seen = Set<String>()
        func locationKey(_ diagnostic: AgentDiagnostic) -> String {
            "\(diagnostic.file ?? "-")|\(diagnostic.line ?? -1)|\(diagnostic.column ?? -1)|\(diagnostic.severity)|\(diagnostic.message)"
        }

        for raw in parsed {
            var diagnostic = AgentDiagnostic(severity: raw.severity == .error ? "error" : "warning", message: raw.message)
            diagnostic.code = TypstDiagnosticCode.slug(for: raw.message)
            diagnostic.docs = TypstDiagnosticCode.docsURL(for: raw.message)
            if let location = raw.location {
                let (file, line) = mapLocation(location.path, location.line)
                diagnostic.file = file
                diagnostic.line = line
                diagnostic.column = raw.caretColumn.map { $0 + 1 } ?? location.column
                diagnostic.length = raw.caretLength
                if let column = diagnostic.column, let length = diagnostic.length {
                    diagnostic.endColumn = column + max(0, length)
                }
            }
            diagnostic.snippet = raw.snippet
            diagnostic.hints = raw.hints
            diagnostic.trace = raw.trace.map { frame in
                let snippet = frame.snippet
                guard let location = frame.location else { return .init(message: frame.message, snippet: snippet) }
                let (file, line) = mapLocation(location.path, location.line)
                return .init(message: frame.message, file: file, line: line, snippet: snippet)
            }

            // A bad label is reported where the reference is *evaluated*, so a
            // document with a `#show ref` handler reports every broken `@ref`
            // at that handler — one real document produced 16 errors all
            // pointing at the same unrelated line. Re-point them at the source
            // line(s) that actually contain the reference. For a duplicate
            // label the reference lines are not the problem at all: what has to
            // change is the definition, so those are reported instead.
            if let label = TypstLabelReference.labelName(in: raw.message) {
                let isDuplicate = raw.message.contains("occurs multiple times")
                let lines = originalText.components(separatedBy: "\n")
                let targets: [(line: Int, column: Int?, snippet: String?)]
                let noun: String
                if isDuplicate {
                    noun = "duplicate label definition"
                    targets = TypstLabelReference.definitions(of: label, in: originalText).map { line in
                        (line, nil, lines.dropFirst(line - 1).first)
                    }
                } else {
                    let references = TypstLabelReference.references(of: label, in: originalText)
                    noun = "reference"
                    targets = references.map { ($0.line, $0.column, $0.snippet) }
                }
                if let first = targets.first {
                    var hint = "Typst reports this where the \(isDuplicate ? "label" : "reference") is evaluated; resolved to the \(noun) at \(displayPath):\(first.line)."
                    if isDuplicate, targets.count > 1 {
                        hint = "`<\(label)>` is defined on \(targets.count) lines (\(targets.map { String($0.line) }.joined(separator: ", "))). Typst allows each label once; remove or rename the extra definition."
                    }
                    if targets.count > Self.maxLabelExpansions {
                        hint += " It appears on \(targets.count) lines; the first \(Self.maxLabelExpansions) are listed."
                    }
                    diagnostic.hints.append(hint)
                    for target in targets.prefix(Self.maxLabelExpansions) {
                        var expanded = diagnostic
                        expanded.file = displayPath
                        expanded.line = target.line
                        expanded.column = target.column
                        expanded.endColumn = target.column.map { $0 + label.count + 1 }
                        expanded.snippet = target.snippet
                        expanded.length = target.column == nil ? nil : label.count + 1
                        guard seen.insert(locationKey(expanded)).inserted else { continue }
                        Self.attachGuidance(to: &expanded)
                        result.diagnostics.append(expanded)
                    }
                    continue
                }
            }

            // Same message, same place, printed twice (Typst sometimes repeats a
            // diagnostic once per evaluation) — keep one.
            guard seen.insert(locationKey(diagnostic)).inserted else { continue }

            Self.attachGuidance(to: &diagnostic)
            result.diagnostics.append(diagnostic)
        }
        if !result.success && result.diagnostics.isEmpty {
            let raw = output.trimmingCharacters(in: .whitespacesAndNewlines)
            result.log = raw
            result.diagnostics.append(AgentDiagnostic(
                severity: "error",
                message: raw.isEmpty ? "Typst exited with code \(status)." : raw))
        }

        // One typo can produce hundreds of diagnostics: a single unbalanced
        // `#figure(` in a real 7,500-line document produced 213 "expected
        // comma" and 36 "the character `#` is not valid in code" errors. Listing
        // all of them buries the one line that has to be fixed, so each code is
        // capped and the remainder is counted.
        let suppressed = Self.collapseRepeats(in: &result.diagnostics)
        result.suppressedCount = suppressed.errors
        result.suppressedWarningCount = suppressed.warnings

        // 7. Dependency list, so a caller can tell whether a diagnostic belongs
        // to the edited file or to something it imports.
        if let data = fm.contents(atPath: depsURL.path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inputs = json["inputs"] as? [String] {
            result.deps = inputs.map { input in
                input.hasPrefix("/") ? input : rootURL.appendingPathComponent(input).standardizedFileURL.path
            }
        }

        // 7. Collect written files.
        if result.success && !request.checkOnly {
            result.outputs = Self.generatedFiles(for: outputURL, since: started)
        }
        return finish(result)
    }

    // MARK: - Helpers

    /// Most diagnostics a single `code` may contribute to the list.
    ///
    /// A cascading syntax error repeats the same message on every following
    /// line: one unbalanced `#figure(` in a real 7,500-line document produced
    /// 213 "expected comma" and 36 "the character `#` is not valid in code"
    /// diagnostics. Keeping a few per code preserves the pattern (and the first
    /// real location) while leaving the list small enough to act on.
    nonisolated static let maxDiagnosticsPerCode = 8

    /// Trims runs of identical codes, keeping the earliest locations and
    /// returning how many errors and warnings were dropped.
    ///
    /// Severities are counted separately so a flood of warnings cannot push the
    /// one real error out of the list.
    nonisolated static func collapseRepeats(
        in diagnostics: inout [AgentDiagnostic]
    ) -> (errors: Int, warnings: Int) {
        var kept: [AgentDiagnostic] = []
        var perKey: [String: Int] = [:]
        var suppressedErrors = 0
        var suppressedWarnings = 0
        for diagnostic in diagnostics {
            // Uncoded diagnostics are kept: they are the unusual ones.
            guard let code = diagnostic.code else {
                kept.append(diagnostic)
                continue
            }
            // Keyed on the message, not just the code: a cascade repeats one
            // message on every line, while `label <a>` and `label <b>` are
            // different defects that both map to `label-problem`. Keying on the
            // code alone would hide 14 distinct missing labels behind one cap.
            let key = "\(diagnostic.severity)|\(code)|\(diagnostic.message)"
            let count = perKey[key, default: 0]
            if count >= maxDiagnosticsPerCode {
                if diagnostic.severity == "warning" { suppressedWarnings += 1 } else { suppressedErrors += 1 }
                continue
            }
            perKey[key] = count + 1
            kept.append(diagnostic)
        }
        diagnostics = kept
        return (suppressedErrors, suppressedWarnings)
    }

    nonisolated static func resolve(_ path: String, relativeTo base: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)
        // Resolve /var → /private/var style links so reported paths are consistent.
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    nonisolated static func kind(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "md", "markdown": return "md"
        case "note": return "note"
        default: return "typ"
        }
    }

    nonisolated static func containsWebImage(_ text: String) -> Bool {
        let range = NSRange(0..<text.utf16.count)
        return CompilerRegex.webImage.matches(in: text, options: [], range: range).contains { match in
            (text as NSString).substring(with: match.range(at: 1)).lowercased().hasPrefix("http")
        }
    }

    /// The files Typst wrote for `template` (expands `{p}` / `{0p}` page templates).
    nonisolated static func generatedFiles(for template: URL, since date: Date) -> [String] {
        let fm = FileManager.default
        let base = template.deletingPathExtension().lastPathComponent
        guard let brace = base.firstIndex(of: "{") else {
            return fm.fileExists(atPath: template.path) ? [template.path] : []
        }
        let prefix = String(base[..<brace])
        let ext = template.pathExtension.lowercased()
        let directory = template.deletingLastPathComponent()
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == ext }
            .filter {
                let name = $0.deletingPathExtension().lastPathComponent
                guard name.hasPrefix(prefix) else { return false }
                return name.dropFirst(prefix.count).contains(where: \.isNumber)
            }
            .filter {
                let modified = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return modified >= date.addingTimeInterval(-2)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(\.path)
    }

    /// A label can be referenced many times (`@gen-9-29` appears on four
    /// lines). Reporting every occurrence would flood the result, so the first
    /// few are expanded into located diagnostics and the hint names the rest.
    private static let maxLabelExpansions = 4

    /// Adds the plain-English explanation and the quick fixes the editor shows
    /// in its error panel, so an agent gets the same guidance a person does
    /// instead of only Typst's terse message.
    private static func attachGuidance(to diagnostic: inout AgentDiagnostic) {
        var issue = TypstError(
            line: diagnostic.line,
            message: diagnostic.message,
            severity: diagnostic.severity == "warning" ? .warning : .error)
        issue.file = diagnostic.file
        issue.snippet = diagnostic.snippet
        // The editor's explainer and fixer reason in 0-based caret columns.
        if let column = diagnostic.column, column >= 1 {
            issue.column = column - 1
            if let length = diagnostic.length { issue.length = length }
        }
        diagnostic.explanation = TypstErrorExplainer.explanation(for: issue)
        guard let line = diagnostic.snippet, diagnostic.severity == "error" else { return }
        diagnostic.fixes = TypstSuggestionEngine.shared.suggestFixes(for: issue, in: line).prefix(3).map {
            AgentDiagnostic.Fix(title: $0.title, replacement: $0.replacement)
        }
    }

    /// Runs a process off the main actor and returns its exit code and combined output.
    nonisolated static func run(_ executable: String, arguments: [String], in directory: URL?) async -> (Int32, String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = directory }
            var environment = ProcessInfo.processInfo.environment
            environment["NO_COLOR"] = "1"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return (Int32(-1), "Failed to launch \(executable): \(error.localizedDescription)")
            }
            // Drain concurrently with the wait so a large diagnostic dump
            // can't fill the pipe and block Typst (wait-then-read deadlocks
            // once the ~64 KB pipe buffer is full).
            let result = BlockingProcess.run(process, draining: [pipe.fileHandleForReading])
            return (result.status, result.output)
        }.value
    }

    /// `typst --version` of the active compiler, cached per binary path: the
    /// version string is part of every result's metadata and spawning a process
    /// for it on each check would be wasteful.
    private static var versionCache: [String: String] = [:]

    nonisolated static func cachedVersion(of path: String) async -> String? {
        let cached: String? = await MainActor.run { versionCache[path] }
        if let cached { return cached }
        let (status, output) = await run(path, arguments: ["--version"], in: nil)
        guard status == 0 else { return nil }
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        await MainActor.run { versionCache[path] = version }
        return version
    }

    /// `typst --version` of the active compiler.
    func typstVersion() async -> String? {
        guard let typstPath else { return nil }
        let (status, output) = await Self.run(typstPath, arguments: ["--version"], in: nil)
        return status == 0 ? output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
}
