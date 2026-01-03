import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let refreshProjectSidebar = Notification.Name("refreshProjectSidebar")
}

@MainActor
class EditorController: NSObject, ObservableObject, TypstEditorTextViewDelegate {
    enum ViewMode {
        case both
        case editorOnly
        case previewOnly
    }
    
    enum ColorBlindnessMode: String, CaseIterable {
        case none = "None"
        case protanopia = "Protanopia"
        case deuteranopia = "Deuteranopia"
        case tritanopia = "Tritanopia"
    }
    
    // --- Equation Editor State ---
    @Published var showEquationEditor: Bool = false
    @Published var showTableEditor: Bool = false
    @Published var currentEquationContent: String = ""
    var currentEquationRange: NSRange?
    
    // --- Table Editor State ---
    var currentTableRange: NSRange?
    @Published var currentTableCells: [String] = []
    @Published var tableEditInitialRows: Int = 0
    @Published var tableEditInitialCols: Int = 0
    @Published var tableColumnsString: String = ""
    @Published var tableInset: String = ""
    @Published var tableAlign: String = ""
    @Published var useTableHeader: Bool = false
    @Published var tableHeaderCells: [String] = []
    
    // --- Link ---
    @Published var isLinkActive: Bool = false
    @Published var showLinkEditor: Bool = false
    @Published var currentLinkRange: NSRange?
    @Published var currentLinkURL: String = ""
    @Published var currentLinkText: String = ""
    
    // --- Quote Editor State ---
    @Published var showQuoteEditor: Bool = false
    @Published var currentQuoteRange: NSRange?
    @Published var currentQuoteContent: String = ""
    @Published var currentQuoteAttribution: String = ""
    @Published var isQuoteBlock: Bool = true
    
    // --- Bibliography Editor State ---
    @Published var showBibliographyEditor: Bool = false
    @Published var currentBibliographyRange: NSRange?
    @Published var bibSources: String = ""
    @Published var bibTitle: String = ""
    @Published var bibFull: Bool = false
    @Published var bibStyle: String = "apa"
    
    // --- File Context ---
    @Published var currentFileURL: URL?
    @Published var projectRootURL: URL?
    @Published var shouldCopyImages: Bool = true
    
    // --- Image Editor State ---
    @Published var showImageEditor: Bool = false
    @Published var showLayoutEditor: Bool = false
    @Published var pendingImagePath: String = ""
    @Published var imageWidth: String = "auto"
    @Published var imageHeight: String = "auto"
    @Published var imageAlt: String = ""
    @Published var imageFit: String = "contain"
    @Published var imageValidationError: String? = nil
    @Published var imageValidationWarning: String? = nil
    @Published var selectedImageURL: URL? = nil
    @Published var isBoldActive: Bool = false
    @Published var isItalicActive: Bool = false
    @Published var isUnderlineActive: Bool = false
    @Published var isHighlightActive: Bool = false
    @Published var isStrikeActive: Bool = false
    @Published var isSubscriptActive: Bool = false
    @Published var isSuperscriptActive: Bool = false
    @Published var isQuoteActive: Bool = false
    @Published var isCodeBlockActive: Bool = false
    @Published var currentHeadingLevel: Int = 0
    @Published var isEquationActive: Bool = false
    @Published var isTableActive: Bool = false
    @Published var isImageActive: Bool = false
    @Published var isBibliographyActive: Bool = false
    @Published var isCodeActive: Bool = false
    @Published var showDeleteEquationAlert: Bool = false
    @Published var showDeleteCodeAlert: Bool = false
    @Published var showGoToLineAlert: Bool = false
    @Published var showExportErrorAlert: Bool = false
    @Published var showHelp: Bool = false
    @Published var showFileNotFoundAlert: Bool = false
    @Published var lastExportError: String = ""
    @Published var missingFileName: String = ""
    @Published var targetLineNumber: String = ""
    @Published var zoomLevel: CGFloat = 1.0
    @Published var isSidebarVisible: Bool = true
    @Published var isSearchVisible: Bool = false
    @Published var wrapLines: Bool = true
    @Published var viewMode: ViewMode = .both
    @Published var isVerticalSplit: Bool = true
    @Published var colorBlindnessMode: ColorBlindnessMode = .none
    @Published var isPreviewDarkMode: Bool = true
    @Published var cursorSize: CGFloat = 2.0 // Default thickness
    
    var currentImageRange: NSRange? = nil
    
    var isTypstFile: Bool {
        currentFileURL?.pathExtension.lowercased() == "typ"
    }
    
    func openEquationEditor(at range: NSRange, initialContent: String) {
        currentEquationRange = range
        currentEquationContent = initialContent
        showEquationEditor = true
    }
    
    func adjustZoom(by delta: CGFloat) {
        let newZoom = zoomLevel + delta
        zoomLevel = max(0.5, min(3.0, newZoom))
    }
    
