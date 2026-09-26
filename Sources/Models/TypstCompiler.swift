import Foundation
import Combine

// MARK: - Precompiled Regexes

enum CompilerRegex {
    static let stroke = try! NSRegularExpression(pattern: "((?:bottom|top|left|right)\\s*:\\s*[0-9.]+\\s*pt)(?!\\s*\\+)", options: [.caseInsensitive])
    static let luma = try! NSRegularExpression(pattern: "luma\\(\\s*([0-9.]+)\\s*(%?)\\s*\\)", options: [.caseInsensitive])
    static let black = try! NSRegularExpression(pattern: "(:\\s*\\b)(black|rgb\\(\\s*0\\s*,\\s*0\\s*,\\s*0\\s*\\)|rgb\\(\"#000000\"\\))(\\b|\\))", options: [.caseInsensitive])
    static let diagnosticLocation = try! NSRegularExpression(pattern: ":\\d+:\\d+")
    static let markdownConverterFunc = try! NSRegularExpression(pattern: #"^#([A-Za-z][A-Za-z0-9_]*)[\[(]"#)
    static let mathBlock = try! NSRegularExpression(pattern: "\\$\\$?([^\\$]+)\\$\\$?")
    static let trailSupSub = try! NSRegularExpression(pattern: "([\\^_])\\s*$")
    static let trailOp = try! NSRegularExpression(pattern: "([+\\-*\\/=<>]|\\\\times|\\\\cdot)\\s*$")
    static let loneCaret = try! NSRegularExpression(pattern: "(?<![\\\\\\$])\\^\\s*$")
    static let bareHash = try! NSRegularExpression(pattern: "(?<!\\\\)#\\s*$")
    static let codeSpan = try! NSRegularExpression(pattern: "(?s)(`+).*?(?<!`)\\1(?!`)")
    static let mathRegion = try! NSRegularExpression(pattern: "(?s)\\$\\$.+?\\$\\$|(?<!\\\\)\\$(?!\\s)[^\\$\\n]+?(?<!\\s)(?<!\\\\)\\$|(?s)\\\\\\[.+?\\\\\\]|(?s)\\\\\\([^\\n]+?\\\\\\)")
    static let operatorRe = try! NSRegularExpression(pattern: "(?<!\\\\)[@#$<>]")
    static let webImage = try! NSRegularExpression(pattern: #"#image\(\s*"([^"]*)""#)
    static let relativeImport = try! NSRegularExpression(pattern: #"(\b(?:import|include)\s+")([^/@.][^"]*)(")"#)
    static let relativeImage = try! NSRegularExpression(pattern: #"(#image\(\s*")(?!\.\./)(?![/~])(?!https?://)([^"]+)(")"#)
}

struct TypstError: Identifiable, Equatable {
    enum Severity: Equatable {
        case error
        case warning
    }

    let id = UUID()
    let line: Int // 1-based
    let message: String
    var severity: Severity = .error

    /// Convenience constructor that keeps existing call sites (line/message) working.
    init(line: Int, message: String, severity: Severity = .error) {
        self.line = line
        self.message = message
        self.severity = severity
    }
}

@MainActor
class TypstCompiler: ObservableObject {
    @Published var compilationStatus: String = "Ready"
    @Published var isCompiling: Bool = false
    @Published var errors: [TypstError] = []

    public var fileLoader: ((String) -> String?)? = nil

    // Backing stores that feed the published `errors` list.
    // `typstErrors`   – real compilation errors reported by the `typst` binary.
    // `typstWarnings` – `warning:` diagnostics reported by the `typst` binary
    //                   (non-blocking; the document still compiles).
    // `noteWarnings`  – advisory warnings produced by `delimitImproperOperators`
    //                   for hybrid `.note` files (one per source line that needed
    //                   auto-delimiting). Kept separate so they survive a
    //                   successful recompile but are cleared when content changes.
    private var typstErrors: [TypstError] = []
    private var typstWarnings: [TypstError] = []
    private var noteWarnings: [TypstError] = []

    /// Merges real errors + advisory warnings into the published `errors` list and
    /// notifies observers. Real compile errors are listed first (they block output);
    /// warnings follow. Compile diagnostics are cleared on a successful recompile;
    /// `.note` delimiting warnings persist until the source changes.
    private func publishIssues() {
        let combined = typstErrors + typstWarnings + noteWarnings
        self.errors = combined
        NotificationCenter.default.post(name: .typstErrorsUpdated, object: combined)
    }

    var isDarkMode: Bool = false
    private var preambleLineCount: Int {
        var count = 0
        if isDarkMode {
            count += darkModePreamble.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        }
        if currentFileExtension == "note" {
            count += Self.notePreamble.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        }
        return count
    }
    
    private let darkModePreamble = """
// Base page and text colors
#set page(fill: rgb("#1a1a1a"))
#set text(fill: rgb("#d1d1d1"))

// Links
#show link: set text(fill: rgb("#58a6ff"))

// Geometric shape strokes (Safe to set globally)
#set line(stroke: rgb("#d1d1d1"))
#set rect(stroke: rgb("#d1d1d1"))
#set square(stroke: rgb("#d1d1d1"))
#set circle(stroke: rgb("#d1d1d1"))
#set ellipse(stroke: rgb("#d1d1d1"))
#set polygon(stroke: rgb("#d1d1d1"))

// Inline raw text (code)
#show raw: set text(fill: rgb("#d1d1d1"))

// Code blocks (adds distinct background and subtle border)
#show raw.where(block: true): set block(
  fill: rgb("#2a2a2a"),
  inset: 8pt,
  radius: 4pt,
  stroke: rgb("#444444")
)
""" + "\n"

    // Helpers every .note file can rely on. Defined first so any user
    // definition of the same name in the note body shadows ours.
    nonisolated static let notePreamble =
"""
#let title(body) = align(center)[#text(size: 24pt, weight: "bold")[#body]]
#let note-box(title, body) = block(
  width: 100%,
  fill: rgb("#eef2f7"),
  stroke: (left: 2.5pt + rgb("#3b82f6")),
  inset: (x: 12pt, y: 10pt),
)[
  #text(size: 11pt, weight: "bold")[#title]
  #v(4pt)
  #body
]
""" + "\n"
    
    // Check if typst makes sense or we need full path
    private func resolveTypstPath() -> String? {
        // Priority 0: Check for custom user-built Typst
        if GeneralSettingsManager.shared.useCustomTypst, 
           let customPath = GeneralSettingsManager.shared.resolvedCustomTypstPath {
            return customPath
        }

        // Priority 1: Check if bundled with the app
        if let bundlePath = Bundle.main.resourcePath {
            let bundledTypst = "\(bundlePath)/bin/typst"
            if FileManager.default.fileExists(atPath: bundledTypst) {
                return bundledTypst
            }
        }
        
        // Priority 2: Common system paths and workspace bundled binary
        let localProjectPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("typst-aarch64-apple-darwin/typst").path
        let paths = [
            localProjectPath,
            NSString(string: "~/Desktop/TypstEdit/typst-aarch64-apple-darwin/typst").expandingTildeInPath,
            "/opt/homebrew/bin/typst",
            "/usr/local/bin/typst",
            "/usr/bin/typst",
            NSString(string: "~/bin/typst").expandingTildeInPath,
            NSString(string: "~/.cargo/bin/typst").expandingTildeInPath,
        ]
        
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    private var currentProcess: Process?
    private var processOutputPipe: Pipe?
    
    // We keep track of the current shadow file being watched
    private var currentShadowSourceURL: URL?
    public private(set) var currentShadowPDFURL: URL?

    // Lenient-mode fallback tracking (used for .note / .md files)
    // `fallbackAttempts[line] = n` records how many escalating fixes we've applied
    // to that raw shadow-file line. Each escalation is more aggressive so that,
    // eventually, *something* always renders.
    //   0 → (untouched)   1 → escape special chars   2 → wrap whole line in #raw()
    private var currentFileExtension: String = ""
    private var fallbackAttempts: [Int: Int] = [:]
    private var pendingFallbackRawLines: [Int] = []   // shadow-file error lines awaiting a fallback fix

    // Watch-output stream state. `typst watch` diagnostics can be split across
    // arbitrary pipe chunks, so output is buffered until a complete line arrives,
    // and each diagnostic's `error:`/`warning:` line is held until its location
    // line (`┌─ file:line:col`) is seen.
    private var pendingOutputBuffer: String = ""
    private var pendingDiagnosticLine: String? = nil

    /// Maps a converted-output line number (1-based, excluding the injected preamble)
    /// back to the user's source line, so compile errors are reported against the text
    /// in the editor rather than the intermediate shadow file. Rebuilt on each
    /// `updateContent`.
    private var shadowToSourceLine: [Int: Int] = [:]
    
    func cleanUp() {
        if let process = currentProcess {
            process.terminate()
        }
        currentProcess = nil
        processOutputPipe?.fileHandleForReading.readabilityHandler = nil
        processOutputPipe = nil
        currentShadowSourceURL = nil
        currentShadowPDFURL = nil
        // Drop any partially-buffered watch output so the next watch starts clean.
        pendingOutputBuffer = ""
        pendingDiagnosticLine = nil
        pendingFallbackRawLines = []
        // We do not clear fallback tracking here because updateContent() sets them
        // up just before cleanUp() is called to switch processes.
    }

    /// Call this when the project or app is about to close to remove the temp/ directory.
    func cleanUpProjectTemp(projectRoot: URL) {
        TypstCompiler.cleanUpTempDirectory(in: projectRoot)
    }

    /// Removes the `temp/` directory inside the given project root, silently.
    static func cleanUpTempDirectory(in projectRoot: URL) {
        let tempDir = projectRoot.appendingPathComponent("temp")
        cleanUpTempDirectory(tempDir)
    }

    private static func cleanUpTempDirectory(_ tempDir: URL) {
        // Skip cleanup if project is already in a temp directory (to avoid deleting the entire project)
        if SafeDirectoryManager.containsSpecialDirectory(tempDir) == "temp" {
            print("[TypstCompiler] Skipping cleanup of temp directory (project is in temp): \(tempDir.path)")
            return
        }
        guard FileManager.default.fileExists(atPath: tempDir.path) else { return }
        do {
            try FileManager.default.removeItem(at: tempDir)
            print("[TypstCompiler] Cleaned up temp directory: \(tempDir.path)")
        } catch {
            print("[TypstCompiler] Failed to remove temp directory \(tempDir.path): \(error)")
        }
    }

    /// Creates the temp directory inside the project folder if it doesn't exist, and returns its URL.
    /// Prevents nested temp directories if the project is already in a temp folder.
    private func ensureTempDirectory(in projectRoot: URL) -> URL {
        let tempDir = SafeDirectoryManager.safeTempDirectory(in: projectRoot)
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try? SafeDirectoryManager.createDirectorySafely(at: tempDir, withIntermediateDirectories: true)
        }
        return tempDir
    }
    
    // Writes content to the shadow file. If watch is not running, starts it.
    func updateContent(source: String, fileURL: URL) async {
        await MainActor.run { self.isCompiling = true }
        
        let workingDirectory = fileURL.deletingLastPathComponent()
        let filename = fileURL.lastPathComponent
        
        // Use a 'temp/' subdirectory inside the project folder so Typst root restrictions are satisfied
        // and the files are clearly visible (not hidden dot-files).
        let projectTempDir = ensureTempDirectory(in: workingDirectory)
        let shadowSourceURL = projectTempDir.appendingPathComponent("\(filename).preview.typ")
        let shadowPDFURL = projectTempDir.appendingPathComponent("\(filename).preview.pdf")
        
        let projectRoot = workingDirectory
        
        // Write content to shadow file
        do {
            var finalSource = source
            
            // If the file is a Markdown (.md) or hybrid Note (.note) file,
            // convert Markdown syntax to Typst before compilation.
            // Native Typst syntax (= headings, #functions, etc.) passes through unchanged.
            let ext = fileURL.pathExtension.lowercased()

            // Track the file type for lenient-mode fallback, and reset escape history
            // and the watch-output stream state because the user typed new content —
            // start fresh.
            currentFileExtension = ext
            fallbackAttempts = [:]
            pendingFallbackRawLines = []
            pendingDiagnosticLine = nil
            pendingOutputBuffer = ""

            // Operator-delimiting warnings for `.note` files (computed alongside
            // sanitization below, committed to `noteWarnings` once we publish).
            var pendingNoteWarnings: [TypstError] = []

            if ext == "md" || ext == "note" {
                if ext == "note" {
                    finalSource = Self.autoFixBrokenNoteSyntax(finalSource)
                }
                let textToProcess = finalSource
                let aiService = AICompletionService.shared
                let isHybrid = (ext == "note")
                // For hybrid `.note` files, first delimit any operator characters
                // (`@ # $ < >`) that aren't valid Typst so the parser doesn't have
                // to guess. This runs on the user's original text (accurate line
                // numbers for the warnings) and produces backslash escapes that the
                // sanitizer's hybrid rules already treat as idempotent.
                let (sanitized, warnings, lineMap) = await Task.detached {
                    let delimited = isHybrid ? Self.delimitImproperOperators(textToProcess) : (output: textToProcess, warnings: [TypstError]())
                    let cleaned = aiService.sanitizeMarkdownToTypst(delimited.output, isHybrid: isHybrid)
                    // Map converted-output lines back to the user's source so compile
                    // errors land on the line the user actually wrote.
                    let map = Self.buildLineMap(source: source, output: cleaned)
                    return (cleaned, delimited.warnings, map)
                }.value
                finalSource = sanitized
                shadowToSourceLine = lineMap
                pendingNoteWarnings = warnings
            } else {
                pendingNoteWarnings = []
                shadowToSourceLine = [:]
            }
            
            var injectedPreamble = ""
            if ext == "note" {
                injectedPreamble += Self.notePreamble
            }
            if isDarkMode {
                // 1. Inject the color into partial strokes safely
                finalSource = CompilerRegex.stroke.stringByReplacingMatches(
                    in: finalSource,
                    options: [],
                    range: NSRange(0..<finalSource.utf16.count),
                    withTemplate: "$1 + rgb(\"#d1d1d1\")"
                )
                
                // 2. Automatically invert luma() for dark mode (e.g., luma(220) -> luma(35))
                let nsString = NSMutableString(string: finalSource)
                let matches = CompilerRegex.luma.matches(in: finalSource, options: [], range: NSRange(0..<finalSource.utf16.count))
                
                // Iterate in reverse so replacing text doesn't shift the ranges of earlier matches
                for match in matches.reversed() {
                    let valString = nsString.substring(with: match.range(at: 1))
                    let isPercent = match.range(at: 2).length > 0
                    
                    if let val = Double(valString) {
                        // If it's a percentage use 100 - x, otherwise use 255 - x
                        let invertedVal = isPercent ? max(0, 100.0 - val) : max(0, 255.0 - val)
                        
                        // Format cleanly without trailing decimals if it's a whole number
                        let formattedVal = invertedVal.truncatingRemainder(dividingBy: 1) == 0 ?
                                           String(format: "%.0f", invertedVal) :
                                           String(format: "%.1f", invertedVal)
                        
                        let replacement = "luma(\(formattedVal)\(isPercent ? "%" : ""))"
                        nsString.replaceCharacters(in: match.range, with: replacement)
                    }
                }
                finalSource = nsString as String

                // 3. Catch explicit black colors used in parameters and invert them
                // Matches "fill: black" or "stroke: rgb(0,0,0)" but ignores the word "black" in regular text
                finalSource = CompilerRegex.black.stringByReplacingMatches(
                    in: finalSource,
                    options: [],
                    range: NSRange(0..<finalSource.utf16.count),
                    withTemplate: "$1rgb(\"#d1d1d1\")"
                )

                // 4. Append the preamble
                injectedPreamble += darkModePreamble
            }
            finalSource = injectedPreamble + finalSource
            
            // Download web images and inject local paths before saving
            finalSource = await resolveWebImages(in: finalSource, projectRoot: projectRoot)
            
            finalSource = await self.rewriteRelativeImports(in: finalSource, sourceDirectory: workingDirectory, tempDirectory: projectTempDir)
            
            let finalSourceToWrite = finalSource
            try await Task.detached {
                try finalSourceToWrite.write(to: shadowSourceURL, atomically: true, encoding: .utf8)
            }.value
            
            // Reset the issue list for the new content: drop stale compile errors
            // and warnings, and install the freshly-computed operator-delimiting
            // warnings. We're on the main actor here, so this lands before
            // `startWatching` below.
            self.noteWarnings = pendingNoteWarnings
            self.typstErrors = []
            self.typstWarnings = []
            self.publishIssues()
        } catch {
            self.compilationStatus = "Error writing shadow file: \(error)"
            return
        }
        
        // If we are already watching THIS file, we are done
        if let current = currentShadowSourceURL, current == shadowSourceURL, currentProcess?.isRunning == true {
             self.compilationStatus = "Compiling..." 
             return
        }
        
        // Otherwise, stop previous watch and start new one
        cleanUp()
        startWatching(sourceURL: shadowSourceURL, outputURL: shadowPDFURL, projectRoot: projectRoot)
    }
    
    private func startWatching(sourceURL: URL, outputURL: URL, projectRoot: URL) {
        guard let typstPath = resolveTypstPath() else {
            self.compilationStatus = "Error: 'typst' executable not found."
            return
        }
        
        currentShadowSourceURL = sourceURL
        currentShadowPDFURL = outputURL
        // Clear compile diagnostics when (re)starting a watch; keep note warnings,
        // which describe the source and are recomputed on each `updateContent`.
        self.typstErrors = []
        self.typstWarnings = []
        self.pendingDiagnosticLine = nil
        self.pendingOutputBuffer = ""
        self.pendingFallbackRawLines = []
        self.publishIssues()
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        
        // Use --root to ensure relative imports from the temporary file work correctly
        process.arguments = ["watch", sourceURL.path, outputURL.path, "--root", projectRoot.path]
        
        let pipe = Pipe()
        process.standardError = pipe // typst often logs to stderr or stdout, check both? usually stderr for logs
        process.standardOutput = pipe
        
        self.processOutputPipe = pipe
        self.currentProcess = process
        
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isCompiling = false
                self?.compilationStatus = "Watch process ended."
            }
        }
        
        do {
            try process.run()
            self.isCompiling = true
            self.compilationStatus = "Watching..."
            
            // Start reading output in background
            monitorOutput(pipe: pipe, outputURL: outputURL)
        } catch {
            self.compilationStatus = "Failed to start watch: \(error)"
        }
    }
    
    private func monitorOutput(pipe: Pipe, outputURL: URL) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }

            guard let chunk = String(data: data, encoding: .utf8) else { return }

            Task { @MainActor [weak self] in
                self?.handleCompilerOutput(chunk, outputURL: outputURL)
            }
        }
    }

    /// Processes one chunk of `typst watch` output. Chunks arrive at arbitrary
    /// boundaries — a diagnostic's `error:` line and its `┌─ file:line:col` location
    /// can land in different chunks, and even mid-line — so text is buffered and only
    /// complete lines are handed to `consumeCompilerOutputLine`.
    private func handleCompilerOutput(_ chunk: String, outputURL: URL) {
        pendingOutputBuffer += chunk
        var lines = pendingOutputBuffer.components(separatedBy: "\n")
        // The final element is an incomplete line unless the chunk ended with "\n";
        // keep it buffered until its remainder arrives.
        pendingOutputBuffer = lines.popLast() ?? ""
        for line in lines {
            consumeCompilerOutputLine(line, outputURL: outputURL)
        }
    }

    private func consumeCompilerOutputLine(_ line: String, outputURL: URL) {
        print("[TYPST-OUTPUT]: \(line)")

        if line.contains("compiling ...") {
            isCompiling = true
            compilationStatus = "Compiling..."
            return
        }

        if line.contains("compiled successfully") {
            isCompiling = false
            compilationStatus = "Watching..."
            // Notify the view with a small delay to ensure the file is fully flushed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .pdfDidUpdate, object: outputURL)
            }
            // A successful compile clears stale compile diagnostics, but keeps the
            // `.note` operator-delimiting warnings, which stay valid until the
            // source changes.
            typstErrors = []
            typstWarnings = []
            publishIssues()
            return
        }

        if line.contains("compiled with errors") {
            // NOTE: this contains the substring "compiled", so it must be checked
            // separately from the success case above. `typst watch` keeps running
            // after a failed compile and re-reports the full diagnostic set below
            // this marker, so start the batch from a clean slate.
            isCompiling = false
            compilationStatus = "Compilation Error"
            typstErrors = []
            typstWarnings = []
            pendingDiagnosticLine = nil
            return
        }

        if line.hasPrefix("error: ") || line.hasPrefix("warning: ")
            || pendingDiagnosticLine != nil
            || line.trimmingCharacters(in: .whitespaces).isEmpty {
            consumeDiagnosticLine(line)
            return
        }
    }

    /// State machine for one diagnostic block:
    ///
    ///     error: unclosed raw text
    ///       ┌─ file.typ:256:209
    ///
    /// The `error:`/`warning:` line is remembered until its location line arrives;
    /// a blank line ends the block. Location-less diagnostics are dropped (they
    /// surface through `compilationStatus` instead), matching the previous behavior.
    private func consumeDiagnosticLine(_ line: String) {
        if line.hasPrefix("error: ") || line.hasPrefix("warning: ") {
            pendingDiagnosticLine = line
            return
        }

        if pendingDiagnosticLine != nil {
            if let match = CompilerRegex.diagnosticLocation.firstMatch(in: line, options: [], range: NSRange(0..<line.utf16.count)) {
                let matchStr = (line as NSString).substring(with: match.range)
                recordDiagnosticLocation(matchStr)
                pendingDiagnosticLine = nil
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                pendingDiagnosticLine = nil
            }
            return
        }

        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            // Blank line ends a diagnostic block — repair anything it flagged.
            flushPendingFallbackFix()
        }
    }

    /// Batch variant of the incremental diagnostic parser for one-shot compile runs
    /// (e.g. exports) where the full compiler output is already in memory.
    private func parseErrors(from output: String) {
        for line in output.components(separatedBy: "\n") {
            consumeDiagnosticLine(line)
        }
    }

    /// Records the file location of the pending diagnostic, mapping the shadow-file
    /// line back to the user's source line. `warning:` diagnostics are kept separate
    /// from errors: they don't block output but are still surfaced and navigable.
    private func recordDiagnosticLocation(_ locationMatch: String) {
        let parts = locationMatch.split(separator: ":")
        guard let lineNum = parts.first.flatMap({ Int($0) }) else { return }

        if !pendingFallbackRawLines.contains(lineNum) {
            pendingFallbackRawLines.append(lineNum)
        }

        guard let diagnosticLine = pendingDiagnosticLine else { return }
        let isWarning = diagnosticLine.hasPrefix("warning: ")
        let prefix = isWarning ? "warning: " : "error: "
        let message = String(diagnosticLine.dropFirst(prefix.count))

        let error = TypstError(
            line: sourceLine(forShadowLine: lineNum),
            message: message,
            severity: isWarning ? .warning : .error
        )
        if isWarning {
            if !typstWarnings.contains(where: { $0.line == error.line && $0.message == message }) {
                typstWarnings.append(error)
            }
        } else {
            if !typstErrors.contains(where: { $0.line == error.line && $0.message == message }) {
                typstErrors.append(error)
            }
        }
        publishIssues()
    }

    /// Runs the lenient fallback fixer for any diagnostics that completed since the
    /// last flush. For `.note` / `.md` files this rewrites the offending shadow-file
    /// lines so the document compiles and the preview is preserved.
    private func flushPendingFallbackFix() {
        let rawLines = pendingFallbackRawLines
        pendingFallbackRawLines = []
        guard !rawLines.isEmpty else { return }
        guard currentFileExtension == "note" || currentFileExtension == "md" else { return }
        attemptFallbackFix(rawErrorLines: rawLines)
    }

    /// Maps a shadow-file line number to the line in the user's editor buffer. The
    /// shadow file holds the converted text (Markdown→Typst for `.note` / `.md`)
    /// plus the injected preamble, so raw compiler positions don't address the
    /// source; `shadowToSourceLine` — built on each `updateContent` — bridges them,
    /// falling back to the preamble-only adjustment for unmatched lines.
    private func sourceLine(forShadowLine line: Int) -> Int {
        let outputLine = line - preambleLineCount
        if outputLine >= 1, let mapped = shadowToSourceLine[outputLine] {
            return mapped
        }
        return max(1, outputLine)
    }

    // MARK: - Shadow → Source Line Mapping

    /// Builds a map from converted-output line (1-based) to source line by walking
    /// both texts in order and matching normalized lines within a small look-ahead
    /// window. The conversion is mostly structure-preserving (headings, lists,
    /// paragraphs and fenced code stay one line each); block-level expansions such
    /// as Markdown tables → `#table(...)` calls insert extra output lines, which the
    /// window absorbs before the next anchor re-syncs the walk.
    nonisolated static func buildLineMap(source: String, output: String) -> [Int: Int] {
        let srcLines = source.components(separatedBy: "\n")
        let outLines = output.components(separatedBy: "\n")
        var map: [Int: Int] = [:]
        var s = 0 // next source line candidate (0-based)
        let window = 8

        for (i, outLine) in outLines.enumerated() {
            let normalized = normalizedForLineMap(outLine)
            var bestJ = -1
            var bestScore = 0.0
            if !normalized.isEmpty {
                let upper = min(srcLines.count, s + window)
                for j in s..<upper {
                    let score = lineMapSimilarity(normalized, normalizedForLineMap(srcLines[j]))
                    if score > bestScore {
                        bestScore = score
                        bestJ = j
                    }
                }
            }
            if bestJ >= 0 && bestScore >= 0.6 {
                map[i + 1] = bestJ + 1
                s = bestJ + 1
            } else {
                // Unanchored line (blank separator, expanded table cell, …): keep it
                // at the current source position.
                map[i + 1] = min(s + 1, max(srcLines.count, 1))
            }
        }
        return map
    }

    private nonisolated static func normalizedForLineMap(_ line: String) -> String {
        String(line.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private nonisolated static func lineMapSimilarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        let common = a.commonPrefix(with: b).count
        return Double(common) / Double(max(a.count, b.count))
    }

    // MARK: - Lenient Fallback Fixer (.note / .md)

    /// For non-strict file types, when Typst reports an error on specific lines of the shadow
    /// file, this method rewrites those lines so the document always compiles and text is
    /// preserved. The content is rendered verbatim in the output instead of being silently
    /// dropped.
    ///
    /// Two escalating strategies are applied, per line, tracked via `fallbackAttempts`:
    ///
    ///   **Strategy 1 – Escape:** escape every Typst-special character on the line so it
    ///   becomes literal plain text. Cheapest fix, looks the nicest, but doesn't help for
    ///   multi-line constructs (e.g. an unbalanced `]` inside a generated `#table()` cell).
    ///
    ///   **Strategy 2 – Wrap in `#raw()`:** replace the entire line with
    ///   `#raw("escaped content", block: true)`. Raw blocks are *never* parsed by Typst,
    ///   so this is guaranteed to compile, no matter what the original line contained.
    ///
    /// `typst watch` detects the file change after each rewrite and recompiles, so a single
    /// problematic section may be fixed across two watch cycles (escape first, raw-wrap if
    /// that wasn't enough).
    ///
    /// **Exclusions:** Lines that start with native Typst top-level directives
    /// (`#import`, `#include`, `#let`, `#set`, `#show`, `#return`) are deliberately left
    /// untouched. These are intentional Typst code the user wrote — for example a package
    /// `#import` may briefly fail while the package downloads, and silently escaping it
    /// would break the rest of the document. The original error is surfaced to the user
    /// instead of being swallowed by the fallback.
    /// Parses raw line numbers where Typst reported errors in its stderr output.
    private func parseRawErrorLines(from output: String) -> [Int] {
        var rawLines: [Int] = []
        let lines = output.components(separatedBy: .newlines)
        var currentErrorMsg: String? = nil
        for line in lines {
            if line.starts(with: "error: ") {
                currentErrorMsg = String(line.dropFirst("error: ".count))
            } else if currentErrorMsg != nil, let match = CompilerRegex.diagnosticLocation.firstMatch(in: line, options: [], range: NSRange(0..<line.utf16.count)) {
                let matchStr = (line as NSString).substring(with: match.range) // ":10:5"
                let parts = matchStr.split(separator: ":")
                if parts.count >= 1, let lineNum = Int(parts[0]) {
                    if !rawLines.contains(lineNum) {
                        rawLines.append(lineNum)
                    }
                }
                currentErrorMsg = nil
            }
        }
        return rawLines
    }

    /// Applies the lenient fallback fix (Strategy 1: escape special characters; Strategy 2: wrap in #raw())
    /// to the specified source file URL for the offending error lines. Returns true if file was modified.
    @discardableResult
    private func applyFallbackFix(to fileURL: URL, rawErrorLines: [Int], attempts: inout [Int: Int], isHybrid: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }

        // Group the offending lines by which strategy we should try next.
        // Lines we've already maxed out (attempt >= 2) are skipped.
        var escapeTargets: [Int] = []
        var rawWrapTargets: [Int] = []
        for line in rawErrorLines {
            let attempt = attempts[line, default: 0]
            if attempt == 0 { escapeTargets.append(line) }
            else if attempt == 1 { rawWrapTargets.append(line) }
        }
        guard !(escapeTargets.isEmpty && rawWrapTargets.isEmpty) else {
            print("[FallbackFix] All error lines already maxed out — skipping.")
            return false
        }

        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            var fileLines = content.components(separatedBy: "\n")
            var modified = false

            // --- Strategy 1: escape special characters ---
            for rawLine in escapeTargets {
                let idx = rawLine - 1  // 1-based → 0-based
                guard idx >= 0 && idx < fileLines.count else { continue }

                let original = fileLines[idx]
                let trimmed = original.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }                          // nothing to escape
                if trimmed.hasPrefix("#raw(\"") { continue }             // already a raw block
                if isProtectedTypstDirective(trimmed, isHybrid: isHybrid) {
                    attempts[rawLine] = 2  // mark as maxed so we don't keep retrying
                    print("[FallbackFix][skip] line \(rawLine): protected directive — \(trimmed.prefix(40))")
                    continue
                }

                fileLines[idx] = escapeTypstLine(original)
                attempts[rawLine] = 1
                modified = true
                print("[FallbackFix][escape] line \(rawLine): \(original.prefix(60))")
            }

            // --- Strategy 2: wrap the whole line in #raw("...", block: true) ---
            for rawLine in rawWrapTargets {
                let idx = rawLine - 1
                guard idx >= 0 && idx < fileLines.count else { continue }

                let original = fileLines[idx]
                let trimmed = original.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if trimmed.hasPrefix("#raw(\"") { continue }             // idempotent
                if isProtectedTypstDirective(trimmed, isHybrid: isHybrid) {
                    attempts[rawLine] = 2
                    print("[FallbackFix][skip] line \(rawLine): protected directive — \(trimmed.prefix(40))")
                    continue
                }

                // Escape backslashes and double-quotes so the line is a valid Typst string.
                let escaped = original
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                fileLines[idx] = "#raw(\"\(escaped)\", block: true)"
                attempts[rawLine] = 2
                modified = true
                print("[FallbackFix][raw-wrap] line \(rawLine): \(original.prefix(60))")
            }

            if modified {
                let newContent = fileLines.joined(separator: "\n")
                try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
                return true
            }
        } catch {
            print("[FallbackFix] Failed to apply fallback fix: \(error)")
        }
        return false
    }

    private func attemptFallbackFix(rawErrorLines: [Int]) {
        guard let shadowURL = currentShadowSourceURL else { return }
        let modified = applyFallbackFix(to: shadowURL, rawErrorLines: rawErrorLines, attempts: &fallbackAttempts, isHybrid: currentFileExtension == "note")
        if modified {
            print("[FallbackFix] Shadow file updated — typst watch will recompile.")
        }
    }

    /// Returns true if `line` is intentional Typst code that should never be touched by
    /// the lenient fallback fixer.
    ///
    /// Top-level directives (`#import`, `#include`, `#let`, `#set`, `#show`, `#return`)
    /// are always protected in every file type — for example, a `#import` that briefly
    /// fails while a package is downloading should never be escaped, otherwise the rest
    /// of the document (which depends on that import) breaks too.
    ///
    /// In hybrid `.note` files we additionally protect any `#word(…)` / `#word[…]` call.
    /// `.note` files mix Markdown and intentional Typst, so a line like
    /// `#score(generated-abc, width: 100%)` is user-written Typst, not generated
    /// Markdown output. We still allow the fallback to act on Markdown-converted
    /// constructs (`#link`, `#image`, `#table`, `#strike`, `#figure`, `#align`,
    /// `#line`, `#footnote`, `#super`, `#sub`, `#underline`, `#highlight`, `#raw`,
    /// `#quote`)
    /// which are the functions `sanitizeMarkdownToTypst` is known to emit.
    private func isProtectedTypstDirective(_ line: String, isHybrid: Bool) -> Bool {
        // Always-protected top-level keywords.
        let topLevel = ["#import", "#include", "#let", "#set", "#show", "#return"]
        if topLevel.contains(where: { line.hasPrefix($0) }) { return true }

        // Only apply the user-Typst heuristic in hybrid `.note` files. Pure `.md` files
        // don't contain user Typst, so a stray `#word(…)` there is more likely a typo.
        guard isHybrid else { return false }

        // Match `#identifier` followed by `(`, `[`, or a space-and-keyword (e.g. `#let x`).
        // The negative lookahead filters out the Markdown converter's known outputs so
        // the fallback can still repair broken converter-generated tables/links/images.
        let markdownConverterFuncs = [
            "link", "image", "table", "strike", "figure", "align", "line",
            "footnote", "super", "sub", "underline", "highlight", "raw", "quote",
        ]
        let nsLine = line as NSString
        guard let match = CompilerRegex.markdownConverterFunc.firstMatch(in: line, options: [], range: NSRange(0..<nsLine.length)) else {
            return false
        }
        let name = nsLine.substring(with: match.range(at: 1))
        return !markdownConverterFuncs.contains(name)
    }

    /// Escapes all Typst special characters in a line so it compiles as literal plain text.
    /// Safely handles strings that might already be partially escaped by removing existing
    /// escapes first, preventing double-escaping (e.g., \$ turning into \\\$).
    private func escapeTypstLine(_ line: String) -> String {
        var result = line
        
        // 1. Remove existing standard Typst escapes to prevent double-escaping
        result = result.replacingOccurrences(of: "\\#", with: "#")
        result = result.replacingOccurrences(of: "\\$", with: "$")
        result = result.replacingOccurrences(of: "\\@", with: "@")
        result = result.replacingOccurrences(of: "\\<", with: "<")
        result = result.replacingOccurrences(of: "\\`", with: "`")
        
        // 2. Escape all special characters
        result = result.replacingOccurrences(of: "#",  with: "\\#")
        result = result.replacingOccurrences(of: "$",  with: "\\$")
        result = result.replacingOccurrences(of: "@",  with: "\\@")
        result = result.replacingOccurrences(of: "<",  with: "\\<")
        result = result.replacingOccurrences(of: "`",  with: "\\`")
        
        return result
    }

    // MARK: - Auto-Fix Broken Syntax (.note)

    /// Proactively repairs broken or incomplete syntax in `.note` files prior to compilation,
    /// ensuring quick compilation without having to fail and recompile through watch cycles.
    ///
    /// Fixes:
    /// - Unclosed code fences (odd count of ```) -> closed at EOF
    /// - Unclosed single-line math expressions ($... without closing $) -> closed with $
    /// - Dangling exponents and subscripts in math ($...^$ or $..._$) -> completed with ^{} or _{}
    /// - Dangling binary / relational operators before closing $ -> completed with ""
    /// - Unbalanced delimiters within math blocks (parentheses, brackets, braces)
    /// - Trailing lone carets (^) in content mode outside math -> escaped as \^
    /// - Trailing bare hash (#) in content mode -> escaped as \#
    nonisolated static func autoFixBrokenNoteSyntax(_ source: String) -> String {
        guard !source.isEmpty else { return source }
        
        var lines = source.components(separatedBy: "\n")
        
        // 1. Check code fences: if count of triple-backtick lines is odd, close at EOF
        var inCodeBlock = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
            }
        }
        if inCodeBlock {
            lines.append("```")
        }
        
        // 2. Process line by line for inline math and syntax fixes outside code blocks
        var currentlyInCode = false
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                currentlyInCode.toggle()
                continue
            }
            if currentlyInCode { continue }
            
            var line = lines[i]

            // Inline code spans are blanked (length-preserving) before any math
            // heuristics run: a lone `$` inside `code` (e.g. the register `$2002`)
            // is not unclosed math, and code contents (`_`, `=`, `\` …) must not
            // veto the currency heuristic for real dollars elsewhere on the line.
            let codeRanges = Self.inlineCodeRanges(in: line)
            let maskedLine = Self.lineMaskingCodeSpans(line, ranges: codeRanges)
            let nsMasked = maskedLine as NSString

            // Fix unclosed single-line math $...
            // Count unescaped $ signs outside code spans (UTF-16 offsets, matching NSRegularExpression)
            var dollarIndices: [Int] = []
            for j in 0..<nsMasked.length {
                if nsMasked.character(at: j) == 0x24 { // $
                    let isEscaped = (j > 0 && nsMasked.character(at: j - 1) == 0x5C) // backslash
                    if !isEscaped {
                        dollarIndices.append(j)
                    }
                }
            }

            // If odd number of $, close the math — unless the dollars read as
            // currency amounts (e.g. `$4017 … $4015`, all followed by a digit and
            // no math operators anywhere). Closing those would pair two currency
            // dollars into a bogus math region that swallows the rest of the line;
            // the delimiting pass escapes them as literal text instead.
            if dollarIndices.count % 2 != 0 {
                let isCurrency = !dollarIndices.isEmpty && dollarIndices.allSatisfy { idx in
                    idx + 1 < nsMasked.length && (0x30...0x39).contains(nsMasked.character(at: idx + 1))
                }
                let hasMathOperators = maskedLine.contains("=") || maskedLine.contains("^")
                    || maskedLine.contains("_") || maskedLine.contains("\\")
                if !(isCurrency && !hasMathOperators) {
                    line.append("$")
                }
            }

            // Fix dangling ^ or _ or binary operators inside math blocks: $...$ or $$...$$
            let nsLine = line as NSString
            let matches = CompilerRegex.mathBlock.matches(in: line, options: [], range: NSRange(0..<nsLine.length))
            var fixedLine = line
            for m in matches.reversed() {
                // Never "fix" content inside inline code spans (`` `$x +$` `` is
                // the user's code, not broken math).
                if codeRanges.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                    continue
                }
                let mathContent = nsLine.substring(with: m.range(at: 1))
                var fixedMath = mathContent
                
                // Replace trailing ^ or _ before end of math: e.g. "k=1^" -> "k=1^{}"
                fixedMath = CompilerRegex.trailSupSub.stringByReplacingMatches(in: fixedMath, options: [], range: NSRange(0..<fixedMath.utf16.count), withTemplate: "$1{}")
                
                // Replace trailing binary/relational operators before end of math: e.g. "x + " -> "x + \"\""
                fixedMath = CompilerRegex.trailOp.stringByReplacingMatches(in: fixedMath, options: [], range: NSRange(0..<fixedMath.utf16.count), withTemplate: "$1 \"\"")
                
                // Replace trailing lone backslash
                if fixedMath.hasSuffix("\\") && !fixedMath.hasSuffix("\\\\") {
                    fixedMath.removeLast()
                }
                
                // Check balanced delimiters inside this math block: ( ), [ ], { }
                var parenCount = 0
                var bracketCount = 0
                var braceCount = 0
                for c in fixedMath {
                    if c == "(" { parenCount += 1 }
                    else if c == ")" { parenCount = max(0, parenCount - 1) }
                    else if c == "[" { bracketCount += 1 }
                    else if c == "]" { bracketCount = max(0, bracketCount - 1) }
                    else if c == "{" { braceCount += 1 }
                    else if c == "}" { braceCount = max(0, braceCount - 1) }
                }
                if braceCount > 0 { fixedMath.append(String(repeating: "}", count: braceCount)) }
                if bracketCount > 0 { fixedMath.append(String(repeating: "]", count: bracketCount)) }
                if parenCount > 0 { fixedMath.append(String(repeating: ")", count: parenCount)) }
                
                if fixedMath != mathContent {
                    let fullMatchRange = m.range
                    let delimiter = (nsLine.substring(with: fullMatchRange).hasPrefix("$$")) ? "$$" : "$"
                    let replacement = "\(delimiter)\(fixedMath)\(delimiter)"
                    fixedLine = (fixedLine as NSString).replacingCharacters(in: fullMatchRange, with: replacement)
                }
            }
            line = fixedLine
            
            // Content mode fixes:
            // Escape lone trailing ^ at end of line (outside math):
            line = CompilerRegex.loneCaret.stringByReplacingMatches(in: line, options: [], range: NSRange(0..<line.utf16.count), withTemplate: "\\\\^")
            
            // Bare trailing # at end of line:
            line = CompilerRegex.bareHash.stringByReplacingMatches(in: line, options: [], range: NSRange(0..<line.utf16.count), withTemplate: "\\\\#")
            
            lines[i] = line
        }
        
        return lines.joined(separator: "\n")
    }

    /// Ranges of inline code spans (`` `…` ``) in a single line, using the same
    /// matching-backtick-run rule as the sanitizer and `delimitImproperOperators`.
    nonisolated static func inlineCodeRanges(in line: String) -> [NSRange] {
        let ns = line as NSString
        guard ns.length > 0 else { return [] }
        return CompilerRegex.codeSpan.matches(in: line, options: [], range: NSRange(0..<ns.length)).map { $0.range }
    }

    /// Returns a copy of `line` where every character inside `ranges` is replaced by a
    /// space (newlines preserved). The result has exactly the same UTF-16 length, so
    /// offsets in the masked string address the original line.
    nonisolated static func lineMaskingCodeSpans(_ line: String, ranges: [NSRange]) -> String {
        let ns = line as NSString
        guard ns.length > 0 else { return line }
        var chars: [unichar] = (0..<ns.length).map { ns.character(at: $0) }
        for r in ranges {
            let end = min(r.location + r.length, chars.count)
            guard r.location < end else { continue }
            for i in r.location..<end where chars[i] != 0x0A {
                chars[i] = 0x20
            }
        }
        return NSString(characters: chars, length: chars.count) as String
    }

    // MARK: - Improper Operator Delimiting (.note)

    /// For hybrid `.note` files, locates Typst operator characters (`@ # $ < >`)
    /// that are NOT used as valid Typst syntax and delimits each with a backslash
    /// so the parser doesn't have to guess their meaning (and silently mis-render).
    ///
    /// Left untouched (i.e. legitimate Typst / Markdown that we must not break):
    ///   - `@label`            references (an `@` followed by an identifier that
    ///                          isn't glued to a preceding word / email)
    ///   - `#word`, `#"…"`, `#(…)`, `#{…}`, `#123`   top-level code expressions
    ///   - `$ … $`             math (masked out before scanning)
    ///   - `<label>`, `<tag>`, `</tag>`, `<!--…-->`  labels & HTML (handled later)
    ///   - anything inside inline/fenced code spans or math regions (masked out)
    ///
    /// Each source line that needed delimiting produces a single `.warning`
    /// `TypstError` (1-based line numbers refer to the user's original file). The
    /// returned `output` is meant to feed into `sanitizeMarkdownToTypst`, whose
    /// hybrid escape rules are idempotent (`(?<!\\)`) so they won't double-escape.
    nonisolated static func delimitImproperOperators(_ source: String) -> (output: String, warnings: [TypstError]) {
        let ns = source as NSString
        let length = ns.length
        guard length > 0 else { return (source, []) }

        // 1. Build a mask of the same length where protected regions (code spans
        //    and math) are blanked to spaces — newlines preserved — so operator
        //    scanning can't match inside them while every line offset stays exact.
        var masked: [unichar] = Array(repeating: 0, count: length)
        for i in 0..<length { masked[i] = ns.character(at: i) }
        func blank(_ r: NSRange) {
            guard r.location != NSNotFound, r.location < length, r.length > 0 else { return }
            let end = min(r.location + r.length, length)
            for i in r.location..<end where masked[i] != 0x0A { masked[i] = 0x20 }
        }
        // Inline / fenced code spans with matching backtick runs (same pattern the
        // sanitizer uses).
        CompilerRegex.codeSpan.enumerateMatches(in: source, options: [], range: NSRange(0..<length)) { m, _, _ in
            if let m = m { blank(m.range) }
        }
        // Math regions: $$…$$, $…$, \[…\], \(…\).
        CompilerRegex.mathRegion.enumerateMatches(in: source, options: [], range: NSRange(0..<length)) { m, _, _ in
            if let m = m { blank(m.range) }
        }
        let maskedString = NSString(characters: masked, length: length) as String

        // 2. Precompute a line number for every character index (O(1) lookup later).
        var lineOf: [Int] = Array(repeating: 1, count: length + 1)
        var running = 1
        for i in 0..<length {
            lineOf[i] = running
            if masked[i] == 0x0A { running += 1 }
        }
        lineOf[length] = running

        // 3. Character-class helpers (ASCII code points).
        func charAt(_ i: Int) -> unichar? { (i >= 0 && i < length) ? masked[i] : nil }
        func isDigit(_ x: unichar?) -> Bool { guard let x = x else { return false }; return (0x30...0x39).contains(x) }
        func isAlpha(_ x: unichar?) -> Bool { guard let x = x else { return false }; return (0x41...0x5A).contains(x) || (0x61...0x7A).contains(x) }
        func isAlnum(_ x: unichar?) -> Bool { isAlpha(x) || isDigit(x) }
        func isIdentStart(_ x: unichar?) -> Bool { x == 0x5F || isAlpha(x) }                 // [_A-Za-z]
        func isHashContinuation(_ x: unichar?) -> Bool {                                       // valid after '#'
            guard let x = x else { return false }
            if isAlnum(x) || x == 0x5F { return true }                                         // word / number
            return x == 0x22 || x == 0x7B || x == 0x28                                         // " { (
        }
        func isTagStart(_ x: unichar?) -> Bool {                                               // valid after '<'
            guard let x = x else { return false }
            return isAlpha(x) || x == 0x2F || x == 0x21                                        // letter / !
        }
        func isTagEndPrev(_ x: unichar?) -> Bool {                                             // valid before '>'
            guard let x = x else { return false }
            if isAlnum(x) || x == 0x5F { return true }                                         // name char
            return x == 0x2D || x == 0x2F || x == 0x22 || x == 0x27 || x == 0x3D              // - / " ' =
        }
        // An ATX Markdown heading (`#`, `##` … followed by a space, at line start,
        // optionally inside a blockquote). The sanitizer converts these to Typst `=`
        // headings, so every `#` of the heading run must reach it unescaped.
        func isMarkdownHeadingStart(_ loc: Int) -> Bool {
            var i = loc - 1
            // Skip back over the rest of the heading run, then any blockquote/space prefix.
            while i >= 0, let c = charAt(i), c == 0x23 { i -= 1 }                              // '#'
            while i >= 0, let c = charAt(i), c == 0x20 || c == 0x09 || c == 0x3E { i -= 1 }    // space, tab, '>'
            if i >= 0, let c = charAt(i), c != 0x0A { return false }                           // not at line start
            var j = loc
            while let c = charAt(j), c == 0x23 { j += 1 }                                      // run of '#'
            guard let after = charAt(j) else { return true }
            return after == 0x20 || after == 0x09
        }
        // A Markdown blockquote marker: `>` at line start (optionally nested after
        // other `>`), which the sanitizer's heading/list rules recognize as a prefix.
        func isBlockquoteMarker(_ loc: Int) -> Bool {
            var i = loc - 1
            while i >= 0, let c = charAt(i), c == 0x20 || c == 0x09 || c == 0x3E { i -= 1 }    // space, tab, '>'
            if i >= 0, let c = charAt(i), c != 0x0A { return false }
            guard let next = charAt(loc + 1) else { return true }                              // bare '>' line
            return next == 0x20 || next == 0x09 || next == 0x0A
        }

        // 4. Enumerate every unescaped operator and classify it against its context.
        var improper: [(loc: Int, op: Character)] = []
        for m in CompilerRegex.operatorRe.matches(in: maskedString, options: [], range: NSRange(0..<length)) {
            let loc = m.range.location
            guard loc < length else { continue }
            let u = masked[loc]
            let prev = charAt(loc - 1)
            let next = charAt(loc + 1)
            let improperNow: Bool
            switch u {
            case 0x40: // @  — must begin a reference (not be glued to a word/email)
                improperNow = isAlnum(prev) || !isIdentStart(next)
            case 0x23: // #  — must be the start of a code expression
                improperNow = !isHashContinuation(next) && !isMarkdownHeadingStart(loc)
            case 0x24: // $  — any leftover $ is stray once math is masked
                improperNow = true
            case 0x3C: // <  — must open a label / HTML tag
                improperNow = !isTagStart(next)
            case 0x3E: // >  — must close a label / HTML tag (or open a blockquote)
                improperNow = !isTagEndPrev(prev) && !isBlockquoteMarker(loc)
            default:
                improperNow = false
            }
            if improperNow, let scalar = UnicodeScalar(u) {
                improper.append((loc, Character(scalar)))
            }
        }
        guard !improper.isEmpty else { return (source, []) }

        // 5. Group delimitations per source line → one warning per line.
        var byLine: [Int: [Character]] = [:]
        var lineOrder: [Int] = []
        for (loc, op) in improper {
            let ln = lineOf[loc]
            if byLine[ln] == nil { lineOrder.append(ln) }
            var arr = byLine[ln] ?? []
            if !arr.contains(op) { arr.append(op) }
            byLine[ln] = arr
        }
        let warnings: [TypstError] = lineOrder.sorted().map { ln in
            let ops = (byLine[ln] ?? []).map { String($0) }.joined(separator: ", ")
            let msg = "Auto-escaped \(ops) — not valid Typst here, so the parser would " +
                      "guess its meaning. Use proper Typst syntax or escape it yourself (e.g. \\@)."
            return TypstError(line: ln, message: msg, severity: .warning)
        }

        // 6. Apply the backslash escapes to the original source (right-to-left so
        //    earlier insert locations aren't shifted by later ones).
        let mutable = NSMutableString(string: source)
        for (loc, _) in improper.sorted(by: { $0.loc > $1.loc }) {
            mutable.insert("\\", at: loc)
        }
        return ((mutable as String), warnings)
    }

    // --- Export Functions ---
    
    nonisolated static func exportDestinationURL(for format: String, requested: URL) -> URL {
        let normalizedFormat = format.lowercased()
        let validImageFormats = Set(["png", "svg"])
        guard validImageFormats.contains(normalizedFormat) else {
            return requested
        }

        let templateName = "{0p}"
        let baseName = requested.deletingPathExtension().lastPathComponent
        if baseName.contains("{p}") || baseName.contains("{0p}") {
            return requested
        }

        let directory = requested.deletingLastPathComponent()
        let pagePatternURL = directory.appendingPathComponent("\(baseName)-\(templateName).\(normalizedFormat)")
        return pagePatternURL
    }

    nonisolated static func firstGeneratedExportURL(for templateURL: URL) -> URL? {
        let directory = templateURL.deletingLastPathComponent()
        let templateName = templateURL.deletingPathExtension().lastPathComponent
        let extensionName = templateURL.pathExtension.lowercased()
        let prefix = templateName
            .replacingOccurrences(of: "{0p}", with: "")
            .replacingOccurrences(of: "{p}", with: "")

        guard let fileEnumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }

        let matches = fileEnumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == extensionName }
            .filter { $0.deletingPathExtension().lastPathComponent.hasPrefix(prefix + "-") || $0.deletingPathExtension().lastPathComponent == prefix }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return matches.first
    }
    
    func export(sourceURL: URL, outputURL: URL, format: String, projectRoot: URL? = nil) async -> (success: Bool, error: String?) {
        guard let typstPath = resolveTypstPath() else {
            return (false, "Error: 'typst' executable not found.")
        }
        
        let effectiveOutputURL = Self.exportDestinationURL(for: format, requested: outputURL)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        
        var arguments = ["compile", sourceURL.path, effectiveOutputURL.path, "--format", format]
        
        // Pass root if available
        if let root = projectRoot {
            arguments.append(contentsOf: ["--root", root.path])
            process.currentDirectoryURL = root
        }
        
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            if process.terminationStatus != 0 {
                print("[TYPST-EXPORT-ERROR]: \(output)")
                if output.contains("error:") {
                    parseErrors(from: output)
                }
                return (false, output.isEmpty ? "Unknown Typst error (exit code \(process.terminationStatus))" : output)
            }
            
            print("[TYPST-EXPORT-SUCCESS]: \(effectiveOutputURL.lastPathComponent)")
            return (true, nil)
        } catch {
            print("[TYPST-EXPORT] Failed to run: \(error)")
            return (false, error.localizedDescription)
        }
    }

    /// Exports note/markdown content to PNG, SVG, or PDF by preprocessing Markdown,
    /// adding necessary preambles, resolving images, and applying fallback fixes on error.
    func exportFormatted(content: String, fileExtension: String, originalFileURL: URL, outputURL: URL, format: String, projectRoot: URL? = nil) async -> (success: Bool, error: String?) {
        guard let typstPath = resolveTypstPath() else {
            return (false, "Error: 'typst' executable not found.")
        }
        
        let preferredDirectory = originalFileURL.deletingLastPathComponent()
        let tempDir = ensureTempDirectory(in: preferredDirectory)
        let tempID = UUID().uuidString
        let sourceURL = tempDir.appendingPathComponent(".export-\(tempID.prefix(8)).typ")
        
        var finalContent = content
        let ext = fileExtension.lowercased()
        let isHybrid = (ext == "note")
        
        if isHybrid {
            finalContent = Self.autoFixBrokenNoteSyntax(finalContent)
        }
        
        if ext == "md" || ext == "note" {
            let aiService = AICompletionService.shared
            let textToProcess = finalContent
            finalContent = await Task.detached {
                let input = isHybrid ? Self.delimitImproperOperators(textToProcess).output : textToProcess
                return aiService.sanitizeMarkdownToTypst(input, isHybrid: isHybrid)
            }.value
        }
        if ext == "note" {
            finalContent = Self.notePreamble + finalContent
        }
        
        finalContent = await resolveWebImages(in: finalContent, projectRoot: projectRoot)
        
        finalContent = await self.rewriteRelativeImports(in: finalContent, sourceDirectory: preferredDirectory, tempDirectory: tempDir)
        
        do {
            try finalContent.write(to: sourceURL, atomically: true, encoding: .utf8)
        } catch {
            return (false, "Failed to write temp export source: \(error.localizedDescription)")
        }
        
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        
        let effectiveRoot = preferredDirectory
        let effectiveOutputURL = Self.exportDestinationURL(for: format, requested: outputURL)
        var arguments = ["compile", sourceURL.path, effectiveOutputURL.path, "--format", format]
        arguments.append(contentsOf: ["--root", effectiveRoot.path])
        
        var cleanFallbackAttempts: [Int: Int] = [:]
        var iteration = 0
        var lastOutput = ""
        
        while iteration < 3 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: typstPath)
            process.currentDirectoryURL = effectiveRoot
            process.arguments = arguments
            
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lastOutput = String(data: data, encoding: .utf8) ?? ""
                
                if process.terminationStatus == 0 {
                    return (true, nil)
                }
                
                if ext == "note" || ext == "md" {
                    let rawLines = parseRawErrorLines(from: lastOutput)
                    if !rawLines.isEmpty {
                        let modified = applyFallbackFix(to: sourceURL, rawErrorLines: rawLines, attempts: &cleanFallbackAttempts, isHybrid: isHybrid)
                        if modified {
                            iteration += 1
                            continue
                        }
                    }
                }
                
                return (false, lastOutput.isEmpty ? "Unknown Typst error (exit code \(process.terminationStatus))" : lastOutput)
            } catch {
                return (false, error.localizedDescription)
            }
        }
        
        return (false, lastOutput)
    }

    func compileClean(content: String, fileExtension: String? = nil, originalFileURL: URL? = nil, projectRoot: URL?) async -> (success: Bool, pdfURL: URL?, error: String?) {
        guard let typstPath = resolveTypstPath() else {
            return (false, nil, "Error: 'typst' executable not found.")
        }
        
        let preferredDirectory = originalFileURL?.deletingLastPathComponent()
        
        let tempDir: URL
        if let pref = preferredDirectory {
            tempDir = ensureTempDirectory(in: pref)
        } else {
            tempDir = FileManager.default.temporaryDirectory
        }
        
        let tempID = UUID().uuidString
        let sourceURL = tempDir.appendingPathComponent(".clean-\(tempID.prefix(8)).typ")
        
        let pdfURL: URL
        if let original = originalFileURL {
            let tempFolder = tempDir.appendingPathComponent(tempID)
            try? FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
            let pdfFilename = original.deletingPathExtension().appendingPathExtension("pdf").lastPathComponent
            pdfURL = tempFolder.appendingPathComponent(pdfFilename)
        } else {
            pdfURL = tempDir.appendingPathComponent(".clean-\(tempID.prefix(8)).pdf")
        }
        
        var finalContent = content
        
        let ext = fileExtension ?? currentFileExtension
        let isHybrid = (ext == "note")
        
        if isHybrid {
            finalContent = Self.autoFixBrokenNoteSyntax(finalContent)
        }
        
        if ext == "md" || ext == "note" {
            let aiService = AICompletionService.shared
            let textToProcess = finalContent
            finalContent = await Task.detached {
                // Delimit improper operators first (same pass as the live preview)
                // so exports of `.note` files don't break on stray @/#/$/</>.
                let input = isHybrid ? Self.delimitImproperOperators(textToProcess).output : textToProcess
                return aiService.sanitizeMarkdownToTypst(input, isHybrid: isHybrid)
            }.value
        }
        if ext == "note" {
            finalContent = Self.notePreamble + finalContent
        }
        
        finalContent = await resolveWebImages(in: finalContent, projectRoot: projectRoot)
        
        finalContent = await self.rewriteRelativeImports(in: finalContent, sourceDirectory: preferredDirectory ?? tempDir, tempDirectory: tempDir)
        
        do {
            try finalContent.write(to: sourceURL, atomically: true, encoding: .utf8)
        } catch {
            return (false, nil, "Failed to write temp source: \(error.localizedDescription)")
        }
        
        let effectiveRoot = preferredDirectory ?? projectRoot
        var arguments = ["compile", sourceURL.path, pdfURL.path]
        if let root = effectiveRoot {
            arguments.append(contentsOf: ["--root", root.path])
        }
        
        defer {
            // Clean up temp source file
            try? FileManager.default.removeItem(at: sourceURL)
        }
        
        var cleanFallbackAttempts: [Int: Int] = [:]
        var iteration = 0
        var lastOutput = ""
        
        while iteration < 3 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: typstPath)
            if let root = effectiveRoot {
                process.currentDirectoryURL = root
            }
            process.arguments = arguments
            
            let pipe = Pipe()
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                if process.terminationStatus == 0 {
                    return (true, pdfURL, nil)
                }
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lastOutput = String(data: data, encoding: .utf8) ?? "Unknown error"
                
                if ext == "note" || ext == "md" {
                    let rawLines = parseRawErrorLines(from: lastOutput)
                    if !rawLines.isEmpty {
                        let modified = applyFallbackFix(to: sourceURL, rawErrorLines: rawLines, attempts: &cleanFallbackAttempts, isHybrid: isHybrid)
                        if modified {
                            iteration += 1
                            continue
                        }
                    }
                }
                
                return (false, nil, lastOutput)
            } catch {
                return (false, nil, error.localizedDescription)
            }
        }
        
        return (false, nil, lastOutput)
    }

    // MARK: - Web Image Resolver
    
    private func resolveWebImages(in text: String, projectRoot: URL?) async -> String {
        let matches = CompilerRegex.webImage.matches(in: text, options: [], range: NSRange(0..<text.utf16.count))
        var urlsToFetch: Set<String> = []
        
        let nsText = text as NSString
        for match in matches {
            let url = nsText.substring(with: match.range(at: 1))
            if url.lowercased().hasPrefix("http") {
                urlsToFetch.insert(url)
            }
        }
        
        guard !urlsToFetch.isEmpty, let root = projectRoot else { return text }
        
        // Replace web URLs with cached local copies inside the project's temp/ folder
        var processed = text
        let tempDir: URL
        let tempDirPath = SafeDirectoryManager.safeTempDirectory(in: root)
        if !FileManager.default.fileExists(atPath: tempDirPath.path) {
            try? SafeDirectoryManager.createDirectorySafely(at: tempDirPath, withIntermediateDirectories: true)
        }
        tempDir = tempDirPath

        for url in urlsToFetch {
            if let (data, ext) = await WebImageCache.shared.download(urlString: url) {
                let safeName = "web_img_\(abs(url.hashValue)).\(ext)"
                let localURL = tempDir.appendingPathComponent(safeName)
                
                // Always overwrite to clear out any corrupted HTML 403 pages from previous runs
                try? data.write(to: localURL, options: .atomic)
                
                // FIX: Use an absolute path from the Typst root to ensure it resolves 
                // correctly regardless of where the shadow file is located.
                processed = processed.replacingOccurrences(of: "\"\(url)\"", with: "\"/temp/\(safeName)\"")
            }
        }
        
        return processed
    }
    
    // MARK: - Relative Import Rewriter
    
    /// Rewrites relative `#import`, `#include`, and `#image` paths so they remain valid
    /// when the shadow source is written into a temporary folder. If the original source
    /// is nested under a subdirectory, we compute the path relative to the temp directory
    /// rather than blindly prepending `../`.
    func rewriteRelativeImports(in content: String, sourceDirectory: URL?, tempDirectory: URL?) async -> String {
        // Preserve the old behavior when no source context is available.
        guard let sourceDirectory, let tempDirectory else {
            return await rewriteRelativeImports(in: content)
        }

        let relativePrefix = (tempDirectory == sourceDirectory) ? "" : relativePath(from: tempDirectory, to: sourceDirectory)
        let prefixForImports = relativePrefix.isEmpty || relativePrefix == "." ? "" : relativePrefix + "/"

        var processed = content

        let importMatches = CompilerRegex.relativeImport.matches(
            in: processed,
            options: [],
            range: NSRange(0..<processed.utf16.count)
        ).reversed()

        for match in importMatches {
            let prefix = (processed as NSString).substring(with: match.range(at: 1))
            let rawPath = (processed as NSString).substring(with: match.range(at: 2))
            let suffix = (processed as NSString).substring(with: match.range(at: 3))
            
            var rewrittenPath = resolveRelativeImportPath(rawPath, relativePrefix: prefixForImports)
            
            if (rawPath.hasSuffix(".note") || rawPath.hasSuffix(".md")), let loader = self.fileLoader {
                let filename = (rawPath as NSString).lastPathComponent
                if let fileContent = loader(filename) {
                    let isHybrid = rawPath.hasSuffix(".note")
                    let textToProcess = isHybrid ? Self.autoFixBrokenNoteSyntax(fileContent) : fileContent
                    let aiService = AICompletionService.shared
                    var converted = await Task.detached {
                        let input = isHybrid ? Self.delimitImproperOperators(textToProcess).output : textToProcess
                        return aiService.sanitizeMarkdownToTypst(input, isHybrid: isHybrid)
                    }.value
                    
                    if isHybrid {
                        converted = Self.notePreamble + converted
                    }
                    
                    let newFilename = filename.replacingOccurrences(of: ".note", with: ".typ").replacingOccurrences(of: ".md", with: ".typ")
                    let tempFileURL = tempDirectory.appendingPathComponent(newFilename)
                    try? converted.write(to: tempFileURL, atomically: true, encoding: .utf8)
                    
                    // We point the import directly to the newly compiled .typ file in the temp directory!
                    rewrittenPath = newFilename
                }
            }

            let rewritten = prefix + rewrittenPath + suffix
            let fullRange = Range(match.range, in: processed)!
            processed.replaceSubrange(fullRange, with: rewritten)
        }

        let imageMatches = CompilerRegex.relativeImage.matches(
            in: processed,
            options: [],
            range: NSRange(0..<processed.utf16.count)
        ).reversed()

        for match in imageMatches {
            let prefix = (processed as NSString).substring(with: match.range(at: 1))
            let rawPath = (processed as NSString).substring(with: match.range(at: 2))
            let suffix = (processed as NSString).substring(with: match.range(at: 3))
            let rewritten = prefix + resolveRelativeImportPath(rawPath, relativePrefix: prefixForImports) + suffix
            let fullRange = Range(match.range, in: processed)!
            processed.replaceSubrange(fullRange, with: rewritten)
        }

        return processed
    }

    private func rewriteRelativeImports(in content: String) async -> String {
        var processed = content

        processed = CompilerRegex.relativeImport.stringByReplacingMatches(
            in: processed,
            options: [],
            range: NSRange(0..<processed.utf16.count),
            withTemplate: "$1../$2$3"
        )

        processed = CompilerRegex.relativeImage.stringByReplacingMatches(
            in: processed,
            options: [],
            range: NSRange(0..<processed.utf16.count),
            withTemplate: "$1../$2$3"
        )

        return processed
    }

    private func relativePath(from tempDirectory: URL, to sourceDirectory: URL) -> String {
        let from = tempDirectory.standardizedFileURL.pathComponents
        let to = sourceDirectory.standardizedFileURL.pathComponents

        var common = 0
        let count = min(from.count, to.count)
        while common < count, from[common] == to[common] {
            common += 1
        }

        let upCount = max(0, from.count - common)
        let downComponents = Array(to.dropFirst(common))
        let upComponents = Array(repeating: "..", count: upCount)
        let combined = upComponents + downComponents
        return combined.joined(separator: "/")
    }

    private func resolveRelativeImportPath(_ rawPath: String, relativePrefix: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return rawPath }
        if relativePrefix.isEmpty { return trimmed }
        return relativePrefix + trimmed
    }
} // End of TypstCompiler class

