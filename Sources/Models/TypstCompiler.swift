import Foundation
import Combine

struct TypstError: Identifiable, Equatable {
    let id = UUID()
    let line: Int // 1-based
    let message: String
}

@MainActor
class TypstCompiler: ObservableObject {
    @Published var compilationStatus: String = "Ready"
    @Published var isCompiling: Bool = false
    @Published var errors: [TypstError] = []
    
    var isDarkMode: Bool = false
    private var preambleLineCount: Int {
        var count = 0
        if isDarkMode {
            count += darkModePreamble.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        }
        if currentFileExtension == "note" {
            count += notePreamble.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        }
        return count
    }
    
    private let darkModePreamble = 
"""
#set page(fill: rgb("#1a1a1a"))
#set text(fill: rgb("#d1d1d1"))
#set line(stroke: rgb("#d1d1d1"))
#set rect(stroke: rgb("#d1d1d1"))
#set circle(stroke: rgb("#d1d1d1"))
#set table(stroke: rgb("#d1d1d1"))
#show raw: set text(fill: rgb("#d1d1d1"))
""" + "\n"
    
    private let notePreamble =
"""
#let title(body) = align(center)[#text(size: 24pt, weight: "bold")[#body]]
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
        
        // Priority 2: Common system paths
        let paths = [
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

    // Lenient-mode fallback tracking (used for .note / .md files)
    // `fallbackAttempts[line] = n` records how many escalating fixes we've applied
    // to that raw shadow-file line. Each escalation is more aggressive so that,
    // eventually, *something* always renders.
    //   0 → (untouched)   1 → escape special chars   2 → wrap whole line in #raw()
    private var currentFileExtension: String = ""
    private var fallbackAttempts: [Int: Int] = [:]
    private var lastRawErrorLines: [Int] = []        // raw shadow-file line numbers from last error
    
    func cleanUp() {
        if let process = currentProcess {
            process.terminate()
        }
        currentProcess = nil
        processOutputPipe?.fileHandleForReading.readabilityHandler = nil
        processOutputPipe = nil
        currentShadowSourceURL = nil
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
            // because the user typed new content — start fresh.
            currentFileExtension = ext
            fallbackAttempts = [:]
            lastRawErrorLines = []

            if ext == "md" || ext == "note" {
                let textToProcess = finalSource
                let aiService = AICompletionService.shared
                finalSource = await Task.detached {
                    aiService.sanitizeMarkdownToTypst(textToProcess, isHybrid: ext == "note")
                }.value
            }
            
            var injectedPreamble = ""
            if ext == "note" {
                injectedPreamble += notePreamble
            }
            if isDarkMode {
                injectedPreamble += darkModePreamble
            }
            finalSource = injectedPreamble + finalSource
            
            // Download web images and inject local paths before saving
            finalSource = await resolveWebImages(in: finalSource, projectRoot: projectRoot)
            
            let finalSourceToWrite = finalSource
            try await Task.detached {
                try finalSourceToWrite.write(to: shadowSourceURL, atomically: true, encoding: .utf8)
            }.value
            
            // Clear errors on new content update
            Task { @MainActor in
                if !self.errors.isEmpty {
                    self.errors = []
                    NotificationCenter.default.post(name: .typstErrorsUpdated, object: [])
                }
            }
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
        self.errors = [] // Clear errors on start
        
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
            
            if let output = String(data: data, encoding: .utf8) {
                print("[TYPST-OUTPUT]: \(output)") // Enhanced logging
                
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    
                    // Simple heuristic: if we see "compiled" or "success", update view
                    if output.contains("compiled successfully") || output.contains("compiled") {
                         // Notify View with a small delay to ensure file is fully flushed
                         DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                             NotificationCenter.default.post(name: .pdfDidUpdate, object: outputURL)
                         }
                         // Also clear errors if success? Ideally yes.
                         // But if we have warnings? Typst prints warnings too.
                         // If "compiled successfully", usually no errors.
                         if !self.errors.isEmpty {
                             self.errors = []
                             NotificationCenter.default.post(name: .typstErrorsUpdated, object: [])
                         }
                    } else if output.contains("error:") {
                        print("[TYPST] Detected error message")
                        self.compilationStatus = "Compilation Error"
                        self.parseErrors(from: output)

                        // Lenient mode: for .note and .md files, escape the exact lines that
                        // Typst rejected so the document always compiles and text is preserved.
                        if self.currentFileExtension == "note" || self.currentFileExtension == "md" {
                            let rawLines = self.lastRawErrorLines
                            if !rawLines.isEmpty {
                                self.attemptFallbackFix(rawErrorLines: rawLines)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func parseErrors(from output: String) {
        // Regex to match "error: message" and subsequent "  at file:line:col"
        // Typst error format often looks like:
        // error: expected length, found string
        //    at file.typ:15:10
        //
        // Or sometimes just "error: ..." if no location.
        // We will iterate line by line to build a list.
        
        let lines = output.components(separatedBy: .newlines)
        // Accumulate errors instead of resetting.
        // We rely on updateContent() or specific "success" messages to clear old errors.
        var newErrors: [TypstError] = self.errors 
        
        var currentErrorMsg: String? = nil
        
        var newRawErrorLines: [Int] = []

        for line in lines {
            if line.starts(with: "error: ") {
                // If we had a previous error pending without a location, maybe add it? 
                // But usually we want location. For now, let's start a new error.
                currentErrorMsg = String(line.dropFirst("error: ".count))
            } else if let msg = currentErrorMsg, let range = line.range(of: ":\\d+:\\d+", options: .regularExpression) {
                // We found a location line for the current error
                // Extract line number
                let match = String(line[range]) // ":10:5"
                let parts = match.split(separator: ":")
                if parts.count >= 1, let lineNum = Int(parts[0]) {
                    // Keep the raw shadow-file line for fallback fix purposes
                    if !newRawErrorLines.contains(lineNum) {
                        newRawErrorLines.append(lineNum)
                    }

                    let adjustedLine = max(1, lineNum - preambleLineCount)
                    
                    // Avoid duplicate errors for the same line if possible, or just allow them
                    // Check if we already have this error
                    let error = TypstError(line: adjustedLine, message: msg)
                    if !newErrors.contains(where: { $0.line == adjustedLine && $0.message == msg }) {
                        newErrors.append(error)
                    }
                }
                currentErrorMsg = nil // Consumed
            }
        }

        // Store raw error lines so the fallback fixer can locate them in the shadow file
        if !newRawErrorLines.isEmpty {
            lastRawErrorLines = newRawErrorLines
        }
        
        // Update errors if changed.
        if self.errors != newErrors {
            self.errors = newErrors
            NotificationCenter.default.post(name: .typstErrorsUpdated, object: newErrors)
        }
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
    private func attemptFallbackFix(rawErrorLines: [Int]) {
        guard let shadowURL = currentShadowSourceURL else { return }
        guard FileManager.default.fileExists(atPath: shadowURL.path) else { return }

        // Group the offending lines by which strategy we should try next.
        // Lines we've already maxed out (attempt >= 2) are skipped.
        var escapeTargets: [Int] = []
        var rawWrapTargets: [Int] = []
        for line in rawErrorLines {
            let attempt = fallbackAttempts[line, default: 0]
            if attempt == 0 { escapeTargets.append(line) }
            else if attempt == 1 { rawWrapTargets.append(line) }
        }
        guard !(escapeTargets.isEmpty && rawWrapTargets.isEmpty) else {
            print("[FallbackFix] All error lines already maxed out — skipping.")
            return
        }

        do {
            let content = try String(contentsOf: shadowURL, encoding: .utf8)
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
                if isProtectedTypstDirective(trimmed, isHybrid: currentFileExtension == "note") {
                    // Don't mangle intentional Typst — surface the error instead.
                    fallbackAttempts[rawLine] = 2  // mark as maxed so we don't keep retrying
                    print("[FallbackFix][skip] line \(rawLine): protected directive — \(trimmed.prefix(40))")
                    continue
                }

                fileLines[idx] = escapeTypstLine(original)
                fallbackAttempts[rawLine] = 1
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
                if isProtectedTypstDirective(trimmed, isHybrid: currentFileExtension == "note") {
                    fallbackAttempts[rawLine] = 2
                    print("[FallbackFix][skip] line \(rawLine): protected directive — \(trimmed.prefix(40))")
                    continue
                }

                // Escape backslashes and double-quotes so the line is a valid Typst string.
                let escaped = original
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                fileLines[idx] = "#raw(\"\(escaped)\", block: true)"
                fallbackAttempts[rawLine] = 2
                modified = true
                print("[FallbackFix][raw-wrap] line \(rawLine): \(original.prefix(60))")
            }

            if modified {
                let newContent = fileLines.joined(separator: "\n")
                try newContent.write(to: shadowURL, atomically: true, encoding: .utf8)
                print("[FallbackFix] Shadow file updated — typst watch will recompile.")
            }
        } catch {
            print("[FallbackFix] Failed to apply fallback fix: \(error)")
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
    /// `#line`, `#footnote`, `#super`, `#sub`, `#underline`, `#highlight`, `#raw`)
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
            "footnote", "super", "sub", "underline", "highlight", "raw",
        ]
        let pattern = #"^#([A-Za-z][A-Za-z0-9_]*)[\[(]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let nsLine = line as NSString
        guard let match = regex.firstMatch(in: line, options: [], range: NSRange(0..<nsLine.length)) else {
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

    // --- Export Functions ---
    
    func export(sourceURL: URL, outputURL: URL, format: String, projectRoot: URL? = nil) async -> (success: Bool, error: String?) {
        guard let typstPath = resolveTypstPath() else {
            return (false, "Error: 'typst' executable not found.")
        }
        
        // If it's a multi-page document and the format is PNG/SVG, 
        // Typst expects a template like "output-{0p}.png" if we don't want it to fail.
        // However, we'll let the user provide the name via the NSSavePanel.
        // If they don't provide a {p} template, Typst will fail for multi-page docs.
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        
        var arguments = ["compile", sourceURL.path, outputURL.path, "--format", format]
        
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
            
            print("[TYPST-EXPORT-SUCCESS]: \(outputURL.lastPathComponent)")
            return (true, nil)
        } catch {
            print("[TYPST-EXPORT] Failed to run: \(error)")
            return (false, error.localizedDescription)
        }
    }

    func compileClean(content: String, fileExtension: String? = nil, preferredDirectory: URL? = nil, projectRoot: URL?) async -> (success: Bool, pdfURL: URL?, error: String?) {
        guard let typstPath = resolveTypstPath() else {
            return (false, nil, "Error: 'typst' executable not found.")
        }
        
        // Use preferred directory (e.g. sibling of source file) to ensure relative imports work
        let tempDir = preferredDirectory ?? FileManager.default.temporaryDirectory
        let tempID = preferredDirectory != nil ? ".clean-\(UUID().uuidString.prefix(8))" : UUID().uuidString
        let sourceURL = tempDir.appendingPathComponent("\(tempID).typ")
        let pdfURL = tempDir.appendingPathComponent("\(tempID).pdf")
        
        var finalContent = content
        
        let ext = fileExtension ?? currentFileExtension
        if ext == "md" || ext == "note" {
            let aiService = AICompletionService.shared
            let textToProcess = finalContent
            finalContent = await Task.detached {
                aiService.sanitizeMarkdownToTypst(textToProcess, isHybrid: ext == "note")
            }.value
        }
        if ext == "note" {
            finalContent = notePreamble + finalContent
        }
        
        finalContent = await resolveWebImages(in: finalContent, projectRoot: projectRoot)
        
        do {
            try finalContent.write(to: sourceURL, atomically: true, encoding: .utf8)
        } catch {
            return (false, nil, "Failed to write temp source: \(error.localizedDescription)")
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        
        var arguments = ["compile", sourceURL.path, pdfURL.path]
        if let root = projectRoot {
            arguments.append(contentsOf: ["--root", root.path])
            process.currentDirectoryURL = root
        }
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardError = pipe
        
        defer {
            // Clean up temp source file
            try? FileManager.default.removeItem(at: sourceURL)
        }
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "Unknown error"
                return (false, nil, output)
            }
            
            return (true, pdfURL, nil)
        } catch {
            return (false, nil, error.localizedDescription)
        }
    }

    // MARK: - Web Image Resolver
    
    private func resolveWebImages(in text: String, projectRoot: URL?) async -> String {
        let pattern = #"#image\(\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        
        let matches = regex.matches(in: text, options: [], range: NSRange(0..<text.utf16.count))
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