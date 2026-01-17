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
        return self.components(separatedBy: invalidCharSet).joined(separator: "-")
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
    
    init(content: String) {
        self.sourceLines = content.components(separatedBy: .newlines)
    }
    
    func convert() -> String {
        // Preamble
        outputLines.append("#set text(font: \"Segoe UI\", size: 11pt)")
        outputLines.append("#set page(paper: \"a4\", margin: (x: 2cm, y: 2.5cm))")
        outputLines.append("#set heading(numbering: \"1.1\")")
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
            l = l.replacingOccurrences(of: "@subsec:On-Hold.", with: "@subsec:On-Hold).") // missing paren in original
            l = l.replacingOccurrences(of: ":_*__", with: ":_*") // doubled underscores
            l = l.replacingOccurrences(of: ":*__", with: ":*") 
            
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
        if line.hasPrefix("\\end_layout") { flushBuffer(); endLayout(); return }
        
        // Insets
        if line.hasPrefix("\\begin_inset") {
            let insetType = line.replacingOccurrences(of: "\\begin_inset ", with: "")
            parseInset(type: insetType)
            return
        }

        // Formatting
        if line.hasPrefix("\\series bold") {
            if !isBold {
                ensureSpaceBeforeOpener()
                textBuffer += "*"
                isBold = true
            }
            return
        }
        if line.hasPrefix("\\series default") {
            if isBold {
                if isItalic { textBuffer += "_" } // Close inner italic
                textBuffer += "*"
                isBold = false
                if currentLayout == .labeling && !textBuffer.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                    textBuffer += ":"
                }
                if isItalic { textBuffer += "_" } // Re-open inner italic
            }
            return
        }
        if line.hasPrefix("\\emph on") || line.hasPrefix("\\shape italic") {
            if !isItalic {
                ensureSpaceBeforeOpener()
                textBuffer += "_"
                isItalic = true
            }
            return
        }
        if line.hasPrefix("\\emph default") || line.hasPrefix("\\shape default") {
            if isItalic {
                textBuffer += "_"
                isItalic = false
            }
            return
        }

        // Garbage Filtering
        let garbagePrefixes = ["\\labelwidthstring", "\\align", "placement ", "alignment ", "wide ", "sideways ", "status open", "status collapsed", "\\family", "\\size", "\\bar", "\\strikeout", "\\xout", "\\uuline", "\\uwave", "\\noun", "\\color", "\\lang", "name \"", "reference \"", "clip", "keepaspectratio", "rotateOrigin", "lyxscale", "scale"]
        if garbagePrefixes.contains(where: { line.hasPrefix($0) }) { return }
        
        // Text
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
                if !isFormatOpener && !startsWithPunctuation { textBuffer += " " }
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
            figBlock = figBlock.replacingRegex(pattern: "\\\\rotatebox\\{90\\}\\{\\\\includegraphics(\\[[^\\]]*\\])?\\{([^}]+)\\}\\s?\\}", with: "#rotate(-90deg)[#image(\"$2\")]", options: opts)
            
            // 2. Individual replacements if they didn't match the combined one
            figBlock = figBlock.replacingRegex(pattern: "\\\\rotatebox\\{90\\}\\{([^}]*)\\}", with: "#rotate(-90deg)[$1]", options: opts)
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
        content = content.replacingRegex(pattern: "\\\\end\\{titlepage\\}", with: "#pagebreak()", options: opts)
        content = content.replacingOccurrences(of: "\\centering", with: "#set align(center)\n")
        content = content.replacingRegex(pattern: "\\\\rotatebox\\{90\\}\\{([^}]*)\\}", with: "#rotate(-90deg)[$1]", options: opts)
        content = content.replacingOccurrences(of: "\\Huge", with: "#set text(size: 24pt)\n")
        content = content.replacingOccurrences(of: "\\Large", with: "#set text(size: 18pt)\n")
        content = content.replacingOccurrences(of: "\\scshape", with: "#set text(features: (\"smcp\",))\n")
        content = content.replacingOccurrences(of: "\\today", with: "#datetime.today().display()")
        content = content.replacingRegex(pattern: "\\\\textbf\\{([^}]+)\\}", with: "*$1*", options: opts)
        content = content.replacingRegex(pattern: "\\\\textit\\{([^}]+)\\}", with: "_$1_", options: opts)
        content = content.replacingRegex(pattern: "\\\\vspace\\*?\\{[^}]+\\}", with: "#v(2em)", options: opts)
        content = content.replacingOccurrences(of: "\\vfill", with: "#v(1fr)")
        content = content.replacingOccurrences(of: "\\\\", with: "\\\n") 
        content = content.replacingOccurrences(of: "~", with: " ") 
        content = content.replacingRegex(pattern: "\\\\includegraphics(\\[[^\\]]*\\])?\\{([^}]+)\\}", with: "#image(\"$2\")", options: opts)
        content = content.replacingRegex(pattern: "\\\\label\\{([^}]+)\\}", with: " <$1>", options: opts)
        
        if content.contains("a3paper") { content = content.replacingOccurrences(of: "\\newgeometry{a3paper}", with: "#set page(paper: \"a3\")") }
        content = content.replacingOccurrences(of: "\\restoregeometry", with: "#set page(paper: \"a4\")")
        content = content.replacingRegex(pattern: "\\\\pdfpagewidth=([0-9]+[a-z]+)", with: "#set page(width: $1)", options: opts)
        content = content.replacingRegex(pattern: "\\\\pdfpageheight=([0-9]+[a-z]+)", with: "#set page(height: $1)", options: opts)
        content = content.replacingOccurrences(of: "\\newpage", with: "#pagebreak()")
        content = content.replacingOccurrences(of: "\\thispagestyle{empty}", with: "") 

        content = content.replacingOccurrences(of: "{", with: "[")
        content = content.replacingOccurrences(of: "}", with: "]")

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
        case .labeling: textBuffer += "\(indent)- " 
        case .title: outputLines.append("#align(center, text(17pt, weight: \"bold\")[")
        case .author: outputLines.append("#align(center, text(12pt)[")
        case .code: outputLines.append("```")
        case .caption: textBuffer += "*Figure:* "
        default: if nestingLevel > 0 { textBuffer += indent }
        }
    }
    
   private func endLayout() {
    // PHASE 1: State-Aware Closure
    // Inspect the boolean flags. If true, the LyX layout ended without explicitly
    // turning off formatting. We must enforce closure now.
    
    // 1. Close Italics
    if isItalic {
        if !textBuffer.isEmpty {
            if !textBuffer.hasSuffix("_") { textBuffer += "_" }
            isItalic = false
        } else if !outputLines.isEmpty {
            var lastLine = outputLines.removeLast()
            if !lastLine.hasSuffix("_") { lastLine += "_" }
            outputLines.append(lastLine)
            isItalic = false
        }
    }
    
    // 2. Close Bold
    if isBold {
        if !textBuffer.isEmpty {
            // If it's a labeling layout, we want the colon OUTSIDE the formatting or at least handled consistently.
            // Let's put the colon right after the text, then close bold.
            if currentLayout == .labeling && !textBuffer.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                textBuffer += ":"
            }
            textBuffer += "*"
        } else if !outputLines.isEmpty {
            var lastLine = outputLines.removeLast()
            if lastLine.hasPrefix("#") {
                 // Don't append formatting to structural commands
                 outputLines.append(lastLine)
                 outputLines.append("*")
            } else {
                if currentLayout == .labeling && !lastLine.trimmingCharacters(in:.whitespaces).hasSuffix(":") {
                    lastLine += ":"
                }
                lastLine += "*"
                outputLines.append(lastLine)
            }
        }
    }

    // PHASE 2: Structural Closure
    // Now that character formatting is secure, we close the block-level elements.
    switch currentLayout {
    case .title, .author: 
        // These layouts wrap content in #align(center,...) functions.
        outputLines.append("])\n")
    case .code: 
        // Closes the triple-backtick block for raw code.
        outputLines.append("```\n")
    default: 
        // Standard paragraphs simply need a separation from the next block.
        outputLines.append("") 
    }
    
    // PHASE 3: Safe State Reset
    currentLayout = .standard
    isBold = false
    isItalic = false
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
        else { if type.contains("Float") { return }; skipInset() }
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
        while currentLineIndex < sourceLines.count {
            let line = sourceLines[currentLineIndex].trimLeading()
            if line == "\\end_inset" { break }
            if line.hasPrefix("filename") {
                let path = line.replacingOccurrences(of: "filename ", with: "")
                flushBuffer()
                outputLines.append("#image(\"\(path)\")") 
            }
            currentLineIndex += 1
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
                    textBuffer += " <\(labelName.sanitizedLabel())>"
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
        if !textBuffer.isEmpty {
            outputLines.append(textBuffer)
            textBuffer = ""
        }
    }
    
    private func escapeTypstText(_ text: String) -> String {
        var res = text
        res = res.replacingOccurrences(of: "\\", with: "\\\\")
        res = res.replacingOccurrences(of: "#", with: "\\#")
        res = res.replacingOccurrences(of: "@", with: "\\@")
        res = res.replacingOccurrences(of: "[", with: "\\[")
        res = res.replacingOccurrences(of: "]", with: "\\]")
        res = res.replacingOccurrences(of: "*", with: "\\*")
        res = res.replacingOccurrences(of: "_", with: "\\_")
        res = res.replacingOccurrences(of: "`", with: "\\`")
        res = res.replacingOccurrences(of: "$", with: "\\$")
        return res
    }
    
    private func convertLatexMathToTypst(_ latex: String) -> String {
        var m = latex
        m = m.replacingOccurrences(of: "\\begin_inset Formula ", with: "")
        m = m.replacingOccurrences(of: "\\[", with: "")
        m = m.replacingOccurrences(of: "\\]", with: "")
        m = m.replacingOccurrences(of: "$", with: "")
        m = m.replacingRegex(pattern: "\\\\frac\\{([^}]*)\\}\\{([^}]*)\\}", with: "($1)/($2)")
        m = m.replacingOccurrences(of: "\\cdot", with: "dot")
        m = m.replacingOccurrences(of: "\\times", with: "times")
        m = m.replacingOccurrences(of: "\\sum", with: "sum")
        m = m.replacingOccurrences(of: "\\prod", with: "product")
        m = m.replacingOccurrences(of: "\\int", with: "integral")
        m = m.replacingOccurrences(of: "\\infty", with: "infinity")
        m = m.replacingOccurrences(of: "\\rightarrow", with: "arrow.r")
        m = m.replacingOccurrences(of: "\\leftarrow", with: "arrow.l")
        m = m.replacingOccurrences(of: "\\mathbb{R}", with: "RR")
        m = m.replacingOccurrences(of: "\\mathbb{N}", with: "NN")
        m = m.replacingOccurrences(of: "\\mathbb{Z}", with: "ZZ")
        m = m.replacingOccurrences(of: "\\in", with: "in")
        
        let greek = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega"]
        for g in greek {
            m = m.replacingOccurrences(of: "\\\\\(g)", with: g, options: .regularExpression)
            m = m.replacingOccurrences(of: "\\\\\(g.capitalized)", with: g.capitalized, options: .regularExpression)
        }
        
        m = m.replacingOccurrences(of: "\\", with: "")
        m = m.replacingOccurrences(of: "{", with: "(")
        m = m.replacingOccurrences(of: "}", with: ")")
        
        return m.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