    func setZoomLevel(_ level: CGFloat) {
        zoomLevel = max(0.5, min(3.0, level))
    }
    
    func saveEquation(_ newContent: String) {
        guard let range = currentEquationRange, let textView = textView else { 
            print("[ERROR] saveEquation aborted: range=\(String(describing: currentEquationRange)), textView=\(textView != nil)")
            return 
        }
        
        print("[DEBUG] saveEquation: range=\(range), content length=\(newContent.count)")
        
        let replacement = "$\(newContent)$"
        
        if range.location != NSNotFound {
            print("[DEBUG] Inserting replacement: '\(replacement)' at range: \(range)")
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.insertText(replacement, replacementRange: range)
                textView.didChangeText()
                
                // For a better UX, select the newly inserted equation
                let newRange = NSRange(location: range.location, length: replacement.count)
                textView.setSelectedRange(newRange)
            }
        }
        
        showEquationEditor = false
    }
    @Published var errors: [TypstError] = []
    @Published var scrollPosition: CGFloat = 0
    
    // Référence faible vers la vue native pour manipuler le texte directement
    weak var textView: NSTextView? {
        didSet {
            setupScrollNotification()
        }
    }
    
    // Recherche
    @Published var searchQuery: String = "" {
        didSet {
            if searchQuery != oldValue {
                performSearch()
            }
        }
    }
    @Published var searchMatches: [NSRange] = []
    @Published var currentMatchIndex: Int = -1
    
    var matchCount: Int {
        searchMatches.count
    }
    
    // Demande de redessiner la règle (numéros de ligne)
    func needsRedraw() {
        textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
    
    // --- Undo/Redo Functions ---
    
    func undo() {
        textView?.undoManager?.undo()
    }
    
    func redo() {
        textView?.undoManager?.redo()
    }
    
    // --- Snippet Functions ---
    
    func insertTableSnippet() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        setupTableEditor(at: range.location)
        self.showTableEditor = true
    }
    
    func openTableEditor(at range: NSRange) {
        setupTableEditor(at: range.location)
        self.showTableEditor = true
    }
    
    func textViewDidChangeSelection() {
        updateFormattingState()
    }
    
    private func setupTableEditor(at location: Int) {
        guard let textView = textView else { return }
        
        // Reset state
        self.currentTableRange = nil
        self.currentTableCells = []
        self.tableEditInitialRows = 0
        self.tableEditInitialCols = 0
        self.tableColumnsString = ""
        self.tableInset = ""
        self.tableAlign = ""
        self.useTableHeader = false
        self.tableHeaderCells = []
        
        // Detect existing table
        if let tableInfo = TableDetector.parseTable(in: textView.string, at: location) {
            self.currentTableRange = tableInfo.range
            self.currentTableCells = tableInfo.cells
            self.tableEditInitialRows = tableInfo.rows
            self.tableEditInitialCols = tableInfo.columns
            self.tableColumnsString = tableInfo.columnsString ?? "\(tableInfo.columns)"
            self.tableInset = tableInfo.inset ?? ""
            self.tableAlign = tableInfo.align ?? ""
            if let headers = tableInfo.headerCells {
                self.useTableHeader = true
                self.tableHeaderCells = headers
            }
        }
    }
    
    private func ensureTypstContent(_ str: String) -> String {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "[]" }
        
        // If it's already wrapped in [] or "", or is a number, return as is
        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) ||
           (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
           (Double(trimmed) != nil) ||
           (trimmed == "true" || trimmed == "false" || trimmed == "none") {
            return trimmed
        }
        
        // If it looks like a function call or a variable starting with #, or contains math $
        if trimmed.hasPrefix("#") || trimmed.contains("(") || (trimmed.hasPrefix("$") && trimmed.hasSuffix("$")) {
            return trimmed
        }
        
        return "[\(trimmed)]"
    }
    
    func insertTable(rows: Int, cols: Int, columnsString: String, inset: String, align: String, useHeader: Bool, headerCells: [String]) {
        guard let textView = textView else { return }
        
        var snippet = "#table(\n"
        
        // Columns
        if !columnsString.isEmpty {
            snippet += "  columns: \(columnsString),\n"
        } else {
            snippet += "  columns: \(cols),\n"
        }
        
        // Inset
        if !inset.isEmpty {
            snippet += "  inset: \(inset),\n"
        }
        
        // Align
        if !align.isEmpty {
            snippet += "  align: \(align),\n"
        }
        
        // Header
        if useHeader {
            let headerCount = !columnsString.isEmpty ? 
                (Int(columnsString) ?? columnsString.split(separator: ",").count) : cols
            
            var effectiveHeaders = headerCells
            if effectiveHeaders.count > headerCount {
                effectiveHeaders = Array(effectiveHeaders.prefix(headerCount))
            } else {
                while effectiveHeaders.count < headerCount {
                    effectiveHeaders.append("[]")
                }
            }
            
            let headerContent = effectiveHeaders.map { ensureTypstContent($0) }.joined(separator: ", ")
            snippet += "  table.header(\n    \(headerContent),\n  ),\n"
        }
        
        // Preserve data from currentTableCells if we are editing
        let totalCellsNeeded = rows * cols
        var cellsToInsert: [String] = []
        
        for i in 0..<totalCellsNeeded {
            let r = i / cols
            let c = i % cols
            
            if let oldCols = tableEditInitialCols != 0 ? tableEditInitialCols : nil {
                let oldIndex = r * oldCols + c
                if r < tableEditInitialRows && c < oldCols && oldIndex < currentTableCells.count {
                    cellsToInsert.append(currentTableCells[oldIndex])
                } else {
                    cellsToInsert.append("[]")
                }
            } else {
                cellsToInsert.append("[]")
            }
        }
        
        for r in 0..<rows {
            var rowText = "  "
            for c in 0..<cols {
                let index = r * cols + c
                rowText += "\(ensureTypstContent(cellsToInsert[index])), "
            }
            snippet += rowText.trimmingCharacters(in: CharacterSet(charactersIn: ", ")) + ",\n"
        }
        snippet += ")"
        
        let rangeToReplace = currentTableRange ?? textView.selectedRange()
        
        if rangeToReplace.location != NSNotFound {
            textView.insertText(snippet, replacementRange: rangeToReplace)
        }
        
        // Clear state
        currentTableRange = nil
        currentTableCells = []
        tableEditInitialRows = 0
        tableEditInitialCols = 0
        tableColumnsString = ""
        tableInset = ""
        tableAlign = ""
        useTableHeader = false
        tableHeaderCells = []
        
        showTableEditor = false
    }
    
    func insertImageSnippet() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        
        // Reset state
        self.pendingImagePath = ""
        self.imageWidth = "auto"
        self.imageHeight = "auto"
        self.imageAlt = ""
        self.imageFit = "contain"
        self.imageValidationError = nil
        self.selectedImageURL = nil
        self.currentImageRange = nil
        
        if let imageInfo = ImageDetector.parseImage(in: textView.string, at: range.location) {
            setupImageEditor(with: imageInfo)
        }
        
        self.showImageEditor = true
    }
    
    func openImageEditor(at range: NSRange) {
        guard let textView = textView else { return }
        if let imageInfo = ImageDetector.parseImage(in: textView.string, at: range.location) {
            setupImageEditor(with: imageInfo)
            self.showImageEditor = true
        }
    }
    
    private func setupImageEditor(with imageInfo: ImageInfo) {
        self.currentImageRange = imageInfo.range
        self.pendingImagePath = imageInfo.path
        self.imageWidth = imageInfo.width ?? "auto"
        self.imageHeight = imageInfo.height ?? "auto"
        self.imageAlt = imageInfo.alt ?? ""
        self.imageFit = imageInfo.fit ?? "contain"
        self.selectedImageURL = nil
        self.imageValidationError = nil
        self.imageValidationWarning = nil
    }
    
    func browseForImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .svg]
        panel.title = "Select Image"
        
        if panel.runModal() == .OK, let selectedURL = panel.url {
            self.selectedImageURL = selectedURL
            self.imageValidationError = nil
        }
    }
    
    private func handleImageSelection(selectedURL: URL, shouldCopy: Bool) -> String? {
        print("[DEBUG] handleImageSelection: shouldCopy=\(shouldCopy), projectRootURL=\(projectRootURL?.path ?? "nil"), currentFileURL=\(currentFileURL?.path ?? "nil")")
        
        var imagePath = selectedURL.path
        
        if shouldCopy, let root = projectRootURL {
            let fileName = selectedURL.lastPathComponent
            let destinationURL = root.appendingPathComponent(fileName)
            
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    let timestamp = Int(Date().timeIntervalSince1970)
                    let newFileName = "\(selectedURL.deletingPathExtension().lastPathComponent)_\(timestamp).\(selectedURL.pathExtension)"
                    let newDestinationURL = root.appendingPathComponent(newFileName)
                    try FileManager.default.copyItem(at: selectedURL, to: newDestinationURL)
                    imagePath = newFileName
                } else {
                    try FileManager.default.copyItem(at: selectedURL, to: destinationURL)
                    imagePath = fileName
                }
                
                NotificationCenter.default.post(name: .refreshProjectSidebar, object: nil)
            } catch {
                print("[ERROR] Failed to copy image: \(error.localizedDescription)")
                if let currentFile = currentFileURL {
                     imagePath = relativePath(from: currentFile.deletingLastPathComponent(), to: selectedURL) ?? selectedURL.path
                }
            }
        } else if let currentFile = currentFileURL {
            let rel = relativePath(from: currentFile.deletingLastPathComponent(), to: selectedURL)
            imagePath = rel ?? selectedURL.path
        }
        
        return imagePath
    }
    
    func generateImageSnippet() -> String {
        var finalPath = pendingImagePath
        if let selectedURL = selectedImageURL {
            // This is a bit tricky for real-time preview since we don't want to copy the file yet.
            // For preview, we'll just show the filename or the original path.
            finalPath = selectedURL.lastPathComponent
        }
        
        if finalPath.isEmpty { return "" }
        
        var params: [String] = []
        params.append("\"\(finalPath)\"")
        
        if imageWidth != "auto" && !imageWidth.isEmpty {
            params.append("width: \(imageWidth)")
        }
        
        if imageHeight != "auto" && !imageHeight.isEmpty {
            params.append("height: \(imageHeight)")
        }
        
        if !imageAlt.isEmpty {
            params.append("alt: \"\(imageAlt)\"")
        }
        
        if imageFit != "contain" {
            params.append("fit: \"\(imageFit)\"")
        }
        
        return "#image(\(params.joined(separator: ", ")))"
    }
    
    func validateImageSettings() {
        imageValidationError = nil
        imageValidationWarning = nil
        
        if selectedImageURL == nil && pendingImagePath.isEmpty {
            imageValidationError = "Please select an image file."
            return
        }
        
        // Validate width
        if !imageWidth.isEmpty && imageWidth != "auto" {
            if !validateTypstLength(imageWidth) {
                imageValidationError = "Invalid width: '\(imageWidth)'. Use auto, %, pt, mm, cm, in."
            }
        }
        
        // Validate height
        if !imageHeight.isEmpty && imageHeight != "auto" {
            if !validateTypstLength(imageHeight) {
                imageValidationError = "Invalid height: '\(imageHeight)'. Use auto, %, pt, mm, cm, in."
            } else if imageHeight.hasSuffix("%") {
                // Layout conflict warning
                imageValidationWarning = "Tip: 100% height often collapses to zero height on pages with auto-size. Consider using fixed units or width: 100% instead."
            }
        }
    }
    
    private func validateTypstLength(_ length: String) -> Bool {
        let trimmed = length.trimmingCharacters(in: .whitespaces)
        if trimmed == "auto" { return true }
        
        // Regex for Typst length: optional number, followed by unit
        // Typst also supports things like 10pt + 50% but we'll stick to basic validation for now.
        let pattern = "^-?(\\d+(\\.\\d+)?)(pt|mm|cm|in|%|em|fr)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        return regex.firstMatch(in: trimmed, options: [], range: range) != nil
    }
    
    func saveImageSnippet() {
        validateImageSettings()
        if imageValidationError != nil { return }
        
        // Final processing (copying file)
         var finalPath = pendingImagePath
         if let selectedURL = selectedImageURL {
             if let path = handleImageSelection(selectedURL: selectedURL, shouldCopy: shouldCopyImages) {
                 finalPath = path
             } else {
                 imageValidationError = "Failed to copy image to project."
                 return
             }
         }
         
         // Re-generate final snippet with correct path
         var params: [String] = []
         params.append("\"\(finalPath)\"")
         
         if imageWidth != "auto" && !imageWidth.isEmpty {
             params.append("width: \(imageWidth)")
         }
         
         if imageHeight != "auto" && !imageHeight.isEmpty {
             params.append("height: \(imageHeight)")
         }
         
         if !imageAlt.isEmpty {
             params.append("alt: \"\(imageAlt)\"")
         }
         
         if imageFit != "contain" {
             params.append("fit: \"\(imageFit)\"")
         }
         
         let snippet = "#image(\(params.joined(separator: ", ")))"
        
        if let range = currentImageRange, let textView = textView {
             textView.insertText(snippet, replacementRange: range)
        } else {
             insertText(snippet)
        }
        
        // Reset state
        showImageEditor = false
        pendingImagePath = ""
        selectedImageURL = nil
        currentImageRange = nil
        imageWidth = "auto"
        imageHeight = "auto"
        imageAlt = ""
        imageFit = "contain"
        imageValidationError = nil
        imageValidationWarning = nil
    }
    
    private func relativePath(from base: URL, to target: URL) -> String? {
        let baseComponents = base.pathComponents
        let targetComponents = target.pathComponents
        
        var commonPrefixCount = 0
        for i in 0..<min(baseComponents.count, targetComponents.count) {
            if baseComponents[i] == targetComponents[i] {
                commonPrefixCount += 1
            } else {
                break
            }
        }
        
        var relComponents = Array(repeating: "..", count: baseComponents.count - commonPrefixCount)
        relComponents.append(contentsOf: targetComponents[commonPrefixCount...])
        
        return relComponents.joined(separator: "/")
    }
    
    func insertChartSnippet() {
        guard let textView = textView else { return }
        SnippetsManager.shared.insertSnippet("chart", into: textView)
    }
    
    func insertTimelineSnippet() {
        guard let textView = textView else { return }
        SnippetsManager.shared.insertSnippet("timeline", into: textView)
    }
    
    func openLayoutEditor() {
        self.showLayoutEditor = true
    }
    
    // --- Search Functions ---
    
    func performSearch() {
        guard let textView = textView, !searchQuery.isEmpty else {
            clearSearch()
            return
        }
        
        let text = textView.string
        searchMatches = []
        
        // Find all matches (case-insensitive)
        let searchOptions: NSString.CompareOptions = [.caseInsensitive]
        var searchRange = NSRange(location: 0, length: text.utf16.count)
        
        while searchRange.location < text.utf16.count {
            let foundRange = (text as NSString).range(of: searchQuery, options: searchOptions, range: searchRange)
            if foundRange.location == NSNotFound {
                break
            }
            searchMatches.append(foundRange)
            searchRange = NSRange(location: foundRange.location + foundRange.length, 
                                length: text.utf16.count - (foundRange.location + foundRange.length))
        }
        
        // Highlight all matches
        if !searchMatches.isEmpty {
            currentMatchIndex = 0
            highlightMatches()
            scrollToMatch(at: 0)
        }
    }
    
    func highlightMatches() {
        guard let textView = textView, let textStorage = textView.textStorage else { return }
        
        // Remove previous highlights
        textStorage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: textStorage.length))
        
        // Highlight all matches in yellow
        for (index, range) in searchMatches.enumerated() {
            let isCurrentMatch = (index == currentMatchIndex)
            let highlightColor = isCurrentMatch ? 
                NSColor.systemYellow : // Current match
                NSColor(calibratedRed: 1.0, green: 1.0, blue: 0.0, alpha: 0.3) // Other matches
            textStorage.addAttribute(.backgroundColor, value: highlightColor, range: range)
        }
    }
    
    func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count
        highlightMatches()
        scrollToMatch(at: currentMatchIndex)
    }
    
    func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
        highlightMatches()
        scrollToMatch(at: currentMatchIndex)
    }
    
    func scrollToMatch(at index: Int) {
        guard let textView = textView, index >= 0, index < searchMatches.count else { return }
        let range = searchMatches[index]
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }
    
    func clearSearch() {
        searchMatches = []
        currentMatchIndex = -1
        if let textView = textView, let textStorage = textView.textStorage {
            textStorage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: textStorage.length))
        }
    }
    
    // --- Commandes d'édition de texte ---
    
    // Insère du texte à la position du curseur
    func insertText(_ text: String) {
        guard let textView = textView else { return }
        
        let range = textView.selectedRange()
        if range.location != NSNotFound {
            textView.insertText(text, replacementRange: range)
        } else {
            // Fallback: ajout à la fin si pas de sélection valide
            let endRange = NSRange(location: textView.string.count, length: 0)
            textView.insertText(text, replacementRange: endRange)
        }
    }
    
    // Entoure la sélection actuelle avec un préfixe et un suffixe
    func wrapSelection(prefix: String, suffix: String) {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        
        if range.length == 0 {
            // Si rien n'est sélectionné : on insère les marqueurs et on place le curseur au milieu
            textView.insertText(prefix + suffix, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location + prefix.count, length: 0))
        } else {
            // Si du texte est sélectionné : on l'entoure
            if let string = textView.string as NSString? {
                let selectedText = string.substring(with: range)
                let newText = prefix + selectedText + suffix
                textView.insertText(newText, replacementRange: range)
            }
        }
    }
    
    func updateFormattingState() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        let text = textView.string
        
        isBoldActive = FormatDetector.findBoldRange(in: text, at: range.location) != nil
        isItalicActive = FormatDetector.findItalicRange(in: text, at: range.location) != nil
        isUnderlineActive = FormatDetector.findUnderlineRange(in: text, at: range.location) != nil
        isHighlightActive = FormatDetector.findHighlightRange(in: text, at: range.location) != nil
        isStrikeActive = FormatDetector.findStrikeRange(in: text, at: range.location) != nil
        isCodeActive = FormatDetector.findCodeRange(in: text, at: range.location) != nil
        isLinkActive = FormatDetector.findLinkRange(in: text, at: range.location) != nil
        isQuoteActive = FormatDetector.findQuoteRange(in: text, at: range.location) != nil
        isCodeBlockActive = FormatDetector.findCodeBlockRange(in: text, at: range.location) != nil
        isSubscriptActive = FormatDetector.findSubscriptRange(in: text, at: range.location) != nil
        isSuperscriptActive = FormatDetector.findSuperscriptRange(in: text, at: range.location) != nil
        
        currentHeadingLevel = FormatDetector.detectHeadingLevel(in: text, at: range.location)
        
        isEquationActive = EquationDetector.findEquationRange(in: text, at: range.location) != nil
        isTableActive = TableDetector.findTableRange(in: text, at: range.location) != nil
        isImageActive = ImageDetector.findImageRange(in: text, at: range.location) != nil
        isBibliographyActive = BibliographyDetector.findBibliographyRange(in: text, at: range.location) != nil
    }
    
    // --- Heading Actions ---
    
    func setHeadingLevel(_ level: Int) {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        let text = textView.string
        
        let currentLevel = FormatDetector.detectHeadingLevel(in: text, at: range.location)
        if currentLevel == level { return }
        
        // Find existing heading prefix if any
        let headingRange = FormatDetector.findHeadingRange(in: text, at: range.location)
        
        if level == 0 {
            // Remove heading
            if let hr = headingRange {
                textView.insertText("", replacementRange: hr)
            }
        } else {
            let prefix = String(repeating: "=", count: level) + " "
            if let hr = headingRange {
                // Replace existing prefix
                textView.insertText(prefix, replacementRange: hr)
            } else {
                // Add new prefix at start of line
                let nsText = text as NSString
                let lineRange = nsText.lineRange(for: NSRange(location: range.location, length: 0))
                textView.insertText(prefix, replacementRange: NSRange(location: lineRange.location, length: 0))
            }
        }
        
        updateFormattingState()
    }
    
    // --- Formatting Actions ---
    
    func toggleBold() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        if let boldRange = FormatDetector.findBoldRange(in: textView.string, at: range.location) {
            unwrapFormatting(range: boldRange, prefixLen: 1, suffixLen: 1)
        } else {
            wrapSelection(prefix: "*", suffix: "*")
        }
        updateFormattingState()
    }
    
    func toggleItalic() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        if let italicRange = FormatDetector.findItalicRange(in: textView.string, at: range.location) {
            unwrapFormatting(range: italicRange, prefixLen: 1, suffixLen: 1)
        } else {
            wrapSelection(prefix: "_", suffix: "_")
        }
        updateFormattingState()
    }
    
    func toggleUnderline() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        if let underlineRange = FormatDetector.findUnderlineRange(in: textView.string, at: range.location) {
            unwrapBracketedFormatting(range: underlineRange, prefixPattern: #"^#underline\s*[\[\(]"#)
        } else {
            wrapSelection(prefix: "#underline[", suffix: "]")
        }
        updateFormattingState()
    }
    
    func toggleHighlight() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        if let highlightRange = FormatDetector.findHighlightRange(in: textView.string, at: range.location) {
            unwrapBracketedFormatting(range: highlightRange, prefixPattern: #"^#highlight\s*[\[\(]"#)
        } else {
            wrapSelection(prefix: "#highlight[", suffix: "]")
        }
        updateFormattingState()
    }
    
    func toggleStrike() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        if let strikeRange = FormatDetector.findStrikeRange(in: textView.string, at: range.location) {
            unwrapBracketedFormatting(range: strikeRange, prefixPattern: #"^#strike\s*[\[\(]"#)
        } else {
            wrapSelection(prefix: "#strike[", suffix: "]")
        }
        updateFormattingState()
    }
    
    func toggleSubscript() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        if let subRange = FormatDetector.findSubscriptRange(in: textView.string, at: range.location) {
            unwrapBracketedFormatting(range: subRange, prefixPattern: #"^#sub\s*[\[\(]"#)
        } else {
            wrapSelection(prefix: "#sub[", suffix: "]")
        }
        updateFormattingState()
    }
    
    func toggleSuperscript() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        if let supRange = FormatDetector.findSuperscriptRange(in: textView.string, at: range.location) {
            unwrapBracketedFormatting(range: supRange, prefixPattern: #"^#sup\s*[\[\(]"#)
        } else {
            wrapSelection(prefix: "#sup[", suffix: "]")
        }
        updateFormattingState()
    }
    
    private func unwrapBracketedFormatting(range: NSRange, prefixPattern: String) {
        guard let textView = textView else { return }
        let text = textView.string as NSString
        let snippet = text.substring(with: range)
        
        if let openerRange = snippet.range(of: prefixPattern, options: .regularExpression) {
            let prefixLen = snippet.distance(from: snippet.startIndex, to: openerRange.upperBound)
            unwrapFormatting(range: range, prefixLen: prefixLen, suffixLen: 1)
        } else {
            // Fallback: search for first [ or (
            if let startParen = snippet.firstIndex(where: { $0 == "[" || $0 == "(" }) {
                let prefixLen = snippet.distance(from: snippet.startIndex, to: startParen) + 1
                unwrapFormatting(range: range, prefixLen: prefixLen, suffixLen: 1)
            }
        }
    }
    
    private func unwrapFormatting(range: NSRange, prefixLen: Int, suffixLen: Int) {
        guard let textView = textView else { return }
        let nsText = textView.string as NSString
        let fullSnippet = nsText.substring(with: range)
        
        let contentStart = fullSnippet.index(fullSnippet.startIndex, offsetBy: prefixLen)
        let contentEnd = fullSnippet.index(fullSnippet.endIndex, offsetBy: -suffixLen)
        let innerContent = String(fullSnippet[contentStart..<contentEnd])
        
        textView.insertText(innerContent, replacementRange: range)
    }
    
    func toggleCode() {
        if isCodeActive {
            showDeleteCodeAlert = true
        } else {
            wrapSelection(prefix: "`", suffix: "`")
        }
    }
    
    func deleteCodeBlock() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        if let codeRange = FormatDetector.findCodeRange(in: textView.string, at: range.location) {
             textView.insertText("", replacementRange: codeRange)
             updateFormattingState()
        }
    }
    
    func insertMath() {
        if isEquationActive {
            showDeleteEquationAlert = true
        } else {
            wrapSelection(prefix: "$", suffix: "$")
        }
    }
    
    func deleteEquation() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        if let equationRange = EquationDetector.findEquationRange(in: textView.string, at: range.location) {
             textView.insertText("", replacementRange: equationRange)
             updateFormattingState()
        }
    }
    
    // --- Commenting Actions ---
    
    func toggleLineComment() {
        guard let textView = textView else { return }
        let nsString = textView.string as NSString
        let range = textView.selectedRange()
        let lineRange = nsString.lineRange(for: range)
        let selectedLinesText = nsString.substring(with: lineRange)
        
        let lines = selectedLinesText.components(separatedBy: .newlines)
        var newLines: [String] = []
        
        // If all non-empty lines start with //, remove them. Otherwise add them.
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let areAllCommented = !nonEmptyLines.isEmpty && nonEmptyLines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        
        for line in lines {
            if areAllCommented {
                if let prefixRange = line.range(of: "//") {
                    var newLine = line
                    newLine.removeSubrange(prefixRange)
                    newLines.append(newLine)
                } else {
                    newLines.append(line)
                }
            } else {
                newLines.append("// " + line)
            }
        }
        
        let replacement = newLines.joined(separator: "\n")
        textView.insertText(replacement, replacementRange: lineRange)
    }
    
    func toggleBlockComment() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        let nsString = textView.string as NSString
        let selectedText = nsString.substring(with: range)
        
        if selectedText.hasPrefix("/*") && selectedText.hasSuffix("*/") {
            let inner = String(selectedText.dropFirst(2).dropLast(2))
            textView.insertText(inner, replacementRange: range)
        } else {
            textView.insertText("/* \(selectedText) */", replacementRange: range)
        }
    }
    
    func toggleQuote() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        
        // Reset state
        currentQuoteRange = nil
        currentQuoteContent = ""
        currentQuoteAttribution = ""
        isQuoteBlock = true
        
        // If cursor is inside a quote, parse it
        if let quoteInfo = FormatDetector.parseQuote(in: textView.string, at: range.location) {
            currentQuoteRange = quoteInfo.range
            currentQuoteContent = quoteInfo.content
            currentQuoteAttribution = quoteInfo.attribution
            isQuoteBlock = quoteInfo.isBlock
        } else if range.length > 0 {
            // If text is selected but not a quote, use it as initial content
            let nsString = textView.string as NSString
            currentQuoteContent = nsString.substring(with: range)
        }
        
        showQuoteEditor = true
    }
    
    func insertQuote(text: String, attribution: String, isBlock: Bool) {
        guard let textView = textView else { return }
        
        var params: [String] = []
        if isBlock { params.append("block: true") }
        if !attribution.isEmpty { params.append("attribution: \"\(attribution)\"") }
        
        let paramStr = params.isEmpty ? "" : "(\(params.joined(separator: ", ")))"
        let snippet = "#quote\(paramStr)[\(text)]"
        
        let rangeToReplace = currentQuoteRange ?? textView.selectedRange()
        textView.insertText(snippet, replacementRange: rangeToReplace)
        showQuoteEditor = false
    }
    
    func toggleCodeBlock() {
        // Simple wrap for now
        wrapSelection(prefix: "```\n", suffix: "\n```")
    }
    
    func insertPageBreak() {
        guard let textView = textView else { return }
        textView.insertText("#pagebreak()\n", replacementRange: textView.selectedRange())
    }
    
    func insertHorizontalLine() {
        guard let textView = textView else { return }
        textView.insertText("#line(length: 100%)\n", replacementRange: textView.selectedRange())
    }
    
    func insertFootnote() {
        wrapSelection(prefix: "#footnote[", suffix: "]")
    }
    
    func toggleBibliography() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        
        // Reset state
        currentBibliographyRange = nil
        bibSources = ""
        bibTitle = ""
        bibFull = false
        bibStyle = "apa"
        
        if let info = BibliographyDetector.parseBibliography(in: textView.string, at: range.location) {
            currentBibliographyRange = info.range
            bibSources = info.sources
            bibTitle = info.title ?? ""
            bibFull = info.full
            bibStyle = info.style ?? "apa"
        }
        
        showBibliographyEditor = true
    }
    
    func insertBibliography(sources: String, title: String, full: Bool, style: String) {
        guard let textView = textView else { return }
        
        var params: [String] = []
        // sources is positional, but we can also use sources: if it's cleaner or needed
        // For Typst, it's usually #bibliography("sources") or #bibliography(("src1", "src2"))
        
        let cleanedSources: String
        if sources.contains(",") {
            let split = sources.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            cleanedSources = "(" + split.map { "\"\($0)\"" }.joined(separator: ", ") + ")"
        } else {
            cleanedSources = "\"\(sources)\""
        }
        
        if !title.isEmpty { params.append("title: \"\(title)\"") }
        if full { params.append("full: true") }
        if !style.isEmpty && style != "apa" { params.append("style: \"\(style)\"") }
        
        let paramStr = params.isEmpty ? "" : ", " + params.joined(separator: ", ")
        let snippet = "#bibliography(\(cleanedSources)\(paramStr))"
        
        let rangeToReplace = currentBibliographyRange ?? textView.selectedRange()
        textView.insertText(snippet, replacementRange: rangeToReplace)
        showBibliographyEditor = false
        updateFormattingState()
    }
    
    func applyTextColor(_ color: String) {
         // color should be a Typst color string like "red", "blue", "rgb(...)".
         wrapSelection(prefix: "#text(fill: \(color))[", suffix: "]")
    }
    
    // --- Zoom Actions ---
    
    func zoomIn() {
        zoomLevel += 0.1
    }
    
    func zoomOut() {
        zoomLevel = max(0.5, zoomLevel - 0.1)
    }
    
    func selectAll() {
        textView?.selectAll(nil)
    }
    
    // Opens the visual equation editor for a new equation at the cursor
    func openNewEquationEditor() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        
        // Priority: Check if cursor or selection is inside an existing equation
        if let equationRange = EquationDetector.findEquationRange(in: textView.string, at: range.location) {
            let fullText = textView.string as NSString
            let content = fullText.substring(with: equationRange)
            var innerContent = content
            
            if content.hasPrefix("$$") && content.hasSuffix("$$") && content.count >= 4 {
                innerContent = String(content.dropFirst(2).dropLast(2))
            } else if content.hasPrefix("$") && content.hasSuffix("$") && content.count >= 2 {
                innerContent = String(content.dropFirst(1).dropLast(1))
            }
            
            currentEquationRange = equationRange
            currentEquationContent = innerContent
            showEquationEditor = true
            return
        }
        
        // Fallback: If there is a selection, use it as initial content (stripping $ if present)
        var initialContent = ""
        if range.length > 0 {
             let selectedText = (textView.string as NSString).substring(with: range)
             // Simple strip of surrounding $
             initialContent = selectedText.trimmingCharacters(in: CharacterSet(charactersIn: "$"))
        }
        
        currentEquationRange = range
        currentEquationContent = initialContent
        showEquationEditor = true
    }
    
    // --- Navigation ---
    
    @MainActor
    func goToLine(_ lineNumber: Int) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager else { return }
        
        let text = textView.string as NSString
        var currentLine = 1
        var charIndex = 0
        
        while currentLine < lineNumber && charIndex < text.length {
            if text.character(at: charIndex) == 10 { // newline
                currentLine += 1
            }
            charIndex += 1
        }
        
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textView.textContainer!)
        textView.scrollToVisible(rect)
        textView.setSelectedRange(NSRange(location: charIndex, length: 0))
    }
    
    func toggleLink() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        let text = textView.string
        
        if let linkRange = FormatDetector.findLinkRange(in: text, at: range.location) {
            // Edit existing
            self.currentLinkRange = linkRange
            let linkSnippet = (text as NSString).substring(with: linkRange)
            
            // Basic parsing of #link("url")[text]
            if let urlRange = linkSnippet.range(of: "(?<=\"|')[^\"']+(?=\"|')", options: .regularExpression) {
                self.currentLinkURL = String(linkSnippet[urlRange])
            } else {
                self.currentLinkURL = ""
            }
            
            if let textRange = linkSnippet.range(of: "(?<=\\[)[^\\]]+(?=\\])", options: .regularExpression) {
                self.currentLinkText = String(linkSnippet[textRange])
            } else {
                self.currentLinkText = ""
            }
        } else {
            // New link
            self.currentLinkRange = nil
            self.currentLinkURL = ""
            if range.length > 0 {
                self.currentLinkText = (text as NSString).substring(with: range)
            } else {
                self.currentLinkText = ""
            }
        }
        
        self.showLinkEditor = true
    }
    
    func insertLink(url: String, text: String) {
        guard let textView = textView else { return }
        
        var snippet = ""
        if text.isEmpty {
            snippet = "#link(\"\(url)\")"
        } else {
            snippet = "#link(\"\(url)\")[\(text)]"
        }
        
        let rangeToReplace = currentLinkRange ?? textView.selectedRange()
        textView.insertText(snippet, replacementRange: rangeToReplace)
        
        showLinkEditor = false
        updateFormattingState()
    }
    
    @MainActor
    private func setupScrollNotification() {
        guard let scrollView = textView?.enclosingScrollView else { return }
        
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}