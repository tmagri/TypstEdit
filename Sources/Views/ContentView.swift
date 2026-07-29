import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import CodeEditSourceEditor
import AppKit

struct ContentView: View {
    @Binding var selectedFile: URL?
    @ObservedObject var editorController: EditorController
    @ObservedObject private var aiService = AICompletionService.shared
    @ObservedObject private var aiSettings = AISettingsManager.shared
    
    @StateObject private var compiler = TypstCompiler()
    @StateObject private var fileSystem = FileSystemModel()
    
    @Environment(\.colorScheme) var colorScheme
    
    // Legacy local state removed, using editorController.sourceCode
    @State private var currentPDFURL: URL?

    @State private var exportedPDFURL: URL?
    
    // Debounce timer
    @State private var workItem: DispatchWorkItem?
    
    @State private var reloadToken: UUID = UUID()
    @State private var lastSaved: Date?
    @State private var showSavePopup: Bool = false

    /// PDF preview zoom. Persisted across launches. `0` means "auto / fit".
    @AppStorage("pdfZoomFactor") private var pdfZoomFactor: Double = 0
    @State private var showRenameAlert: Bool = false
    @State private var renameTargetURL: URL?
    @State private var newFileName: String = ""
    @State private var currentLoadID: UUID = UUID()
    @State private var isInternalSelectionChange: Bool = false
    @State private var showRecoveryAlert: Bool = false
    @State private var recoveryContentToRestore: String?
    @EnvironmentObject var themeManager: ThemeManager

