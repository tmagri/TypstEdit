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
    
    init(content: String) {
        self.sourceLines = content.components(separatedBy: .newlines)
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
        
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex]
            processLine(line.trimLeading(), rawLine: line)
            currentLineIndex += 1
        }
        
        flushBuffer()
        
        // Post-Processing Cleanup (User Request)
        return postProcess(outputLines).joined(separator: "\n")
    }
    
    // MARK: - Post Processing
    
    // Parses header info from sourceLines to determine font usage
    private func parseFontSettings() -> (String?, String?) {
        var font: String? = nil
        var size: String? = "11pt"
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
        
        for line in sourceLines {
            if line.hasPrefix("\\papersize") {
                let parts = line.components(separatedBy: " ")
                if parts.count > 1 {
                    let val = parts[1].trimmingCharacters(in: .whitespaces)
                    if val != "default" { paper = val }
                }
            }
            if line.hasPrefix("\\secnumdepth") {
                let parts = line.components(separatedBy: " ")
                if parts.count > 1, let depth = Int(parts[1]), depth > 0 {
                    numbering = true
                }
            }
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
    
    private func processLine(_ line: String, rawLine: String) {
        if line.hasPrefix("#") && !line.hasPrefix("#LyX") { return }
        
        if line == "\\begin_body" { inBody = true; return }
        if line == "\\end_body" { inBody = false; return }
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
        if line.hasPrefix("\\end_layout") { endLayout(); flushBuffer(); return }
        
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
        let garbagePrefixes = ["\\labelwidthstring", "\\align", "placement ", "alignment ", "wide ", "sideways ", "status open", "status collapsed", "\\family", "\\size", "\\bar", "\\strikeout", "\\xout", "\\uuline", "\\uwave", "\\noun", "\\color", "\\lang", "name \"", "reference \"", "clip", "keepaspectratio", "rotateOrigin", "lyxscale", "scale", "\\series ", "\\shape ", "\\emph "]
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
            if currentLayout == .labeling || currentLayout == .description {
                if !textBuffer.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                    textBuffer = textBuffer.trimmingCharacters(in: .whitespaces) + ":"
                }
            } else {
                if !textBuffer.hasSuffix("*") { textBuffer += "*" }
            }
            isBold = false
        }

        // 2. Structural Closure
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
    
    private func parseInset(type: String) {
        if type.hasPrefix("Formula") { parseMathInset(type: type) }
        else if type.hasPrefix("Graphics") { parseGraphicsInset() }
        else if type.hasPrefix("Quotes") { parseQuotes(type: type) }
        else if type.hasPrefix("CommandInset ref") { parseReferenceInset() }
        else if type.hasPrefix("CommandInset label") { parseLabelInset() }
        else if type.hasPrefix("CommandInset toc") { flushBuffer(); outputLines.append("#outline()"); skipInset() }
        else if type.hasPrefix("Newpage") { flushBuffer(); outputLines.append("#pagebreak()"); skipInset() }
        else if type.hasPrefix("Flex URL") { parseUrlInset() }
        else if type.hasPrefix("space") { textBuffer += " "; skipInset() }
        else if type.hasPrefix("Float") { parseFloatInset(type: type) } // Handle Float
        else { skipInset() }
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
        var height: String?
        
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex].trimLeading()
            if line == "\\end_inset" { currentLineIndex += 1; break }
            
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
        skipInset()
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
        return res
    }
    
    private func convertLatexMathToTypst(_ latex: String) -> String {
        var m = latex
        m = m.replacingOccurrences(of: "\\begin_inset Formula ", with: "")
        m = m.replacingOccurrences(of: "\\[", with: "")
        m = m.replacingOccurrences(of: "\\]", with: "")
        m = m.replacingOccurrences(of: "$", with: "")
        
        // 1. Map common LaTeX commands to Typst or intermediate forms
        // Handle nested-prone commands first
        m = m.replacingRegex(pattern: "\\\\mathrm\\s*\\{([^}]+)\\}", with: " upright(\"$1\") ")
        m = m.replacingRegex(pattern: "\\\\text\\s*\\{([^}]+)\\}", with: " \"$1\" ")
        m = m.replacingRegex(pattern: "\\\\textrm\\s*\\{([^}]+)\\}", with: " \"$1\" ")
        m = m.replacingRegex(pattern: "\\\\textit\\s*\\{([^}]+)\\}", with: " italic(\"$1\") ")
        m = m.replacingRegex(pattern: "\\\\textbf\\s*\\{([^}]+)\\}", with: " bold(\"$1\") ")
        
        // Handle fractions after inner commands are resolved
        m = m.replacingRegex(pattern: "\\\\frac\\s*\\{([^}]*)\\}\\s*\\{([^}]*)\\}", with: "($1)/($2)")
        
        m = m.replacingOccurrences(of: "\\cdot", with: " dot ")
        m = m.replacingOccurrences(of: "\\times", with: " times ")
        m = m.replacingOccurrences(of: "\\sum", with: " sum ")
        m = m.replacingOccurrences(of: "\\prod", with: " product ")
        m = m.replacingOccurrences(of: "\\int", with: " integral ")
        m = m.replacingOccurrences(of: "\\infty", with: " infinity ")
        m = m.replacingOccurrences(of: "\\rightarrow", with: " arrow.r ")
        m = m.replacingOccurrences(of: "\\leftarrow", with: " arrow.l ")
        m = m.replacingOccurrences(of: "\\in", with: " in ")
        m = m.replacingOccurrences(of: "\\{", with: " \"{\" ")
        m = m.replacingOccurrences(of: "\\}", with: " \"}\" ")
        
        let greek = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega"]
        for g in greek {
            m = m.replacingOccurrences(of: "\\\\\(g)", with: " \(g) ", options: .regularExpression)
            m = m.replacingOccurrences(of: "\\\\\(g.capitalized)", with: " \(g.capitalized) ", options: .regularExpression)
        }
        
        // 2. Quote multiletter identifiers (Packs, Volume, etc)
        // We find words of 2+ letters that are not known functions or already in quotes
        let words = m.components(separatedBy: CharacterSet(charactersIn: " ()[]{}*/+-=,.:;^$_"))
        var toQuote = Set<String>()
        let known = Set(["dot", "times", "sum", "product", "integral", "infinity", "in", "RR", "NN", "ZZ", "italic", "bold", "upright", "arrow", "r", "l"])
        
        for w in words {
            let t = w.trimmingCharacters(in: .whitespaces)
            if t.count > 1 {
                if !greek.contains(t.lowercased()) && !known.contains(t.lowercased()) && !t.hasPrefix("\"") {
                    toQuote.insert(t)
                }
            }
        }
        
        for q in toQuote {
            m = m.replacingRegex(pattern: "\\b\(q)\\b", with: "\"\(q)\"")
        }

        // 3. Final cleanup
        m = m.replacingOccurrences(of: "\\", with: "")
        m = m.replacingOccurrences(of: "{", with: "(")
        m = m.replacingOccurrences(of: "}", with: ")")
        m = m.replacingOccurrences(of: "()", with: "")
        
        return m.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
