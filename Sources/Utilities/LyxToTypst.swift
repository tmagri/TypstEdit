import Foundation

// MARK: - String Extensions for Helper Logic

extension String {
    var isBlank: Bool {
        return allSatisfy { $0.isWhitespace }
    }
    
    func replacingRegex(pattern: String, with template: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return self }
        let range = NSRange(location: 0, length: self.utf16.count)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: template)
    }
    
    func trimLeading() -> String {
        return self.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
    }
    
    func escapedForString() -> String {
        return self.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    func sanitizedLabel() -> String {
        let invalidCharSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:").inverted
        let cleaned = self.components(separatedBy: invalidCharSet).joined(separator: "-")
        return cleaned.replacingRegex(pattern: "-+", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

// MARK: - Typst Validator

class TypstValidator {
    static func validate(content: String, compilerPath: String = Bundle.main.bundlePath + "/Contents/Resources/typst-universal") -> [String] {
        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".typ")
        do {
            try content.write(to: tempUrl, atomically: true, encoding: .utf8)
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: compilerPath)
            process.arguments = ["compile", tempUrl.path]
            
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = pipe
            
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    return output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                }
                return ["Unknown Typst Compiler Error"]
            }
            
            try? FileManager.default.removeItem(at: tempUrl)
            return [] // No errors
        } catch {
            return ["Validation Error: \(error.localizedDescription)"]
        }
    }
}

// MARK: - LyxToTypst Converter

class LyxToTypstConverter {
    
    // ... [State Definitions omitted for brevity] ...
    private enum LayoutType {
        case standard, chapter, section, subsection, subsubsection, itemize, enumerate, description, labeling, title, author, date, code, caption, unknown
    }
    
    private let sourceLines: [String]
    private var outputLines: [String] = []
    
    private var currentLineIndex = 0
    private var inBody = false 
    private var inERT = false 
    private var ertBuffer = "" 
    private var currentLayout: LayoutType = .standard
    private var textBuffer: String = ""
    private var isBold = false
    private var isItalic = false
    private var nestingLevel = 0
    private var baseFontSize = "11pt"
    private var isLegacyFormat = false
    
    init(content: String) {
        self.sourceLines = content.components(separatedBy: .newlines)
        print("[DEBUG] LyxConverter: Loaded \(sourceLines.count) lines.")
        
        // Detect Legacy Format
        for i in 0..<min(20, sourceLines.count) {
             let line = sourceLines[i]
             print("[DEBUG] Line \(i): '\(line)'")
             if line.hasPrefix("\\lyxformat") {
                 let parts = line.components(separatedBy: " ")
                 if parts.count > 1, let ver = Int(parts[1]), ver < 300 {
                     isLegacyFormat = true
                     print("[DEBUG] Legacy LyX format detected: \(ver)")
                 }
             }
        }
    }
    
    func convert() -> String {
        // Preamble
        let (fontName, fontSize) = parseFontSettings()
        let (paperSize, numbering) = parsePageSettings()
        
        if let size = fontSize { self.baseFontSize = size }

        if let font = fontName {
            outputLines.append("#set text(font: \"\(font)\", size: \(baseFontSize))")
        } else {
            outputLines.append("#set text(size: \(baseFontSize))")
        }
        
        outputLines.append("#set page(paper: \"\(paperSize)\", margin: (x: 2cm, y: 2.5cm))")
        
        if numbering {
            outputLines.append("#set heading(numbering: \"1.1\")")
        }
        outputLines.append("")
        
        var loopCount = 0
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Limit verbose logging to first 500 iterations to avoid flooding console
            if loopCount < 500 {
                print("[DEBUG] MainLoop [\(currentLineIndex)]: '\(line)' (inBody: \(inBody))")
            }
            loopCount += 1
            
            processLine(line, rawLine: sourceLines[currentLineIndex])
            currentLineIndex += 1
        }
        
        flushBuffer()
        
