import Foundation

// MARK: - Request / Result

/// A Markdown ↔ Typst conversion request from the CLI or an MCP client.
///
/// Exactly one of `inputPath` / `source` must be set. The direction follows
/// the file extension (or `sourceKind` for inline text): Markdown, `.note` and
/// Typst are the three kinds this app understands, and each pair has exactly
/// one sensible conversion.
struct AgentConvertRequest: Sendable {
    var inputPath: String? = nil
    var source: String? = nil
    /// Syntax of `source`: `md`, `note` or `typ`.
    var sourceKind: String = "md"
    /// Write the result here. Defaults to no file (text is returned only).
    var outputPath: String? = nil
    /// Treat Markdown as a `.note` body: Markdown prose with live Typst regions.
    var isHybrid = false
    /// Compile the produced Typst and report diagnostics. Off by default: it
    /// needs the compiler and is not always wanted for a plain conversion.
    var verify = false
    /// Base for relative paths.
    var workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

struct AgentConvertResult: Codable, Sendable {
    var schemaVersion = 1
    var success: Bool
    /// `ok` or `errors` — branch on this instead of parsing prose.
    var status: String = "ok"
    var input: String?
    var inputKind: String
    var outputKind: String
    /// The converted document.
    var output: String
    var outputPath: String?
    var bytes: Int = 0
    var lineCount: Int = 0
    /// Things the conversion could not carry across (an unknown direction, a
    /// missing file, a compile error).
    var warnings: [String] = []
    /// What TypstEdit did, in plain language.
    var notes: [String] = []
    var durationMs = 0
    /// True when `verify` ran, so "0 errors" can be told from "not checked".
    var verified = false
    var diagnostics: [AgentDiagnostic] = []
    var errorCount = 0
    var warningCount = 0