// MARK: - Web Image Caching Actor
actor WebImageCache {
    static let shared = WebImageCache()
    private var cache: [String: (Data, String)] = [:]
    private var activeDownloads: [String: Task<(Data, String)?, Never>] = [:]

    func download(urlString: String) async -> (Data, String)? {
        if let cached = cache[urlString] { return cached }
        
        // If we are already downloading this image, wait for it
        if let active = activeDownloads[urlString] {
            return await active.value
        }

        let task = Task { () -> (Data, String)? in
            guard let url = URL(string: urlString) else { return nil }
            do {
                var request = URLRequest(url: url)
                // Masquerade as Safari to prevent servers (like Wikimedia) from returning 403 Forbidden HTML pages
                request.addValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
                
                let (data, response) = try await URLSession.shared.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    print("[ImageCache] HTTP Error \(httpResponse.statusCode) downloading \(urlString)")
                    return nil
                }
                
                var ext = url.pathExtension.lowercased()
                if ext.isEmpty { ext = "png" }
                
                if let mimeType = response.mimeType {
                    if mimeType == "image/png" { ext = "png" }
                    else if mimeType == "image/jpeg" { ext = "jpg" }
                    else if mimeType == "image/gif" { ext = "gif" }
                    else if mimeType == "image/svg+xml" { ext = "svg" }
                }
                
                // Magic bytes fallback (supercedes MIME type if it's wrong, like the GitHub issue)
                if data.count > 4 {
                    let bytes = [UInt8](data.prefix(4))
                    if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
                        ext = "png"
                    } else if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
                        ext = "jpg"
                    } else if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 {
                        ext = "gif"
                    }
                }
                
                return (data, ext)
            } catch {
                print("[ImageCache] Failed to download \(urlString): \(error)")
                return nil
            }
        }

        activeDownloads[urlString] = task
        let result = await task.value
        if let res = result { cache[urlString] = res }
        activeDownloads[urlString] = nil
        return result
    }
}

extension Notification.Name {
    static let pdfDidUpdate = Notification.Name("pdfDidUpdate")
    static let typstErrorsUpdated = Notification.Name("typstErrorsUpdated")
}