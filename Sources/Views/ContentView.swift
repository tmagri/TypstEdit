
import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit

struct ContentView: View {
    @Binding var selectedFile: URL?
    @ObservedObject var editorController: EditorController
    
    @StateObject private var compiler = TypstCompiler()
    @StateObject private var fileSystem = FileSystemModel()
    
    @State private var sourceCode: String = ""
    @State private var currentPDFURL: URL? // Preview PDF for live viewing
    @State private var exportedPDFURL: URL? // Exported PDF for sharing/printing
    
    // Debounce timer
    @State private var workItem: DispatchWorkItem?
    
    @State private var reloadToken: UUID = UUID()
    @State private var lastSaved: Date?
    @State private var showSavePopup: Bool = false
    @State private var showRenameAlert: Bool = false
    @State private var renameTargetURL: URL?
    @State private var newFileName: String = ""
    @State private var currentLoadID: UUID = UUID()
    @State private var isInternalSelectionChange: Bool = false
    @EnvironmentObject var themeManager: ThemeManager
    
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
        .onChange(of: selectedFile) { newValue in
            handleFileSelectionChange(newValue: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .insertSnippet)) { notification in
            handleSnippetInsertion(notification: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .backupProject)) { _ in
            handleBackup()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("insertLink"))) { _ in
            editorController.toggleLink()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuCommand)) { notification in
            if let command = notification.object as? String {
                handleMenuCommand(command)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileDidCreate)) { notification in
            if let url = notification.object as? URL {
                self.selectedFile = url
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
            if let info = notification.object as? [String: URL], let newURL = info["new"] {
                self.selectedFile = newURL
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfDidUpdate)) { notification in
            if let url = notification.object as? URL {
                self.currentPDFURL = url
                self.reloadToken = UUID()
                if let selectedFile = selectedFile {
                    exportPDF(from: selectedFile)
                }
            }
        }
        .onChange(of: sourceCode) { newValue in
            editorController.checkUnsavedChanges(currentContent: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestSave)) { notification in
            saveFile(to: notification.object as? URL)
        }
        .onAppear {
            if let file = selectedFile {
                loadFile(url: file)
            }
        }
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Subviews
    
    private var mainLayout: some View {
        Group {
            if fileSystem.currentFolder == nil {
                WelcomeView(model: fileSystem, onOpen: { url in
                    self.selectedFile = url
                    let folder = url.deletingLastPathComponent()
                    fileSystem.currentFolder = folder
                    fileSystem.loadFiles()
                })
                .background(themeManager.mainBackground)
            } else {
                VStack(spacing: 0) {
                    HSplitView {
                        if editorController.isSidebarVisible {
                            SidebarView(model: fileSystem, selectedFile: $selectedFile, editorController: editorController)
                                .onChange(of: fileSystem.currentFolder) { newFolder in
                                    editorController.projectRootURL = newFolder
                                }
                                .onAppear {
                                    editorController.projectRootURL = fileSystem.currentFolder
                                }
                                .frame(minWidth: 200, idealWidth: 200, maxWidth: 400)
                        }
                        
                        if selectedFile != nil {
                            editorPreviewArea
                        } else {
                            emptyStateView
                        }
                    }
                    .onChange(of: editorController.isPreviewDarkMode) { newValue in
                        compiler.isDarkMode = newValue
                        scheduleCompilation()
                    }
                    .toolbar {
                        appToolbar
                    }
                    .toolbarBackground(.hidden, for: .windowToolbar)
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
        ZStack {
            themeManager.contentOverlay.ignoresSafeArea() 
            themeManager.mainBackground.ignoresSafeArea() 
            
            let isTextual = editorController.currentFileType == .typst || editorController.currentFileType == .text
            
            if !isTextual || editorController.viewMode == .editorOnly {
                editorBox.padding(.horizontal, 12)
            } else if editorController.viewMode == .previewOnly {
                pdfBox
            } else {
                ResizableSplitView(initialWidth: 500, isVertical: editorController.isVerticalSplit) {
                    editorBox.padding(.leading, 12)
                } right: {
                    pdfBox
                }
            }
        }
        .layoutPriority(1)
    }
    
    private var pdfBox: some View {
        ZStack {
            themeManager.pdfBackground
            PreviewView(
                url: currentPDFURL,
                reloadToken: reloadToken,
                colorBlindnessMode: editorController.colorBlindnessMode,
                isPreviewDarkMode: editorController.isPreviewDarkMode,
                onWordCountChange: { count in
                    DispatchQueue.main.async { editorController.wordCount = count }
                }
            )
            .padding(20)
        }
        .cornerRadius(12)
        .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
        .padding(.vertical, 12)
        .padding(.trailing, 12)
    }
    
    private var emptyStateView: some View {
        ZStack {
            themeManager.contentOverlay.ignoresSafeArea()
            Text("Select a file")
                .foregroundColor(themeManager.textColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }
    
    private var savePopup: some View {
        Group {
            if showSavePopup {
                VStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                    Text("Saved!")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(20)
                .background(Color.black.opacity(0.8))
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
                    Image(systemName: "arrow.uturn.backward")
                        .foregroundColor(themeManager.textColor)
                        .padding(6)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(8)
                }
                .help("Undo (Cmd+Z)")
                .buttonStyle(.plain)
                
                Button(action: editorController.redo) {
                    Image(systemName: "arrow.uturn.forward")
                        .foregroundColor(themeManager.textColor)
                        .padding(6)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(8)
                }
                .help("Redo (Cmd+Shift+Z)")
                .buttonStyle(.plain)
            }
        }
        
        ToolbarItem(placement: .principal) {
            Text("\(selectedFile?.lastPathComponent ?? "")\(editorController.hasUnsavedChanges ? "*" : "")")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(themeManager.textColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)
        }
        
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                if editorController.isSearchVisible {
                    searchBar
                }
                
                Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 1, height: 16)
                
                HStack(spacing: 8) {
                    Button(action: { saveFile() }) {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundColor(themeManager.textColor)
                            .padding(6)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(8)
                    }
                    .help("Save (Cmd+S)")
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.plain)
                    
                    if editorController.isTypstFile {
                        Button(action: printPDF) {
                            Image(systemName: "printer")
                                .foregroundColor(themeManager.textColor)
                                .padding(6)
                                .background(Color.black.opacity(0.3))
                                .cornerRadius(8)
                        }
                        .help("Print")
                        .buttonStyle(.plain)
                        
                        ShareButton(fileURL: exportedPDFURL)
                            .frame(width: 28, height: 28)
                            .padding(4)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(8)
                            .help("Share")
                    }
                }
                
                if let lastSaved = lastSaved {
                    Text("Last saved: \(lastSaved.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 13))
                TextField("Search", text: $editorController.searchQuery)
                    .textFieldStyle(.plain)
                    .frame(width: 130)
                    .foregroundColor(themeManager.textColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.3))
            .cornerRadius(8)
            
            if !editorController.searchQuery.isEmpty && editorController.matchCount > 0 {
                searchResultsPopup
            }
        }
    }
    
    private var searchResultsPopup: some View {
        HStack(spacing: 8) {
            Text("\(editorController.currentMatchIndex + 1) of \(editorController.matchCount)")
                .font(.caption)
                .foregroundColor(themeManager.secondaryTextColor)
            
            Divider().frame(height: 12)
            
            Button(action: { editorController.previousMatch() }) {
                Image(systemName: "chevron.up").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            
            Button(action: { editorController.nextMatch() }) {
                Image(systemName: "chevron.down").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            
            Divider().frame(height: 12)
            
            Button(action: { 
                editorController.searchQuery = ""
                editorController.clearSearch()
            }) {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.3))
        .cornerRadius(6)
        .offset(y: 2)
    }
    
    private var toolbarArea: some View {
        Group {
            if editorController.currentFileType == .typst {
                HStack {
                    ToolbarView(controller: editorController)
                        .padding(.leading, 44)
                    Spacer()
                }
                .padding(.trailing, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.3))
                .overlay(Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 1), alignment: .bottom)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    private var editorContent: some View {
        Group {
            if editorController.currentFileType == .typst || editorController.currentFileType == .text {
                EditorView(text: $sourceCode, controller: editorController, onCommit: {
                    scheduleCompilation()
                })
                .environmentObject(themeManager)
                .padding(8)
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
                    VisualEquationEditor(
                        initialEquation: $editorController.currentEquationContent,
                        onSave: { newEquation in
                            editorController.saveEquation(newEquation)
                        },
                        onCancel: {
                            editorController.showEquationEditor = false
                        }
                    )
                    .frame(width: 900, height: 500)
                }
                .sheet(isPresented: $editorController.showLinkEditor) {
                    LinkEditorView(
                        controller: editorController,
                        onInsert: { url, text in
                            editorController.insertLink(url: url, text: text)
                        },
                        onCancel: {
                            editorController.showLinkEditor = false
                        }
                    )
                }
                .sheet(isPresented: $editorController.showTableEditor) {
                    TableEditorView(
                        controller: editorController,
                        onInsert: { rows, cols in
                            editorController.insertTable(
                                rows: rows,
                                cols: cols,
                                columnsString: editorController.tableColumnsString,
                                inset: editorController.tableInset,
                                align: editorController.tableAlign,
                                useHeader: editorController.useTableHeader,
                                headerCells: editorController.tableHeaderCells
                            )
                        },
                        onCancel: {
                            editorController.showTableEditor = false
                        }
                    )
                }
                .sheet(isPresented: $editorController.showImageEditor) {
                    ImageEditorView(
                        controller: editorController,
                        onInsert: {
                            editorController.saveImageSnippet()
                        },
                        onCancel: {
                            editorController.showImageEditor = false
                        }
                    )
                }
                .sheet(isPresented: $editorController.showSymbolPicker) {
                    SymbolPickerView(controller: editorController)
                }
                .sheet(isPresented: $editorController.showQuoteEditor) {
                    QuoteEditorView(
                        controller: editorController,
                        onInsert: { text, attribution, isBlock in
                            editorController.insertQuote(text: text, attribution: attribution, isBlock: isBlock)
                        },
                        onCancel: {
                            editorController.showQuoteEditor = false
                        }
                    )
                }
                .sheet(isPresented: $editorController.showBibliographyEditor) {
                    BibliographyEditorView(controller: editorController)
                }
                .sheet(isPresented: $editorController.showLayoutEditor) {
                    LayoutEditorView(
                        controller: editorController,
                        isPresented: $editorController.showLayoutEditor
                    )
                }
                .sheet(isPresented: $editorController.showHelp) {
                    HelpView()
                        .environmentObject(themeManager)
                }
                .sheet(isPresented: $editorController.showOutlineEditor) {
                    OutlineEditorView(controller: editorController)
                }
                .sheet(isPresented: $editorController.showFigureEditor) {
                    FigureEditorView(controller: editorController)
                }
                .sheet(isPresented: $editorController.showExternalDataEditor) {
                    ExternalDataEditorView(controller: editorController)
                }
                .sheet(isPresented: $editorController.showFootnoteEditor) {
                    FootnoteEditorView(controller: editorController)
                }
                .alert("Delete Equation?", isPresented: $editorController.showDeleteEquationAlert) {
                    Button("Delete", role: .destructive) { editorController.deleteEquation() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Are you sure you want to remove this equation?")
                }
                .alert("Delete Code Block?", isPresented: $editorController.showDeleteCodeAlert) {
                    Button("Delete", role: .destructive) { editorController.deleteCodeBlock() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Are you sure you want to remove this code block?")
                }
                .alert("Go to Line", isPresented: $editorController.showGoToLineAlert) {
                    TextField("Line Number", text: $editorController.targetLineNumber)
                    Button("Go") {
                        if let line = Int(editorController.targetLineNumber) {
                            editorController.goToLine(line)
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                }
                .alert("Rename File", isPresented: $showRenameAlert) {
                    TextField("New Name", text: $newFileName)
                    Button("Rename") {
                        if let url = renameTargetURL {
                            fileSystem.performRename(from: url, to: newFileName)
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                }
                .alert("Export Error", isPresented: $editorController.showExportErrorAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(editorController.lastExportError)
                }
                .alert("File Not Found", isPresented: $editorController.showFileNotFoundAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("The file '\(editorController.missingFileName)' could not be found. It may have been moved or deleted.")
                }
            
                if editorController.isTypstFile {
                    HStack {
                        Text("Words: \(editorController.wordCount)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(themeManager.textColor)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.3))
                    .overlay(Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 1), alignment: .top)
                }
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        .cornerRadius(12)
        .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
        .padding(.vertical, 12)
    }
    
    // MARK: - Handlers
    
    private func handleFileSelectionChange(newValue: URL?) {
        DispatchQueue.main.async {
            // 1. Ignore if this is part of a revert operation
            if self.isInternalSelectionChange {
                self.isInternalSelectionChange = false
                return
            }
            
            // 2. Identify the file we are actually LEAVING
            let currentlyLoadedFile = self.editorController.currentFileURL
            
            // 3. Guard against redundant calls if clicked same file
            if newValue == currentlyLoadedFile {
                return
            }
            
            print("[DEBUG] handleFileFileSelectionChange (controller=\(ObjectIdentifier(self.editorController))) from \(currentlyLoadedFile?.lastPathComponent ?? "nil") to \(newValue?.lastPathComponent ?? "nil"), hasUnsavedChanges=\(self.editorController.hasUnsavedChanges)")
            
            // 4. Check for unsaved changes in the file we are leaving
            if self.editorController.hasUnsavedChanges, let prev = currentlyLoadedFile {
                if let appDelegate = AppDelegate.shared {
                    if !appDelegate.showSaveWarningIfNeeded(for: prev) {
                        // User cancelled switch - revert selection
                        print("[DEBUG] handleFileFileSelectionChange: Reverting selection to \(prev.lastPathComponent)")
                        self.isInternalSelectionChange = true
                        self.selectedFile = prev
                        return
                    }
                } else {
                    print("[ERROR] handleFileFileSelectionChange: AppDelegate.shared is nil!")
                }
            }
            
            // 5. Proceed with loading the new file
            self.loadFile(url: newValue)
        }
    }
    
    private func handleSnippetInsertion(notification: Notification) {
        if let snippetKey = notification.object as? String {
            switch snippetKey {
            case "table": editorController.insertTableSnippet()
            case "image": editorController.insertImageSnippet()
            case "chart": editorController.insertChartSnippet()
            case "equation": editorController.openNewEquationEditor()
            case "timeline": editorController.insertTimelineSnippet()
            default: break
            }
        }
    }
    
    // MARK: - Helper Methods
    
    func loadFile(url: URL?) {
        guard let url = url else { return }
        let loadID = UUID()
        self.currentLoadID = loadID
        
        // 1. Clear previous state to avoid stale previews and conflicts
        self.currentPDFURL = nil
        self.reloadToken = UUID()
        
        // 2. Update truth immediately so UI identifies the file type
        self.editorController.currentFileURL = url
        self.exportedPDFURL = url.deletingPathExtension().appendingPathExtension("pdf")
        RecentFilesManager.shared.add(url: url)
        
        let isTextual = editorController.currentFileType.isTextual
        if !isTextual {
            print("[DEBUG] loadFile: binary file detected, skipping string read: \(url.lastPathComponent)")
            self.sourceCode = ""
            self.editorController.syncSavedContent("")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                DispatchQueue.main.async {
                    print("[DEBUG] loadFile completion: currentLoadID=\(self.currentLoadID == loadID), url=\(url.lastPathComponent)")
                    guard self.currentLoadID == loadID else { return }
                    
                    self.editorController.syncSavedContent(content)
                    self.sourceCode = content
                    
                    scheduleCompilation(with: content)
                    print("[INFO] Successfully loaded file into editor: \(url.lastPathComponent)")
                }
            } catch {
                print("[ERROR] Failed to read file \(url.path): \(error)")
                DispatchQueue.main.async {
                    guard self.currentLoadID == loadID else { return }
                    if (try? url.checkResourceIsReachable()) != true {
                        editorController.missingFileName = url.lastPathComponent
                        editorController.showFileNotFoundAlert = true
                        RecentFilesManager.shared.remove(url: url)
                        if self.selectedFile == url { self.selectedFile = nil }
                    }
                }
            }
        }
    }
    
    func saveFile(to url: URL? = nil) {
        let targetURL = url ?? selectedFile
        guard let url = targetURL else { return }
        
        do {
            try sourceCode.write(to: url, atomically: true, encoding: .utf8)
            RecentFilesManager.shared.add(url: url)
            DispatchQueue.main.async {
                if url == self.selectedFile {
                    self.editorController.syncSavedContent(self.sourceCode)
                    self.scheduleCompilation(with: self.sourceCode)
                    self.lastSaved = Date()
                    withAnimation { self.showSavePopup = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { self.showSavePopup = false }
                    }
                } else {
                    print("[INFO] Background file saved: \(url.lastPathComponent)")
                }
            }
        } catch {
            print("[ERROR] Failed to save file \(url.lastPathComponent): \(error)")
        }
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
                        if let root = editorController.projectRootURL, dest.path.hasPrefix(root.path) {
                            fileSystem.loadFiles()
                        }
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
        let workingDirectory = sourceURL.deletingLastPathComponent()
        let filename = sourceURL.lastPathComponent
        let shadowPDFURL = workingDirectory.appendingPathComponent(".\(filename).preview.pdf")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if FileManager.default.fileExists(atPath: shadowPDFURL.path) {
                do {
                    if FileManager.default.fileExists(atPath: pdfDestination.path) {
                        try FileManager.default.removeItem(at: pdfDestination)
                    }
                    try FileManager.default.copyItem(at: shadowPDFURL, to: pdfDestination)
                    self.exportedPDFURL = pdfDestination
                } catch {
                    print("[ERROR] Failed to export PDF: \(error)")
                }
            }
        }
    }
    
    func printPDF() {
        guard let url = currentPDFURL, let document = PDFDocument(url: url) else { return }
        let printInfo = NSPrintInfo.shared
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        let op = document.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true)
        op?.run()
    }
    
    func scheduleCompilation(with content: String? = nil) {
        guard let url = selectedFile, editorController.isTypstFile else { 
            compiler.cleanUp()
            currentPDFURL = nil
            return 
        }
        workItem?.cancel()
        let currentSource = content ?? sourceCode
        let isDark = editorController.isPreviewDarkMode
        let newWorkItem = DispatchWorkItem {
            Task {
                compiler.isDarkMode = isDark
                await compiler.updateContent(source: currentSource, fileURL: url)
            }
        }
        workItem = newWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: newWorkItem)
    }
    
    @MainActor
    func handleBackup() {
        guard let root = fileSystem.currentFolder else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(root.lastPathComponent)_backup.zip"
        if panel.runModal() == .OK, let dest = panel.url {
            Task {
                if await fileSystem.createBackup(to: dest) {
                    NSWorkspace.shared.open(dest.deletingLastPathComponent())
                } else {
                    editorController.lastExportError = "Failed to create project backup."
                    editorController.showExportErrorAlert = true
                }
            }
        }
    }
    
    @MainActor
    func handleMenuCommand(_ command: String) {
        switch command {
        case "newFile": fileSystem.createNewFile()
        case "uploadFile": fileSystem.importFile()
        case "renameFile":
            if let url = selectedFile {
                self.renameTargetURL = url
                self.newFileName = url.lastPathComponent
                self.showRenameAlert = true
            }
        case "quickExportPDF": if let url = selectedFile { exportPDF(from: url) }
        case "exportPDF": handleExport(format: "pdf")
        case "exportPNG": handleExport(format: "png")
        case "exportSVG": handleExport(format: "svg")
        case "undo": editorController.undo()
        case "redo": editorController.redo()
        case "goToLine": editorController.showGoToLineAlert = true
        case "selectAll": editorController.selectAll()
        case "toggleLineComment": editorController.toggleLineComment()
        case "toggleBlockComment": editorController.toggleBlockComment()
        case "toggleHighlight": editorController.toggleHighlight()
        case "toggleStrike": editorController.toggleStrike()
        case "toggleLink": editorController.toggleLink()
        case "toggleQuote": editorController.toggleQuote()
        case "toggleCodeBlock": editorController.toggleCodeBlock()
        case "toggleSubscript": editorController.toggleSubscript()
        case "toggleSuperscript": editorController.toggleSuperscript()
        case "insertFootnote": editorController.insertFootnote()
        case "insertBibliography": editorController.toggleBibliography()
        case "showHelp": editorController.showHelp = true
        case "insertPageBreak": editorController.insertPageBreak()
        case "insertHorizontalLine": editorController.insertHorizontalLine()
        case "toggleSidebar": withAnimation { editorController.isSidebarVisible.toggle() }
        case "viewEditorOnly": withAnimation { editorController.viewMode = .editorOnly }
        case "viewPreviewOnly": withAnimation { editorController.viewMode = .previewOnly }
        case "viewBothPanels": withAnimation { editorController.viewMode = .both }
        case "splitVertical": withAnimation { editorController.isVerticalSplit = true }
        case "splitHorizontal": withAnimation { editorController.isVerticalSplit = false }
        case "zoomIn": editorController.zoomIn()
        case "zoomOut": editorController.zoomOut()
        default: break
        }
    }
}