    func jsonString(pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    var summary: String {
        let name = input.map { ($0 as NSString).lastPathComponent } ?? "inline source"
        var lines = [
            "OK: converted \(name) from \(inputKind) to \(outputKind) (\(lineCount) lines, \(bytes) bytes)."
        ]
        if let outputPath { lines.append("  output: \(outputPath)") }
        lines += notes.map { "  note: \($0)" }
        lines += warnings.map { "  warning: \($0)" }
        if verified {
            lines.append("  verify: \(errorCount) error\(errorCount == 1 ? "" : "s"), \(warningCount) warning\(warningCount == 1 ? "" : "s")")
        }
        if !diagnostics.isEmpty {
            lines.append("")
            lines += diagnostics.map(\.humanReadable)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Service

/// Markdown ↔ Typst conversion shared by the `typstedit` CLI and the MCP
/// server, so both produce exactly what pasting into the editor produces.
@MainActor
enum AgentDocumentConverter {

    enum Direction {
        case markdownToTypst
        case typstToMarkdown
        case copy
    }

    // MARK: Entry point

    static func convert(_ request: AgentConvertRequest) async -> AgentConvertResult {
        let started = Date()
        let fm = FileManager.default
        var result = AgentConvertResult(
            success: false, input: request.inputPath,
            inputKind: request.sourceKind, outputKind: request.sourceKind, output: "")

        func finish(_ result: AgentConvertResult) -> AgentConvertResult {
            var final = result
            final.status = final.success && final.errorCount == 0 ? "ok" : "errors"
            final.durationMs = Int(Date().timeIntervalSince(started) * 1000)
            final.bytes = final.output.utf8.count
            final.lineCount = final.output.isEmpty ? 0 : final.output.components(separatedBy: "\n").count
            return final
        }
        func fail(_ message: String) -> AgentConvertResult {
            result.success = false
            result.warnings.append(message)
            return finish(result)
        }

        // 1. Resolve the source text and its kind.
        let text: String
        let kind: String
        let sourceDirectory: URL
        var realFileURL: URL?

        if let path = request.inputPath, !path.isEmpty {
            let url = AgentCompileService.resolve(path, relativeTo: request.workingDirectory)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return fail("Input file not found: \(url.path)")
            }
            guard !isDirectory.boolValue else {
                return fail("Input is a folder, not a file: \(url.path)")
            }
            guard let decoded = try? TextFileEncoding.string(from: url) else {
                return fail("Could not read \(url.path).")
            }
            if decoded.encoding != .utf8 {
                result.notes.append("Read the file as \(decoded.encodingName).")
            }
            text = decoded.text
            kind = AgentCompileService.kind(forExtension: url.pathExtension)
            sourceDirectory = url.deletingLastPathComponent()
            realFileURL = url
            result.input = url.path
        } else if let source = request.source {
            text = source
            kind = AgentCompileService.kind(forExtension: request.sourceKind)
            sourceDirectory = request.workingDirectory
        } else {
            return fail("Nothing to convert: pass a file path or inline source.")
        }
        result.inputKind = kind

        let direction = self.direction(from: kind, isHybrid: request.isHybrid)
        result.outputKind = direction == .markdownToTypst ? "typ" : (direction == .typstToMarkdown ? "md" : kind)
        if direction == .copy {
            result.notes.append("'\(kind)' is already the requested format; the text was copied unchanged.")
        }

        // 2. Convert.
        let converted: String
        switch direction {
        case .markdownToTypst:
            let hybrid = request.isHybrid || kind == "note"
            converted = AICompletionService.shared.sanitizeMarkdownToTypst(text, isHybrid: hybrid)
            if hybrid {
                result.notes.append("Converted with the hybrid (.note) pass, so live Typst regions survive.")
            }
        case .typstToMarkdown:
            let loader = markdownFileLoader(sourceURL: realFileURL, root: sourceDirectory)
            do {
                converted = try TypstToMarkdownConverter(fileLoader: loader).convert(source: text)
            } catch {
                return fail("Couldn't convert to Markdown: \(error.localizedDescription)")
            }
            result.notes.append("Converted with TypstEdit's Typst→Markdown converter (\(kind == "note" ? "Note" : "Typst") input).")
        case .copy:
            converted = text
        }
        result.output = converted

        if converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.warnings.append("The conversion produced no output; the source may use constructs the converter cannot express.")
        }

        // 3. Optionally verify that the produced Typst compiles.
        if request.verify, direction == .markdownToTypst {
            var verification = AgentCompileRequest()
            verification.source = converted
            verification.sourceKind = request.isHybrid || kind == "note" ? "note" : "typ"
            if let realFileURL {
                verification.workingDirectory = realFileURL.deletingLastPathComponent()
                verification.root = realFileURL.deletingLastPathComponent().path
            }
            verification.checkOnly = true
            let check = await AgentCompileService.shared.compile(verification)
            result.diagnostics = check.diagnostics
            result.errorCount = check.errorCount
            result.warningCount = check.warningCount
            result.verified = true
            if !check.success {
                result.notes.append("The converted Typst does not compile yet; see the diagnostics below.")
            }
            if let firstNote = check.notes.first {
                result.notes.append(firstNote)
            }
        }

        // 4. Optionally write the output.
        if let rawOutput = request.outputPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawOutput.isEmpty {
            if let problem = write(converted, to: rawOutput, request: request, sourceURL: realFileURL, result: &result) {
                return fail(problem)
            }
        }

        result.success = result.errorCount == 0
        return finish(result)
    }

    // MARK: Helpers

    /// Which conversion a source kind needs.
    static func direction(from kind: String, isHybrid: Bool) -> Direction {
        if isHybrid { return .markdownToTypst }
        switch kind {
        case "md": return .markdownToTypst
        case "note", "typ": return .typstToMarkdown
        default: return .copy
        }
    }

    /// Writes `text` to `rawOutput`, choosing a sensible extension when the
    /// caller names a folder or omits one. Returns an error message, or nil.
    private static func write(
        _ text: String,
        to rawOutput: String,
        request: AgentConvertRequest,
        sourceURL: URL?,
        result: inout AgentConvertResult
    ) -> String? {
        let fm = FileManager.default
        var outputURL = AgentCompileService.resolve(rawOutput, relativeTo: request.workingDirectory)
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: outputURL.path, isDirectory: &isDirectory)
        let extensionForFormat = result.outputKind == "typ" ? "typ" : "md"

        if rawOutput.hasSuffix("/") || (exists && isDirectory.boolValue) {
            let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "converted"
            outputURL = outputURL.appendingPathComponent("\(base).\(extensionForFormat)")
        } else if outputURL.pathExtension.isEmpty {
            outputURL = outputURL.appendingPathExtension(extensionForFormat)
        }

        if let sourceURL, outputURL.standardizedFileURL.path == sourceURL.standardizedFileURL.path {
            return "Output would overwrite the input file. Pass a different output path."
        }
        do {
            try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: outputURL, atomically: true, encoding: .utf8)
        } catch {
            return "Could not write \(outputURL.path): \(error.localizedDescription)"
        }
        result.outputPath = outputURL.path
        return nil
    }

    /// Resolves `#include`/`#import` targets relative to the source file, and
    /// refuses anything outside that folder tree — the same bound the editor's
    /// Markdown conversion applies.
    private static func markdownFileLoader(sourceURL: URL?, root: URL) -> ((String) -> String?)? {
        let base = sourceURL?.deletingLastPathComponent() ?? root
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        return { filename in
            let cleaned = filename.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            let candidate = cleaned.hasPrefix("/")
                ? URL(fileURLWithPath: cleaned)
                : base.appendingPathComponent(cleaned)
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path == resolvedRoot.path || resolved.path.hasPrefix(resolvedRoot.path + "/") else {
                return nil
            }
            return (try? TextFileEncoding.string(from: resolved))?.text
        }
    }
}