    // MARK: - Editor State
    // MARK: - Editor State
    // editorState moved to EditorController

    
    // MARK: - Body
    
    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow, state: .active, emphasized: false)
                .ignoresSafeArea()
            
            themeManager.mainBackground.ignoresSafeArea()
            
            mainLayout
            
            savePopup
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        .cornerRadius(12)
        .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
        .padding(.vertical, 12)
        .onChange(of: selectedFile) { newValue in handleFileSelectionChange(newValue: newValue) }
        .onReceive(NotificationCenter.default.publisher(for: .insertSnippet)) { notification in handleSnippetInsertion(notification: notification) }
        .onReceive(NotificationCenter.default.publisher(for: .backupProject)) { _ in handleBackup() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("insertLink"))) { _ in editorController.toggleLink() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("insertTable"))) { _ in editorController.insertTableSnippet() }
        .onReceive(NotificationCenter.default.publisher(for: .menuCommand)) { notification in
            if let command = notification.object as? String { handleMenuCommand(command) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openStandaloneFile)) { notification in
            if let url = notification.object as? URL {
                self.selectedFile = url
                self.loadFile(url: url)
                fileSystem.currentFolder = nil // Ensures it stays in standalone mode
                fileSystem.rootNodes = []
                editorController.projectRootURL = nil
                editorController.isSidebarVisible = false
                RAGManager.shared.disableForStandaloneMode()
            }
        }
        .onOpenURL { url in 
            handleOpenURL(url) 
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectAndFile)) { notification in
            if let url = notification.object as? URL {
                self.selectedFile = url
                self.loadFile(url: url)
                let folder = url.deletingLastPathComponent()
                fileSystem.currentFolder = folder
                fileSystem.loadFiles()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("openNotebooks"))) { _ in
            fileSystem.currentFolder = NotebookManager.shared.rootDirectory
            fileSystem.isNewUnsavedFile = false
            fileSystem.rootNodes = [] // Just keep empty to not load file system for it
            editorController.isSidebarVisible = true
            self.selectedFile = nil
            self.editorController.currentFileURL = nil
            self.editorController.sourceCode = ""
            self.currentPDFURL = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectFolder)) { notification in
            if let url = notification.object as? URL {
                fileSystem.currentFolder = url
                fileSystem.isNewUnsavedFile = false
                fileSystem.loadFiles()
                editorController.isSidebarVisible = true
                
                // Try to open main.typ if it exists, otherwise clear selection
                let mainFile = url.appendingPathComponent("main.typ")
                if FileManager.default.fileExists(atPath: mainFile.path) {
                    self.selectedFile = mainFile
                    self.loadFile(url: mainFile)
                } else {
                    self.selectedFile = nil
                    self.editorController.currentFileURL = nil
                    self.editorController.sourceCode = ""
                    self.currentPDFURL = nil
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileDidCreate)) { notification in
            if let url = notification.object as? URL {
                self.selectedFile = url
                fileSystem.isNewUnsavedFile = false
            } else {
                // New unsaved file
                self.selectedFile = nil
                self.editorController.currentFileURL = nil
                self.editorController.sourceCode = ""
                self.editorController.editorState = .init()
                self.editorController.syncSavedContent("")
                fileSystem.isNewUnsavedFile = true
                self.editorController.isSidebarVisible = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestRename)) { notification in
            if let url = notification.object as? URL {
                self.renameTargetURL = url
                self.newFileName = url.lastPathComponent
                self.showRenameAlert = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileDidRename)) { notification in
            if let info = notification.object as? [String: URL], let newURL = info["new"] { self.selectedFile = newURL }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfDidUpdate)) { notification in
            if let url = notification.object as? URL {
                self.currentPDFURL = url
                self.reloadToken = UUID()
            }
        }
        .onChange(of: editorController.sourceCode) { newValue in
            editorController.checkUnsavedChanges(currentContent: newValue)
            scheduleCompilation(with: newValue)
        }
        .onChange(of: editorController.viewMode) { _ in
            // Notes don't auto-compile while typing — when the user brings the
            // preview back on screen, refresh it once so it isn't left stale/blank.
            if editorController.viewMode != .editorOnly,
               selectedFile?.pathExtension.lowercased() == "note" {
                scheduleCompilation()
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: .requestSave)) { notification in saveFile(to: notification.object as? URL) }
        .preferredColorScheme(themeManager.appTheme.colorScheme)
        .onAppear { 
            if let file = selectedFile { loadFile(url: file) }
            applyAppKitAppearance(themeManager.appTheme)
            editorController.applyTheme()
            syncPreviewTheme()
        }
        .onChange(of: themeManager.appTheme) { newTheme in 
            editorController.setupDefaultConfiguration()
            applyAppKitAppearance(newTheme)
            editorController.applyTheme() 
            syncPreviewTheme()
        }
        .onChange(of: colorScheme) { _ in 
            editorController.setupDefaultConfiguration()
            editorController.applyTheme() 
            syncPreviewTheme()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetToWelcome)) { _ in
            // Clear all active file/project state to trigger the WelcomeView
            self.selectedFile = nil
            self.fileSystem.currentFolder = nil
            self.fileSystem.isNewUnsavedFile = false
            self.editorController.currentFileURL = nil
            self.editorController.projectRootURL = nil
            self.editorController.sourceCode = ""
            self.editorController.syncSavedContent("")
            self.currentPDFURL = nil
            self.editorController.isSidebarVisible = false
        }
    } // End of ZStack
    
    // MARK: - Subviews
    
    private var mainLayout: some View {
        Group {
           if fileSystem.currentFolder == nil && !fileSystem.isNewUnsavedFile && selectedFile == nil {
                WelcomeView(model: fileSystem, onOpen: { file in
                    if file.isProject {
                        // Re-open in project mode: show sidebar with parent folder
                        self.selectedFile = file.url
                        self.loadFile(url: file.url)
                        let folder = file.url.deletingLastPathComponent()
                        fileSystem.currentFolder = folder
                        fileSystem.loadFiles()
                        fileSystem.isNewUnsavedFile = false
                        editorController.isSidebarVisible = true
                    } else {
                        // Re-open as standalone single file (no sidebar)
                        NotificationCenter.default.post(name: .openStandaloneFile, object: file.url)
                    }
                })
                .background(themeManager.mainBackground)
            } else {
                VStack(spacing: 0) {
                    HSplitView {
                        if editorController.isSidebarVisible {
                            SidebarView(model: fileSystem, selectedFile: $selectedFile, editorController: editorController)
                                .onChange(of: fileSystem.currentFolder) { newFolder in editorController.projectRootURL = newFolder }
                                .onAppear { editorController.projectRootURL = fileSystem.currentFolder }
                                .frame(minWidth: 200, idealWidth: 200, maxWidth: 400)
                        }
                        
                        if selectedFile != nil || fileSystem.isNewUnsavedFile {
                            editorPreviewArea
                        } else {
                            emptyStateView
                        }
                    }
                    .onChange(of: editorController.isPreviewDarkMode) { newValue in
                        compiler.isDarkMode = newValue
                        scheduleCompilation()
                    }
                    .toolbar { appToolbar }
                    .onChange(of: compiler.errors) { newErrors in
                        editorController.errors = newErrors
                        editorController.needsRedraw()
                        NotificationCenter.default.post(name: .typstErrorsUpdated, object: newErrors)
                    }
                }
            }
        }
    }
    
    private var editorPreviewArea: some View {
        VStack(spacing: 0) {
            ZStack {
                themeManager.contentOverlay.ignoresSafeArea()
                themeManager.mainBackground.ignoresSafeArea()
                
                let isTypst = editorController.currentFileType == .typst
                let isCompilable = isTypst || editorController.isMarkdownFile
                
                if isCompilable {
                    if editorController.viewMode == .editorOnly {
                        editorBox.padding(.horizontal, 12)
                    } else if editorController.viewMode == .previewOnly {
                        pdfBox.padding(.leading, 12)
                    } else {
                        ResizableSplitView(initialWidth: 500, isVertical: editorController.isVerticalSplit) {
                            editorBox.padding(.leading, 12)
                        } right: {
                            pdfBox
                        }
                    }
                } else {
                    editorBox.padding(.horizontal, 12)
                }
            }
            .layoutPriority(1)
            
            statusBar
        }
    }
    
    private var statusBar: some View {
        Group {
            if editorController.isTypstFile || editorController.isMarkdownFile {
                HStack {
                    // Toggle Sidebar Button
                    Button(action: {
                        withAnimation {
                            editorController.isSidebarVisible.toggle()
                        }
                    }) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 11))
                            .foregroundColor(editorController.isSidebarVisible ? .accentColor : themeManager.textColor.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Sidebar")
                    
                    Divider().frame(height: 12).padding(.horizontal, 4)

                    if editorController.isTypstFile {
                        Text("Words: \(editorController.wordCount)").font(.caption).monospacedDigit().foregroundColor(themeManager.textColor)
                        
                        Divider().frame(height: 12).padding(.horizontal, 4)
                    }
                    
                    // View Mode Options
                    HStack(spacing: 8) {
                        Button(action: {
                            editorController.viewMode = .editorOnly
                        }) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11))
                                .foregroundColor(editorController.viewMode == .editorOnly ? .accentColor : themeManager.textColor.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .help("Only Show Editor")
                        
                        Button(action: {
                            editorController.viewMode = .previewOnly
                        }) {
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 11))
                                .foregroundColor(editorController.viewMode == .previewOnly ? .accentColor : themeManager.textColor.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .help("Preview Only")
                        
                        Button(action: {
                            editorController.viewMode = .both
                            editorController.isVerticalSplit = true
                        }) {
                            Image(systemName: "square.split.2x1")
                                .font(.system(size: 11))
                                .foregroundColor(editorController.viewMode == .both && editorController.isVerticalSplit ? .accentColor : themeManager.textColor.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .help("Split Vertically")
                        
                        Button(action: {
                            editorController.viewMode = .both
                            editorController.isVerticalSplit = false
                        }) {
                            Image(systemName: "square.split.1x2")
                                .font(.system(size: 11))
                                .foregroundColor(editorController.viewMode == .both && !editorController.isVerticalSplit ? .accentColor : themeManager.textColor.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .help("Split Horizontally")
                    }
                    
                    Divider().frame(height: 12).padding(.horizontal, 4)
                    
                    Button(action: {
                        toggleMaximizeWindow()
                    }) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 11))
                            .foregroundColor(themeManager.textColor.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Maximize / Window")
                    
                    Spacer()
                    HStack(spacing: 8) {
                        // AI / Intellisense Status Indicator
                        if aiService.isFetching || aiSettings.intellisenseEnabled || aiSettings.isEnabled {
                            HStack(spacing: 4) {
                                if aiService.isFetching {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.6)
                                    Text("AI")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.blue)
                                } else if aiSettings.intellisenseEnabled {
                                    Text("Intellisense")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.green)
                                } else if aiSettings.isEnabled {
                                    Text("AI")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.blue.opacity(0.7))
                                }
                            }
                        }
                        
                        // Editor Status Message (e.g., "File Saved")
                        if editorController.showStatusMessage {
                            Text(editorController.statusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color.primary.opacity(0.3))
                .overlay(Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 1), alignment: .top)
            }
        }
    }
    
    private var pdfBox: some View {
        ZStack {
            themeManager.pdfBackground
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { toggleWindowMaximize() }
            PreviewView(
                url: currentPDFURL,
                reloadToken: reloadToken,
                colorBlindnessMode: editorController.colorBlindnessMode,
                isPreviewDarkMode: editorController.isPreviewDarkMode,
                zoomScale: CGFloat(pdfZoomFactor),
                onZoomScaleChange: { newZoom in
                    DispatchQueue.main.async {
                        pdfZoomFactor = Double(newZoom)
                    }
                },
                onWordCountChange: { count in DispatchQueue.main.async { editorController.wordCount = count } }
            )
            .padding(20)
            
            if compiler.isCompiling {
                ProgressView()
                    .controlSize(.large)
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if currentPDFURL != nil {
                pdfZoomControls
                    .padding(14)
            }
        }
        .cornerRadius(12)
        .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
        .padding(.vertical, 12)
        .padding(.trailing, 12)
    }

    private var pdfZoomControls: some View {
        HStack(spacing: 2) {
            zoomButton(icon: "minus") { adjustZoom(by: 1.0 / 1.2) }
                .keyboardShortcut("-", modifiers: .command)

            Text(zoomLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 46)
                .foregroundColor(themeManager.textColor)
                .help("Current zoom")
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { resetZoom() }

            zoomButton(icon: "plus") { adjustZoom(by: 1.2) }
                .keyboardShortcut("+", modifiers: .command)

            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)

            zoomButton(icon: "arrow.up.left.and.arrow.down.right") { resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1))
    }

    private var zoomLabel: String {
        pdfZoomFactor > 0 ? "\(Int(pdfZoomFactor * 100))%" : "Fit"
    }

    private func zoomButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundColor(themeManager.textColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(icon == "minus" ? "Zoom Out (Cmd−)" : icon == "plus" ? "Zoom In (Cmd+)" : "Fit to Window (Cmd+0)")
    }

    private func adjustZoom(by factor: Double) {
        let current = pdfZoomFactor > 0 ? pdfZoomFactor : 1.0
        pdfZoomFactor = max(0.1, min(5.0, current * factor))
    }

    private func resetZoom() {
        pdfZoomFactor = 0
    }
    
    private var emptyStateView: some View {
        ZStack {
            themeManager.contentOverlay.ignoresSafeArea()
            Text("Select a file").foregroundColor(themeManager.textColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggleWindowMaximize() }
        .layoutPriority(1)
    }
    
    private var savePopup: some View {
        Group {
            if showSavePopup {
                VStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                    Text("Saved!").font(.headline).foregroundColor(.white)
                }
                .padding(20)
                .background(Color.primary.opacity(0.8))
                .cornerRadius(12)
                .transition(.scale.combined(with: .opacity))
                .zIndex(100)
            }
        }
    }
    
    @ToolbarContentBuilder
    private var appToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                Button(action: editorController.undo) {
                    Image(systemName: "arrow.uturn.backward").foregroundColor(themeManager.textColor)
                        .padding(6).background(Color.primary.opacity(0.05)).cornerRadius(8)
                }
                .help("Undo (Cmd+Z)").buttonStyle(.plain)
                
                Button(action: editorController.redo) {
                    Image(systemName: "arrow.uturn.forward").foregroundColor(themeManager.textColor)
                        .padding(6).background(Color.primary.opacity(0.05)).cornerRadius(8)
                }
                .help("Redo (Cmd+Shift+Z)").buttonStyle(.plain)
            }
        }
        ToolbarItem(placement: .principal) {
            Text("\(selectedFile?.lastPathComponent ?? "")\(editorController.hasUnsavedChanges ? "*" : "")")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(themeManager.textColor)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.primary.opacity(0.3)).cornerRadius(8)
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                Button(action: { editorController.showFindPanel() }) {
                    Image(systemName: "magnifyingglass").foregroundColor(themeManager.textColor)
                        .padding(6).background(Color.primary.opacity(0.05)).cornerRadius(8)
                }
                .help("Search (Cmd+F)").buttonStyle(.plain)
                
                Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 1, height: 16)
                HStack(spacing: 8) {
                    Button(action: { saveFile() }) {
                        Image(systemName: "square.and.arrow.down").foregroundColor(themeManager.textColor)
                            .padding(6).background(Color.primary.opacity(0.05)).cornerRadius(8)
                    }
                    .help("Save (Cmd+S)").keyboardShortcut("s", modifiers: .command).buttonStyle(.plain)
                    
                    if editorController.isTypstFile {
                        Button(action: { Task { await printPDF() } }) {
                            Image(systemName: "printer").foregroundColor(themeManager.textColor)
                                .padding(6).background(Color.primary.opacity(0.05)).cornerRadius(8)
                        }
                        .help("Print").buttonStyle(.plain)
                        
                        ShareButton(fileURL: editorController.cleanPDFURL ?? exportedPDFURL).frame(width: 28, height: 28)
                            .padding(4).background(Color.primary.opacity(0.3)).cornerRadius(8).help("Share")
                            .onHover { inside in
                                if inside && editorController.cleanPDFURL == nil {
                                    Task { await editorController.generateCleanPDF(compiler: compiler, fileURL: selectedFile) }
                                }
                            }
                    }
                }
                if let lastSaved = lastSaved {
                    Text("Last saved: \(lastSaved.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }
    
    // Custom search bar removed in favor of native panel    
    private var toolbarArea: some View {
        Group {
            if editorController.currentFileType == .typst || editorController.isMarkdownFile{
                HStack {
                    ToolbarView(controller: editorController).padding(.leading, 44)
                    Spacer()
                }
               .padding(.horizontal, 12).padding(.vertical, 4)
               .background(Color(NSColor.controlBackgroundColor))
               .contentShape(Rectangle()) 
               .onTapGesture(count: 2) { toggleWindowMaximize() }
               .overlay(Divider(), alignment: .top) 
            }
        }
    }

    private var editorContent: some View {
        Group {
            if editorController.currentFileType.isTextual {
                SourceEditor(
                    $editorController.sourceCode,
                    // Pick the highlighting language based on file extension.
                    //  - .md   -> Markdown
                    //  - .note -> Markdown grammar with a Typst overlay (Typst wins on overlap)
                    //  - else  -> Typst
                    language: editorController.highlightLanguage,
                    configuration: editorController.editorConfiguration,
                    state: $editorController.editorState,
                    coordinators: [editorController.sourceEditorBridge],
                    completionDelegate: editorController.aiCompletionProvider
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(editorController.currentFileURL?.absoluteString ?? "none")
                .clipShape(Rectangle())
            } else if let url = selectedFile {
                FilePreviewView(fileURL: url, fileType: editorController.currentFileType)
                    .environmentObject(themeManager)
            }
        }
    }
    private var editorBox: some View {
        ZStack {
            themeManager.editorBackground
            
            VStack(spacing: 0) {
                toolbarArea
                editorContent
                
                .sheet(isPresented: $editorController.showEquationEditor) {
                    VisualEquationEditor(initialEquation: $editorController.currentEquationContent, onSave: { editorController.saveEquation($0) }, onCancel: { editorController.showEquationEditor = false }).frame(width: 900, height: 500)
                }
                .sheet(isPresented: $editorController.showLinkEditor) {
                    LinkEditorView(controller: editorController, onInsert: { u, t in editorController.insertLink(url: u, text: t) }, onCancel: { editorController.showLinkEditor = false })
                }
                .sheet(isPresented: $editorController.showTableEditor) {
                    TableEditorView(controller: editorController, onInsert: { r, c in editorController.insertTable(rows: r, cols: c, columnsString: editorController.tableColumnsString, inset: editorController.tableInset, align: editorController.tableAlign, useHeader: editorController.useTableHeader, headerCells: editorController.tableHeaderCells) }, onCancel: { editorController.showTableEditor = false })
                }
                .sheet(isPresented: $editorController.showImageEditor) {
                    ImageEditorView(controller: editorController, onInsert: { editorController.saveImageSnippet() }, onCancel: { editorController.showImageEditor = false })
                }
                .sheet(isPresented: $editorController.showSymbolPicker) { SymbolPickerView(controller: editorController) }
                .sheet(isPresented: $editorController.showAIPromptEditor) { AIPromptView(controller: editorController).environmentObject(themeManager) }
                .sheet(isPresented: $editorController.showAIRefinePreview) { AIRefinePreviewView(controller: editorController).environmentObject(themeManager) }
                .sheet(isPresented: $editorController.showQuoteEditor) {
                    QuoteEditorView(controller: editorController, onInsert: { t, a, b in editorController.insertQuote(text: t, attribution: a, isBlock: b) }, onCancel: { editorController.showQuoteEditor = false })
                }
                .sheet(isPresented: $editorController.showBibliographyEditor) { BibliographyEditorView(controller: editorController) }
                .sheet(isPresented: $editorController.showLayoutEditor) { LayoutEditorView(controller: editorController, isPresented: $editorController.showLayoutEditor) }
                .sheet(isPresented: $editorController.showHelp) { HelpView().environmentObject(themeManager) }
                .sheet(isPresented: $editorController.showOutlineEditor) { OutlineEditorView(controller: editorController) }
                .sheet(isPresented: $editorController.showFigureEditor) { FigureEditorView(controller: editorController) }
                .sheet(isPresented: $editorController.showExternalDataEditor) { ExternalDataEditorView(controller: editorController) }
                .sheet(isPresented: $editorController.showFootnoteEditor) { FootnoteEditorView(controller: editorController) }
                .sheet(isPresented: $editorController.showTagEditor) { TagEditorView(controller: editorController) }
                .sheet(isPresented: $editorController.showFoundationEditor) { FoundationEditorView(controller: editorController) }
                .sheet(isPresented: $editorController.showBlockEditor) {
                    BlockEditorView(controller: editorController, onCancel: { editorController.showBlockEditor = false })
                }
                .sheet(isPresented: $editorController.showGridEditor) {
                    GridEditorView(controller: editorController, onCancel: { editorController.showGridEditor = false })
                }              
                .alert("Delete Equation?", isPresented: $editorController.showDeleteEquationAlert) {
                    Button("Delete", role: .destructive) { editorController.deleteEquation() }
                    Button("Cancel", role: .cancel) { }
                } message: { Text("Are you sure you want to remove this equation?") }
                .alert("Delete Code Block?", isPresented: $editorController.showDeleteCodeAlert) {
                    Button("Delete", role: .destructive) { editorController.deleteCodeBlock() }
                    Button("Cancel", role: .cancel) { }
                } message: { Text("Are you sure you want to remove this code block?") }
                .alert("Go to Line", isPresented: $editorController.showGoToLineAlert) {
                    TextField("Line Number", text: $editorController.targetLineNumber)
                    Button("Go") { if let line = Int(editorController.targetLineNumber) { editorController.goToLine(line) } }
                    Button("Cancel", role: .cancel) { }
                }
                .alert("Rename File", isPresented: $showRenameAlert) {
                    TextField("New Name", text: $newFileName)
                    Button("Rename") { if let url = renameTargetURL { fileSystem.performRename(from: url, to: newFileName) } }
                    Button("Cancel", role: .cancel) { }
                }
                .alert("Export Error", isPresented: $editorController.showExportErrorAlert) {
                    Button("OK", role: .cancel) { }
                } message: { Text(editorController.lastExportError) }
                .alert("File Not Found", isPresented: $editorController.showFileNotFoundAlert) {
                    Button("OK", role: .cancel) { }
                } message: { Text("The file '\(editorController.missingFileName)' could not be found. It may have been moved or deleted.") }
                .alert("Recover Unsaved Changes?", isPresented: $showRecoveryAlert) {
                    Button("Recover") {
                        if let content = recoveryContentToRestore {
                            editorController.restoreContent(content)
                            editorController.showStatus("Recovered unsaved changes")
                        }
                    }
                    Button("Discard", role: .destructive) {
                        if let url = selectedFile {
                            AutoRecoveryManager.shared.clearRecovery(for: url)
                        }
                    }
                } message: {
                    Text("Unsaved changes were found for this file. Do you want to recover them?")
                }
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        .cornerRadius(12)
        .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
        .padding(.vertical, 12)
    }
    
    // MARK: - Handlers
    // MARK: - Handlers
    
    private func handleOpenURL(_ url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                // 1. If it's a folder, open as a project
                fileSystem.currentFolder = url
                fileSystem.isNewUnsavedFile = false
                fileSystem.loadFiles()
                editorController.isSidebarVisible = true
                
            } else if url.pathExtension.lowercased() == "typ" {
                // 2. If it's a Typst file, open its parent folder as a project AND open the file
                let folder = url.deletingLastPathComponent()
                fileSystem.currentFolder = folder
                fileSystem.isNewUnsavedFile = false
                fileSystem.loadFiles()
                
                self.selectedFile = url
                self.loadFile(url: url)
                
                editorController.isSidebarVisible = true
                
            } else {
                // 3. If it's a Markdown file (or anything else), force standalone mode
                NotificationCenter.default.post(name: .openStandaloneFile, object: url)
            }
        }
    }

    private func handleFileSelectionChange(newValue: URL?) {
        if self.isInternalSelectionChange { self.isInternalSelectionChange = false; return }
        
        let currentlyLoadedFile = self.editorController.currentFileURL
        if newValue == currentlyLoadedFile { return }
        
        if self.editorController.hasUnsavedChanges, let prev = currentlyLoadedFile {
            if let appDelegate = AppDelegate.shared {
                appDelegate.showSaveWarningAsync(for: prev) { proceed in
                    if proceed {
                        self.loadFile(url: newValue)
                    } else {
                        self.isInternalSelectionChange = true
                        self.selectedFile = prev
                    }
                }
                return
            }
        }
        self.loadFile(url: newValue)
    }
    
    private func handleSnippetInsertion(notification: Notification) {
        if let snippetKey = notification.object as? String {
            switch snippetKey {
            case "table": editorController.insertTableSnippet()
            case "image": editorController.insertImageSnippet()
            case "equation": editorController.openNewEquationEditor()
            default: break
            }
        }
    }
    
    // MARK: - Helper Methods
    private func toggleWindowMaximize() {
        if let window = NSApp.keyWindow {
            window.zoom(nil)
        }
    }
    
    func loadFile(url: URL?) {
        guard let url = url else { return }
        print("[DEBUG] loadFile: Starting load for \(url.lastPathComponent)")
        let loadID = UUID()
        self.currentLoadID = loadID
        
        // 1. Do NOT clear state here. Wait for new content.
        
        // 2. Pre-check file type for non-textual files to avoid delay
        // Check extension manually since editorController.currentFileURL isn't updated yet
        let ext = url.pathExtension.lowercased()
        let isTextual = ["typ", "txt", "md", "json", "yml", "yaml", "toml", "css", "js", "ts", "html", "bib", "svg", "lyx", "note"].contains(ext)

        if !isTextual && ext != "pdf" && ext != "png" && ext != "jpg" { // Basic check
             // For non-text, update immediately as there is no content to read
             self.editorController.currentFileURL = url
             self.currentPDFURL = nil
             return
        }

        // 3. Load content in background
        print("[DEBUG] loadFile: Dispatching background read")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let content = try LyxToTypstConverter.load(from: url)
                print("[DEBUG] loadFile: Read success (len: \(content.count)). Dispatching main update (id: \(loadID))")
                DispatchQueue.main.async {
                    guard self.currentLoadID == loadID else { 
                        print("[DEBUG] loadFile: Load ID mismatch (cancelled)")
                        return 
                    }
                    
                    // Update State ATOMICALLY (as much as possible)
                    self.editorController.currentFileURL = url
                    self.currentPDFURL = nil
                    self.reloadToken = UUID()
                    self.exportedPDFURL = url.deletingPathExtension().appendingPathExtension("pdf")
                    RecentFilesManager.shared.add(url: url, isProject: fileSystem.currentFolder != nil)
                    
                    self.editorController.syncSavedContent(content)
                    print("[DEBUG] loadFile: Updating sourceCode")
                    self.editorController.sourceCode = content
                    // Reset undo manager/state by creating new state?
                    // self.editorController.editorState = .init() // Let .id() handle recreation or keep state?
                    // Better to reset state for new file
                    self.editorController.editorState = .init()
                    

                    
                    self.scheduleCompilation(with: content)
                    
                    // Check for recovery
                    if AutoRecoveryManager.shared.hasRecovery(for: url) {
                        if let recovered = AutoRecoveryManager.shared.restoreContent(for: url) {
                            // Only offer recovery if it differs from what we just loaded
                             let normalizedDisk = content.trimmingCharacters(in: .whitespacesAndNewlines)
                             let normalizedRecovery = recovered.trimmingCharacters(in: .whitespacesAndNewlines)
                             
                             if normalizedDisk != normalizedRecovery {
                                 self.recoveryContentToRestore = recovered
                                 self.showRecoveryAlert = true
                             } else {
                                 // Recovery is same as disk (maybe user saved but validation didn't clear?)
                                 AutoRecoveryManager.shared.clearRecovery(for: url)
                             }
                        }
                    }
                    
                    print("[DEBUG] loadFile: Complete")
                }
            } catch {
                print("[ERROR] loadFile: Failed to load file at \(url): \(error)")
                DispatchQueue.main.async {
                    guard self.currentLoadID == loadID else { return }
                    // Update URL anyway so we can show error or empty state correctly?
                    // Or keep previous file?
                    // If we don't update currentFileURL, we stay on old file.
                    
                    if (try? url.checkResourceIsReachable()) != true {
                        self.editorController.missingFileName = url.lastPathComponent
                        self.editorController.showFileNotFoundAlert = true
                        RecentFilesManager.shared.remove(url: url)
                        if self.selectedFile == url { self.selectedFile = nil }
                    } else {
                         // File exists but read failed (e.g. binary?)
                         self.editorController.currentFileURL = url
                         // Don't update sourceCode
                    }
                }
            }
        }
    }
    
    func saveFile(to url: URL? = nil) {
        let targetURL = url ?? selectedFile
        
        if targetURL == nil {
            // Show save panel for unsaved file
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "typ")!]
            panel.nameFieldStringValue = "untitled.typ"
            if panel.runModal() == .OK, let savedURL = panel.url {
                 performSave(to: savedURL)
                 fileSystem.isNewUnsavedFile = false
                 self.selectedFile = savedURL
                 self.editorController.isSidebarVisible = true
                 // If no current folder, maybe set it to the saved location?
                 if fileSystem.currentFolder == nil {
                     fileSystem.currentFolder = savedURL.deletingLastPathComponent()
                     fileSystem.loadFiles()
                 }
            }
            return
        }
        
        guard let url = targetURL else { return }
        performSave(to: url)
    }
    
    private func performSave(to url: URL) {
        // Capture a rotating backup of the CURRENT on-disk content before overwriting.
        // Only fires on explicit Save (not on .note auto-save), guarding against the
        // insert-clears-text class of bugs where a save would otherwise destroy good work.
        BackupManager.shared.backupExistingFile(at: url, projectRoot: editorController.projectRootURL)

        do {
            try editorController.sourceCode.write(to: url, atomically: true, encoding: .utf8)
            RecentFilesManager.shared.add(url: url, isProject: fileSystem.currentFolder != nil)
            DispatchQueue.main.async {
                if url == self.selectedFile || fileSystem.isNewUnsavedFile {
                    self.editorController.syncSavedContent(self.editorController.sourceCode)
                    self.scheduleCompilation(with: self.editorController.sourceCode, force: true)
                    self.exportPDF(from: url) // Update clean PDF on disk on save
                    self.lastSaved = Date()
                    self.editorController.showStatus("File Saved")
                    AutoRecoveryManager.shared.clearRecovery(for: url) // Clear recovery on save
                    withAnimation { self.showSavePopup = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { self.showSavePopup = false } }
                }
            }

        } catch { print("[ERROR] Failed to save file \(url.lastPathComponent): \(error)") }
    }
    
    @MainActor
    func handleExport(format: String) {
        guard let url = selectedFile else { return }
        let suggestedName = url.deletingPathExtension().appendingPathExtension(format).lastPathComponent
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format)!]
        panel.nameFieldStringValue = suggestedName
        if panel.runModal() == .OK, let dest = panel.url {
            Task {
                let result = await compiler.export(sourceURL: url, outputURL: dest, format: format, projectRoot: editorController.projectRootURL)
                await MainActor.run {
                    if result.success {
                        NSWorkspace.shared.open(dest)
                        if let root = editorController.projectRootURL, dest.path.hasPrefix(root.path) { fileSystem.loadFiles() }
                    } else {
                        editorController.lastExportError = result.error ?? "Unknown error"
                        editorController.showExportErrorAlert = true
                    }
                }
            }
        }
    }

    func exportPDF(from sourceURL: URL) {
        let pdfDestination = sourceURL.deletingPathExtension().appendingPathExtension("pdf")
        
        Task {
            let ext = sourceURL.pathExtension.lowercased()
            let result = await compiler.compileClean(content: editorController.sourceCode,
                                                     fileExtension: ext,
                                                     originalFileURL: sourceURL, // Pass source URL to inherit its filename
                                                     projectRoot: editorController.projectRootURL)
            
            if result.success, let tempPDF = result.pdfURL {
                do {
                    if FileManager.default.fileExists(atPath: pdfDestination.path) {
                        try FileManager.default.removeItem(at: pdfDestination)
                    }
                    try FileManager.default.copyItem(at: tempPDF, to: pdfDestination)
                    await MainActor.run {
                        self.exportedPDFURL = pdfDestination
                    }
                } catch {
                    print("[ERROR] Failed to export clean PDF: \(error)")
                }
            }
        }
    }
    
    func printPDF() async {
        let pdfURLToPrint: URL?
        if let cleanURL = editorController.cleanPDFURL {
            pdfURLToPrint = cleanURL
        } else {
            pdfURLToPrint = await editorController.generateCleanPDF(compiler: compiler, fileURL: selectedFile)
        }
        
        guard let url = pdfURLToPrint, let document = PDFDocument(url: url) else { return }
        let printInfo = NSPrintInfo.shared
        printInfo.topMargin = 0; printInfo.bottomMargin = 0; printInfo.leftMargin = 0; printInfo.rightMargin = 0
        document.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true)?.run()
    }
    
    func scheduleCompilation(with content: String? = nil, force: Bool = false) {
        let isUnsaved = fileSystem.isNewUnsavedFile && selectedFile == nil
        let isCompilable = editorController.isTypstFile || editorController.isMarkdownFile
        guard (selectedFile != nil || isUnsaved), isCompilable else {
            compiler.cleanUp(); currentPDFURL = nil; return
        }

        let url = selectedFile ?? FileManager.default.temporaryDirectory.appendingPathComponent("untitled.typ")

        workItem?.cancel()
        let currentSource = content ?? editorController.sourceCode
        let isDark = editorController.isPreviewDarkMode
        let isNote = url.pathExtension.lowercased() == "note"
        let delay = isNote ? 3.0 : 0.5
        // Note files: auto-save always runs, but compilation (whole-document
        // Markdown→Typst sanitization + a typst CLI process) is deliberately NOT
        // triggered by typing — it runs only on explicit save (`force`) or while the
        // preview pane is actually visible.
        let shouldCompile = !isNote || force || editorController.viewMode != .editorOnly
        let newWorkItem = DispatchWorkItem {
            Task {
                compiler.isDarkMode = isDark

                // Auto-save .note files to prevent data loss
                if isNote {
                    do {
                        try await Task.detached {
                            try currentSource.write(to: url, atomically: true, encoding: .utf8)
                        }.value
                        DispatchQueue.main.async {
                            self.editorController.syncSavedContent(currentSource)
                            AutoRecoveryManager.shared.clearRecovery(for: url)
                        }
                    } catch {
                        print("[ERROR] Failed to auto-save note: \(error)")
                    }
                }

                guard shouldCompile else { return }
                await compiler.updateContent(source: currentSource, fileURL: url)
            }
        }
        workItem = newWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: newWorkItem)
    }
    
    @MainActor
    func handleBackup() {
        guard let root = fileSystem.currentFolder else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(root.lastPathComponent)_backup.zip"
        if panel.runModal() == .OK, let dest = panel.url {
            Task {
                if await fileSystem.createBackup(to: dest) { NSWorkspace.shared.open(dest.deletingLastPathComponent()) }
                else { editorController.lastExportError = "Failed to create project backup."; editorController.showExportErrorAlert = true }
            }
        }
    }
    
    @MainActor
    func handleMenuCommand(_ command: String) {
        switch command {
        case "newFile": fileSystem.createNewFile()
        case "renameFile": if let url = selectedFile { self.renameTargetURL = url; self.newFileName = url.lastPathComponent; self.showRenameAlert = true }
        case "quickExportPDF": if let url = selectedFile { exportPDF(from: url) }
        case "exportPDF": handleExport(format: "pdf")
        case "exportPNG": handleExport(format: "png")
        case "exportSVG": handleExport(format: "svg")
        case "openLayoutEditor": editorController.openLayoutEditor()
        case "undo": editorController.undo()
        case "redo": editorController.redo()
        case "cut": editorController.cutSelection()
        case "copy": editorController.copySelection()
        case "paste": editorController.pasteSelection()
        case "pasteAsPlainText": editorController.pasteAsPlainText()
        case "pasteForceTypst": editorController.pasteForceConvertToTypst()

        case "delete": editorController.deleteSelection()
        case "goToLine": editorController.showGoToLineAlert = true
        case "selectAll": editorController.selectAll()
        
        // Formatting
        case "toggleBold": editorController.toggleBold()
        case "toggleItalic": editorController.toggleItalic()
        case "toggleUnderline": editorController.toggleUnderline()
        case "toggleHighlight": editorController.toggleHighlight()
        case "toggleStrike": editorController.toggleStrike()
        case "toggleSubscript": editorController.toggleSubscript()
        case "toggleSuperscript": editorController.toggleSuperscript()
        case "toggleLineComment": editorController.toggleLineComment()
        case "toggleBlockComment": editorController.toggleBlockComment()
        
        // Lists & Code
        case "toggleBulletList": editorController.toggleBulletList()
        case "toggleNumberList": editorController.toggleNumberList()
        case "toggleCode": editorController.toggleCode()
        case "toggleCodeBlock": editorController.toggleCodeBlock()
        case "toggleQuote": editorController.toggleQuote()
        
        // Insert / Open Editors
        case "insertPageBreak": editorController.insertPageBreak()
        case "insertHorizontalLine": editorController.insertHorizontalLine()
        case "insertFootnote": editorController.openFootnoteEditor() // "insertFootnote" menu item usually opens editor or inserts default
        case "openTagEditor": editorController.openTagEditor()
        case "insertBibliography": editorController.toggleBibliography()
        case "openContextualEditor": editorController.openContextualEditor()
        case "openFigureEditor": editorController.openFigureEditor()
        case "openSymbolPicker": editorController.showSymbolPicker = true
        case "openOutlineEditor": editorController.openOutlineEditor()
        case "openExternalDataEditor": editorController.openExternalDataEditor()
        case "showHelp": editorController.showHelp = true
            
        // Note: For SourceEditor, selection/cursor logic might need to be hooked up to `editorState`
        case "toggleSidebar": withAnimation { editorController.isSidebarVisible.toggle() }
        case "viewEditorOnly": withAnimation { editorController.viewMode = .editorOnly }
        case "viewPreviewOnly": withAnimation { editorController.viewMode = .previewOnly }
        case "viewBothPanels": withAnimation { editorController.viewMode = .both }
        case "splitVertical": withAnimation { editorController.isVerticalSplit = true }
        case "splitHorizontal": withAnimation { editorController.isVerticalSplit = false }

        case "toggleScopedBlock": editorController.toggleScopedBlock()
        case "openBlockEditor": editorController.openBlockEditor()
        case "openGridEditor": editorController.openGridEditor()
        case "aiPrompt": editorController.openAIPromptEditor()
        case "openFoundationEditor": editorController.openFoundationEditor()
        case "zoomIn": editorController.zoomIn()
        case "zoomOut": editorController.zoomOut()
        case "restoreBackup": showRestoreBackupSheet()
        default: break
        }
    }

    /// Presents a chooser for the current file's rotating backups and loads the selected
    /// snapshot into the editor (without saving), so the user can review/undo before saving.
    @MainActor
    func showRestoreBackupSheet() {
        guard let url = selectedFile ?? editorController.currentFileURL else {
            editorController.showStatus("Open a file before restoring a backup")
            return
        }
        let backups = BackupManager.shared.listBackups(for: url, projectRoot: editorController.projectRootURL)
        guard !backups.isEmpty else {
            editorController.showStatus("No backups available for this file yet")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Restore Backup for \(url.lastPathComponent)"
        alert.informativeText = "Choose a backup to load into the editor. The file on disk won't change until you Save."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        for (i, entry) in backups.enumerated() {
            let label = "#\(i + 1) — \(formatter.string(from: entry.modified))  (\(entry.url.lastPathComponent))"
            popup.addItem(withTitle: label)
        }
        popup.selectItem(at: 0)
        alert.accessoryView = popup

        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.isKeyWindow }) ?? NSApp.mainWindow else {
            if alert.runModal() == .alertFirstButtonReturn {
                restoreSelectedBackup(at: popup.indexOfSelectedItem, from: backups)
            }
            return
        }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.restoreSelectedBackup(at: popup.indexOfSelectedItem, from: backups)
        }
    }

    @MainActor
    private func restoreSelectedBackup(at index: Int, from backups: [(url: URL, modified: Date)]) {
        guard backups.indices.contains(index) else { return }
        guard let content = BackupManager.shared.restoreContent(from: backups[index].url) else {
            editorController.showStatus("Could not read backup file")
            return
        }
        editorController.restoreContent(content)
        editorController.showStatus("Restored backup into editor — review and Save to keep")
    }

    private func applyAppKitAppearance(_ theme: AppTheme) {
        switch theme {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system:
            NSApp.appearance = nil // Reverts to following macOS System Settings
        }
    }

    private func syncPreviewTheme() {
        let isDark: Bool
        switch themeManager.appTheme {
        case .light: isDark = false
        case .dark: isDark = true
        case .system: isDark = (colorScheme == .dark)
        }
        
        if editorController.isPreviewDarkMode != isDark {
            editorController.isPreviewDarkMode = isDark
        }
    }
    
    private func toggleMaximizeWindow() {
        let app = NSApplication.shared
        let keyWin = app.windows.first(where: { $0.isKeyWindow })
        let target = keyWin ?? app.mainWindow
        if let window = target {
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else {
                window.zoom(nil)
            }
        }
    }
}
