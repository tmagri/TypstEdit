import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let refreshProjectSidebar = Notification.Name("refreshProjectSidebar")
}

import CodeEditSourceEditor
import Combine

@MainActor
class EditorController: NSObject, ObservableObject {
    enum SupportedFileType {
        case typst
        case text
        case image
        case pdf
        case other
        
        var isTextual: Bool {
            switch self {
            case .typst, .text: return true
            default: return false
            }
        }
    }

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
    
    // --- Outline Editor State ---
    @Published var showOutlineEditor: Bool = false
    @Published var currentOutlineRange: NSRange?
    @Published var outlineTitle: String = ""
    @Published var outlineTarget: String = "Heading"
    @Published var outlineDepthString: String = ""
    @Published var outlineIndent: Bool = false
    
    // --- Figure Editor State ---
    @Published var showFigureEditor: Bool = false
    @Published var currentFigureContent: String = ""
    
    // --- External Data Editor State ---
    @Published var showExternalDataEditor: Bool = false
    
    // MARK: - New Features (Symbol Picker & Word Count)
    @Published var showSymbolPicker: Bool = false
    @Published var wordCount: Int = 0
    
    // MARK: - Symbol Insertion
    // MARK: - Helper Properties
    
    var selectedRange: NSRange {
        get {
            if let pos = editorState.cursorPositions?.first {
                return pos.range
            }
            return NSRange(location: sourceCode.count, length: 0)
        }
        set {
            editorState.cursorPositions = [.init(range: newValue)]
        }
    }
    
    func insertText(_ text: String, replacementRange: NSRange? = nil, newCursorRange: NSRange? = nil) {
        let range = replacementRange ?? selectedRange
        print("[EditorController] insertText: '\(text)' at \(range)")
        
        guard let stringRange = Range(range, in: sourceCode) else { 
             print("[EditorController] insertText FAILED: Invalid range \(range) for len \(sourceCode.count)")
             showStatus("Insert failed: invalid range")
             return 
        }
        
        sourceCode.replaceSubrange(stringRange, with: text)
        
        // --- Sync with actual editor if available ---
        // This is necessary because SourceEditor's binding is one-way (upwards) in some versions
        if let tvc = textViewController {
             print("[EditorController] Syncing with TextViewController: \(ObjectIdentifier(tvc))")
             // Use surgical update to avoid resetting the entire highlighter (fixes "going white")
             tvc.textView.replaceCharacters(in: range, with: text)
        } else {
             print("[EditorController] WARNING: No TextViewController available for sync")
        }
        
        if let explicitCursor = newCursorRange {
            editorState.cursorPositions = [.init(range: explicitCursor)]
            textViewController?.setCursorPositions([.init(range: explicitCursor)], scrollToVisible: true)
        } else {
            // Default behavior: move to end
            if let newEndIndex = sourceCode.index(stringRange.lowerBound, offsetBy: text.count, limitedBy: sourceCode.endIndex) {
                 let loc = newEndIndex.utf16Offset(in: sourceCode)
                 let newRange = NSRange(location: loc, length: 0)
                 editorState.cursorPositions = [.init(range: newRange)]
                 textViewController?.setCursorPositions([.init(range: newRange)], scrollToVisible: true)
            }
        }
    }

    override init() {
        super.init()
        self.sourceEditorBridge = SourceEditorBridge(controller: self)
        setupDefaultConfiguration()
    }
    
    private func setupDefaultConfiguration() {
        self.editorConfiguration = SourceEditorConfiguration(
            appearance: .init(
                theme: customTheme,
                font: NSFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
                wrapLines: true,
                tabWidth: 2
            )
        )
    }
    func insertSymbol(code: String, unicode: String) {
        // Detect if we are in math mode ($ ... $)
        let index = selectedRange.location
        
        // Simple heuristic: count unescaped $ before cursor. Odd = math mode.
        let isMathMode = FormatDetector.isMathMode(in: sourceCode, at: index)
        
        let contentToInsert = isMathMode ? code : unicode
        insertText(contentToInsert)
        showStatus("Inserted Symbol")
    }
    
    
    // MARK: - Typst Insertion Logic
    @Published var currentFileURL: URL? {
        didSet {
            updateFileType()
        }
    }
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
    @Published var isOutlineActive: Bool = false
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
    
    // --- Status Message ---
    @Published var statusMessage: String = ""
    @Published var showStatusMessage: Bool = false
    
    @Published var zoomLevel: CGFloat = 1.0
    @Published var isSidebarVisible: Bool = true
    @Published var wrapLines: Bool = true
    @Published var isBulletListActive: Bool = false
    @Published var isNumberListActive: Bool = false
    @Published var isFootnoteActive: Bool = false
    @Published var isPageBreakActive: Bool = false
    @Published var isHorizontalLineActive: Bool = false
    
    // --- Footnote Editor State ---
    @Published var showFootnoteEditor: Bool = false
    @Published var footnoteBody: String = ""
    @Published var footnoteNumbering: String = "1"
    @Published var currentFootnoteRange: NSRange?
    
    @Published var hasUnsavedChanges: Bool = false
    private var savedContent: String = ""
    @Published var viewMode: ViewMode = .both
    @Published var isVerticalSplit: Bool = true
    @Published var colorBlindnessMode: ColorBlindnessMode = .none
    @Published var isPreviewDarkMode: Bool = true
    @Published var cursorSize: CGFloat = 2.0 // Default thickness
    
    // --- CodeEditSourceEditor State ---
    @Published var sourceCode: String = ""
    @Published var editorState: SourceEditorState = .init() {
        didSet {
            // Check if selection changed to update UI state
            let oldRanges = oldValue.cursorPositions?.map { $0.range }
            let newRanges = editorState.cursorPositions?.map { $0.range }
            if oldRanges != newRanges {
                 updateFormattingState()
            }
        }
    }
    
    // Bridge to the actual editor for programmatic updates
    var sourceEditorBridge: SourceEditorBridge!
    weak var textViewController: TextViewController?
    
