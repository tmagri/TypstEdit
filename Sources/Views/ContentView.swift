import SwiftUI
import Combine
import UniformTypeIdentifiers

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
    @EnvironmentObject var themeManager: ThemeManager
    
    // MARK: - Computed Properties for UI Components
    
    private var editorBox: some View {
        ZStack {
            themeManager.editorBackground
            
            VStack(spacing: 0) {
                // Formatting Toolbar above editor
                HStack {
                    ToolbarView(controller: editorController)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.1))
               
                // Editor
                EditorView(text: $sourceCode, controller: editorController, onCommit: {
                    scheduleCompilation()
                })
                .environmentObject(themeManager)
                .padding(8)
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
                    .frame(width: 900, height: 500) // Improved size for wider equations and better fit
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
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        .cornerRadius(12)
        .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
        .padding(.vertical, 12)
    }
    
    var body: some View {
        ZStack {
            // Main Background with Visual Effect
            VisualEffectView(
                material: .hudWindow,
                blendingMode: .withinWindow,
                state: .active,
                emphasized: false
            )
            .ignoresSafeArea()
            
            themeManager.mainBackground.ignoresSafeArea() // Should be .clear
            
            if fileSystem.currentFolder == nil {
                WelcomeView(model: fileSystem, onOpen: { url in
                    self.selectedFile = url
                    let folder = url.deletingLastPathComponent()
                    fileSystem.currentFolder = folder
                    fileSystem.loadFiles()
                })
                .background(themeManager.mainBackground)
            } else {
                // Unified HSplitView for Transparency
                HSplitView {
                    // LEFT: Sidebar (starts minimized)
                    if editorController.isSidebarVisible {
                        SidebarView(model: fileSystem, selectedFile: $selectedFile, editorController: editorController)
                            .onChange(of: fileSystem.currentFolder) { newFolder in
                                editorController.projectRootURL = newFolder
                            }
                            .onChange(of: selectedFile) { newFile in
                                editorController.currentFileURL = newFile
                            }
                            .onAppear {
                                editorController.projectRootURL = fileSystem.currentFolder
                                editorController.currentFileURL = selectedFile
                            }
                            .frame(minWidth: 200, idealWidth: 200, maxWidth: 400)
                    }
                    
                    // RIGHT: Main Content (Editor + PDF)
                    if selectedFile != nil {
                         ZStack {
                            themeManager.contentOverlay.ignoresSafeArea() 
                            themeManager.mainBackground.ignoresSafeArea() // .clear
                            
                            if editorController.viewMode == .editorOnly {
                                editorBox
                                    .padding(.leading, 12)
                                    .padding(.trailing, 12)
                            } else if editorController.viewMode == .previewOnly {
                                ZStack {
                                    themeManager.pdfBackground
                                    PreviewView(url: currentPDFURL, reloadToken: reloadToken, colorBlindnessMode: editorController.colorBlindnessMode)
                                        .padding(20)
                                }
                                .cornerRadius(12)
                                .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
                                .padding(12)
                            } else {
                                ResizableSplitView(initialWidth: 500, isVertical: editorController.isVerticalSplit) {
                                    // Left Pane: Integrated Ruler + Editor
                                    editorBox
                                        .padding(.leading, 12)
                                } right: {
                                    // PDF Preview Area with Shadow Box
                                    ZStack {
                                        themeManager.pdfBackground
                                        
                                        PreviewView(url: currentPDFURL, reloadToken: reloadToken, colorBlindnessMode: editorController.colorBlindnessMode)
                                            .padding(20)
                                    }
                                    .cornerRadius(12)
                                    .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
                                    .padding(.vertical, 12)
                                    .padding(.leading, 0) // Remove padding as handle provides spacing
                                    .padding(.trailing, 12) // Keep trailing padding for window edge
                                }
                            }
                        }
                        .layoutPriority(1)
                    } else {
                        // Empty state when no file selected but folder open
                         ZStack {
                            themeManager.contentOverlay.ignoresSafeArea()
                            Text("Select a file")
                                .foregroundColor(themeManager.textColor)
                         }
                         .frame(maxWidth: .infinity, maxHeight: .infinity)
                         .layoutPriority(1)
                    }
                }
                // Toolbar attached to the main split view
                .toolbar {
                    // Undo/Redo on the left
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
                        Text(selectedFile?.lastPathComponent ?? "")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(themeManager.textColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(8)
                    }
                    
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 8) {
                            
                            // Search Bar with Popup
                            if editorController.isSearchVisible {
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
                                
                                // Search results popup (appears when there are matches)
                                if !editorController.searchQuery.isEmpty && editorController.matchCount > 0 {
                                    HStack(spacing: 8) {
                                        // Match counter
                                        Text("\(editorController.currentMatchIndex + 1) of \(editorController.matchCount)")
                                            .font(.caption)
                                            .foregroundColor(themeManager.secondaryTextColor)
                                        
                                        Divider()
                                            .frame(height: 12)
                                        
                                        // Previous match button
                                        Button(action: { editorController.previousMatch() }) {
                                            Image(systemName: "chevron.up")
                                                .font(.system(size: 10))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Previous")
                                        
                                        // Next match button
                                        Button(action: { editorController.nextMatch() }) {
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 10))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Next")
                                        
                                        Divider()
                                            .frame(height: 12)
                                        
                                        // Done button
                                        Button(action: { 
                                            editorController.searchQuery = ""
                                            editorController.clearSearch()
                                        }) {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 10))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Done")
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(Color.black.opacity(0.3))
                                    .cornerRadius(6)
                                    .offset(y: 2)
                                }
                            }
                            }
                            
                            // Divider
Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 1, height: 16)
                            
                            // Actions: Save, Print, Share
                            HStack(spacing: 8) {
                                Button(action: saveFile) {
                                    Image(systemName: "square.and.arrow.down")
                                        .foregroundColor(themeManager.textColor)
                                        .padding(6)
                                        .background(Color.black.opacity(0.3))
                                        .cornerRadius(8)
                                }
                                .help("Save (Cmd+S)")
                                .keyboardShortcut("s", modifiers: .command)
                                .buttonStyle(.plain)
                                
                                // Print Button
                                Button(action: printPDF) {
                                    Image(systemName: "printer")
                                        .foregroundColor(themeManager.textColor)
                                        .padding(6)
                                        .background(Color.black.opacity(0.3))
                                        .cornerRadius(8)
                                }
                                .help("Print")
                                .buttonStyle(.plain)
                                
                                // Share Button (Native Anchor)
                                ShareButton(fileURL: exportedPDFURL)
                                    .frame(width: 28, height: 28)
                                    .padding(4)
                                    .background(Color.black.opacity(0.3))
                                    .cornerRadius(8)
                                    .help("Share")
                            }
                            
                            // Save Status & Finder
                            if let lastSaved = lastSaved {
                                Text("Last saved: \(lastSaved.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                        }
                    }
                }
                // Important: Hide explicit window toolbar background to use our transparency
                .toolbarBackground(.hidden, for: .windowToolbar)
                .onChange(of: compiler.errors) { newErrors in
                    editorController.errors = newErrors
                    editorController.needsRedraw()
                    // Broadcast errors to sidebar
                    NotificationCenter.default.post(name: .typstErrorsUpdated, object: newErrors)
                }
            }
            
            // Save Popup
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
        .onChange(of: selectedFile) { newValue in
            loadFile(url: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .insertSnippet)) { notification in
            if let snippetKey = notification.object as? String {
                switch snippetKey {
                case "table":
                    editorController.insertTableSnippet()
                case "image":
                    editorController.insertImageSnippet()
                case "chart":
                    editorController.insertChartSnippet()
                case "equation":
                    editorController.openNewEquationEditor()
                case "timeline":
                    editorController.insertTimelineSnippet()
                default:
                    break
                }
            }
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
                
                // Auto-export PDF to project directory when preview updates
                if let selectedFile = selectedFile {
                    exportPDF(from: selectedFile)
                }
            }
        }

        .preferredColorScheme(.dark)
    }
    
    func loadFile(url: URL?) {
        guard let url = url else { return }
        do {
            self.sourceCode = try String(contentsOf: url, encoding: .utf8)
            // Set exported PDF URL based on file path
            self.exportedPDFURL = url.deletingPathExtension().appendingPathExtension("pdf")
            // Add to recents
            RecentFilesManager.shared.add(url: url)
            // Trigger watch
            scheduleCompilation()
        } catch {
            print("Failed to read file: \(error)")
        }
    }
    
    func saveFile() {
        guard let url = selectedFile else { return }
        do {
            // Save .typ file
            try sourceCode.write(to: url, atomically: true, encoding: .utf8)
            RecentFilesManager.shared.add(url: url)
            
            // Trigger compilation to generate PDF
            scheduleCompilation()
            
            // UI Feedback
            lastSaved = Date()
            withAnimation {
                showSavePopup = true
            }
            // Hide after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    showSavePopup = false
                }
            }
        } catch {
            print("Error saving: \(error)")
        }
    }
    
    func exportPDF(from sourceURL: URL) {
        let pdfDestination = sourceURL.deletingPathExtension().appendingPathExtension("pdf")
        let workingDirectory = sourceURL.deletingLastPathComponent()
        let filename = sourceURL.lastPathComponent
        let shadowPDFURL = workingDirectory.appendingPathComponent(".\(filename).preview.pdf")
        
        // Export happens after a short delay to ensure compilation is complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if FileManager.default.fileExists(atPath: shadowPDFURL.path) {
                do {
                    // Remove old PDF if exists
                    if FileManager.default.fileExists(atPath: pdfDestination.path) {
                        try FileManager.default.removeItem(at: pdfDestination)
                    }
                    // Copy preview PDF to final destination
                    try FileManager.default.copyItem(at: shadowPDFURL, to: pdfDestination)
                    print("[INFO] PDF exported to: \(pdfDestination.path)")
                    // Update exported PDF URL for sharing
                    self.exportedPDFURL = pdfDestination
                } catch {
                    print("[ERROR] Failed to export PDF: \(error)")
                }
            }
        }
    }
    
    func printPDF() {
        print("[DEBUG] printPDF called")
        print("[DEBUG] currentPDFURL: \(String(describing: currentPDFURL))")
        
        guard let url = currentPDFURL else {
            print("[ERROR] printPDF: currentPDFURL is nil")
            return
        }
        
        guard let document = PDFDocument(url: url) else {
            print("[ERROR] printPDF: Failed to load PDFDocument from URL: \(url)")
            return
        }
        
        print("[DEBUG] printPDF: PDF loaded successfully, page count: \(document.pageCount)")
        
        let printInfo = NSPrintInfo.shared
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        
        // Scale to fit logic is complex in code, but standard print op handles typical cases
        let op = document.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true)
        print("[DEBUG] printPDF: Running print operation")
        op?.run()
    }
    
    func sharePDF() {
        guard let url = currentPDFURL else { return }
        let picker = NSSharingServicePicker(items: [url])
        // Need a view to attach to. For now, try standard view.
        // In SwiftUI, we need to bridge to AppKit view.
        // Simplest way: dispatch to main and find key window's content view.
        
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow, let contentView = window.contentView else { return }
            picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
    }

    func scheduleCompilation() {
        guard let url = selectedFile else { return }
        
        workItem?.cancel()
        let currentSource = sourceCode
        let fileURL = url
        
        let newWorkItem = DispatchWorkItem {
            Task {
                await compiler.updateContent(source: currentSource, fileURL: fileURL)
            }
        }
        workItem = newWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: newWorkItem)
    }
    
    func handleBackup() {
        guard let root = fileSystem.currentFolder else { return }
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(root.lastPathComponent)_backup.zip"
        panel.title = "Backup Project"
        panel.message = "Choose a location to save your project backup."
        
        if panel.runModal() == .OK, let dest = panel.url {
            Task {
                let success = await fileSystem.createBackup(to: dest)
                if success {
                    NSWorkspace.shared.open(dest.deletingLastPathComponent())
                } else {
                    editorController.lastExportError = "Failed to create project backup."
                    editorController.showExportErrorAlert = true
                }
            }
        }
    }
    
    func handleMenuCommand(_ command: String) {
        switch command {
        case "newFile":
            fileSystem.createNewFile()
        case "uploadFile":
            fileSystem.importFile()
        case "renameFile":
            if let url = selectedFile {
                self.renameTargetURL = url
                self.newFileName = url.lastPathComponent
                self.showRenameAlert = true
            }
        case "exportPDF":
            if let url = selectedFile { exportPDF(from: url) }
        case "exportPNG":
            handleExport(format: "png")
        case "exportSVG":
            handleExport(format: "svg")
        case "undo":
            editorController.undo()
        case "redo":
            editorController.redo()
        case "toggleSearch":
            // Focus search field?
            break
        case "goToLine":
            editorController.showGoToLineAlert = true
        case "selectAll":
            editorController.selectAll()
        case "toggleLineComment":
            editorController.toggleLineComment()
        case "toggleBlockComment":
            editorController.toggleBlockComment()
        case "toggleHighlight":
            editorController.toggleHighlight()
        case "toggleStrike":
            editorController.toggleStrike()
        case "toggleLink":
            editorController.toggleLink()
        case "toggleQuote":
            editorController.toggleQuote()
        case "toggleCodeBlock":
            editorController.toggleCodeBlock()
        case "insertPageBreak":
            editorController.insertPageBreak()
        case "insertHorizontalLine":
            editorController.insertHorizontalLine()
        case "toggleSidebar":
            withAnimation { editorController.isSidebarVisible.toggle() }
        case "showSettings":
            // Notification or direct show
            break
        case "viewEditorOnly":
            withAnimation { editorController.viewMode = .editorOnly }
        case "viewPreviewOnly":
            withAnimation { editorController.viewMode = .previewOnly }
        case "viewBothPanels":
            withAnimation { editorController.viewMode = .both }
        case "splitVertical":
            withAnimation { editorController.isVerticalSplit = true }
        case "splitHorizontal":
            withAnimation { editorController.isVerticalSplit = false }
        case "zoomIn":
            editorController.zoomIn()
        case "zoomOut":
            editorController.zoomOut()
        default:
            break
        }
    }
    
    func handleExport(format: String) {
        guard let url = selectedFile else { return }
        
        // Export naming recommendation for multi-page documents
        let suggestedName = url.deletingPathExtension().appendingPathExtension(format).lastPathComponent
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format)!]
        panel.nameFieldStringValue = suggestedName
        panel.message = "For multi-page \(format.uppercased()) export, you can use {p} in the filename (e.g. image-{p}.\(format))"
        
        if panel.runModal() == .OK, let dest = panel.url {
            Task {
                let result = await compiler.export(sourceURL: url, outputURL: dest, format: format, projectRoot: editorController.projectRootURL)
                if result.success {
                    NSWorkspace.shared.open(dest)
                    
                    // Refresh sidebar if destination is within project root
                    if let root = editorController.projectRootURL, dest.path.hasPrefix(root.path) {
                        NotificationCenter.default.post(name: .refreshProjectSidebar, object: nil)
                    }
                } else {
                    editorController.lastExportError = result.error ?? "Unknown error"
                    editorController.showExportErrorAlert = true
                }
            }
        }
    }
}
import PDFKit



extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
