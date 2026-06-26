import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let refreshProjectSidebar = Notification.Name("refreshProjectSidebar")
    static let openProjectAndFile = Notification.Name("openProjectAndFile")
    static let openStandaloneFile = Notification.Name("openStandaloneFile")
    static let openProjectFolder = Notification.Name("openProjectFolder")
}

import CodeEditSourceEditor
import CodeEditTextView
import Combine

@MainActor
class EditorController: NSObject, ObservableObject {
    enum SupportedFileType {
        case typst
        case text
        case markdown
        case image
        case pdf
        case other
        
        var isTextual: Bool {
            switch self {
            case .typst, .text, .markdown: return true
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
    @Published var isFigureActive: Bool = false
    @Published var currentFigureRange: NSRange?
    @Published var currentFigureContent: String = ""
    @Published var currentFigureCaption: String = ""
    @Published var currentFigureLabel: String = ""
    @Published var currentFigureKind: String = ""
    @Published var currentFigureSupplement: String = ""
    
    // --- Block Editor State ---
    @Published var isBlockActive: Bool = false
    @Published var showBlockEditor: Bool = false
    @Published var currentBlockRange: NSRange?
    @Published var blockFill: String = ""
    @Published var blockInset: String = ""
    @Published var blockRadius: String = ""
    @Published var blockWidth: String = ""
    @Published var blockStroke: String = ""
    @Published var blockContent: String = ""

    // --- Grid Editor State ---
    @Published var isGridActive: Bool = false
    @Published var showGridEditor: Bool = false
    @Published var currentGridRange: NSRange?
    @Published var gridColumns: String = ""
    @Published var gridGutter: String = ""
    @Published var gridCells: [String] = []

    // --- External Data Editor State ---
    @Published var showExternalDataEditor: Bool = false
    
    // --- AI Prompt Editor State ---
    @Published var showAIPromptEditor: Bool = false
    @Published var aiPromptText: String = ""
    @Published var isAIGenerating: Bool = false
    @Published var useMCPForPrompt: Bool = true
    
    // MARK: - New Features (Symbol Picker & Word Count)
    @Published var showSymbolPicker: Bool = false
    @Published var wordCount: Int = 0
    
    // --- Print / Share Support ---
    @Published var cleanPDFURL: URL? = nil
    
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


    private var scrollMonitor: Any?
    private var findPanelClickMonitor: Any?
    private var findPanelCloseTask: Task<Void, Never>?
    private var pasteMonitor: Any?

    override init() {
        super.init()
        self.sourceEditorBridge = SourceEditorBridge(controller: self)
        setupDefaultConfiguration()
        setupErrorSubscription()
        
        // Listen for Ctrl+Scroll or Cmd+Scroll to zoom
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self else { return event }
            
            // Check if Control or Command is held down
            if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command) {
                // Trackpads provide precise scrolling deltas, mice provide standard deltas
                let delta = event.hasPreciseScrollingDeltas ? (event.scrollingDeltaY * 0.01) : (event.deltaY * 0.1)
                
                // Adjust the zoom smoothly
                self.adjustZoom(by: delta)
                
                return nil // Consume the event so the page doesn't scroll
            }
            return event
        }
        // Listen for Cmd+V to paste as plain text
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            
            // Check if the keystroke is Cmd+V
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "v" {
                
                // ONLY intercept if the code editor is actively focused
                // (We don't want to hijack pastes in the Find panel or Rename alerts)
                if let textView = self.textViewController?.textView,
                   NSApp.keyWindow?.firstResponder == textView {
                    
                    self.pasteSelection()
                    return nil // Consume the event so macOS doesn't double-paste
                }
            }
            return event
        }
    }
    
    func setupDefaultConfiguration() {
        let baseFontSize: CGFloat = 13.0
        let scaledFontSize = baseFontSize * zoomLevel
        
        let newFont = NSFont(name: "Menlo", size: scaledFontSize) ?? .monospacedSystemFont(ofSize: scaledFontSize, weight: .regular)
        
        self.editorConfiguration = SourceEditorConfiguration(
            appearance: .init(
                theme: customTheme,
                font: newFont,
                wrapLines: wrapLines,
                tabWidth: 2
            )
        )
        
        // Force the underlying native text view to accept the new font immediately
        if let tvc = textViewController {
            tvc.textView.font = newFont
            tvc.textView.layoutManager.setNeedsLayout()
            tvc.textView.needsDisplay = true
        }
        
        updateTextViewWrapping()
    }
    