    // Stable configuration to prevent "going white" due to frequent resets
    var editorConfiguration: SourceEditorConfiguration!
    
    private var _customTheme: EditorTheme?
    var customTheme: EditorTheme {
        if let theme = _customTheme { return theme }
        
        func safeColor(_ color: NSColor) -> NSColor {
            return color.usingColorSpace(.sRGB) ?? color
        }
        
        func attr(_ color: NSColor, bold: Bool = false, italic: Bool = false) -> EditorTheme.Attribute {
            return EditorTheme.Attribute(color: safeColor(color), bold: bold, italic: italic)
        }
        
        // One Dark Inspired Palette (Refined for Typst)
        let oneDarkBg = NSColor(red: 40/255, green: 44/255, blue: 52/255, alpha: 1.0)
        let oneDarkFg = NSColor(red: 171/255, green: 178/255, blue: 191/255, alpha: 1.0)
        // let oneDarkRed = NSColor(red: 224/255, green: 108/255, blue: 117/255, alpha: 1.0) // Unused

        let oneDarkGreen = NSColor(red: 152/255, green: 195/255, blue: 121/255, alpha: 1.0)
        let oneDarkYellow = NSColor(red: 229/255, green: 192/255, blue: 123/255, alpha: 1.0)
        let oneDarkBlue = NSColor(red: 97/255, green: 175/255, blue: 239/255, alpha: 1.0)
        let oneDarkPurple = NSColor(red: 198/255, green: 120/255, blue: 221/255, alpha: 1.0)
        let oneDarkTeal = NSColor(red: 86/255, green: 182/255, blue: 194/255, alpha: 1.0)
        let oneDarkGray = NSColor(red: 92/255, green: 99/255, blue: 112/255, alpha: 1.0)
        
        let insertionPoint: NSColor
        if #available(macOS 14.0, *) {
            insertionPoint = safeColor(NSColor.textInsertionPointColor)
        } else {
            insertionPoint = oneDarkFg
        }
        