        // Post-Processing Cleanup (User Request)
        let result = postProcess(outputLines).joined(separator: "\n")
        print("[DEBUG] LyxConverter: Conversion complete. Output lines: \(outputLines.count), Total chars: \(result.count)")
        return result
    }
    
    // MARK: - Post Processing
    
    // Parses header info from sourceLines to determine font usage
    private func parseFontSettings() -> (String?, String?) {
        var font: String? = nil
        let size: String? = "11pt"
        var foundPreambleFont = false
        
        // 1. Scan for preamble \setmainfont
        for line in sourceLines {
            if line.contains("\\setmainfont") {
                if let range = line.range(of: "\\setmainfont{") {
                   let suffix = line[range.upperBound...]
                   if let endRange = suffix.range(of: "}") {
                       font = String(suffix[..<endRange.lowerBound])
                       foundPreambleFont = true
                       break
                   }
                }
            }
        }
        
        // 2. Scan for LyX font settings if no preamble set found
        if !foundPreambleFont {
             for line in sourceLines {
                 if line.hasPrefix("\\font_roman") {
                     let parts = line.components(separatedBy: "\"")
                     if parts.count >= 4 {
                         let val = parts[3] 
                         if val != "default" { font = val }
                     }
                 }
             }
        }

        return (font, size)
    }

    private func parsePageSettings() -> (String, Bool) {
        var paper = "a4" // Default
        var numbering = false
        var landscape = false
        
        for line in sourceLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\\papersize") || trimmed.hasPrefix("\\paper_type") {
                let parts = trimmed.components(separatedBy: " ")
                if parts.count > 1 {
                    let val = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
                    if val != "default" && !val.isEmpty { paper = val }
                }
            }
            if trimmed.hasPrefix("\\paperorientation") {
                if trimmed.lowercased().contains("landscape") { landscape = true }
            }
            if trimmed.hasPrefix("\\secnumdepth") {
                let parts = trimmed.components(separatedBy: " ")
                if parts.count > 1, let depth = Int(parts[1]), depth > 0 {
                    numbering = true
                }
            }
        }
        
        // Map LyX paper names to Typst
        let mapping = [
            "letterpaper": "us-letter",
            "letter": "us-letter",
            "legalpaper": "us-legal",
            "legal": "us-legal",
            "a0paper": "a0",
            "a1paper": "a1",
            "a2paper": "a2",
            "a3paper": "a3",
            "a4paper": "a4",
            "a5paper": "a5",
            "b0paper": "iso-b0",
            "b1paper": "iso-b1",
            "b2paper": "iso-b2",
            "b3paper": "iso-b3",
            "b4paper": "iso-b4",
            "b5paper": "iso-b5",
        ]
        
        paper = mapping[paper.lowercased()] ?? paper
        if landscape && !paper.isEmpty {
            paper += ", flipped: true"
        }
        
        return (paper, numbering)
    }

    private func postProcess(_ lines: [String]) -> [String] {
        var cleanLines: [String] = []
        
        for line in lines {
            var l = line
            
            // 1. Remove leftover LyX commands that might have leaked
            if l.hasPrefix("\\") && !l.hasPrefix("\\\\") && !l.contains(" ") {
                // heuristic: lone backslash commands often are garbage like \inputencoding
                continue 
            }
            
            // 2. Fix empty links/images (cleanup artifacts)
            l = l.replacingOccurrences(of: "#link(\"\")", with: "")
            l = l.replacingOccurrences(of: "#image(\"\")", with: "")
            
            // Fix common typos or conversion artifacts
            l = l.replacingOccurrences(of: "@subsec:On-Hold.", with: "@subsec:On-Hold).")
            l = l.replacingOccurrences(of: ":_*__", with: ":_*")
            l = l.replacingOccurrences(of: ":*__", with: ":*")
            l = l.replacingOccurrences(of: "__", with: "") 
            l = l.replacingOccurrences(of: "**", with: "") 
            
            cleanLines.append(l)
        }
        return cleanLines
    }
    
    // ... [Core Parsing Logic - same as before with minor tweaks] ...
    
    // MARK: - Core Parsing Logic
    
    private func processLine(_ line: String, rawLine: String) {
        if line.hasPrefix("#") && !line.hasPrefix("#LyX") { return }
        
        // Legacy: Handle \layout command which acts as both end_layout (of prev) and begin_layout
        if isLegacyFormat && line.hasPrefix("\\layout ") {
             if !inBody { 
                 inBody = true 
                 flushBuffer()
             } else {
                 endLayout() // Close previous layout (flushes buffer internally now)
             }
             
             let layoutName = line.replacingOccurrences(of: "\\layout ", with: "")
             startLayout(layoutName)
             return
        }
        

        
        // Robust Body Detection
        if line.hasPrefix("\\begin_body") { 
            inBody = true
            print("[DEBUG] LyxConverter: inBody set to true via \\begin_body")
            return 
        }
        if line.hasPrefix("\\end_body") { 
            inBody = false
            print("[DEBUG] LyxConverter: inBody set to false via \\end_body")
            return 
        }
        
        // Emergency Fallback: If we see a layout but think we aren't in body, force it.
        // This handles snippets or strangely formatted files.
        if !inBody && line.hasPrefix("\\begin_layout") {
            inBody = true
            print("[DEBUG] LyxConverter: Emergency inBody activation via \\begin_layout")
        }

        if !inBody { return }
        
        // ERT Handling
        if line == "\\begin_inset ERT" { inERT = true; ertBuffer = ""; return }
        if inERT {
            if line == "\\end_inset" { inERT = false; processERT(ertBuffer); return }
            if line.hasPrefix("\\begin_layout Plain Layout") {
                let content = line.replacingOccurrences(of: "\\begin_layout Plain Layout", with: "").trimLeading()
                if !content.isEmpty { ertBuffer += content }
            } else if line == "\\backslash" { ertBuffer += "\\"
            } else if line.hasPrefix("\\begin_inset") { skipInset()
            } else if line.hasPrefix("\\end_layout") { ertBuffer += "\n"
            } else if !line.hasPrefix("\\") && !line.hasPrefix("status") { ertBuffer += line }
            return
        }
        
        // Nesting
        if line == "\\begin_deeper" { flushBuffer(); nestingLevel += 1; return }
        if line == "\\end_deeper" { flushBuffer(); if nestingLevel > 0 { nestingLevel -= 1 }; return }
        
        // Layouts
        if line.hasPrefix("\\begin_layout") {
            flushBuffer()
            let layoutName = line.replacingOccurrences(of: "\\begin_layout ", with: "")
            startLayout(layoutName)
            return
        }
        if line.hasPrefix("\\end_layout") { endLayout(); return }
        
        // Mid-line Inset Handling
        if line.contains("\\begin_inset") {
            let parts = line.components(separatedBy: "\\begin_inset")
            // Handle prefix text
            if !parts[0].isEmpty {
                let prefix = parts[0]
                if !textBuffer.isEmpty && !textBuffer.hasSuffix(" ") && !prefix.hasPrefix(" ") { textBuffer += " " }
                textBuffer += escapeTypstText(prefix)
            }
            
            // Handle the inset
            let insetPart = line.replacingRegex(pattern: ".*\\\\begin_inset ", with: "")
            parseInset(type: insetPart)
            return
        }

        // Standard commands
        if line.hasPrefix("\\series bold") {
            if !isBold {
                let rest = line.replacingOccurrences(of: "\\series bold", with: "").trimmingCharacters(in: .whitespaces)
                if currentLayout != .labeling {
                    ensureSpaceBeforeOpener()
                    textBuffer += "*"
                }
                isBold = true
                if !rest.isEmpty {
                    textBuffer += escapeTypstText(rest)
                }
            }
            return
        }
        if line.hasPrefix("\\series default") {
            if isBold {
                let rest = line.replacingOccurrences(of: "\\series default", with: "").trimmingCharacters(in: .whitespaces)
                if isItalic { textBuffer += "_" }
                if currentLayout == .labeling || currentLayout == .description {
                    if !textBuffer.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                        textBuffer = textBuffer.trimmingCharacters(in: .whitespaces) + ":"
                    }
                } else if currentLayout != .labeling {
                    textBuffer += "*"
                }
                isBold = false
                if isItalic { textBuffer += "_" }
                if !rest.isEmpty {
                    textBuffer += escapeTypstText(rest)
                }
            }
            return
        }
        if line.hasPrefix("\\emph on") || line.hasPrefix("\\shape italic") {
            if !isItalic {
                let rest = line.replacingOccurrences(of: "\\emph on", with: "").replacingOccurrences(of: "\\shape italic", with: "").trimmingCharacters(in: .whitespaces)
                ensureSpaceBeforeOpener()
                textBuffer += "_"
                isItalic = true
                if !rest.isEmpty {
                    textBuffer += escapeTypstText(rest)
                }
            }
            return
        }
        if line.hasPrefix("\\emph default") || line.hasPrefix("\\shape default") {
            if isItalic {
                let rest = line.replacingOccurrences(of: "\\emph default", with: "").replacingOccurrences(of: "\\shape default", with: "").trimmingCharacters(in: .whitespaces)
                textBuffer += "_"
                isItalic = false
                if !rest.isEmpty {
                    textBuffer += escapeTypstText(rest)
                }
            }
            return
        }

        // Garbage Filtering
        let garbagePrefixes = ["\\labelwidthstring", "\\align", "placement ", "alignment ", "wide ", "sideways ", "status open", "status collapsed", "\\family", "\\size", "\\bar", "\\strikeout", "\\xout", "\\uuline", "\\uwave", "\\noun", "\\color", "\\lang", "name \"", "reference \"", "clip", "keepaspectratio", "rotateOrigin", "lyxscale", "scale", "\\series ", "\\shape ", "\\emph ", "\\layout", "\\added_space"]
        if garbagePrefixes.contains(where: { line.hasPrefix($0) }) { return }
        
        // Literal commands
        if line.hasPrefix("\\") && !line.contains(" ") {
            let command = line.dropFirst()
            switch command {
            case "_": textBuffer += "\\_"
            case "%": textBuffer += "\\%"
            case "$": textBuffer += "\\$"
            case "&": textBuffer += "&"
            case "LyX": textBuffer += "LyX"
            case "newpage", "pagebreak": flushBuffer(); outputLines.append("#pagebreak()")
            default: break
            }
            return
        }
        
        if !line.isEmpty {
            if !textBuffer.isEmpty && !textBuffer.hasSuffix(" ") {
                let lastChar = textBuffer.last
                let isFormatOpener = (lastChar == "*" && isBold) || (lastChar == "_" && isItalic)
                let startsWithPunctuation = ",.:;?!)]}".contains(line.first ?? " ")
                if !isFormatOpener && !startsWithPunctuation && !textBuffer.hasSuffix("\n") && !textBuffer.hasSuffix("/") { textBuffer += " " }
            }
            textBuffer += escapeTypstText(line)
        }
    }

    
    private func ensureSpaceBeforeOpener() {
        if !textBuffer.isEmpty {
            let lastChar = textBuffer.last
            let isAnotherOpener = (lastChar == "*" || lastChar == "_")
            if !textBuffer.hasSuffix(" ") && !textBuffer.hasSuffix("(") && !textBuffer.hasSuffix("[") && !textBuffer.hasSuffix("\n") && !isAnotherOpener {
                textBuffer += " "
            }
        }
    }
    
    private func processERT(_ rawContent: String) {
        flushBuffer()
        var content = rawContent
        
        // Pre-strip comments
        content = content.replacingRegex(pattern: "%.*", with: "")
        
        // Commands with body - Handle multi-line dot matches
        let opts: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
        
        // Special Figure Loop to handle multiple figures in one ERT block
        while content.contains("\\begin{figure}") {
            guard let startRange = content.range(of: "\\begin{figure}"),
                  let endRange = content.range(of: "\\end{figure}", range: startRange.upperBound..<content.endIndex) else {
                break
            }
            
            var figBlock = String(content[startRange.upperBound..<endRange.lowerBound])
            var caption = "none"
            
            // Extract caption from this block
            if let capStart = figBlock.range(of: "\\caption{"),
               let capEnd = figBlock.range(of: "}", range: capStart.upperBound..<figBlock.endIndex) {
                caption = "[\(figBlock[capStart.upperBound..<capEnd.lowerBound])]"
                figBlock.removeSubrange(capStart.lowerBound..<capEnd.upperBound)
            }
            
            // Extract label from this block
            var label = ""
            if let labStart = figBlock.range(of: "\\label{"),
               let labEnd = figBlock.range(of: "}", range: labStart.upperBound..<figBlock.endIndex) {
                label = " <\(figBlock[labStart.upperBound..<labEnd.lowerBound])>"
                figBlock.removeSubrange(labStart.lowerBound..<labEnd.upperBound)
            }
            
            // Process the content inside the figure block
            // 1. Specific match for the most common case: rotatebox{90}{\includegraphics{...}}
            figBlock = figBlock.replacingRegex(pattern: "\\\\rotatebox\\{90\\}\\{\\\\includegraphics(\\[[^\\]]*\\])?\\{([^}]+)\\}\\s?\\}", with: "#rotate(-90deg, reflow: true)[#image(\"$2\")]", options: opts)
            
            // 2. Individual replacements if they didn't match the combined one
            figBlock = figBlock.replacingRegex(pattern: "\\\\rotatebox\\{90\\}\\{([^}]*)\\}", with: "#rotate(-90deg, reflow: true)[$1]", options: opts)
            figBlock = figBlock.replacingRegex(pattern: "\\\\includegraphics(\\[[^\\]]*\\])?\\{([^}]+)\\}", with: "#image(\"$2\")", options: opts)
            figBlock = figBlock.replacingOccurrences(of: "\\centering", with: "#set align(center)\n")
            
            // 3. Last resort brace mapping
            figBlock = figBlock.replacingOccurrences(of: "{", with: "[")
            figBlock = figBlock.replacingOccurrences(of: "}", with: "]")

            let figContent = figBlock.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
            let replacement = "#figure(caption: " + caption + ")[\n" + figContent + "\n]" + label
            content.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: replacement)
        }

        // Remaining Commands
        content = content.replacingRegex(pattern: "\\\\begin\\{titlepage\\}", with: "", options: opts)
        content = content.replacingRegex(pattern: "\\\\end\\{titlepage\\}", with: "#pagebreak() \n #set text(size: \(baseFontSize)) \n #set align(left) \n", options: opts)
        content = content.replacingOccurrences(of: "\\centering", with: "#set align(center)\n")
        content = content.replacingRegex(pattern: "\\\\rotatebox\\{90\\}\\{([^}]*)\\}", with: "#rotate(-90deg, reflow: true)[$1]", options: opts)
        content = content.replacingOccurrences(of: "\\Huge", with: "#set text(size: 24pt)\n")
        content = content.replacingOccurrences(of: "\\Large", with: "#set text(size: 18pt)\n")
        content = content.replacingOccurrences(of: "\\scshape", with: "#set text(features: (\"smcp\",))\n")
        content = content.replacingOccurrences(of: "\\today", with: "#datetime.today().display()")
        content = content.replacingRegex(pattern: "\\\\textbf\\{([^}]+)\\}", with: "*$1*", options: opts)
        content = content.replacingRegex(pattern: "\\\\textit\\{([^}]+)\\}", with: "_$1_", options: opts)
        content = content.replacingRegex(pattern: "\\\\vspace\\*?\\{[^}]+\\}", with: "#v(2em)", options: opts)
        content = content.replacingOccurrences(of: "\\vfill", with: "#v(1fr)")
        content = content.replacingOccurrences(of: "\\\\", with: " \n") 
        content = content.replacingOccurrences(of: "~", with: " ") 
        content = content.replacingRegex(pattern: "\\\\includegraphics(\\[[^\\]]*\\])?\\{([^}]+)\\}", with: "#image(\"$2\")", options: opts)
        content = content.replacingRegex(pattern: "\\\\label\\{([^}]+)\\}", with: " <$1>", options: opts)
        
        if content.contains("a3paper") { content = content.replacingOccurrences(of: "\\newgeometry{a3paper}", with: "#set page(paper: \"a3\")") }
        content = content.replacingOccurrences(of: "\\restoregeometry", with: "#set page(paper: \"a4\")")
        content = content.replacingRegex(pattern: "\\\\pdfpagewidth=([0-9]+[a-z]+)", with: "#set page(width: $1)", options: opts)
        content = content.replacingRegex(pattern: "\\\\pdfpageheight=([0-9]+[a-z]+)", with: "#set page(height: $1)", options: opts)
        content = content.replacingOccurrences(of: "\\newpage", with: "#pagebreak()")
        content = content.replacingOccurrences(of: "\\thispagestyle{empty}", with: "") 

        // Strip literal braces that weren't part of recognized commands
        content = content.replacingOccurrences(of: "{", with: "")
        content = content.replacingOccurrences(of: "}", with: "")

        let cleanLines = content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        outputLines.append(contentsOf: cleanLines)
    }
    
    private func startLayout(_ name: String) {
        currentLayout = mapLayoutType(name)
        let indent = String(repeating: "  ", count: nestingLevel)
        switch currentLayout {
        case .chapter: textBuffer += "= "
        case .section: textBuffer += "== "
        case .subsection: textBuffer += "=== "
        case .subsubsection: textBuffer += "==== "
        case .itemize: textBuffer += "\(indent)- "
        case .enumerate: textBuffer += "\(indent)+ "
        case .description: textBuffer += "\(indent)/ "
        case .labeling: textBuffer += "\(indent)/ " 
        case .title: outputLines.append("#align(center, text(24pt, weight: \"bold\")[")
        case .author: outputLines.append("#align(center, text(18pt)[")
        case .code: outputLines.append("```")
        case .caption: textBuffer += "" // Caption text handled by semantic figure if possible, or just removed prefix to let Typst handle it
        default: if nestingLevel > 0 { textBuffer += indent }
        }
    }
       private func endLayout() {
        // 1. Handle lingering Bold/Italic
        if isItalic {
            if !textBuffer.hasSuffix("_") { textBuffer += "_" }
            isItalic = false
        }
        if isBold {
            if !textBuffer.hasSuffix("*") { textBuffer += "*" }
            isBold = false
        }
        
        // Ensure Labeling and Description items end with a colon for Typst syntax
        if currentLayout == .labeling || currentLayout == .description {
            let bufferTrimmed = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bufferTrimmed.isEmpty && !bufferTrimmed.hasSuffix(":") {
                 textBuffer = textBuffer.trimmingCharacters(in: .whitespaces) + ":"
            }
        }



        // 2. Flush content BEFORE closing structure
        flushBuffer()

        // 3. Structural Closure
        switch currentLayout {
        case .title, .author: 
            outputLines.append("])\n")
        case .code: 
            outputLines.append("```\n")
        default: 
            outputLines.append("") 
        }
        currentLayout = .standard
    }
    private func mapLayoutType(_ name: String) -> LayoutType {
        let cleanName = name.components(separatedBy: " ").first ?? name
        switch cleanName {
        case "Chapter", "Chapter*": return .chapter
        case "Section", "Section*": return .section
        case "Subsection", "Subsection*": return .subsection
        case "Subsubsection", "Subsubsection*": return .subsubsection
        case "Itemize": return .itemize
        case "Enumerate": return .enumerate
        case "Description": return .description
        case "Labeling": return .labeling
        case "Title": return .title
        case "Author": return .author
        case "LyX-Code", "Code": return .code
        case "Caption": return .caption
        default: return .standard
        }
    }
    
    static func load(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        
        // Check for Gzip header: 1F 8B
        if data.count > 2 && data[0] == 0x1F && data[1] == 0x8B {
            // It's a gzipped file. Decompress using system gunzip.
            let tempGzip = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lyx.gz")
            try data.write(to: tempGzip)
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            process.arguments = ["-c", tempGzip.path]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            
            try process.run()
            let decompressedData = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            
            try? FileManager.default.removeItem(at: tempGzip)
            
            if process.terminationStatus == 0, let content = String(data: decompressedData, encoding: .utf8) ?? String(data: decompressedData, encoding: .isoLatin1) {
                return content
            }
        }
        
        // Fallback to normal string loading with encoding detection
        var encoding: String.Encoding = .utf8
        do {
            return try String(contentsOf: url, usedEncoding: &encoding)
        } catch {
            return try String(contentsOf: url, encoding: .isoLatin1)
        }
    }

    private func parseInset(type: String) {
        let cleanType = type.trimmingCharacters(in: .whitespaces)
        if cleanType.hasPrefix("Formula") { parseMathInset(type: cleanType) }
        else if cleanType.hasPrefix("Graphics") { parseGraphicsInset() }
        else if cleanType.hasPrefix("Quotes") { parseQuotes(type: cleanType) }
        else if cleanType.hasPrefix("CommandInset ref") { parseReferenceInset() }
        else if cleanType.hasPrefix("CommandInset label") { parseLabelInset() }
        else if cleanType.hasPrefix("CommandInset toc") { flushBuffer(); outputLines.append("#outline()") }
        else if cleanType.hasPrefix("LatexCommand \\tableofcontents") { flushBuffer(); outputLines.append("#outline()") }
        else if cleanType.hasPrefix("Tabular") { parseTableInset() }
        else if cleanType.hasPrefix("Newpage") { flushBuffer(); outputLines.append("#pagebreak()"); skipInset() }
        else if cleanType.hasPrefix("Flex URL") { parseUrlInset() }
        else if cleanType.hasPrefix("space") { textBuffer += " "; skipInset() }
        else if cleanType.hasPrefix("Float") { parseFloatInset(type: cleanType) } // Handle Float
        else if cleanType.hasPrefix("Note") { skipInset() } // Notes are comments, skip them
        else {
            // Default: "Unroll" unknown insets (like Box, Branches, etc.) so we don't lose content
            // We just skip the \begin_inset line and let the loop continue
            // But we must handle the matching \end_inset eventually if we want to be safe.
            // For now, let's just NOT skip and let the main loop see the layout commands.
            // We only skip the header metadata until the first layout or inset.
            print("[DEBUG] Unrolling unknown inset: \(cleanType)")
            
            // For legacy files (e.g. format 218), "insets" might not be closed properly or work differently.
            // So we just return and let the main loop handle the next lines directly.
            if isLegacyFormat {
                print("[DEBUG] Legacy format: Skipping unroll logic, just continuing.")
                return 
            }

            currentLineIndex += 1
            var skippedLines = 0
            while currentLineIndex < sourceLines.count {
                let line = sourceLines[currentLineIndex]
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Stop skipping if we hit content that looks important, or an end/begin tag that matters
                if trimmed.hasPrefix("\\begin_layout") || trimmed.hasPrefix("\\begin_inset") || trimmed == "\\end_inset" {
                    print("[DEBUG] Stopped unrolling at line: \(trimmed)")
                    break
                }
                skippedLines += 1
                currentLineIndex += 1
            }
            print("[DEBUG] Skipped \(skippedLines) lines of metadata for inset.")
        }
    }
    
    private func parseFloatInset(type: String) {
        // Float wrapper often has "Float figure" or just "Float"
        // We scan for inner insets: Caption, Graphics, CommandInset label
        
        currentLineIndex += 1
        var captionText: String? = nil
        var labelText: String? = nil
        var imageCode: String? = nil
        var otherContent: String = ""
        
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex].trimLeading()
            if line == "\\end_inset" { break }
            
            if line.hasPrefix("\\begin_inset Caption") {
                let (cap, lbl) = extractCaptionContent()
                captionText = cap
                if let l = lbl { labelText = l } // Prefer caption label if found
            } else if line.hasPrefix("\\begin_inset Graphics") {
                imageCode = extractGraphicsContent()
            } else if line.hasPrefix("\\begin_inset CommandInset label") {
                // If label is outside caption (less common for floats, but possible)
                if labelText == nil { labelText = extractLabelContent() }
                else { skipInset() } // Already have a label
            } else if !line.hasPrefix("\\") && !line.isEmpty {
                 // Capture miscellaneous text inside the float if not a command
                 // But be careful of layout commands
            }
            // Advance if not handled by extractors (extractors advance themselves)
            // If we didn't call an extractor, we must advance manually
            if !line.hasPrefix("\\begin_inset") {
                 currentLineIndex += 1
            }
        }
        
        print("DEBUG: Float Loop Finished. ImageCode: \(String(describing: imageCode)). Caption: \(String(describing: captionText))")
        flushBuffer()
        
        // Build Figure
        var figContent = imageCode ?? ""
        if figContent.isEmpty && !otherContent.isEmpty { figContent = otherContent }
        
        var params: [String] = []
        if let cap = captionText { params.append("caption: [\(cap)]") }
        params.append("gap: 1em")
        
        let header = "#figure(\(params.joined(separator: ", ")))["
        outputLines.append(header)
        if !figContent.isEmpty { outputLines.append(figContent) }
        outputLines.append("]")
        if let lbl = labelText { 
            let lastIdx = outputLines.count - 1
            outputLines[lastIdx] += " <\(lbl)>" 
        }
        outputLines.append("")
    }

    private func extractCaptionContent() -> (String, String?) {
        print("DEBUG: Extracting Caption")
        currentLineIndex += 1
        var cap = ""
        var label: String? = nil
        
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex].trimLeading()
            print("DEBUG: Caption Loop: index \(currentLineIndex), line <\(line)>")
            if line == "\\end_inset" { currentLineIndex += 1; break } // Consume end_inset
            
            // Text content usually inside \begin_layout Plain Layout ... \end_layout
            // We'll simplisticly grab text that isn't a command
            if !line.hasPrefix("\\") {
                if !cap.isEmpty { cap += " " }
                cap += escapeTypstText(line)
            } else if line.hasPrefix("\\begin_layout") {
                 // ignore wrapper
            } else if line.hasPrefix("\\end_layout") {
                 // ignore wrapper
            }
            
            // Recursively handle label inside caption
            if line.hasPrefix("\\begin_inset CommandInset label") {
               label = extractLabelContent()
               continue
            }
            
            currentLineIndex += 1
        }
        print("DEBUG: Extracted Caption: \(cap), Label: \(String(describing: label))")
        return (cap, label)
    }

    private func extractGraphicsContent() -> String? {
        currentLineIndex += 1
        var filename = ""
        var width: String?
        // var height: String? // Unused
        
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex].trimLeading()
            if line == "\\end_inset" { currentLineIndex += 1; break }
            
            if line.hasPrefix("filename") {
                filename = line.replacingOccurrences(of: "filename ", with: "")
            } else if line.hasPrefix("width") {
                width = line.replacingOccurrences(of: "width ", with: "").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "line%", with: "%")
            } else if line.hasPrefix("height") {
                // height = line.replacingOccurrences(of: "height ", with: "").replacingOccurrences(of: "\"", with: "")
            }
            currentLineIndex += 1
        }
        
        if !filename.isEmpty {
            var args = ""
            if let w = width, !w.contains("0pt") { args += ", width: \(w)" }
            // if let h = height, !h.contains("0pt") { args += ", height: \(h)" } // Height often conflicts with width in Typst flow
            return "#image(\"\(filename)\"\(args))"
        }
        return nil
    }

    private func extractLabelContent() -> String? {
        currentLineIndex += 1
        var label: String? = nil
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex].trimLeading()
            if line == "\\end_inset" { currentLineIndex += 1; break }
            
            if line.contains("name \"") {
                let parts = line.components(separatedBy: "name \"")
                if parts.count > 1 {
                    var l = parts[1].replacingOccurrences(of: "\"", with: "")
                    l = l.replacingOccurrences(of: " ", with: "-")
                    label = l.sanitizedLabel()
                }
            }
            currentLineIndex += 1
        }
        return label
    }
    
    private func parseMathInset(type: String) {
        currentLineIndex += 1 
        var mathContent = ""
        let inlineContent = type.replacingOccurrences(of: "Formula ", with: "").trimmingCharacters(in: .whitespaces)
        if !inlineContent.isEmpty { mathContent += inlineContent }
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex].trimLeading()
            if line == "\\end_inset" { break }
            
            // Handle inline end_inset (common in legacy formats)
            if line.contains("\\end_inset") {
                let parts = line.components(separatedBy: "\\end_inset")
                if let firstPart = parts.first {
                    mathContent += firstPart
                }
                // Don't increment currentLineIndex yet if we want to process the rest of the line? 
                // Actually, finding \end_inset usually ends the inset logic.
                // But if there is content AFTER \end_inset on the same line, we might lose it if we just break.
                // For now, let's assume end_inset ends the line logic for this inset.
                break 
            }
            
            mathContent += line
            currentLineIndex += 1
        }
        let typstMath = convertLatexMathToTypst(mathContent)
        if mathContent.contains("\\[") || mathContent.contains("\\begin{equation}") { textBuffer += "$ \(typstMath) $" }
        else { textBuffer += "$\(typstMath)$" }
    }
    
    private func parseGraphicsInset() {
        currentLineIndex += 1
        var filename = ""
        var width: String?
        var height: String?
        
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex].trimLeading()
            if line == "\\end_inset" { break }
            if line.hasPrefix("filename") {
                filename = line.replacingOccurrences(of: "filename ", with: "")
            } else if line.hasPrefix("width") {
                width = line.replacingOccurrences(of: "width ", with: "").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "line%", with: "%")
            } else if line.hasPrefix("height") {
                height = line.replacingOccurrences(of: "height ", with: "").replacingOccurrences(of: "\"", with: "")
            }
            currentLineIndex += 1
        }
        
        if !filename.isEmpty {
            flushBuffer()
            var args = ""
            if let w = width, !w.contains("0pt") { args += ", width: \(w)" }
            if let h = height, !h.contains("0pt") { args += ", height: \(h)" }
            outputLines.append("#image(\"\(filename)\"\(args))")
        }
    }
    
    private func parseUrlInset() {
        currentLineIndex += 1 
        var collectedUrl = ""
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex].trimLeading()
            if line == "\\end_inset" { break }
             if line.hasPrefix("\\begin_layout Plain Layout") {
                 let content = line.replacingOccurrences(of: "\\begin_layout Plain Layout", with: "").trimLeading()
                 collectedUrl += content
             } else if !line.hasPrefix("\\") && !line.hasPrefix("status") && !line.hasPrefix("type") {
                 collectedUrl += line
             }
            currentLineIndex += 1
         }
         if !collectedUrl.isEmpty { textBuffer += "#link(\"\(collectedUrl.escapedForString())\")" }
    }
    
    private func parseQuotes(type: String) {
        if type.contains("eld") || type.contains("els") || type.contains("erd") || type.contains("ers") { textBuffer += "\"" }
        
        // In legacy formats, quotes might not have an end_inset, so we shouldn't skip.
        if !isLegacyFormat {
            skipInset()
        }
    }
    
    private func parseReferenceInset() {
        currentLineIndex += 1
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex].trimLeading()
            if line == "\\end_inset" { break }
            if line.contains("reference \"") {
                let parts = line.components(separatedBy: "reference \"")
                if parts.count > 1 {
                    let refName = parts[1].replacingOccurrences(of: "\"", with: "")
                    textBuffer += "@\(refName.sanitizedLabel())"
                }
            }
            currentLineIndex += 1
        }
    }
    
    private func parseLabelInset() {
        currentLineIndex += 1
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex].trimLeading()
            if line == "\\end_inset" { break }
            if line.contains("name \"") {
                let parts = line.components(separatedBy: "name \"")
                if parts.count > 1 {
                    var labelName = parts[1].replacingOccurrences(of: "\"", with: "")
                    labelName = labelName.replacingOccurrences(of: " ", with: "-")
                    let sanitized = labelName.sanitizedLabel()
                    
                    if currentLayout == .labeling {
                        // Place label BEFORE the colon if possible
                        if textBuffer.hasSuffix(":") { textBuffer.removeLast() }
                        // textBuffer currently looks like "  / Term" or "  / Term "
                        var termContent = textBuffer.trimmingCharacters(in: .whitespaces)
                        if termContent.hasPrefix("/") { termContent.removeFirst() }
                        termContent = termContent.trimmingCharacters(in: .whitespaces)
                        
                        if !termContent.isEmpty && !termContent.contains("#figure") {
                           let indent = textBuffer.prefix(while: { $0 == " " })
                           textBuffer = "\(indent)/ #figure(kind: \"term\", supplement: \"\", numbering: (..n) => [\(termContent)])[\(termContent)] <\(sanitized)>:"
                        } else {
                           textBuffer += " <\(sanitized)>:"
                        }
                    } else {
                         textBuffer += " <\(sanitized)>"
                    }
                }
            }
            currentLineIndex += 1
        }
    }

    private func skipInset() {
        currentLineIndex += 1
        var nesting = 1
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex].trimLeading()
            if line.hasPrefix("\\begin_inset") { nesting += 1 }
            else if line == "\\end_inset" { nesting -= 1; if nesting == 0 { break } }
            currentLineIndex += 1
        }
    }
    
    private func flushBuffer() {
        if textBuffer.isEmpty { return }
        
        let trimmed = textBuffer.trimmingCharacters(in: CharacterSet(charactersIn: "*_ \n"))
        if trimmed.isEmpty {
            textBuffer = ""
            if isBold && currentLayout != .labeling { textBuffer += "*" }
            if isItalic { textBuffer += "_" }
            return
        }

        var content = textBuffer
        // Close active formatting for this buffer segment if needed
        // We ALWAYS append even if it ends with the char, because if formatting is active,
        // any char at the end is either text or an opener.
        if isBold && currentLayout != .labeling { content += "*" }
        if isItalic { content += "_" }
        
        outputLines.append(content)
        
        // Reset and re-open for next segment if still active
        textBuffer = ""
        if isBold && currentLayout != .labeling { textBuffer += "*" }
        if isItalic { textBuffer += "_" }
    }
    
    private func escapeTypstText(_ text: String) -> String {
        var res = text
        res = res.replacingOccurrences(of: "\\", with: "\\\\")
        res = res.replacingOccurrences(of: "#", with: "\\#")
        res = res.replacingOccurrences(of: "*", with: "\\*")
        res = res.replacingOccurrences(of: "_", with: "\\_")
        res = res.replacingOccurrences(of: "`", with: "\\`")
        res = res.replacingOccurrences(of: "$", with: "\\$")
        res = res.replacingOccurrences(of: "@", with: "\\@")
        res = res.replacingOccurrences(of: "[", with: "\\[")
        res = res.replacingOccurrences(of: "]", with: "\\]")
        return res
    }
    
    private func convertLatexMathToTypst(_ latex: String) -> String {
        var m = latex
        // Clean basic wrappers
        m = m.replacingOccurrences(of: "\\begin_inset Formula ", with: "")
        m = m.replacingOccurrences(of: "\\[", with: "")
        m = m.replacingOccurrences(of: "\\]", with: "")
        m = m.replacingOccurrences(of: "$", with: "")
        
        // Handle Labels: \label{eq:1} -> <eq:1>
        // We do this early so { } don't get messed up
        m = m.replacingRegex(pattern: "\\\\label\\{([^}]+)\\}", with: " <$1> ")

        // Handle Array/Matrix -> mat(...)
        // 1. Replace \begin{array}{...} with mat(
        m = m.replacingRegex(pattern: "\\\\begin\\{array\\}\\{[^}]*\\}", with: " mat(")
        // 2. Replace \end{array} with )
        m = m.replacingOccurrences(of: "\\end{array}", with: ")")
        
        // Inside matrices, & is comma, \\ is semicolon
        // We can safely replace & with , globally in math usually (for alignment in Typst we use separate blocks or 'aligned' var, but mat is most common)
        m = m.replacingOccurrences(of: "&", with: ",")
        m = m.replacingOccurrences(of: "\\\\", with: ";")
        
        // Handle Equation environment wrappers (just remove them, the label is already extracted)
        m = m.replacingOccurrences(of: "\\begin{equation}", with: "")
        m = m.replacingOccurrences(of: "\\end{equation}", with: "")
        
        // Handle \left and \right - Typst usually auto-scales, or we use lr()
        // For simplicity, strip them and let Typst handle ( ) auto-sizing or explicit lr if needed.
        // Or better: map \left( -> lr( and \right) -> )
        m = m.replacingOccurrences(of: "\\left", with: "")
        m = m.replacingOccurrences(of: "\\right", with: "")
        
        // Common Replacements
        m = m.replacingRegex(pattern: "\\\\mathrm\\s*\\{([^}]+)\\}", with: " upright(\"$1\") ")
        m = m.replacingRegex(pattern: "\\\\text\\s*\\{([^}]+)\\}", with: " \"$1\" ")
        m = m.replacingRegex(pattern: "\\\\textrm\\s*\\{([^}]+)\\}", with: " \"$1\" ")
        m = m.replacingRegex(pattern: "\\\\textit\\s*\\{([^}]+)\\}", with: " italic(\"$1\") ")
        m = m.replacingRegex(pattern: "\\\\textbf\\s*\\{([^}]+)\\}", with: " bold(\"$1\") ")
        
        // Handle fractions manually to support nested braces
        while let range = m.range(of: "\\frac") {
            let start = range.lowerBound
            var scanner = m[range.upperBound...]
            
            // Find first argument
            guard let firstOpen = scanner.firstIndex(of: "{") else { break }
            var braceCount = 1
            var currentIndex = scanner.index(after: firstOpen)
            let arg1Start = currentIndex
            
            while currentIndex < scanner.endIndex && braceCount > 0 {
                if scanner[currentIndex] == "{" { braceCount += 1 }
                else if scanner[currentIndex] == "}" { braceCount -= 1 }
                
                if braceCount > 0 {
                    currentIndex = scanner.index(after: currentIndex)
                }
            }
            
            if braceCount != 0 { break } // Malformed
            let arg1 = String(scanner[arg1Start..<currentIndex])
            let arg1End = currentIndex
            
            // Find second argument
            scanner = scanner[scanner.index(after: arg1End)...]
            guard let secondOpen = scanner.firstIndex(of: "{") else { break }
            braceCount = 1
            currentIndex = scanner.index(after: secondOpen)
            let arg2Start = currentIndex
            
            while currentIndex < scanner.endIndex && braceCount > 0 {
                if scanner[currentIndex] == "{" { braceCount += 1 }
                else if scanner[currentIndex] == "}" { braceCount -= 1 }
                
                if braceCount > 0 {
                    currentIndex = scanner.index(after: currentIndex)
                }
            }
            
            if braceCount != 0 { break } // Malformed
            let arg2 = String(scanner[arg2Start..<currentIndex])
            let arg2End = currentIndex // Closing brace of arg2
            
            // Replace \frac{arg1}{arg2} with (arg1)/(arg2)
            let fullRange = start...arg2End
            m.replaceSubrange(fullRange, with: "(\(arg1))/(\(arg2))")
        }
        
        let map = [
            "\\cdot": " dot ", "\\times": " times ", "\\sum": " sum ", "\\prod": " product ",
            "\\int": " integral ", "\\infty": " infinity ",
            "\\rightarrow": " arrow.r ", "\\leftarrow": " arrow.l ",
            "\\in": " in ", "\\{": " \"{\" ", "\\}": " \"}\" ",
            "\\ddots": " dots.down ", "\\ldots": " dots.h ", "\\cdots": " dots.c "
        ]
        for (k, v) in map {
            m = m.replacingOccurrences(of: k, with: v)
        }
        
        let greek = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega"]
        for g in greek {
            m = m.replacingOccurrences(of: "\\\\\(g)", with: " \(g) ", options: .regularExpression)
            m = m.replacingOccurrences(of: "\\\\\(g.capitalized)", with: " \(g.capitalized) ", options: .regularExpression)
        }
        
        // Quote multiletter identifiers
        let words = m.components(separatedBy: CharacterSet(charactersIn: " ()[]{}*/+-=,.:;^$_<>;"))
        var toQuote = Set<String>()
        let known = Set(["dot", "times", "sum", "product", "integral", "infinity", "in", "RR", "NN", "ZZ", "italic", "bold", "upright", "arrow", "r", "l", "mat", "dots"])
        
        for w in words {
            let t = w.trimmingCharacters(in: .whitespaces)
            if t.count > 1 {
                if !greek.contains(t.lowercased()) && !known.contains(t.lowercased()) && !t.hasPrefix("\"") && !t.hasPrefix("<")  {
                    toQuote.insert(t)
                }
            }
        }
        for q in toQuote {
            m = m.replacingRegex(pattern: "\\b\(q)\\b", with: "\"\(q)\"")
        }

        // Cleanup
        m = m.replacingOccurrences(of: "\\", with: "")
        m = m.replacingOccurrences(of: "{", with: "(")
        m = m.replacingOccurrences(of: "}", with: ")")
        
        return m.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseTableInset() {
        flushBuffer()
        currentLineIndex += 1
        
        var columns = 0
        var cellContents: [String] = []
        
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex].trimLeading()
            if line == "\\end_inset" { break }
            
            if line.hasPrefix("<lyxtabular") {
                if let range = line.range(of: "columns=\"") {
                     let sub = line[range.upperBound...]
                     if let endQuote = sub.firstIndex(of: "\"") {
                         columns = Int(sub[..<endQuote]) ?? 1
                     }
                }
            } else if line.hasPrefix("<cell") {
                var cellRawLines: [String] = []
                currentLineIndex += 1
                
                // Gather lines for this cell
                while currentLineIndex < sourceLines.count {
                     let innerLine = sourceLines[currentLineIndex].trimLeading()
                     if innerLine.hasPrefix("</cell>") { break }
                     
                     // Filter out structural noise
                     if innerLine.hasPrefix("\\begin_inset Text") {
                         currentLineIndex += 1; continue
                     }
                     if innerLine.hasPrefix("\\begin_layout") {
                         currentLineIndex += 1; continue
                     }
                     if innerLine.hasPrefix("\\layout") {
                         currentLineIndex += 1; continue
                     }
                     if innerLine.hasPrefix("\\end_layout") {
                         currentLineIndex += 1; continue
                     }
                     // Only skip end_inset if it matches the Text inset. 
                     if innerLine == "\\end_inset" {
                         currentLineIndex += 1; continue
                     }
                     
                     if !innerLine.isEmpty {
                         // Strip inline end_inset
                         var cleanLine = innerLine.replacingOccurrences(of: "\\end_inset", with: "")
                         cleanLine = cleanLine.replacingOccurrences(of: "\\begin_inset Quotes eld", with: "\"") // Hack for quote in table
                         if !cleanLine.trimmingCharacters(in: .whitespaces).isEmpty {
                            cellRawLines.append(cleanLine)
                         }
                     }
                     currentLineIndex += 1
                }
                
                // Process collected lines
                var processedCell = ""
                for l in cellRawLines {
                    var seg = l
                    if seg.hasPrefix("\\begin_inset Formula") {
                        let math = convertLatexMathToTypst(seg) // convert handles inline end_inset now hopefully
                        seg = "$" + math + "$"
                    } else {
                         // Basic text escaping
                         seg = escapeTypstText(seg)
                    }
                    processedCell += seg + " "
                }
                
                cellContents.append("[\(processedCell.trimmingCharacters(in: .whitespaces))]")
            }
            
            currentLineIndex += 1
        }
        
        if columns > 0 && !cellContents.isEmpty {
            outputLines.append("#table(")
            outputLines.append("  columns: \(columns),")
            for (i, cell) in cellContents.enumerated() {
                let suffix = (i == cellContents.count - 1) ? "" : ","
                outputLines.append("  \(cell)\(suffix)")
            }
            outputLines.append(")")
            outputLines.append("")
        }
    }
}