    func updateTextViewWrapping() {
        guard let tvc = textViewController,
              let textView = tvc.textView,
              let scrollView = tvc.scrollView else { return }
        
        textView.translatesAutoresizingMaskIntoConstraints = true
        textView.wrapLines = wrapLines
        
        if wrapLines {
            textView.autoresizingMask = [.width, .height]
            scrollView.hasHorizontalScroller = false
        } else {
            textView.autoresizingMask = [.height]
            
            scrollView.hasHorizontalScroller = true
            scrollView.horizontalScroller?.isHidden = false
            scrollView.autohidesScrollers = false
            scrollView.hasVerticalScroller = true
            
            // Force the layout manager to recalculate visible lines with infinite width
            textView.layoutManager.setNeedsLayout()
            textView.layoutManager.layoutLines()
            
            textView.needsLayout = true
            textView.updateFrameIfNeeded()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                textView.translatesAutoresizingMaskIntoConstraints = true
                textView.layoutManager.layoutLines()
                textView.updateFrameIfNeeded()
                scrollView.hasHorizontalScroller = true
                scrollView.horizontalScroller?.isHidden = false
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
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
    lazy var aiCompletionProvider = AICompletionProvider(controller: self)
    
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
    @Published var isTextColorActive: Bool = false
    @Published var isStrikeActive: Bool = false
    @Published var isSubscriptActive: Bool = false
    @Published var isSuperscriptActive: Bool = false
    @Published var isQuoteActive: Bool = false
    @Published var isCodeBlockActive: Bool = false
    @Published var isTitleActive: Bool = false
    @Published var currentHeadingLevel: Int = 0
    @Published var isEquationActive: Bool = false
    @Published var isTableActive: Bool = false
    @Published var isImageActive: Bool = false
    @Published var isBibliographyActive: Bool = false
    @Published var isOutlineActive: Bool = false
    @Published var isCodeActive: Bool = false
    @Published var isScopedBlockActive: Bool = false
    @Published var showDeleteEquationAlert: Bool = false
    @Published var showDeleteCodeAlert: Bool = false
    @Published var showGoToLineAlert: Bool = false
    @Published var showExportErrorAlert: Bool = false
    @Published var showHelp: Bool = false
    @Published var showFileNotFoundAlert: Bool = false
    @Published var lastExportError: String = ""
    @Published var missingFileName: String = ""
    @Published var targetLineNumber: String = ""
    @Published var showFoundationEditor: Bool = false
    @Published var showPackageManager: Bool = false
    
    // --- Status Message ---
    @Published var statusMessage: String = ""
    @Published var showStatusMessage: Bool = false
    
    @Published var zoomLevel: CGFloat = 1.0 {
        didSet {
            if zoomLevel != oldValue {
                setupDefaultConfiguration()
            }
        }
    }
    @Published var isSidebarVisible: Bool = true
    @Published var wrapLines: Bool = true {
        didSet {
            setupDefaultConfiguration()
        }
    }
    @Published var isBulletListActive: Bool = false
    @Published var isNumberListActive: Bool = false
    @Published var isDescriptionListActive: Bool = false
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
    @Published var sourceCode: String = "" {
        didSet {
            if sourceCode != oldValue {
                cleanPDFURL = nil
            }
        }
    }
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
    @Published var editorConfiguration: SourceEditorConfiguration!
    
    // Locate the _customTheme variable around line 155
    private var _customTheme: EditorTheme?
    private var _customThemeIsDark: Bool?
    
    var customTheme: EditorTheme {
        let appThemeString = UserDefaults.standard.string(forKey: "appTheme") ?? "System"
        let isDark: Bool
        switch appThemeString {
        case "Light": isDark = false
        case "Dark": isDark = true
        default: isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        
        // Return cached theme if the color scheme hasn't changed
        if let theme = _customTheme, _customThemeIsDark == isDark { return theme }
        
        func safeColor(_ color: NSColor) -> NSColor { return color.usingColorSpace(.sRGB) ?? color }
        func attr(_ color: NSColor, bold: Bool = false, italic: Bool = false) -> EditorTheme.Attribute {
            return EditorTheme.Attribute(color: safeColor(color), bold: bold, italic: italic)
        }
        
        let bg = isDark ? NSColor(red: 40/255, green: 44/255, blue: 52/255, alpha: 1.0) : NSColor.white
        let fg = isDark ? NSColor(red: 171/255, green: 178/255, blue: 191/255, alpha: 1.0) : NSColor.black

        let green = isDark ? NSColor(red: 152/255, green: 195/255, blue: 121/255, alpha: 1.0) : NSColor(red: 24/255, green: 112/255, blue: 51/255, alpha: 1.0)
        let yellow = isDark ? NSColor(red: 229/255, green: 192/255, blue: 123/255, alpha: 1.0) : NSColor(red: 136/255, green: 90/255, blue: 10/255, alpha: 1.0)
        let blue = isDark ? NSColor(red: 97/255, green: 175/255, blue: 239/255, alpha: 1.0) : NSColor(red: 9/255, green: 80/255, blue: 208/255, alpha: 1.0)
        let purple = isDark ? NSColor(red: 198/255, green: 120/255, blue: 221/255, alpha: 1.0) : NSColor(red: 130/255, green: 40/255, blue: 180/255, alpha: 1.0)
        let teal = isDark ? NSColor(red: 86/255, green: 182/255, blue: 194/255, alpha: 1.0) : NSColor(red: 20/255, green: 120/255, blue: 130/255, alpha: 1.0)
        let orange = isDark ? NSColor(red: 209/255, green: 154/255, blue: 102/255, alpha: 1.0) : NSColor(red: 180/255, green: 90/255, blue: 30/255, alpha: 1.0)
        let gray = isDark ? NSColor(red: 92/255, green: 99/255, blue: 112/255, alpha: 1.0) : NSColor(red: 120/255, green: 120/255, blue: 130/255, alpha: 1.0)
        
        let insertionPoint: NSColor
        if #available(macOS 14.0, *) {
            insertionPoint = safeColor(NSColor.textInsertionPointColor)
        } else {
            insertionPoint = fg
        }
        
        let isMarkdown = isMarkdownFile
        
        let theme = EditorTheme(
            text: attr(fg),
            insertionPoint: insertionPoint,
            invisibles: attr(gray.withAlphaComponent(0.5)),
            background: safeColor(bg),
            lineHighlight: safeColor(isDark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.05)),
            selection: safeColor(NSColor.selectedTextBackgroundColor).withAlphaComponent(0.4),
            keywords: attr(isMarkdown ? blue : purple, bold: true),
            commands: attr(isMarkdown ? teal : purple),
            types: attr(isMarkdown ? orange : blue, bold: true),
            attributes: attr(isMarkdown ? green : purple, italic: true),
            variables: attr(isMarkdown ? yellow : purple),
            values: attr(teal),
            numbers: attr(yellow),
            strings: attr(green),
            characters: attr(green),
            comments: attr(gray, italic: true),
            markupHeading: attr(blue, bold: true),
            markupBold: attr(fg, bold: true),
            markupItalic: attr(fg, italic: true),
            markupStrikethrough: attr(gray),
            markupList: attr(orange),
            markupQuote: attr(green, italic: true),
            markupLink: attr(teal)
        )
        _customTheme = theme
        _customThemeIsDark = isDark
        return theme
    }

    func applyTheme() {
        // Clear the cache to force a recalculation
        _customTheme = nil 
        _customThemeIsDark = nil
        
        // Regenerate the editor configuration to push the new theme to the source editor
        self.setupDefaultConfiguration()
    }
    var currentImageRange: NSRange? = nil
    
    @Published var currentFileType: SupportedFileType = .typst
    
   private func updateFileType() {
        guard let url = currentFileURL else {
            currentFileType = .typst // Default for new unsaved files
            applyTheme()
            return
        }
        
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "typ":
            currentFileType = .typst
        case "txt", "json", "yml", "yaml", "toml", "css", "js", "ts", "html", "bib", "svg":
            currentFileType = .text
        case "md":
            currentFileType = .markdown
        case "png", "jpg", "jpeg", "gif", "tiff", "bmp", "heic", "webp":
            currentFileType = .image
        case "pdf":
            currentFileType = .pdf
        default:
            currentFileType = .other
        }
        applyTheme() // Auto-update the theme if the file type switches natively
    }

    var isTypstFile: Bool {
        currentFileURL?.pathExtension.lowercased() == "typ"
    }
    