        let theme = EditorTheme(
            text: attr(oneDarkFg),
            insertionPoint: insertionPoint,
            invisibles: attr(oneDarkGray.withAlphaComponent(0.5)),
            background: safeColor(oneDarkBg),
            lineHighlight: safeColor(NSColor.white.withAlphaComponent(0.05)),
            selection: safeColor(NSColor.selectedTextBackgroundColor).withAlphaComponent(0.4),
            keywords: attr(oneDarkPurple, bold: true),   // Strong markup [*bold*] (Purple + Bold)
            commands: attr(oneDarkPurple),
            types: attr(oneDarkBlue, bold: true),      // Headings [= ...] (Blue + Bold)
            attributes: attr(oneDarkPurple, italic: true), // Emph markup [_italic_] (Purple + Italic)
            variables: attr(oneDarkPurple),            // Hashtag commands [#set, etc] (Purple)
            values: attr(oneDarkTeal),
            numbers: attr(oneDarkYellow),              // Math blocks [$...$] (Yellow)
            strings: attr(oneDarkGreen),
            characters: attr(oneDarkGreen),
            comments: attr(oneDarkGray, italic: true)
        )
        _customTheme = theme
        return theme
    }

    
    var currentImageRange: NSRange? = nil
    
    @Published var currentFileType: SupportedFileType = .typst
    
    private func updateFileType() {
        guard let url = currentFileURL else {
            currentFileType = .other
            return
        }
        
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "typ":
            currentFileType = .typst
        case "txt", "md", "json", "yml", "yaml", "toml", "css", "js", "ts", "html", "bib", "svg":
            currentFileType = .text
        case "png", "jpg", "jpeg", "gif", "tiff", "bmp", "heic", "webp":
            currentFileType = .image
        case "pdf":
            currentFileType = .pdf
        default:
            currentFileType = .other
        }
    }
    
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
        guard let range = currentEquationRange else {
            print("[ERROR] saveEquation aborted: range is nil")
            return
        }
        
        let replacement = "$\(newContent)$"
        
        if range.location != NSNotFound {
            insertText(replacement, replacementRange: range)
            
            // For a better UX, select the newly inserted equation
            let newRange = NSRange(location: range.location, length: replacement.utf16.count)
            self.selectedRange = newRange
        }
        
        showEquationEditor = false
    }
    @Published var errors: [TypstError] = []
    @Published var scrollPosition: CGFloat = 0
    
    // Old textView reference removed.
    // We now use direct state manipulation.

    
    // Recherche
    // Search state removed in favor of native find panel

    
    // Demande de redessiner la règle (numéros de ligne)
    // Demande de redessiner la règle (numéros de ligne)
    func needsRedraw() {
        // textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    // --- Unsaved Changes Comparison logic ---
    func syncSavedContent(_ content: String) {
        self.savedContent = content
        print("[DEBUG] EditorController: syncSavedContent (len=\(content.count))")
        self.hasUnsavedChanges = false
        self.showStatus("File Loaded")
    }

    func checkUnsavedChanges(currentContent: String) {
        // Normalize by trimming trailing whitespace/newlines to avoid SourceEditor auto-adjustments
        // from triggering a false "dirty" state immediately after load.
        let normalizedCurrent = currentContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSaved = savedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let dirty = (normalizedCurrent != normalizedSaved)
        
        if self.hasUnsavedChanges != dirty {
            print("[DEBUG] EditorController(\(ObjectIdentifier(self))): checkUnsavedChanges changing to \(dirty) (prev=\(self.hasUnsavedChanges))")
            self.hasUnsavedChanges = dirty
        }
    }
    
    // --- Undo/Redo Functions ---
    
    func undo() {
        // textView?.undoManager?.undo()
    }
    
    func redo() {
        // textView?.undoManager?.redo()
    }
    
    func cutSelection() {
        let range = selectedRange
        if range.length > 0, let r = Range(range, in: sourceCode) {
            let text = String(sourceCode[r])
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            insertText("", replacementRange: range)
        }
    }
    
    func copySelection() {
        let range = selectedRange
        if range.length > 0, let r = Range(range, in: sourceCode) {
            let text = String(sourceCode[r])
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
    
    func pasteSelection() {
        if let items = NSPasteboard.general.pasteboardItems?.first,
           let text = items.string(forType: .string) {
            insertText(text)
        }
    }
    
    func deleteSelection() {
        let range = selectedRange
        if range.length > 0 {
            insertText("", replacementRange: range)
        }
    }
    
    // --- Snippet Functions ---
    
    func insertTableSnippet() {
        let range = selectedRange
        setupTableEditor(at: range.location)
        self.showTableEditor = true
    }
    
    func openTableEditor(at range: NSRange) {
        setupTableEditor(at: range.location)
        self.showTableEditor = true
    }
    
    func textViewDidChangeSelection() {
        DispatchQueue.main.async {
            self.updateFormattingState()
        }
    }
    
    private func setupTableEditor(at location: Int) {
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
        if let tableInfo = TableDetector.parseTable(in: sourceCode, at: location) {
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
        
        let rangeToReplace = currentTableRange ?? selectedRange
        
        if rangeToReplace.location != NSNotFound {
            insertText(snippet, replacementRange: rangeToReplace)
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
        let range = selectedRange
        
        // Reset state
        self.pendingImagePath = ""
        self.imageWidth = "auto"
        self.imageHeight = "auto"
        self.imageAlt = ""
        self.imageFit = "contain"
        self.imageValidationError = nil
        self.selectedImageURL = nil
        self.currentImageRange = nil
        
        if let imageInfo = ImageDetector.parseImage(in: sourceCode, at: range.location) {
            setupImageEditor(with: imageInfo)
        }
        
        self.showImageEditor = true
    }
    
    func openImageEditor(at range: NSRange) {
        if let imageInfo = ImageDetector.parseImage(in: sourceCode, at: range.location) {
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
        
        if let range = currentImageRange {
             insertText(snippet, replacementRange: range)
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
        if let snippet = SnippetsManager.shared.snippets["chart"] {
            insertText(snippet.template)
        }
    }
    
    func insertTimelineSnippet() {
        if let snippet = SnippetsManager.shared.snippets["timeline"] {
            insertText(snippet.template)
        }
    }
    
    func openLayoutEditor() {
        self.showLayoutEditor = true
    }

    // --- Outline Functions ---
    
    func openOutlineEditor() {
        let range = selectedRange
        
        // Reset state
        self.currentOutlineRange = nil
        self.outlineTitle = ""
        self.outlineTarget = "Heading"
        self.outlineDepthString = ""
        self.outlineIndent = false
        
        if let info = OutlineDetector.parseOutline(in: sourceCode, at: range.location) {
            self.currentOutlineRange = info.range
            self.outlineTitle = info.title ?? ""
            self.outlineTarget = info.target ?? "Heading"
            if let depth = info.depth {
                self.outlineDepthString = "\(depth)"
            }
            self.outlineIndent = info.indent ?? false
        }
        
        self.showOutlineEditor = true
    }
    
    func insertOutline(title: String, target: String, depth: Int?, indent: Bool?) {
        var params: [String] = []
        
        if !title.isEmpty {
            params.append("title: [\(title)]")
        }
        
        switch target {
        case "Heading":
            // default is heading, no param needed usually, but can be explicit
            // params.append("target: heading")
            break
        case "Figure":
            params.append("target: figure")
        case "Image":
            params.append("target: image")
        case "Custom":
            // If custom, user might want to edit manually, or we add selector logic later
            break
        default:
            break
        }
        
        if let depth = depth, depth > 0 {
            params.append("depth: \(depth)")
        }
        
        if let indent = indent {
            params.append("indent: \(indent)")
        }
        
        let snippet = "#outline(\(params.joined(separator: ", ")))"
        
        let rangeToReplace = currentOutlineRange ?? selectedRange
        
        if rangeToReplace.location != NSNotFound {
            insertText(snippet, replacementRange: rangeToReplace)
        } else {
            insertText(snippet)
        }
        
        showOutlineEditor = false
        updateFormattingState()
    }
    
    // --- Figure Functions ---
    
    func openFigureEditor() {
         let range = selectedRange
         if range.length > 0 {
             if let r = Range(range, in: sourceCode) {
                 currentFigureContent = String(sourceCode[r])
             }
         } else {
             currentFigureContent = ""
         }
         self.showFigureEditor = true
    }
    
    func insertFigure(content: String, caption: String, label: String, kind: String?, supplement: String?) {
        var params: [String] = []
        
        params.append(ensureTypstContent(content))
        
        if !caption.isEmpty {
            params.append("caption: [\(caption)]")
        }
        
        if let kind = kind, !kind.isEmpty {
             params.append("kind: \(kind)")
        }
        
        if let supplement = supplement, !supplement.isEmpty {
            params.append("supplement: [\(supplement)]")
        }
        
        var snippet = "#figure(\(params.joined(separator: ", ")))"
        
        if !label.isEmpty {
            snippet += " <\(label)>"
        }
        
        let range = selectedRange
        if range.length > 0 {
             insertText(snippet, replacementRange: range)
        } else {
             insertText(snippet)
        }
        
        showFigureEditor = false
    }
    
    // --- External Data Functions ---
    
    func openExternalDataEditor() {
        self.showExternalDataEditor = true
    }
    
    func insertExternalData(filePath: String, type: String, variableName: String?) {
        // e.g. #let data = json("data.json")
        // type: json, csv, xml, yaml, toml
        // filePath: relative or absolute... we should try to make it relative if possible or just use what is given
        
        let pathStr: String
        // If we have a project root, try to make relative
        if let root = projectRootURL, let fileURL = URL(string: filePath) ?? URL(string: "file://" + filePath) {
             pathStr = relativePath(from: root, to: fileURL) ?? filePath
        } else {
             pathStr = filePath
        }
        
        let command = type.lowercased()
        let loadCmd = "\(command)(\"\(pathStr)\")"
        
        let snippet: String
        if let varName = variableName, !varName.isEmpty {
            snippet = "#let \(varName) = \(loadCmd)"
        } else {
            snippet = "#\(loadCmd)"
        }
        
        insertText(snippet)
        showExternalDataEditor = false
    }
    
    // --- List Functions ---
    
    func toggleBulletList() {
        toggleListPrefix("- ")
    }
    
    func toggleNumberList() {
        toggleListPrefix("+ ")
    }
    
    private func toggleListPrefix(_ prefix: String) {
        let range = selectedRange
        guard Range(range, in: sourceCode) != nil else { return }
        
        let nsText = sourceCode as NSString
        let lineRange = nsText.lineRange(for: range)
        let lineContent = nsText.substring(with: lineRange)
        
        // --- Case 1: Single line and empty ---
        let hadTrailingNewline = lineContent.hasSuffix("\n")
        let isSingleLineRepresentation = !lineContent.dropLast(hadTrailingNewline ? 1 : 0).contains("\n")
        
        if isSingleLineRepresentation && lineContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertText(prefix, replacementRange: lineRange)
            return
        }
        
        // --- Case 2: Multiline selection or non-empty line ---
        var lineStrings = lineContent.components(separatedBy: .newlines)
        if hadTrailingNewline { lineStrings.removeLast() }
        
        let otherPrefix = prefix == "- " ? "+ " : "- "
        let headingPattern = #"^(=+)\s"#
        guard let headingRegex = try? NSRegularExpression(pattern: headingPattern, options: []) else { return }
        
        struct LineInfo {
            let headingPrefix: String
            let contentAfterHeading: String
            let hasTargetPrefix: Bool
            let hasOtherPrefix: Bool
            let isBlank: Bool
        }
        
        var infos: [LineInfo] = []
        for line in lineStrings {
            let nsLine = line as NSString
            var headingPrefix = ""
            var remaining = line
            
            if let match = headingRegex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: nsLine.length)) {
                headingPrefix = nsLine.substring(with: match.range)
                remaining = nsLine.substring(from: match.range.length)
            }
            
            let isBlank = remaining.trimmingCharacters(in: .whitespaces).isEmpty
            infos.append(LineInfo(
                headingPrefix: headingPrefix,
                contentAfterHeading: remaining,
                hasTargetPrefix: remaining.hasPrefix(prefix),
                hasOtherPrefix: remaining.hasPrefix(otherPrefix),
                isBlank: isBlank
            ))
        }
        
        let nonBlankInfos = infos.filter { !$0.isBlank }
        if nonBlankInfos.isEmpty { return }
        
        let allHaveTarget = nonBlankInfos.allSatisfy { $0.hasTargetPrefix }
        
        var newLines: [String] = []
        for info in infos {
            if info.isBlank {
                newLines.append(info.headingPrefix + info.contentAfterHeading)
                continue
            }
            
            var newContent = info.contentAfterHeading
            if allHaveTarget {
                newContent = String(newContent.dropFirst(prefix.count))
            } else {
                if info.hasOtherPrefix {
                    newContent = prefix + String(newContent.dropFirst(otherPrefix.count))
                } else if !info.hasTargetPrefix {
                    newContent = prefix + newContent
                }
            }
            newLines.append(info.headingPrefix + newContent)
        }
        
        var replacement = newLines.joined(separator: "\n")
        if hadTrailingNewline { replacement += "\n" }
        
        insertText(replacement, replacementRange: lineRange)
    }

    
    // --- Search Functions ---
    
    // --- Search Functions ---
    
    func showFindPanel() {
        // Trigger the native find panel via editor state
        // CodeEditSourceEditor observes this state and shows/hides the panel
        
        // 1. Pre-populate find text from selection if not empty
        let selectedText = (sourceCode as NSString).substring(with: selectedRange)
        if !selectedText.isEmpty && !selectedText.contains("\n") {
             editorState.findText = selectedText
        }
        
        // 2. Show the panel
        editorState.findPanelVisible = true
        
        // 3. Force Focus & Layout Fix
        // We need to access the FindViewController to adjust constraints and focus the panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self,
                  let textViewController = self.textViewController else { return }
            
            // Access internal findViewController via Mirror
            let tvcMirror = Mirror(reflecting: textViewController)
            guard let findVCChild = tvcMirror.children.first(where: { $0.label == "findViewController" }),
                  let findVC = self.unwrap(findVCChild.value) as? NSViewController else { return }
            
            let containerView = findVC.view
            
            // Find the panel (z=1000)
            guard let findPanel = containerView.subviews.first(where: { $0.layer?.zPosition == 1000 }) else { return }
            
            // Find the editor view (childView). It's likely textViewController.view, but let's be safe
            // In FindViewController, childView is added. It should be the other subview.
            guard let editorView = containerView.subviews.first(where: { $0 != findPanel }) else { return }
            
            // Force focus
            containerView.window?.makeFirstResponder(findPanel)
            
            // 4. Layout: Shift Editor Below Find Panel
            // Remove existing top constraint on editorView
            let topConstraints = containerView.constraints.filter { constraint in
                return (constraint.firstItem === editorView && constraint.firstAttribute == .top) ||
                       (constraint.secondItem === editorView && constraint.secondAttribute == .top)
            }
            
            if !topConstraints.isEmpty {
                containerView.removeConstraints(topConstraints)
            }
            
            // Add new constraint: editorView.top == findPanel.bottom
            let newConstraint = editorView.topAnchor.constraint(equalTo: findPanel.bottomAnchor)
            newConstraint.isActive = true
            
            // 5. Setup Observers for Scrolling
            self.setupFindPanelObservers()
        }
    }
    
    private var findPanelCancellables: Set<AnyCancellable> = []
    
    private func setupFindPanelObservers() {
        findPanelCancellables.removeAll()
        
        // Use Mirror to access internal properties to avoid build errors.
        guard let textViewController = textViewController else { return }
        
        let tvcMirror = Mirror(reflecting: textViewController)
        guard let findVCChild = tvcMirror.children.first(where: { $0.label == "findViewController" }) else { return }
        
        // Unwrap the Optional<FindViewController>
        guard let findVC = unwrap(findVCChild.value) else { return }
        
        // Get ViewModel from FindViewController
        let vcMirror = Mirror(reflecting: findVC)
        guard let vmChild = vcMirror.children.first(where: { $0.label == "viewModel" }) else { return }
        guard let viewModel = unwrap(vmChild.value) else { return }
        
        // Observe objectWillChange (type erased) to detect updates.
        // We cannot observe Published properties via Mirror because we get a copy of the struct.
        guard let observableParams = viewModel as? any ObservableObject else { return }
        
        // Define a generic helper to "open" the existential and access objectWillChange
        func observe<T: ObservableObject>(_ vm: T) {
            vm.objectWillChange
                .eraseToAnyPublisher() // Erase type to avoid associated type complexity
                .receive(on: DispatchQueue.main)
                // Delay slightly to let the change propagate
                .delay(for: .milliseconds(10), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    
                    // Read current values via Mirror
                    let vmMirror = Mirror(reflecting: vm) // reflect on vm directly
                    
                    var currentIndex: Int? = nil
                    var currentMatches: [NSRange] = []
                    
                    // Helper to extract value
                    func extractValue<V>(_ name: String, type: V.Type) -> V? {
                        let child = vmMirror.children.first(where: { $0.label == name || $0.label == "_\(name)" })
                        
                        if let val = child?.value as? V {
                            return val
                        }
                        
                        // If it's a Published struct wrapper
                        if let published = child?.value {
                            let pMirror = Mirror(reflecting: published)
                            if let val = pMirror.children.first(where: { $0.label == "value" || $0.label == "wrappedValue" })?.value as? V {
                                 return val
                            }
                        }
                        return nil
                    }
                    
                    currentIndex = extractValue("currentFindMatchIndex", type: Int?.self) ?? nil
                    currentMatches = extractValue("findMatches", type: [NSRange].self) ?? []

                    // React to changes
                    guard let index = currentIndex,
                          index >= 0,
                          index < currentMatches.count else { return }
                    
                    let matchRange = currentMatches[index]
                    
                    // Update cursor without auto-scroll
                    self.textViewController?.setCursorPositions([.init(range: matchRange)], scrollToVisible: false)
                    
                    // Explicitly scroll using the robust method
                    self.textViewController?.textView.scrollToRange(matchRange, center: true)
                    self.textViewController?.textView.selectionManager.setSelectedRanges([matchRange])
                }
                .store(in: &findPanelCancellables)
        }
        
        // Call the generic helper
        observe(observableParams)
    }
    
    /// Helper to unwrap optional values inside Any
    private func unwrap(_ any: Any) -> Any? {
        let mirror = Mirror(reflecting: any)
        if mirror.displayStyle != .optional {
            return any
        }
        
        if mirror.children.count == 0 { return nil }
        return mirror.children.first!.value
    }
    
    // --- Commandes d'édition de texte ---
    
    // Insère du texte à la position du curseur
    // Legacy insertText removed (redundant)
    
    // Entoure la sélection actuelle avec un préfixe et un suffixe
    func wrapSelection(prefix: String, suffix: String) {
        let range = selectedRange
        print("[EditorController] wrapSelection prefix='\(prefix)' suffix='\(suffix)' at \(range)")
        
        if range.length == 0 {
            // Insert markers and place cursor in between
            let newCursor = NSRange(location: range.location + prefix.count, length: 0)
            insertText(prefix + suffix, replacementRange: range, newCursorRange: newCursor)
        } else {
            // Surround selection
             if let r = Range(range, in: sourceCode) {
                 let selectedText = sourceCode[r]
                 let newText = prefix + selectedText + suffix
                 insertText(newText, replacementRange: range)
             }
        }
    }
    
    func updateFormattingState() {
        let range = selectedRange
        let text = sourceCode
        
        // Use async to avoid "Publishing changes from within view updates is not allowed"
        DispatchQueue.main.async {
            // Debug Log
            print("[EditorController] updateFormattingState at \(range), textLen: \(text.count)")
            
            self.isBoldActive = FormatDetector.findBoldRange(in: text, at: range.location) != nil
            self.isItalicActive = FormatDetector.findItalicRange(in: text, at: range.location) != nil
            self.isUnderlineActive = FormatDetector.findUnderlineRange(in: text, at: range.location) != nil
            self.isHighlightActive = FormatDetector.findHighlightRange(in: text, at: range.location) != nil
            self.isStrikeActive = FormatDetector.findStrikeRange(in: text, at: range.location) != nil
            self.isCodeActive = FormatDetector.findCodeRange(in: text, at: range.location) != nil
            self.isLinkActive = FormatDetector.findLinkRange(in: text, at: range.location) != nil
            self.isQuoteActive = FormatDetector.findQuoteRange(in: text, at: range.location) != nil
            self.isCodeBlockActive = FormatDetector.findCodeBlockRange(in: text, at: range.location) != nil
            self.isSubscriptActive = FormatDetector.findSubscriptRange(in: text, at: range.location) != nil
            self.isSuperscriptActive = FormatDetector.findSuperscriptRange(in: text, at: range.location) != nil
            
            self.currentHeadingLevel = FormatDetector.detectHeadingLevel(in: text, at: range.location)
            
            self.isEquationActive = EquationDetector.findEquationRange(in: text, at: range.location) != nil
            self.isTableActive = TableDetector.findTableRange(in: text, at: range.location) != nil
            self.isImageActive = ImageDetector.findImageRange(in: text, at: range.location) != nil
            self.isBibliographyActive = BibliographyDetector.findBibliographyRange(in: text, at: range.location) != nil
            self.isOutlineActive = OutlineDetector.findOutlineRange(in: text, at: range.location) != nil
            
            self.isBulletListActive = FormatDetector.isBulletListActive(in: text, at: range.location)
            self.isNumberListActive = FormatDetector.isNumberListActive(in: text, at: range.location)
            self.isFootnoteActive = FormatDetector.findFootnoteRange(in: text, at: range.location) != nil
            self.isPageBreakActive = FormatDetector.findPageBreakRange(in: text, at: range.location) != nil
            self.isHorizontalLineActive = FormatDetector.findHorizontalLineRange(in: text, at: range.location) != nil
        }
    }
    
    // --- Footnote Editor Functions ---
    
    func openFootnoteEditor() {
        let range = selectedRange
        
        // Reset state
        self.footnoteBody = ""
        self.footnoteNumbering = "1"
        self.currentFootnoteRange = nil
        
        if let info = FormatDetector.parseFootnote(in: sourceCode, at: range.location) {
            self.currentFootnoteRange = info.range
            self.footnoteBody = info.body
            self.footnoteNumbering = info.numbering ?? "1"
        }
        
        self.showFootnoteEditor = true
    }
    
    func insertFootnote(body: String, numbering: String? = nil) {
        var params: [String] = []
        if let numbering = numbering, !numbering.isEmpty, numbering != "1" {
            params.append("numbering: \"\(numbering)\"")
        }
        
        let paramPart = params.isEmpty ? "" : "(\(params.joined(separator: ", ")))"
        let snippet = "#footnote\(paramPart)[\(body)]"
        
        let rangeToReplace = currentFootnoteRange ?? selectedRange
        
        if rangeToReplace.location != NSNotFound {
            insertText(snippet, replacementRange: rangeToReplace)
        } else {
            insertText(snippet)
        }
        
        showFootnoteEditor = false
        updateFormattingState()
    }
    
    // --- Heading Actions ---
    
    func setHeadingLevel(_ level: Int) {
        let range = selectedRange
        let nsText = sourceCode as NSString
        let lineRange = nsText.lineRange(for: range)
        let lineContent = nsText.substring(with: lineRange)
        
        let hadTrailingNewline = lineContent.hasSuffix("\n")
        let isSingleLineRepresentation = (lineRange.length > 0)
        
        // --- Special Case: Single empty line ---
        if isSingleLineRepresentation && lineContent.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            if level > 0 {
                let prefix = String(repeating: "=", count: level) + " "
                insertText(prefix + "\n", replacementRange: lineRange)
            } else {
                // Remove heading (it was empty anyway, but ensure clean state)
                insertText("\n", replacementRange: lineRange)
            }
            updateFormattingState()
            return
        }
        
        // --- Multiline selection or non-empty line ---
        var lines = lineContent.components(separatedBy: CharacterSet.newlines)
        if hadTrailingNewline { lines.removeLast() }
        
        let headingPattern = #"^(=+)\s"#
        guard let regex = try? NSRegularExpression(pattern: headingPattern, options: []) else { return }
        
        var newLines: [String] = []
        
        // Check if we need to remove existing heading markers from ALL lines (if toggle off or changing level)
        // For simplicity: We strip any leading "= " from all lines, then add new level if > 0
        
        for line in lines {
            // Skip purely blank lines within a selection
            if line.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty {
                newLines.append(line)
                continue
            }
            
            var content = line
            // Remove existing prefix if any
            if let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)) {
                content = String(line.dropFirst(match.range.length))
            }
            
            if level > 0 {
                let prefix = String(repeating: "=", count: level) + " "
                newLines.append(prefix + content)
            } else {
                newLines.append(content)
            }
        }
        
        var replacement = newLines.joined(separator: "\n")
        if hadTrailingNewline { replacement += "\n" }
        
        insertText(replacement, replacementRange: lineRange)
        updateFormattingState()
    }
    
    // --- Formatting Actions ---
    
    func toggleBold() {
        let range = selectedRange
        if let boldRange = FormatDetector.findBoldRange(in: sourceCode, at: range.location) {
            unwrapFormatting(range: boldRange, prefixLen: 1, suffixLen: 1)
            showStatus("Removed Bold")
        } else {
            wrapSelection(prefix: "*", suffix: "*")
            showStatus("Applied Bold")
        }
        updateFormattingState()
    }
    
    func toggleItalic() {
        let range = selectedRange
        if let italicRange = FormatDetector.findItalicRange(in: sourceCode, at: range.location) {
            unwrapFormatting(range: italicRange, prefixLen: 1, suffixLen: 1)
            showStatus("Removed Italic")
        } else {
            wrapSelection(prefix: "_", suffix: "_")
            showStatus("Applied Italic")
        }
        updateFormattingState()
    }
    
    func toggleUnderline() {
        let range = selectedRange
        if let underlineRange = FormatDetector.findUnderlineRange(in: sourceCode, at: range.location) {
            unwrapBracketedFormatting(range: underlineRange, prefixPattern: #"^#underline\s*[\[\(]"#)
        } else {
            wrapSelection(prefix: "#underline[", suffix: "]")
        }
        updateFormattingState()
    }
    
    func toggleHighlight() {
        let range = selectedRange
        if let highlightRange = FormatDetector.findHighlightRange(in: sourceCode, at: range.location) {
            unwrapBracketedFormatting(range: highlightRange, prefixPattern: #"^#highlight\s*[\[\(]"#)
        } else {
            wrapSelection(prefix: "#highlight[", suffix: "]")
        }
        updateFormattingState()
    }
    
    func toggleStrike() {
        let range = selectedRange
        if let strikeRange = FormatDetector.findStrikeRange(in: sourceCode, at: range.location) {
            unwrapBracketedFormatting(range: strikeRange, prefixPattern: #"^#strike\s*[\[\(]"#)
        } else {
            wrapSelection(prefix: "#strike[", suffix: "]")
        }
        updateFormattingState()
    }
    
    func toggleSubscript() {
        let range = selectedRange
        if let subRange = FormatDetector.findSubscriptRange(in: sourceCode, at: range.location) {
            unwrapBracketedFormatting(range: subRange, prefixPattern: #"^#sub\s*[\[\(]"#)
        } else {
            wrapSelection(prefix: "#sub[", suffix: "]")
        }
        updateFormattingState()
    }
    
    func toggleSuperscript() {
        let range = selectedRange
        if let supRange = FormatDetector.findSuperscriptRange(in: sourceCode, at: range.location) {
            unwrapBracketedFormatting(range: supRange, prefixPattern: #"^#super\s*[\[\(]"#)
        } else {
            wrapSelection(prefix: "#super[", suffix: "]")
        }
        updateFormattingState()
    }
    
    private func unwrapBracketedFormatting(range: NSRange, prefixPattern: String) {
        let text = sourceCode as NSString
        let snippet = text.substring(with: range)
        
        if let openerRange = snippet.range(of: prefixPattern, options: String.CompareOptions.regularExpression) {
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
        let nsText = sourceCode as NSString
        let fullSnippet = nsText.substring(with: range)
        
        let contentStart = fullSnippet.index(fullSnippet.startIndex, offsetBy: prefixLen)
        let contentEnd = fullSnippet.index(fullSnippet.endIndex, offsetBy: -suffixLen)
        let innerContent = String(fullSnippet[contentStart..<contentEnd])
        
        insertText(innerContent, replacementRange: range)
    }
    
    func toggleCode() {
        if isCodeActive {
            showDeleteCodeAlert = true
        } else {
            wrapSelection(prefix: "`", suffix: "`")
        }
    }
    
    func deleteCodeBlock() {
        let range = selectedRange
        if let codeRange = FormatDetector.findCodeRange(in: sourceCode, at: range.location) {
             insertText("", replacementRange: codeRange)
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
        let range = selectedRange
        if let equationRange = EquationDetector.findEquationRange(in: sourceCode, at: range.location) {
             insertText("", replacementRange: equationRange)
             updateFormattingState()
        }
    }
    
    // --- Commenting Actions ---
    
    func toggleLineComment() {
        let nsString = sourceCode as NSString
        let range = selectedRange
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
        insertText(replacement, replacementRange: lineRange)
    }
    
    func toggleBlockComment() {
        let range = selectedRange
        let nsString = sourceCode as NSString
        let selectedText = nsString.substring(with: range)
        
        if selectedText.hasPrefix("/*") && selectedText.hasSuffix("*/") {
            let inner = String(selectedText.dropFirst(2).dropLast(2))
            insertText(inner, replacementRange: range)
        } else {
            insertText("/* \(selectedText) */", replacementRange: range)
        }
    }
    
    func toggleQuote() {
        let range = selectedRange
        
        // Reset state
        currentQuoteRange = nil
        currentQuoteContent = ""
        currentQuoteAttribution = ""
        isQuoteBlock = true
        
        // If cursor is inside a quote, parse it
        if let quoteInfo = FormatDetector.parseQuote(in: sourceCode, at: range.location) {
            currentQuoteRange = quoteInfo.range
            currentQuoteContent = quoteInfo.content
            currentQuoteAttribution = quoteInfo.attribution
            isQuoteBlock = quoteInfo.isBlock
        } else if range.length > 0 {
            // If text is selected but not a quote, use it as initial content
            let nsString = sourceCode as NSString
            currentQuoteContent = nsString.substring(with: range)
        }
        
        showQuoteEditor = true
    }
    
    func insertQuote(text: String, attribution: String, isBlock: Bool) {
        var params: [String] = []
        if isBlock { params.append("block: true") }
        if !attribution.isEmpty { params.append("attribution: \"\(attribution)\"") }
        
        let paramStr = params.isEmpty ? "" : "(\(params.joined(separator: ", ")))"
        let snippet = "#quote\(paramStr)[\(text)]"
        
        let rangeToReplace = currentQuoteRange ?? selectedRange
        insertText(snippet, replacementRange: rangeToReplace)
        showQuoteEditor = false
    }
    
    func toggleCodeBlock() {
        // Simple wrap for now
        wrapSelection(prefix: "```\n", suffix: "\n```")
    }
    
    func insertPageBreak() {
        let range = selectedRange
        if let existingRange = FormatDetector.findPageBreakRange(in: sourceCode, at: range.location) {
            insertText("", replacementRange: existingRange)
        } else {
            insertText("#pagebreak()\n", replacementRange: range)
        }
        updateFormattingState()
    }
    
    func insertHorizontalLine() {
        let range = selectedRange
        if let existingRange = FormatDetector.findHorizontalLineRange(in: sourceCode, at: range.location) {
            insertText("", replacementRange: existingRange)
        } else {
            insertText("#line(length: 100%)\n", replacementRange: range)
        }
        updateFormattingState()
    }
    
    func insertFootnote() {
        wrapSelection(prefix: "#footnote[", suffix: "]")
    }
    
    func toggleBibliography() {
        let range = selectedRange
        
        // Reset state
        currentBibliographyRange = nil
        bibSources = ""
        bibTitle = ""
        bibFull = false
        bibStyle = "apa"
        
        if let info = BibliographyDetector.parseBibliography(in: sourceCode, at: range.location) {
            currentBibliographyRange = info.range
            bibSources = info.sources
            bibTitle = info.title ?? ""
            bibFull = info.full
            bibStyle = info.style ?? "apa"
        }
        
        showBibliographyEditor = true
    }
    
    func insertBibliography(sources: String, title: String, full: Bool, style: String) {
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
        
        let rangeToReplace = currentBibliographyRange ?? selectedRange
        insertText(snippet, replacementRange: rangeToReplace)
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
        // Select entire text
        let fullRange = NSRange(location: 0, length: sourceCode.count)
        editorState.cursorPositions = [.init(range: fullRange)]
        // Ensure UI update
        DispatchQueue.main.async {
             self.textViewController?.setCursorPositions([.init(range: fullRange)], scrollToVisible: false)
        }
    }
    
    // Opens the visual equation editor for a new equation at the cursor
    func openNewEquationEditor() {
        let range = selectedRange
        
        // Priority: Check if cursor or selection is inside an existing equation
        if let equationRange = EquationDetector.findEquationRange(in: sourceCode, at: range.location) {
            let fullText = sourceCode as NSString
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
             let selectedText = (sourceCode as NSString).substring(with: range)
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
        let text = sourceCode as NSString
        var currentLine = 1
        var charIndex = 0
        
        while currentLine < lineNumber && charIndex < text.length {
            if text.character(at: charIndex) == 10 { // newline
                currentLine += 1
            }
            charIndex += 1
        }
        
        self.selectedRange = NSRange(location: charIndex, length: 0)
        
        // Explicitly scroll to the new position
        DispatchQueue.main.async {
            let newPos = CursorPosition(range: NSRange(location: charIndex, length: 0))
            self.textViewController?.setCursorPositions([newPos], scrollToVisible: true)
        }
    }
    
    func toggleLink() {
        let range = selectedRange
        let text = sourceCode
        let nsText = text as NSString
        
        if let linkRange = FormatDetector.findLinkRange(in: text, at: range.location) {
            // Edit existing
            self.currentLinkRange = linkRange
            let linkSnippet = nsText.substring(with: linkRange)
            
            // Basic parsing of #link("url")[text]
            if let urlRange = linkSnippet.range(of: "(?<=\"|')[^\"']+(?=\"|')", options: String.CompareOptions.regularExpression) {
                self.currentLinkURL = String(linkSnippet[urlRange])
            } else {
                self.currentLinkURL = ""
            }
            
            if let textRange = linkSnippet.range(of: "(?<=\\[)[^\\]]+(?=\\])", options: String.CompareOptions.regularExpression) {
                self.currentLinkText = String(linkSnippet[textRange])
            } else {
                self.currentLinkText = ""
            }
        } else {
            // New link
            self.currentLinkRange = nil
            self.currentLinkURL = ""
            if range.length > 0 {
                self.currentLinkText = nsText.substring(with: range)
            } else {
                self.currentLinkText = ""
            }
        }
        
        self.showLinkEditor = true
    }
    
    func insertLink(url: String, text: String) {
        var snippet = ""
        if text.isEmpty {
            snippet = "#link(\"\(url)\")"
        } else {
            snippet = "#link(\"\(url)\")[\(text)]"
        }
        
        let rangeToReplace = currentLinkRange ?? selectedRange
        insertText(snippet, replacementRange: rangeToReplace)
        
        showLinkEditor = false
        updateFormattingState()
    }
    
    // --- Context-Aware Editor ---
    
    /// Opens the appropriate editor based on what's at the cursor position
    func openContextualEditor() {
        let range = selectedRange
        let text = sourceCode
        
        // Check in order of priority:
        // 1. Equation
        if EquationDetector.findEquationRange(in: text, at: range.location) != nil {
            openNewEquationEditor()
            return
        }
        
        // 2. Image
        if ImageDetector.findImageRange(in: text, at: range.location) != nil {
            if let imageInfo = ImageDetector.parseImage(in: text, at: range.location) {
                currentImageRange = imageInfo.range
                pendingImagePath = imageInfo.path
                imageWidth = imageInfo.width ?? "auto"
                imageHeight = imageInfo.height ?? "auto"
                imageAlt = imageInfo.alt ?? ""
                imageFit = imageInfo.fit ?? "contain"
                showImageEditor = true
            }
            return
        }
        
        // 3. Table
        if TableDetector.findTableRange(in: text, at: range.location) != nil {
            openTableEditor(at: range)
            return
        }
        
        // 4. Link
        if FormatDetector.findLinkRange(in: text, at: range.location) != nil {
            toggleLink()
            return
        }
        
        // 5. Bibliography
        if BibliographyDetector.findBibliographyRange(in: text, at: range.location) != nil {
            toggleBibliography()
            return
        }
        
        // 6. Outline
        if OutlineDetector.findOutlineRange(in: text, at: range.location) != nil {
            openOutlineEditor()
            return
        }
        
        // 7. Footnote
        if FormatDetector.findFootnoteRange(in: text, at: range.location) != nil {
            openFootnoteEditor()
            return
        }
        
        // If nothing is detected, show status message
        showStatus("No editable element at cursor")
    }
    
    /// Shows a temporary status message to the user
    func showStatus(_ message: String, duration: TimeInterval = 2.0) {
        statusMessage = message
        showStatusMessage = true
        
        // Auto-hide after duration (slightly longer for success messages)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            // Only hide if the message hasn't been changed in the meantime
            if self.statusMessage == message {
                self.showStatusMessage = false
            }
        }
    }
    
    @MainActor
    private func setupScrollNotification() {
        // Scroll notification is handled differently with CodeEditSourceEditor or not needed in the same way.
        // For now, we stub it.
    }
}

/// A bridge between the EditorController and the SourceEditor's underlying TextViewController.
/// This allows for programmatic text updates which are not supported by the SourceEditor binding directly.
@MainActor
class SourceEditorBridge: TextViewCoordinator {
    weak var controller: EditorController?
    
    init(controller: EditorController) {
        self.controller = controller
    }
    
    nonisolated func prepareCoordinator(controller: TextViewController) {
        let ptr = ObjectIdentifier(controller)
        print("[SourceEditorBridge] prepareCoordinator for \(ptr)")
        MainActor.assumeIsolated {
            self.controller?.textViewController = controller
        }
    }
    
    nonisolated func destroy() {
        print("[SourceEditorBridge] destroy")
        // NOTE: We don't set self.controller?.textViewController = nil here
        // because SwiftUI may destroy the old coordinator AFTER creating the new one
        // when switching files, causing a race condition where the new valid ref is cleared.
    }
    
    nonisolated func textViewDidChangeText(controller: TextViewController) {
        // Sync back to EditorController if needed (usually handled by binding, but as a backup)
        // Guard against infinite loops if we are already in an update
        MainActor.assumeIsolated {
            if self.controller?.sourceCode != controller.text {
                 self.controller?.sourceCode = controller.text
            }
        }
    }
}