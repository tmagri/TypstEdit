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
        darkModePreamble.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
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
    
    func cleanUp() {
        if let process = currentProcess {
            process.terminate()
        }
        currentProcess = nil
        // Optional: Clean up shadow files
    }
    
    // Writes content to the shadow file. If watch is not running, starts it.
    func updateContent(source: String, fileURL: URL) async {
        let tempDir = FileManager.default.temporaryDirectory
        let workingDirectory = fileURL.deletingLastPathComponent()
        let filename = fileURL.lastPathComponent
        
        // Store hidden shadow source in project folder to satisfy Typst root restrictions
        let shadowSourceURL = workingDirectory.appendingPathComponent(".\(filename).preview.typ")
        
        // Keep shadow PDF in temp directory to keep project folder clean
        let fileHash = abs(fileURL.path.hashValue)
        let shadowPDFURL = tempDir.appendingPathComponent("typst-edit-\(fileHash).preview.pdf")
        
        let projectRoot = workingDirectory
        
        // Write content to shadow file
        do {
            var finalSource = source
            
            // If the file is a Markdown (.md) file, convert to Typst before compilation
            if fileURL.pathExtension.lowercased() == "md" {
                finalSource = AICompletionService.shared.sanitizeMarkdownToTypst(finalSource)
            }
            
            if isDarkMode {
                finalSource = darkModePreamble + finalSource
            }
            
            // Download web images and inject local paths before saving
            finalSource = await resolveWebImages(in: finalSource, projectRoot: projectRoot)
            
            try finalSource.write(to: shadowSourceURL, atomically: true, encoding: .utf8)
            
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
                    let adjustedLine = isDarkMode ? max(1, lineNum - preambleLineCount) : lineNum
                    
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
        
        // Update errors if changed.
        if self.errors != newErrors {
            self.errors = newErrors
            NotificationCenter.default.post(name: .typstErrorsUpdated, object: newErrors)
        }
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

    func compileClean(content: String, preferredDirectory: URL? = nil, projectRoot: URL?) async -> (success: Bool, pdfURL: URL?, error: String?) {
        guard let typstPath = resolveTypstPath() else {
            return (false, nil, "Error: 'typst' executable not found.")
        }
        
        // Use preferred directory (e.g. sibling of source file) to ensure relative imports work
        let tempDir = preferredDirectory ?? FileManager.default.temporaryDirectory
        let tempID = preferredDirectory != nil ? ".clean-\(UUID().uuidString.prefix(8))" : UUID().uuidString
        let sourceURL = tempDir.appendingPathComponent("\(tempID).typ")
        let pdfURL = tempDir.appendingPathComponent("\(tempID).pdf")
        
        var finalContent = content
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
        
        // Fetch missing images concurrently
        await withTaskGroup(of: Void.self) { group in
            for url in urlsToFetch {
                group.addTask {
                    _ = await WebImageCache.shared.download(urlString: url)
                }
            }
        }
        
        // Replace web URLs with our cached local temp paths
        var processed = text
        for url in urlsToFetch {
            if let (data, ext) = await WebImageCache.shared.download(urlString: url) {
                // Keep the file hidden from the Finder/Sidebar but accessible to Typst
                let safeName = ".web_img_\(abs(url.hashValue)).\(ext)"
                let localURL = root.appendingPathComponent(safeName)
                
                if !FileManager.default.fileExists(atPath: localURL.path) {
                    try? data.write(to: localURL)
                }
                
                processed = processed.replacingOccurrences(of: "\"\(url)\"", with: "\"\(safeName)\"")
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
                let (data, response) = try await URLSession.shared.data(from: url)
                
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