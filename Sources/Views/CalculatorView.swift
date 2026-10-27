import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Calculator panel: a TI-89 home screen inside TypstEdit. Menu-row
/// templates on top, scrolling history in the middle (input left, typeset
/// result right), a monospace entry line at the bottom, and a status strip
/// showing RAD/DEG and AUTO/EXACT/APPROX.
struct CalculatorView: View {
    @ObservedObject var session: CalculatorSession
    @ObservedObject var editorController: EditorController
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var showOpenPanel = false
    @State private var showNewAlert = false
    @State private var showFunctionCatalog = false
    @State private var entryFocusTrigger = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            templateRow
            Divider()
            historyArea
            Divider()
            entryArea
            statusBar
        }
        .background(themeManager.mainBackground)
        .fileImporter(isPresented: $showOpenPanel,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                session.load(from: url)
            }
        }
        .sheet(isPresented: $showFunctionCatalog) {
            CalculatorFunctionCatalogView { guide in
                if guide.category == .documents {
                    // Typst-side helpers (#calc, plot, BesselJ…) are document
                    // code, not calculator input: put them at the cursor when a
                    // Typst-capable file is open, else hand them over via the
                    // clipboard.
                    if editorController.isTypstFile {
                        editorController.insertText(guide.example)
                        session.lastStatus = "Inserted into document"
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(guide.example, forType: .string)
                        session.lastStatus = "Copied to clipboard"
                    }
                } else {
                    // Replace the entry line with the chosen example, ready to
                    // edit or evaluate, like picking a catalogue item on the
                    // TI-89.
                    session.entryLine = guide.example
                    entryFocusTrigger = UUID()
                }
            }
            .environmentObject(themeManager)
        }
        .alert("Start a new calculation?", isPresented: $showNewAlert) {
            Button("New Session", role: .destructive) { session.newSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(session.hasUnsavedChanges
                 ? "The current history and stored variables will be cleared."
                 : "History and stored variables will be cleared.")
        }
        .onAppear { entryFocusTrigger = UUID() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "function")
                .foregroundColor(.accentColor)
            // Hide the title as the panel narrows rather than letting it
            // wrap vertically (same treatment as the sidebar folder name).
            // The icon buttons keep their room throughout, and the title
            // stays available as a tooltip.
            ViewThatFits(in: .horizontal) {
                Text("CALCULATOR")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundColor(themeManager.textColor.opacity(0.6))
                Color.clear
                    .frame(width: 0, height: 0)
            }
            .help("CALCULATOR")
            if session.hasUnsavedChanges {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
            Spacer()
            Button {
                showNewAlert = true
            } label: {
                Image(systemName: "plus.square")
            }
            .buttonStyle(.plain)
            .help("New session")

            Button {
                showOpenPanel = true
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Open .tcalc session")

            Button {
                if session.documentURL != nil {
                    try? session.save(to: session.documentURL!)
                } else {
                    saveSessionAs()
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .help("Save session")

            Menu {
                Button("Save As…") { saveSessionAs() }
                Button("Export as .typ…") { exportTypst() }
                Divider()
                Button("Function Catalog…") { showFunctionCatalog = true }
                Divider()
                Menu("Forget stored variable") {
                    if session.storedVariables.isEmpty {
                        Text("None stored")
                    }
                    ForEach(session.storedVariables, id: \.name) { variable in
                        Button("\(variable.name) = \(variable.value)") {
                            session.deleteVariable(name: variable.name)
                        }
                    }
                }
                if !session.documentParameters.isEmpty {
                    Divider()
                    Menu("Document parameters") {
                        Text("From the open document (calc-param)")
                        ForEach(session.documentParameters, id: \.name) { parameter in
                            Button("\(parameter.name) = \(parameter.value)") {
                                session.entryLine = parameter.value
                                entryFocusTrigger = UUID()
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More session actions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Template row (the TI-89's F-row menus)

    private var templateRow: some View {
        HStack(spacing: 6) {
            templateMenu("F2 Algebra", items: TICommands.algebra)
            templateMenu("F3 Calc", items: TICommands.calculus)
            templateMenu("F4 Other", items: TICommands.other)
            Spacer(minLength: 0)
            Button {
                showFunctionCatalog = true
            } label: {
                Image(systemName: "book.pages")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.textColor.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Function catalog")
            modeMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func templateMenu(_ label: String, items: [TICommand]) -> some View {
        Menu {
            ForEach(items) { item in
                Button(item.label) { insertTemplate(item.template, at: item.cursorOffset) }
            }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(5)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var modeMenu: some View {
        Menu {
            Picker("Angle", selection: $session.angle) {
                ForEach(CASAngleMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            Picker("Exact", selection: $session.exactMode) {
                ForEach(CASExactMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            Divider()
            Picker("Digits", selection: $session.displayDigits) {
                ForEach([6, 9, 12, 15], id: \.self) { n in
                    Text("\(n)").tag(n)
                }
            }
        } label: {
            Text("MODE")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(5)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Puts template text on the entry line and moves the caret inside it,
    /// like picking a TI-89 menu item. A template of `__catalog__` opens the
    /// function catalogue instead.
    private func insertTemplate(_ template: String, at cursorOffset: Int) {
        guard template != "__catalog__" else {
            showFunctionCatalog = true
            return
        }
        let base = session.entryLine
        session.entryLine = base + template
        entryFocusTrigger = UUID()
        pendingCursorOffset = cursorOffset
    }

    @State private var pendingCursorOffset: Int?

    // MARK: - History

    private var historyArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if session.entries.isEmpty {
                        emptyHistory
                    }
                    // Entries are appended in chronological order. Keep
                    // the latest calculation at the bottom, near the input.
                    ForEach(Array(session.entries.enumerated()), id: \.element.id) { index, entry in
                        historyRow(entry, index: index)
                            .id(entry.id)
                        Divider().opacity(0.4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .task(id: session.entries.last?.id) {
                guard let last = session.entries.last else { return }
                // Give SwiftUI a layout pass before scrolling to the newly
                // appended row. Also show the end when reopening the panel
                // or loading a session with the same number of entries.
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var emptyHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type an expression below, or pick a template.")
                .foregroundColor(themeManager.textColor.opacity(0.55))
            Text("Try: solve(x^2-4=0,x)   d(x^3,x)   ∫(x^2,x,0,1)   5→a")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(themeManager.textColor.opacity(0.45))
        }
        .padding(.top, 32)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func historyRow(_ entry: CalculatorEntry, index: Int) -> some View {
        let isSelected = session.recallIndex != nil
            && session.entries.count - 1 - (session.recallIndex ?? 0) == index
        return HStack(alignment: .top, spacing: 12) {
            Text(entry.input)
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(themeManager.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            resultView(entry)
                .frame(maxWidth: 320, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu { entryContextMenu(entry) }
        .onTapGesture {
            session.recallIndex = session.entries.count - 1 - index
        }
    }

    @ViewBuilder
    private func resultView(_ entry: CalculatorEntry) -> some View {
        if entry.isError {
            Text(entry.errorMessage)
                .font(.caption)
                .foregroundColor(.red)
                .frame(maxWidth: 320, alignment: .trailing)
        } else if entry.resultTypst.isEmpty {
            Text(entry.resultPlain)
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(themeManager.textColor)
                .frame(maxWidth: 320, alignment: .trailing)
        } else {
            MathImageView(typst: entry.resultTypst, dark: colorScheme == .dark)
                .frame(maxHeight: 120)
        }
    }

    // MARK: - Entry line

    private var entryArea: some View {
        HStack(spacing: 8) {
            if session.busy {
                ProgressView()
                    .scaleEffect(0.7)
                Button {
                    session.interrupt()
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Stop this calculation (Esc also stops it)")
            }
            TIEntryField(
                text: $session.entryLine,
                focusTrigger: entryFocusTrigger,
                pendingCursorOffset: $pendingCursorOffset,
                onSubmit: { forceApprox in
                    Task { await session.submit(session.entryLine, forceApprox: forceApprox) }
                },
                onArrowUp: {
                    if let recalled = session.moveRecall(-1) {
                        session.entryLine = recalled
                    }
                },
                onArrowDown: {
                    if let recalled = session.moveRecall(1) {
                        session.entryLine = recalled
                    } else {
                        session.entryLine = ""
                    }
                },
                onEscape: {
                    if session.busy {
                        session.interrupt()
                    } else {
                        session.entryLine = ""
                        session.recallIndex = nil
                    }
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(session.statusText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(themeManager.textColor.opacity(0.55))
            Spacer()
            if let status = session.lastStatus {
                Text(status)
                    .font(.caption2)
                    .foregroundColor(themeManager.textColor.opacity(0.55))
            }
            if !CASEngine.isAvailable {
                Label("CAS helper missing — run Tools/cas/build_cas.sh", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .help("The calculator needs build/cas/typstedit-cas. See Tools/cas/README.md.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Right-click menu

    @ViewBuilder
    private func entryContextMenu(_ entry: CalculatorEntry) -> some View {
        // Insertions target the current document; only Typst-capable files
        // (or a fresh untitled document) can receive them.
        let currentURL = editorController.currentFileURL
        let canInsert: Bool = {
            guard let ext = currentURL?.pathExtension.lowercased(), !ext.isEmpty else { return true }
            return ext == "typ" || ext == "note"
        }()

        Section("Insert into document") {
            Button("Inline equation  $…$") {
                insertIntoDocument(CalculatorSession.inlineEquation(entry.resultTypst))
            }
            .disabled(!canInsert || entry.isError)
            Button("Block equation  $ … $") {
                insertIntoDocument(CalculatorSession.blockEquation(entry.resultTypst))
            }
            .disabled(!canInsert || entry.isError)
            Button("Input = Result") {
                insertIntoDocument(CalculatorSession.inputEqualsResult(entry))
            }
            .disabled(!canInsert || entry.isError)
        }
        Section("Copy") {
            Button("Copy as Typst") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.resultTypst, forType: .string)
            }
            .disabled(entry.resultTypst.isEmpty)
            Button("Copy as plain text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.resultPlain, forType: .string)
            }
            .disabled(entry.resultPlain.isEmpty)
        }
        Section {
            Button("Reuse in entry line") {
                session.entryLine = entry.input
                entryFocusTrigger = UUID()
            }
            Button("Delete entry", role: .destructive) {
                session.deleteEntry(id: entry.id)
            }
        }
    }

    private func insertIntoDocument(_ text: String) {
        editorController.insertText(text)
    }

    // MARK: - Save / export panels

    /// Runs a save panel and hands the chosen URL back.
    private func chooseSaveURL(nameFieldLabel: String,
                               message: String,
                               extension ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldLabel = nameFieldLabel
        panel.message = message
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        if let projectRoot = editorController.projectRootURL {
            panel.directoryURL = projectRoot
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if url.pathExtension.lowercased() != ext {
            return url.appendingPathExtension(ext)
        }
        return url
    }

    private func saveSessionAs() {
        guard let url = chooseSaveURL(
            nameFieldLabel: "Save calculation",
            message: "Sessions are saved as .tcalc files in your project.",
            extension: CalculatorDocument.fileExtension) else { return }
        do {
            try session.save(to: url)
        } catch {
            session.lastStatus = "Could not save: \(error.localizedDescription)"
        }
    }

    private func exportTypst() {
        guard let url = chooseSaveURL(
            nameFieldLabel: "Export as Typst",
            message: "Exports the history as display equations.",
            extension: "typ") else { return }
        do {
            try session.exportTypst().write(to: url, atomically: true, encoding: .utf8)
            session.lastStatus = "Exported \(url.lastPathComponent)"
        } catch {
            session.lastStatus = "Could not export: \(error.localizedDescription)"
        }
    }
}

// MARK: - Typeset result image

/// Displays one compiled math snippet, falling back to plain text while
/// compiling (or if the bundled typst can't compile the snippet).
struct MathImageView: View {
    let typst: String
    let dark: Bool

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320)
            } else if failed {
                Text(typst)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: 320, alignment: .trailing)
            } else {
                // Snippet briefly while the SVG compiles.
                Text(typst)
                    .font(.system(.callout, design: .monospaced))
                    .opacity(0.55)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
        }
        .task(id: "\(typst)|\(dark)") {
            image = nil
            failed = false
            if let rendered = await CASMathRenderer.shared.image(typst: typst, dark: dark) {
                image = rendered
            } else {
                failed = true
            }
        }
    }
}

// MARK: - TI-89 menu contents

/// One item of the F2/F3/F4 template rows: label + the text placed on the
/// entry line + where the caret lands inside it.
struct TICommand: Identifiable {
    let label: String
    let template: String
    let cursorOffset: Int
    var id: String { label }

    init(_ label: String, _ template: String, caretOffset: Int? = nil) {
        self.label = label
        self.template = template
        self.cursorOffset = caretOffset ?? template.count
    }
}

enum TICommands {
    static let algebra: [TICommand] = [
        TICommand("solve(", "solve(", caretOffset: 6),
        TICommand("cSolve(", "cSolve(", caretOffset: 7),
        TICommand("zeros(", "zeros(", caretOffset: 6),
        TICommand("factor(", "factor(", caretOffset: 7),
        TICommand("expand(", "expand(", caretOffset: 7),
        TICommand("comDenom(", "comDenom(", caretOffset: 9),
        TICommand("propFrac(", "propFrac(", caretOffset: 9),
        TICommand("tExpand(", "tExpand(", caretOffset: 8),
    ]

    static let calculus: [TICommand] = [
        TICommand("d( differentiate", "d(", caretOffset: 2),
        TICommand("∫( integrate", "∫(", caretOffset: 2),
        TICommand("∫ definite", "∫(x^2, x, 0, 1)", caretOffset: 2),
        TICommand("limit(", "limit(", caretOffset: 6),
        TICommand("Σ( sum", "Σ(", caretOffset: 2),
        TICommand("Π( product", "Π(", caretOffset: 2),
        TICommand("taylor(", "taylor(", caretOffset: 7),
        TICommand("nDeriv(", "nDeriv(", caretOffset: 7),
    ]

    static let other: [TICommand] = [
        TICommand("Browse all functions…", "__catalog__", caretOffset: 0),
        TICommand("2×2 matrix", "[[1,2][3,4]]", caretOffset: 2),
        TICommand("det( determinant", "det(", caretOffset: 4),
        TICommand("transpose(", "transpose(", caretOffset: 10),
        TICommand("rref( row reduction", "rref(", caretOffset: 5),
        TICommand("define f(x)=", "define f(x)=", caretOffset: 12),
        TICommand("5→a  (store)", "5→", caretOffset: 2),
        TICommand("|  with", " | ", caretOffset: 2),
        TICommand("approx(", "approx(", caretOffset: 7),
        TICommand("abs(", "abs(", caretOffset: 4),
        TICommand("√(", "√(", caretOffset: 2),
        TICommand("delVar(", "delVar(", caretOffset: 7),
    ]
}

// MARK: - Entry line (NSTextField)

/// The monospace entry line with TI-89 key handling:
/// ↩ evaluates (⌥↩ forces approximate), ↑/↓ walk the history,
/// Esc clears the line or stops a running calculation.
struct TIEntryField: NSViewRepresentable {
    @Binding var text: String
    let focusTrigger: UUID
    @Binding var pendingCursorOffset: Int?
    let onSubmit: (_ forceApprox: Bool) -> Void
    let onArrowUp: () -> Void
    let onArrowDown: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        if let offset = pendingCursorOffset {
            pendingCursorOffset = nil
            let clamped = min(offset, (text as NSString).length)
            DispatchQueue.main.async {
                field.becomeFirstResponder()
                if let editor = field.currentEditor() {
                    editor.selectedRange = NSRange(location: clamped, length: 0)
                }
            }
        }
        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async {
                field.becomeFirstResponder()
                if let editor = field.currentEditor() {
                    editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TIEntryField
        var lastFocusTrigger: UUID?

        init(_ parent: TIEntryField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        @objc func submit(_ sender: NSTextField) {
            // ⌥↩ mirrors the TI-89's ◆ENTER (approximate result).
            let forceApprox = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
            parent.onSubmit(forceApprox)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onArrowUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onArrowDown()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}
