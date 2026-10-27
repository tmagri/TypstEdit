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
    }

    var severity: String
    var message: String
    var file: String?
    var line: Int?
    var column: Int?
    var length: Int?
    var snippet: String?
    var hints: [String] = []
    var trace: [Frame] = []

    /// Compiler-style text: `file:line:col: error: message`, plus hints and trace.
    var humanReadable: String {
        var location = file ?? "<document>"
        if let line {
            location += ":\(line)"
            if let column { location += ":\(column)" }
        }
        var lines = ["\(location): \(severity): \(message)"]
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
            lines.append("  help: \(frame.message)\(frameLocation)")
        }
        return lines.joined(separator: "\n")
    }
}

struct AgentCompileResult: Codable, Sendable {
    var success: Bool
    var checkOnly: Bool
    var input: String?
    var format: String
    /// Files written (one per page for PNG/SVG). Empty for checks and failures.
    var outputs: [String] = []
    var root: String?
    var typstPath: String?
    var errorCount = 0
    var warningCount = 0
    var diagnostics: [AgentDiagnostic] = []
    /// Informational notes about what TypstEdit did (conversions, fallbacks).
    var notes: [String] = []
    /// Raw compiler output.
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
        let counts = "\(errorCount) error\(errorCount == 1 ? "" : "s"), \(warningCount) warning\(warningCount == 1 ? "" : "s")"
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
            final.errorCount = final.diagnostics.filter { $0.severity == "error" }.count
            final.warningCount = final.diagnostics.filter { $0.severity == "warning" }.count
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
        var arguments = ["compile", compileURL.path, outputURL.path,
                         "--root", rootURL.path,
                         "--format", format.rawValue,
                         "--diagnostic-format", "human"]
        if let pages = request.pages, !pages.isEmpty { arguments += ["--pages", pages] }
        if format == .png, let ppi = request.ppi { arguments += ["--ppi", String(ppi)] }
        for (key, value) in request.inputs.sorted(by: { $0.key < $1.key }) { arguments += ["--input", "\(key)=\(value)"] }
        for fontPath in request.fontPaths { arguments += ["--font-path", Self.resolve(fontPath, relativeTo: request.workingDirectory).path] }

        var fallbackAttempts: [Int: Int] = [:]
        var status: Int32 = -1
        var output = ""
        for attempt in 0..<4 {
            (status, output) = await Self.run(typstPath, arguments: arguments, in: rootURL)
            guard status != 0, attempt < 3, kind == "md" || kind == "note", shadowName != nil else { break }
            let rawLines = helper.parseRawErrorLines(from: output)
            guard !rawLines.isEmpty,
                  helper.applyFallbackFix(to: compileURL, rawErrorLines: rawLines, attempts: &fallbackAttempts, isHybrid: kind == "note")
            else { break }
            if attempt == 0 {
                result.notes.append("Some lines failed to compile and were rendered as plain text (TypstEdit's lenient Markdown mode).")
            }
        }
        result.log = output.trimmingCharacters(in: .whitespacesAndNewlines)
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
            return (rootURL.appendingPathComponent(path).standardizedFileURL.path, line)
        }
        for raw in TypstDiagnosticParser.parse(output) {
            var diagnostic = AgentDiagnostic(severity: raw.severity == .error ? "error" : "warning", message: raw.message)
            if let location = raw.location {
                let (file, line) = mapLocation(location.path, location.line)
                diagnostic.file = file
                diagnostic.line = line
                diagnostic.column = raw.caretColumn.map { $0 + 1 } ?? location.column
                diagnostic.length = raw.caretLength
            }
            diagnostic.snippet = raw.snippet
            diagnostic.hints = raw.hints
            diagnostic.trace = raw.trace.map { frame in
                guard let location = frame.location else { return .init(message: frame.message) }
                let (file, line) = mapLocation(location.path, location.line)
                return .init(message: frame.message, file: file, line: line)
            }
            result.diagnostics.append(diagnostic)
        }
        if !result.success && result.diagnostics.isEmpty {
            result.diagnostics.append(AgentDiagnostic(severity: "error", message: result.log.isEmpty ? "Typst exited with code \(status)." : result.log))
        }

        // 7. Collect written files.
        if result.success && !request.checkOnly {
            result.outputs = Self.generatedFiles(for: outputURL, since: started)
        }
        return finish(result)
    }

    // MARK: - Helpers

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
            // Drain before waiting so a large diagnostic dump can't fill the pipe and block Typst.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }

    /// `typst --version` of the active compiler.
    func typstVersion() async -> String? {
        guard let typstPath else { return nil }
        let (status, output) = await Self.run(typstPath, arguments: ["--version"], in: nil)
        return status == 0 ? output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
}