    var isMarkdownFile: Bool {
        currentFileType == .markdown
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
    
    // --- Error Highlighting ---
    
    private var errorAttributes: [NSAttributedString.Key: Any] {
        return [
            .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.thick.rawValue,
            .underlineColor: NSColor.red
        ]
    }
    
    func setupErrorSubscription() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleTypstErrors(_:)), name: .typstErrorsUpdated, object: nil)
    }
    
    @objc private func handleTypstErrors(_ notification: Notification) {
        if let errors = notification.object as? [TypstError] {
             self.errors = errors
             DispatchQueue.main.async {
                 self.updateErrorHighlights(errors: errors)
             }
        }
    }
    
    func updateErrorHighlights(errors: [TypstError]) {
        guard let tvc = textViewController else { return }
        let textStorage = tvc.textView.textStorage!
        
        print("[EditorController] Updating error highlights: \(errors.count) errors")
        
        // Remove existing error highlights
        // Since we don't track exact ranges of previous errors easily without state,
        // and we can't just clear *all* underlines (might be used by markdown),
        // we ideally should track them.
        // For now, let's assume we can clear specific attributes if we used a custom key, 
        // but standard keys are safer for rendering. 
        // Let's rely on clearing the whole document's error style if possible, 
        // OR better: keep track of old error ranges.
        
        // Simpler approach for now: clear underline color/style for the whole length.
        // This might conflict if other things use specific red underlines.
        let fullRange = NSRange(location: 0, length: textStorage.length)
        if fullRange.length > 0 {
            textStorage.removeAttribute(.underlineColor, range: fullRange)
            textStorage.removeAttribute(.underlineStyle, range: fullRange)
            textStorage.removeAttribute(.toolTip, range: fullRange)
        }
        
        for error in errors {
            if let range = getRangeForLine(error.line) {
                // Ensure range is valid
                if range.location + range.length <= textStorage.length {
                    textStorage.addAttributes(errorAttributes, range: range)
                    textStorage.addAttribute(.toolTip, value: error.message, range: range)
                }
            }
        }
        
        // Force layout update and redraw
        tvc.textView.layoutManager.setNeedsLayout()
        tvc.textView.needsDisplay = true
    }
    
    func getRangeForLine(_ line: Int) -> NSRange? {
        guard line > 0 else { return nil }
        let s = sourceCode as NSString
        var numberOfLines = 0
        var index = 0
        
        while index < s.length {
            numberOfLines += 1
            let lineRange = s.lineRange(for: NSRange(location: index, length: 0))
            if numberOfLines == line {
                return lineRange
            }
            index = NSMaxRange(lineRange)
        }
        return nil
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
        
        // Auto-Recovery: Update if dirty, Clear if clean (e.g. reverted to saved state manually)
        if let url = currentFileURL {
            if dirty {
                AutoRecoveryManager.shared.updateRecovery(content: currentContent, for: url)
            } else {
                // If it became clean (e.g. undo until saved state), we can clear recovery
                AutoRecoveryManager.shared.clearRecovery(for: url)
            }
        }
    }
    
    func restoreContent(_ content: String) {
        self.sourceCode = content
        
        // Force update the underlying text view if available
        if let tvc = textViewController {
            // Replace entire content
             let fullRange = NSRange(location: 0, length: tvc.textView.string.utf16.count)
             if fullRange.length > 0 {
                 tvc.textView.replaceCharacters(in: fullRange, with: content)
             } else {
                 tvc.textView.string = content
             }
        }
        
        // Reset cursor to start
        self.editorState = .init()
        
        // Check unsaved changes (will likely match 'content' but differ from 'savedContent')
        checkUnsavedChanges(currentContent: content)
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
            
            var textToInsert = text
            
            if currentFileType == .typst {
                textToInsert = AICompletionService.shared.sanitizeMarkdownToTypst(textToInsert)
            }
            
            insertText(textToInsert)
        }
    }
    
    func deleteSelection() {
        let range = selectedRange
        if range.length > 0 {
            insertText("", replacementRange: range)
        }
    }
    
    // --- Snippet Functions ---
    
    
    func importLyx() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "lyx")!]
        panel.title = "Import LyX File"
        
        if panel.runModal() == .OK, let selectedURL = panel.url {
            var shouldCopy = true
            
            if let projectRoot = projectRootURL {
                let isOutside = !selectedURL.path.hasPrefix(projectRoot.path)
                if isOutside {
                    let alert = NSAlert()
                    alert.messageText = "Import LyX File"
                    alert.informativeText = "The LyX file is outside your current project. Would you like to copy it into your project or open its directory as a new project?"
                    alert.addButton(withTitle: "Copy to Project")
                    alert.addButton(withTitle: "Open Directory")
                    alert.addButton(withTitle: "Cancel")
                    
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        shouldCopy = true
                    } else if response == .alertSecondButtonReturn {
                        shouldCopy = false
                    } else {
                        return // Cancel
                    }
                }
            } else {
                shouldCopy = false // No project open, so we'll open the directory by default
            }
            
            do {
                let content = try LyxToTypstConverter.load(from: selectedURL)
                
                let converter = LyxToTypstConverter(content: content)
                let typstContent = converter.convert()
                
                let fileName = selectedURL.deletingPathExtension().lastPathComponent
                let targetFileName = "\(fileName).typ"
                
                let targetURL: URL
                if shouldCopy, let projectRoot = projectRootURL {
                    targetURL = projectRoot.appendingPathComponent(targetFileName)
                } else if projectRootURL != nil && !shouldCopy {
                     // Specifically requested "Open Directory" while a project was open
                     targetURL = selectedURL.deletingPathExtension().appendingPathExtension("typ")
                } else {
                    // No project root - original behavior or open in place?
                    // Let's stick to opening in place if no project root is set.
                    targetURL = selectedURL.deletingPathExtension().appendingPathExtension("typ")
                }
                
                try typstContent.write(to: targetURL, atomically: true, encoding: .utf8)
                
                if projectRootURL == nil || !shouldCopy {
                    NotificationCenter.default.post(name: .openProjectAndFile, object: targetURL)
                } else {
                    NotificationCenter.default.post(name: .refreshProjectSidebar, object: nil)
                    NotificationCenter.default.post(name: .fileDidCreate, object: targetURL)
                }
                
                showStatus("LyX File Imported")
            } catch {
                print("[ERROR] Failed to import LyX file: \(error.localizedDescription)")
                showStatus("Import failed: \(error.localizedDescription)")
            }
        }
    }

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
         
         let snippet: String
         if isMarkdownFile {
             snippet = "![\(imageAlt)](\(finalPath))"
         } else {
             let paramsString = params.joined(separator: ", ")
             snippet = "#image(\(paramsString))"
         }
        
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
        
        // Reset state
        self.currentFigureContent = ""
        self.currentFigureCaption = ""
        self.currentFigureLabel = ""
        self.currentFigureKind = ""
        self.currentFigureSupplement = ""
        self.currentFigureRange = nil
        
        if let info = FormatDetector.parseFigure(in: sourceCode, at: range.location) {
            self.currentFigureRange = info.range
            self.currentFigureContent = info.content
            self.currentFigureCaption = info.caption
            self.currentFigureLabel = info.label
            self.currentFigureKind = info.kind ?? ""
            self.currentFigureSupplement = info.supplement ?? ""
        } else if range.length > 0 {
            if let r = Range(range, in: sourceCode) {
                currentFigureContent = String(sourceCode[r])
            }
        }
        
        self.showFigureEditor = true
    }
    
    func insertFigure(content: String, caption: String, label: String, kind: String?, supplement: String?) {
        var params: [String] = []
        
        // Content: If it starts with a function call like image( or table(, don't wrap in []
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContent.hasPrefix("image(") || trimmedContent.hasPrefix("table(") || trimmedContent.hasPrefix("grid(") || trimmedContent.hasPrefix("[") {
            params.append(trimmedContent)
        } else {
            params.append("[\(trimmedContent)]")
        }
        
        if !caption.isEmpty {
            params.append("caption: [\(caption)]")
        }
        
        if let kind = kind, !kind.isEmpty {
             params.append("kind: \"\(kind)\"")
        }
        
        if let supplement = supplement, !supplement.isEmpty {
            params.append("supplement: [\(supplement)]")
        }
        
        var snippet = "#figure(\(params.joined(separator: ", ")))"
        
        if !label.isEmpty {
            snippet += " <\(label)>"
        }
        
        let rangeToReplace = currentFigureRange ?? selectedRange
        if rangeToReplace.location != NSNotFound {
             insertText(snippet, replacementRange: rangeToReplace)
        } else {
             insertText(snippet)
        }
        
        showFigureEditor = false
        updateFormattingState()
    }
    
    // --- External Data Functions ---
    
    func openExternalDataEditor() {
        self.showExternalDataEditor = true
    }
    
    // --- Block Functions ---
    
    func openBlockEditor() {
        let range = selectedRange
        
        // Reset state
        self.currentBlockRange = nil
        self.blockFill = ""
        self.blockInset = ""
        self.blockRadius = ""
        self.blockWidth = ""
        self.blockStroke = ""
        self.blockContent = ""
        
        if let info = FormatDetector.parseBlock(in: sourceCode, at: range.location) {
            self.currentBlockRange = info.range
            self.blockFill = info.fill ?? ""
            self.blockInset = info.inset ?? ""
            self.blockRadius = info.radius ?? ""
            self.blockWidth = info.width ?? ""
            self.blockStroke = info.stroke ?? ""
            self.blockContent = info.content
        } else if range.length > 0 {
            if let r = Range(range, in: sourceCode) {
                blockContent = String(sourceCode[r])
            }
        }
        
        self.showBlockEditor = true
    }
    
    func insertBlock(fill: String, inset: String, radius: String, width: String, stroke: String, content: String) {
        var params: [String] = []
        
        if !fill.isEmpty { params.append("fill: \(fill)") }
        if !inset.isEmpty { params.append("inset: \(inset)") }
        if !radius.isEmpty { params.append("radius: \(radius)") }
        if !width.isEmpty { params.append("width: \(width)") }
        if !stroke.isEmpty { params.append("stroke: \(stroke)") }
        
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmedContent.isEmpty ? "[]" : (trimmedContent.hasPrefix("[") ? trimmedContent : "[\(trimmedContent)]")
        
        let paramStr = params.isEmpty ? "" : "(\(params.joined(separator: ", ")))"
        let snippet = "#block\(paramStr)\(body)"
        
        let rangeToReplace = currentBlockRange ?? selectedRange
        if rangeToReplace.location != NSNotFound {
            insertText(snippet, replacementRange: rangeToReplace)
        } else {
            insertText(snippet)
        }
        
        showBlockEditor = false
        updateFormattingState()
    }
    
    // --- Grid Functions ---
    
    func openGridEditor() {
        let range = selectedRange
        
        // Reset state
        self.currentGridRange = nil
        self.gridColumns = ""
        self.gridGutter = ""
        self.gridCells = []
        
        if let info = FormatDetector.parseGrid(in: sourceCode, at: range.location) {
            self.currentGridRange = info.range
            self.gridColumns = info.columns ?? ""
            self.gridGutter = info.gutter ?? ""
            self.gridCells = info.cells
        }
        
        self.showGridEditor = true
    }
    
    func insertGrid(columns: String, gutter: String, cells: [String]) {
        var params: [String] = []
        
        if !columns.isEmpty { params.append("columns: \(columns)") }
        if !gutter.isEmpty { params.append("gutter: \(gutter)") }
        
        let cellsContent = cells.map { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("[") || trimmed.hasPrefix("#") ? trimmed : "[\(trimmed)]"
        }.joined(separator: ", ")
        
        let paramStr = params.isEmpty ? "" : "(\(params.joined(separator: ", ")))"
        let snippet = "#grid(\n  \(paramStr)\(paramStr.isEmpty ? "" : ",\n  ")\(cellsContent)\n)"
        
        let rangeToReplace = currentGridRange ?? selectedRange
        if rangeToReplace.location != NSNotFound {
            insertText(snippet, replacementRange: rangeToReplace)
        } else {
            insertText(snippet)
        }
        
        showGridEditor = false
        updateFormattingState()
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
        toggleListPrefix(isMarkdownFile ? "1. " : "+ ")
    }
    
    func toggleDescriptionList() {
        toggleListPrefix("/ ")
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
        
        let trimmed = lineContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSingleLineRepresentation && (trimmed.isEmpty || trimmed == prefix.trimmingCharacters(in: .whitespaces)) {
            if trimmed == prefix.trimmingCharacters(in: .whitespaces) {
                // Remove prefix
                let newText = hadTrailingNewline ? "\n" : ""
                let newCursor = NSRange(location: lineRange.location, length: 0)
                insertText(newText, replacementRange: lineRange, newCursorRange: newCursor)
            } else {
                // Add prefix
                let newText = prefix + (hadTrailingNewline ? "\n" : "")
                let newCursor = NSRange(location: lineRange.location + prefix.utf16.count, length: 0)
                insertText(newText, replacementRange: lineRange, newCursorRange: newCursor)
            }
            return
        }
        
        // --- Case 2: Multiline selection or non-empty line ---
        var lineStrings = lineContent.components(separatedBy: .newlines)
        if hadTrailingNewline { lineStrings.removeLast() }
        
        let otherPrefixes = ["- ", "+ ", "/ "].filter { $0 != prefix }
        let headingPattern = #"^(=+)\s"#
        guard let headingRegex = try? NSRegularExpression(pattern: headingPattern, options: []) else { return }
        
        struct LineInfo {
            let headingPrefix: String
            let contentAfterHeading: String
            let hasTargetPrefix: Bool
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
                var replaced = false
                for op in otherPrefixes {
                    if newContent.hasPrefix(op) {
                        newContent = prefix + String(newContent.dropFirst(op.count))
                        replaced = true
                        break
                    }
                }
                if !replaced && !info.hasTargetPrefix {
                    newContent = prefix + newContent
                }
            }
            newLines.append(info.headingPrefix + newContent)
        }
        
        var replacement = newLines.joined(separator: "\n")
        if hadTrailingNewline { replacement += "\n" }
        
        insertText(replacement, replacementRange: lineRange)
    }

    func showFindPanel() {
        // 1. Pre-populate find text from selection
        let selectedText = (sourceCode as NSString).substring(with: selectedRange)
        if !selectedText.isEmpty && !selectedText.contains("\n") {
             editorState.findText = selectedText
        }
        
        // 2. Show the native panel
        editorState.findPanelVisible = true
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
            self.isStrikeActive = FormatDetector.findStrikeRange(in: text, at: range.location) != nil
            self.isTextColorActive = FormatDetector.findTextColorRange(in: text, at: range.location) != nil 
            self.isCodeActive = FormatDetector.findCodeRange(in: text, at: range.location) != nil
            self.isCodeActive = FormatDetector.findCodeRange(in: text, at: range.location) != nil
            self.isLinkActive = FormatDetector.findLinkRange(in: text, at: range.location) != nil
            self.isQuoteActive = FormatDetector.findQuoteRange(in: text, at: range.location) != nil
            self.isCodeBlockActive = FormatDetector.findCodeBlockRange(in: text, at: range.location) != nil
            self.isSubscriptActive = FormatDetector.findSubscriptRange(in: text, at: range.location) != nil
            self.isSuperscriptActive = FormatDetector.findSuperscriptRange(in: text, at: range.location) != nil
            
            self.isTitleActive = FormatDetector.detectIsTitle(in: text, at: range.location)
            self.currentHeadingLevel = FormatDetector.detectHeadingLevel(in: text, at: range.location)
            
            self.isEquationActive = EquationDetector.findEquationRange(in: text, at: range.location) != nil
            self.isTableActive = TableDetector.findTableRange(in: text, at: range.location) != nil
            self.isImageActive = ImageDetector.findImageRange(in: text, at: range.location) != nil
            self.isBibliographyActive = BibliographyDetector.findBibliographyRange(in: text, at: range.location) != nil
            self.isOutlineActive = OutlineDetector.findOutlineRange(in: text, at: range.location) != nil
            
            self.isBulletListActive = FormatDetector.isBulletListActive(in: text, at: range.location)
            self.isNumberListActive = FormatDetector.isNumberListActive(in: text, at: range.location)
            self.isDescriptionListActive = FormatDetector.isDescriptionListActive(in: text, at: range.location)
            self.isFootnoteActive = FormatDetector.findFootnoteRange(in: text, at: range.location) != nil
            self.isPageBreakActive = FormatDetector.findPageBreakRange(in: text, at: range.location) != nil
            self.isHorizontalLineActive = FormatDetector.findHorizontalLineRange(in: text, at: range.location) != nil
            self.isFigureActive = FormatDetector.findFigureRange(in: text, at: range.location) != nil
            self.isScopedBlockActive = FormatDetector.findScopedBlockRange(in: text, at: range.location) != nil
            self.isBlockActive = FormatDetector.findBlockRange(in: text, at: range.location) != nil
            self.isGridActive = FormatDetector.findGridRange(in: text, at: range.location) != nil
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
        
        let markerChar = isMarkdownFile ? "#" : "="
        let markerOnlyPattern = isMarkdownFile ? #"^(#+)\s*$"# : #"^(=+)\s*$"#
        let headingPattern = isMarkdownFile ? #"^(#+)\s"# : #"^(=+)\s"#
        
        let isMarkerOnly = (lineContent.range(of: markerOnlyPattern, options: .regularExpression) != nil)
        let isEmptyLine = lineContent.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
        
        if isSingleLineRepresentation && (isEmptyLine || isMarkerOnly) {
            if level > 0 {
                // ✅ FIXED: Use markerChar instead of "="
                let prefix = String(repeating: markerChar, count: level) + " "
                let newText = prefix + (hadTrailingNewline ? "\n" : "")
                let newCursor = NSRange(location: lineRange.location + prefix.utf16.count, length: 0)
                insertText(newText, replacementRange: lineRange, newCursorRange: newCursor)
            } else {
                // Remove heading marker/Body mode
                let newText = hadTrailingNewline ? "\n" : ""
                let newCursor = NSRange(location: lineRange.location, length: 0)
                insertText(newText, replacementRange: lineRange, newCursorRange: newCursor)
            }
            updateFormattingState()
            return
        }
        
        // --- Multiline selection or non-empty line ---
        var lines = lineContent.components(separatedBy: CharacterSet.newlines)
        if hadTrailingNewline { lines.removeLast() }
        
        guard let regex = try? NSRegularExpression(pattern: headingPattern, options: []) else { return }
        
        var newLines: [String] = []
        
        // Check if we need to remove existing heading markers from ALL lines (if toggle off or changing level)
        // We strip any leading prefix from all lines, then add new level if > 0
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
            
            // Remove title if existing
            let titlePattern = #"^#title\s*\[(.*?)\]\s*$"#
            if let titleRegex = try? NSRegularExpression(pattern: titlePattern, options: []),
               let match = titleRegex.firstMatch(in: content, options: [], range: NSRange(location: 0, length: content.utf16.count)) {
                if let r = Range(match.range(at: 1), in: content) {
                    content = String(content[r])
                }
            }
            
            if level > 0 {
                let prefix = String(repeating: markerChar, count: level) + " "
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
    
    func setTitle() {
        let range = selectedRange
        let nsText = sourceCode as NSString
        let lineRange = nsText.lineRange(for: range)
        let lineContent = nsText.substring(with: lineRange)
        
        let hadTrailingNewline = lineContent.hasSuffix("\n")
        var content = lineContent.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if content.isEmpty {
            let snippet = "#title[]" + (hadTrailingNewline ? "\n" : "")
            let newCursor = NSRange(location: lineRange.location + 7, length: 0)
            insertText(snippet, replacementRange: lineRange, newCursorRange: newCursor)
            updateFormattingState()
            return
        }
        
        // If already a title, remove it (toggle)
        if let titleRange = FormatDetector.findTitleRange(in: sourceCode, at: range.location) {
            // Basic unwrapping: find text inside []
            let fullSnippet = nsText.substring(with: titleRange)
            if let start = fullSnippet.firstIndex(of: "["), let end = fullSnippet.lastIndex(of: "]") {
                let inside = String(fullSnippet[fullSnippet.index(after: start)..<end])
                insertText(inside, replacementRange: titleRange)
            }
            updateFormattingState()
            return
        }
        
        // If it's a heading, strip the marker
        let headingPattern = #"^(=+)\s"#
        if let regex = try? NSRegularExpression(pattern: headingPattern, options: []),
           let match = regex.firstMatch(in: content, options: [], range: NSRange(location: 0, length: content.utf16.count)) {
            content = String(content.dropFirst(match.range.length))
        }
        
        let snippet = "#title[\(content)]" + (hadTrailingNewline ? "\n" : "")
        insertText(snippet, replacementRange: lineRange)
        updateFormattingState()
    }
    
    // --- Formatting Actions ---
    
   // --- Formatting Actions ---
    
    func toggleBold() {
        let range = selectedRange
        if let boldRange = FormatDetector.findBoldRange(in: sourceCode, at: range.location),
           let r = Range(boldRange, in: sourceCode) {
            let snippet = sourceCode[r]
            // If it's Markdown (** or __), unwrap 2 characters; otherwise 1 for Typst (*)
            let prefixLen = (snippet.hasPrefix("**") || snippet.hasPrefix("__")) ? 2 : 1
            
            unwrapFormatting(range: boldRange, prefixLen: prefixLen, suffixLen: prefixLen)
            showStatus("Removed Bold")
        } else {
            let marker = isMarkdownFile ? "**" : "*"
            wrapSelection(prefix: marker, suffix: marker)
            showStatus("Applied Bold")
        }
        updateFormattingState()
    }
    
    func toggleItalic() {
        let range = selectedRange
        if let italicRange = FormatDetector.findItalicRange(in: sourceCode, at: range.location),
           let r = Range(italicRange, in: sourceCode) {
            let snippet = sourceCode[r]
            let prefixLen = 1 // Both Markdown (*) and Typst (_) use 1 character
            
            unwrapFormatting(range: italicRange, prefixLen: prefixLen, suffixLen: prefixLen)
            showStatus("Removed Italic")
        } else {
            let marker = isMarkdownFile ? "*" : "_"
            wrapSelection(prefix: marker, suffix: marker)
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
        
        // 1. Check for Markdown Strike (~~)
        if isMarkdownFile {
            let nsText = sourceCode as NSString
            let safeIndex = max(0, min(range.location, nsText.length))
            if let regex = try? NSRegularExpression(pattern: #"(?s)~~(.*?)~~"#, options: []),
               let match = regex.matches(in: sourceCode, options: [], range: NSRange(location: 0, length: nsText.length)).first(where: { safeIndex >= $0.range.location && safeIndex <= $0.range.upperBound }) {
                
                unwrapFormatting(range: match.range, prefixLen: 2, suffixLen: 2)
                showStatus("Removed Strikethrough")
                updateFormattingState()
                return
            }
        }
        
        // 2. Check for Typst Strike (#strike[...])
        if let strikeRange = FormatDetector.findStrikeRange(in: sourceCode, at: range.location) {
            unwrapBracketedFormatting(range: strikeRange, prefixPattern: #"^#strike\s*[\[\(]"#)
            showStatus("Removed Strikethrough")
        } else {
            if isMarkdownFile {
                wrapSelection(prefix: "~~", suffix: "~~")
            } else {
                wrapSelection(prefix: "#strike[", suffix: "]")
            }
            showStatus("Applied Strikethrough")
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
            if let range = FormatDetector.findCodeRange(in: sourceCode, at: selectedRange.location) {
                unwrapFormatting(range: range, prefixLen: 1, suffixLen: 1)
                showStatus("Removed Inline Code")
            }
        } else {
            wrapSelection(prefix: "`", suffix: "`")
            showStatus("Applied Inline Code")
        }
        updateFormattingState()
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
        let snippet: String
        
        if isMarkdownFile {
            let quotedText = text.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
            snippet = attribution.isEmpty ? quotedText : "\(quotedText)\n> — *\(attribution)*"
        } else {
            var params: [String] = []
            if isBlock { params.append("block: true") }
            if !attribution.isEmpty { params.append("attribution: \"\(attribution)\"") }
            
            let paramStr = params.isEmpty ? "" : "(\(params.joined(separator: ", ")))"
            snippet = "#quote\(paramStr)[\(text)]"
        }
        
        let rangeToReplace = currentQuoteRange ?? selectedRange
        insertText(snippet, replacementRange: rangeToReplace)
        showQuoteEditor = false
    }
    
    func toggleCodeBlock() {
        if isCodeBlockActive {
            if let range = FormatDetector.findCodeBlockRange(in: sourceCode, at: selectedRange.location) {
                unwrapFormatting(range: range, prefixLen: 4, suffixLen: 4) // ```\n and \n```
                showStatus("Removed Code Block")
            }
        } else {
            wrapSelection(prefix: "```\n", suffix: "\n```")
            showStatus("Applied Code Block")
        }
        updateFormattingState()
    }

    func toggleScopedBlock() {
        if isScopedBlockActive {
            if let range = FormatDetector.findScopedBlockRange(in: sourceCode, at: selectedRange.location) {
                unwrapFormatting(range: range, prefixLen: 2, suffixLen: 1) // #[ and ]
                showStatus("Removed Scoped Block")
            }
        } else {
            wrapSelection(prefix: "#[", suffix: "]")
            showStatus("Applied Scoped Block")
        }
        updateFormattingState()
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
            let snippet = isMarkdownFile ? "---\n" : "#line(length: 100%)\n"
            insertText(snippet, replacementRange: range)
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
        let range = selectedRange
        if let colorRange = FormatDetector.findTextColorRange(in: sourceCode, at: range.location) {
            // Replace the existing color inside the tag
            let nsText = sourceCode as NSString
            let snippet = nsText.substring(with: colorRange)
            
            // Regex captures the prefix (group 1) and the suffix (group 2), discarding the old color
            if let regex = try? NSRegularExpression(pattern: "(#text\\s*\\(\\s*fill\\s*:\\s*)(?:[a-zA-Z0-9]+|rgb\\([^)]+\\))(\\s*\\)\\s*\\[)") {
                let newSnippet = regex.stringByReplacingMatches(
                    in: snippet,
                    range: NSRange(location: 0, length: snippet.utf16.count),
                    withTemplate: "$1\(color)$2"
                )
                insertText(newSnippet, replacementRange: colorRange)
                showStatus("Changed Text Color")
            }
        } else {
            // Apply new color wrapper
            wrapSelection(prefix: "#text(fill: \(color))[", suffix: "]")
            showStatus("Applied Text Color")
        }
        updateFormattingState()
    }

    func removeTextColor() {
        let range = selectedRange
        if let colorRange = FormatDetector.findTextColorRange(in: sourceCode, at: range.location) {
            // Unwrap the #text(fill: ...)[...] block completely
            unwrapBracketedFormatting(
                range: colorRange, 
                prefixPattern: #"^#text\s*\(\s*fill\s*:\s*(?:[a-zA-Z0-9]+|rgb\([^)]+\))\s*\)\s*[\[(]"#
            )
            showStatus("Removed Text Color")
            updateFormattingState()
        }
    }
    
    // MARK: - Live Markdown Auto-Translation
    
    /// Detects Markdown syntax on the current line in a `.typ` file and
    /// auto-replaces it with the equivalent Typst syntax in real-time.
    func handleMarkdownAutoformat() {
        // Only auto-translate when editing a Typst file
        guard currentFileType == .typst else { return }
        
        let nsText = sourceCode as NSString
        let cursorLocation = max(0, min(selectedRange.location, nsText.length))
        guard cursorLocation <= nsText.length else { return }
        
        let lineRange = nsText.lineRange(for: NSRange(location: cursorLocation, length: 0))
        let lineContent = nsText.substring(with: lineRange)
        
        // --- 1. Headings: ^#{1,6}\s -> Typst = equivalents ---
        // We explicitly capture the space and rewrite it to prevent AppKit from swallowing the keystroke.
        if let headingRegex = try? NSRegularExpression(pattern: "^(#{1,6})(\\s)", options: []) {
            let nsLine = lineContent as NSString
            if let match = headingRegex.firstMatch(in: lineContent, options: [], range: NSRange(location: 0, length: nsLine.length)) {
                
                let hashCount = match.range(at: 1).length
                let spaceStr = nsLine.substring(with: match.range(at: 2))
                
                // Explicitly bundle the space into the replacement
                let replacementStr = String(repeating: "=", count: hashCount) + spaceStr
                
                // Replace the entire sequence (hashes + space)
                let absoluteRange = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                
                // Snap cursor exactly to the end of the new replacement block
                let newCursor = NSRange(location: absoluteRange.location + replacementStr.utf16.count, length: 0)
                
                insertText(replacementStr, replacementRange: absoluteRange, newCursorRange: newCursor)
                return
            }
        }
        
        // --- 2. Images: ![alt](url "title") -> #image("url", alt: "alt") ---
        if let imgRegex = try? NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\(\\s*([^)\\s]+)(?:\\s+\"[^\"]*\")?\\s*\\)", options: []) {
            if let match = imgRegex.firstMatch(in: lineContent, options: [], range: NSRange(location: 0, length: lineContent.utf16.count)) {
                let nsLine = lineContent as NSString
                let altText = nsLine.substring(with: match.range(at: 1))
                let urlText = nsLine.substring(with: match.range(at: 2)) // Group 2 safely ignores the title
                let replacement = "#image(\"\(urlText)\", alt: \"\(altText)\")"
                
                let absoluteRange = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                let lengthDifference = replacement.utf16.count - match.range.length
                let newCursorLoc = max(absoluteRange.location, cursorLocation + lengthDifference)
                
                insertText(replacement, replacementRange: absoluteRange, newCursorRange: NSRange(location: newCursorLoc, length: 0))
                return
            }
        }
        
        // --- 3. Links: [text](url "title") -> #link("url")[text] ---
        if let linkRegex = try? NSRegularExpression(pattern: "(?<!!)\\[([^\\]]+)\\]\\(\\s*([^)\\s]+)(?:\\s+\"[^\"]*\")?\\s*\\)", options: []) {
            if let match = linkRegex.firstMatch(in: lineContent, options: [], range: NSRange(location: 0, length: lineContent.utf16.count)) {
                let nsLine = lineContent as NSString
                let linkText = nsLine.substring(with: match.range(at: 1))
                let urlText = nsLine.substring(with: match.range(at: 2)) // Group 2 safely ignores the title
                let replacement = "#link(\"\(urlText)\")[\(linkText)]"
                
                let absoluteRange = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                let lengthDifference = replacement.utf16.count - match.range.length
                let newCursorLoc = max(absoluteRange.location, cursorLocation + lengthDifference)
                
                insertText(replacement, replacementRange: absoluteRange, newCursorRange: NSRange(location: newCursorLoc, length: 0))
                return
            }
        }
        
        // --- 4. Bold: **text** -> *text* ---
        if let boldRegex = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*", options: []) {
            if let match = boldRegex.firstMatch(in: lineContent, options: [], range: NSRange(location: 0, length: lineContent.utf16.count)) {
                let nsLine = lineContent as NSString
                let innerText = nsLine.substring(with: match.range(at: 1))
                let replacement = "*\(innerText)*"
                
                let absoluteRange = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                let lengthDifference = replacement.utf16.count - match.range.length
                let newCursorLoc = max(absoluteRange.location, cursorLocation + lengthDifference)
                
                insertText(replacement, replacementRange: absoluteRange, newCursorRange: NSRange(location: newCursorLoc, length: 0))
                return
            }
        }
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
            guard let tvc = self.textViewController else { return }
            
            // 1. Set Cursor
            let newPos = CursorPosition(range: NSRange(location: charIndex, length: 0))
            tvc.setCursorPositions([newPos], scrollToVisible: false) // We handle scroll manually
            
            // 2. Calculate Scroll Position
            if let layoutManager = tvc.textView.layoutManager,
               let rect = layoutManager.rectForOffset(charIndex) {
                   
                if let scrollView = tvc.scrollView {
                    let clipView = scrollView.contentView
                    let viewportHeight = clipView.bounds.height
                    // Center the line
                    let targetY = max(0, rect.origin.y - (viewportHeight / 2) + (rect.height / 2))
                    let targetPoint = CGPoint(x: 0, y: targetY)
                    
                    clipView.scroll(to: targetPoint)
                    scrollView.reflectScrolledClipView(clipView)
                }
            } else {
                 // Fallback if layout not ready?
                 tvc.setCursorPositions([newPos], scrollToVisible: true)
            }
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
        
        if isMarkdownFile {
            snippet = text.isEmpty ? "[\(url)](\(url))" : "[\(text)](\(url))"
        } else {
            snippet = text.isEmpty ? "#link(\"\(url)\")" : "#link(\"\(url)\")[\(text)]"
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
        
        // 4. Figure
        if FormatDetector.findFigureRange(in: text, at: range.location) != nil {
            openFigureEditor()
            return
        }
        
        // 5. Link
        if FormatDetector.findLinkRange(in: text, at: range.location) != nil {
            toggleLink()
            return
        }
        
        // 6. Bibliography
        if BibliographyDetector.findBibliographyRange(in: text, at: range.location) != nil {
            toggleBibliography()
            return
        }
        
        // 7. Outline
        if OutlineDetector.findOutlineRange(in: text, at: range.location) != nil {
            openOutlineEditor()
            return
        }
        
        // 8. Footnote
        if FormatDetector.findFootnoteRange(in: text, at: range.location) != nil {
            openFootnoteEditor()
            return
        }
        
        // 9. Block
        if FormatDetector.findBlockRange(in: text, at: range.location) != nil {
            openBlockEditor()
            return
        }
        
        // 10. Grid
        if FormatDetector.findGridRange(in: text, at: range.location) != nil {
            openGridEditor()
            return
        }
        
        // If nothing is detected, show status message
        showStatus("No editable element at cursor")
    }
    
    /// Generates a clean PDF (no dark mode, no filters) for Print or Share.
    func generateCleanPDF(compiler: TypstCompiler, fileURL: URL?) async -> URL? {
        showStatus("Preparing clean PDF...")
        let preferredDir = fileURL?.deletingLastPathComponent()
        let result = await compiler.compileClean(content: sourceCode, preferredDirectory: preferredDir, projectRoot: projectRootURL)
        
        if result.success, let url = result.pdfURL {
            self.cleanPDFURL = url
            return url
        } else {
            showStatus("Failed to generate clean PDF: \(result.error ?? "Unknown error")")
            return nil
        }
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
    
    // MARK: - AI Prompt Logic
    
    func openAIPromptEditor() {
        self.aiPromptText = ""
        self.showAIPromptEditor = true
    }

    func openFoundationEditor() {
        self.showFoundationEditor = true
    }
    
    func generateAIContent(from prompt: String) async throws -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        
        var finalPrompt = trimmed
        
        if self.useMCPForPrompt {
            // Enrich with project context and guidelines from AIContextManager
           let context = await AIContextManager.shared.generateContext(
                userPrompt: trimmed,
                text: self.sourceCode,
                cursorIndex: self.selectedRange.location,
                fileURL: self.currentFileURL,
                errors: self.errors
            )
            finalPrompt = "\(context)\n\nUSER REQUEST: \(trimmed)"
        }
        
        // NEW: More permissive system prompt tailored for writing and coding
        let systemPrompt = """
        You are an expert Typst editor and general writing assistant.
        Generate the requested content or code based on the user's prompt. 
        If the user asks for prose, annotations, or text, write the text. If they ask for code, write the code.
        IMPORTANT: Output ONLY the raw content to be inserted into the document. Do not include conversational filler like "Here is the text:" and do not wrap the response in markdown code blocks unless explicitly requested.
        """
        
        return try await AICompletionService.shared.fetchCompletion(
            prompt: finalPrompt,
            systemPrompt: systemPrompt,
            maxTokens: 2048 // Increased to allow for longer writing generations
        )
    }
    
    func requestAIFix(for error: TypstError) {
        // Construct a prompt for the fix
        let range = getRangeForLine(error.line)
        var contextCode = ""
        if let range = range, let r = Range(range, in: sourceCode) {
            contextCode = String(sourceCode[r])
        }
        
        // Get surrounding lines for context (e.g. 5 lines before/after)
        var surroundingContext = ""
        if range != nil {
            // This is getting complicated to extract efficiently without helper.
            // Let's just use the error line content for now + error message.
            surroundingContext = contextCode
        }
        
        let prompt = """
        I have a Typst compilation error:
        Error: "\(error.message)"
        
        Code at line \(error.line):
        ```typ
        \(surroundingContext)
        ```
        
        Please provide a corrected version of this line or block to fix the error.
        Explain briefly what was wrong.
        """
        
        // Open AI Prompt Editor with this prompt pre-filled
        self.aiPromptText = prompt
        self.aiReplacementRange = range
        self.showAIPromptEditor = true
        
        // Select the range to visually indicate what will be replaced
        if let range = range {
            self.selectedRange = range
            self.textViewController?.setCursorPositions([CursorPosition(range: range)], scrollToVisible: true)
        }
    }
    
    // Store range to replace
    var aiReplacementRange: NSRange? = nil
    
    func applyAIFix(_ text: String) {
        if let range = aiReplacementRange {
            insertText(text, replacementRange: range)
        } else {
            insertText(text)
        }
        aiReplacementRange = nil // Reset
        showAIPromptEditor = false
        showStatus("AI Fix Applied")
    }
    
    func buildContextMenu(for event: NSEvent, in controller: TextViewController) -> NSMenu? {
        let point = controller.textView.convert(event.locationInWindow, from: nil)
        
        guard let index = controller.textView.layoutManager.textOffsetAtPoint(point) else { return nil }
        
        for error in self.errors {
            // Check if click is on the error line
            if let range = getRangeForLine(error.line), NSLocationInRange(index, range) {
                let menu = NSMenu()
                
                // Static Fixes
                // Get line content
                var lineCode = ""
                if let r = Range(range, in: sourceCode) {
                    lineCode = String(sourceCode[r])
                    // Strip newline for analysis if needed, but replacement usually handles it.
                    // TypstSuggestionEngine expects line content (possibly with newline).
                    // If replacement includes newline, great.
                    // Actually, sourceCode[r] includes the newline if getRangeForLine returns lineRange.
                    // Let's trim for the engine, but remember to preserve newline in replacement if we want?
                    // The engine mimics the input. If input has newline, output typically should.
                    // Let's pass the raw line.
                }
                
                // let fixes = TypstSuggestionEngine.shared.suggestFixes(for: error, in: lineCode)
                
                if !lineCode.isEmpty { // Only offer fixes if we have line content
                    let headerItem = NSMenuItem(title: "Quick Fixes", action: nil, keyEquivalent: "")
                    headerItem.isEnabled = false
                    menu.addItem(headerItem)
                    
                    // Let's handle newline logic here to be safe and robust.
                    var cleanLine = lineCode
                    var suffix = ""
                    if lineCode.hasSuffix("\n") {
                        cleanLine = String(lineCode.dropLast())
                        suffix = "\n"
                    }
                    
                    // Engine works on clean line
                    let cleanFixes = TypstSuggestionEngine.shared.suggestFixes(for: error, in: cleanLine)
                    
                    // Use the clean logic
                    for cleanFix in cleanFixes {
                         let finalReplacement = cleanFix.replacement + suffix
                         let rangeFix = TypstFix(title: cleanFix.title, replacement: finalReplacement, range: range)
                         
                         let item = NSMenuItem(title: cleanFix.title, action: #selector(applyStaticFix(_:)), keyEquivalent: "")
                         item.target = self
                         item.representedObject = rangeFix
                         menu.addItem(item)
                    }
                    menu.addItem(NSMenuItem.separator())
                }
                
                // AI Fix
                let item = NSMenuItem(title: "✨ Fix with AI", action: #selector(fixErrorWithAI(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = error
                menu.addItem(item)
                
                return menu
            }
        }
        return nil
    }
    
    @objc func applyStaticFix(_ sender: NSMenuItem) {
        guard let fix = sender.representedObject as? TypstFix, let range = fix.range else { return }
        
        insertText(fix.replacement, replacementRange: range)
        showStatus("Fixed: \(fix.title)")
    } 
    
    @objc func fixErrorWithAI(_ sender: NSMenuItem) {
        guard let error = sender.representedObject as? TypstError else { return }
        self.requestAIFix(for: error)
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
            // Delay to allow component to finish its own internal setup before we override
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.controller?.setupDefaultConfiguration()
            }
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
            // Aggressively re-apply wrapping settings
            self.controller?.updateTextViewWrapping()
            
            // Live Markdown auto-translation (converts MD syntax to Typst in .typ files)
            self.controller?.handleMarkdownAutoformat()
        }
    }

    nonisolated func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        MainActor.assumeIsolated {
            // Aggressively re-apply wrapping settings
            self.controller?.updateTextViewWrapping()
            // Update formatting state (bold/italic detection)
            self.controller?.updateFormattingState()
        }
    }
    
    @MainActor
    func menu(for event: NSEvent, in controller: TextViewController) -> NSMenu? {
        return self.controller?.buildContextMenu(for: event, in: controller)
    }
}