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
    /// Observed so the status strip can show which model the AI fallback is
    /// using (and let the user switch it without opening Settings).
    @ObservedObject private var aiSettings = AISettingsManager.shared

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

    // MARK: - Template row

    /// One template menu: its name and its items.
    private struct TemplateGroup {
        let name: String
        let items: [TICommand]
    }

    private let templateGroups: [TemplateGroup] = [
        .init(name: "Algebra", items: TICommands.algebra),
        .init(name: "Calc", items: TICommands.calculus),
        .init(name: "Other", items: TICommands.other),
    ]

    // The row adapts as the panel narrows instead of overflowing. The menus
    // are fixed-size, so a single layout clips on both edges in a narrow
    // sidebar. Candidates are tried in order:
    //   1. all menus on one line
    //   2. two lines (templates above, controls below)
    //   3. one compact "ƒx" menu holding all three groups as submenus —
    //      small enough for the sidebar's 150pt minimum width.
    private var templateRow: some View {
        ViewThatFits(in: .horizontal) {
            oneLineTemplateRow
            twoLineTemplateRow
            compactTemplateRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var oneLineTemplateRow: some View {
        HStack(spacing: 6) {
            templateMenus
            Spacer(minLength: 0)
            catalogButton
            modeMenu
        }
    }

    private var twoLineTemplateRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                templateMenus
            }
            HStack(spacing: 6) {
                catalogButton
                modeMenu
                Spacer(minLength: 0)
            }
        }
    }

    /// Last resort for extreme widths: everything folds into a single menu,
    /// keeping the group names as submenu titles.
    private var compactTemplateRow: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(templateGroups, id: \.name) { group in
                    Menu(group.name) {
                        ForEach(group.items) { item in
                            Button(item.label) { insertTemplate(item.template, at: item.cursorOffset) }
                        }
                    }
                }
            } label: {
                pillLabel(Text("ƒx"))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Template menus")

            Spacer(minLength: 0)
            catalogButton
            modeMenu
        }
    }

    private var templateMenus: some View {
        ForEach(templateGroups, id: \.name) { group in
            templateMenu(group.name, items: group.items)
        }
    }

    private func templateMenu(_ label: String, items: [TICommand]) -> some View {
        Menu {
            ForEach(items) { item in
                Button(item.label) { insertTemplate(item.template, at: item.cursorOffset) }
            }
        } label: {
            pillLabel(Text(label))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// The shared pill background for the row's menu buttons.
    private func pillLabel(_ text: Text) -> some View {
        text
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(5)
    }

    private var catalogButton: some View {
        Button {
            showFunctionCatalog = true
        } label: {
            Image(systemName: "book.pages")
                .font(.system(size: 11))
                .foregroundColor(themeManager.textColor.opacity(0.7))
        }
        .buttonStyle(.plain)
        .help("Function catalog")
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
            pillLabel(Text("MODE"))
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
            Text("Try: solve(x^2-4=0,x)   d(x^3,x)   ∫(x^2,x,0,1)   plot(sin(x)/x, x, -5, 5)   5→a")
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
        if let plot = entry.plot {
            // Charts — typed `plot(…)` entries and AI-interpreted plot
            // requests alike — draw as a chart; an AI interpretation keeps
            // its badge and prose under the chart.
            let interpreted = entry.aiAnswer != nil
            VStack(alignment: .trailing, spacing: 4) {
                if interpreted {
                    Label("AI", systemImage: "sparkles")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
                PlotChartView(spec: plot, dark: colorScheme == .dark)
                    .frame(maxWidth: 320)
                    .frame(height: 172)
                    .help("Right-click to insert this chart into the document")
                if let answer = entry.aiAnswer, !answer.isEmpty {
                    AIAnswerView(text: answer,
                                 dark: colorScheme == .dark,
                                 font: .caption,
                                 isSecondary: true)
                }
            }
            .frame(maxWidth: 320, alignment: .trailing)
        } else if let answer = entry.aiAnswer, !answer.isEmpty {
            // AI-fallback entry: when the model's interpretation was
            // computable or provided a math equation, the typeset result
            // shows as math with the model's prose underneath; otherwise
            // the prose is the answer.
            let computed = !entry.resultTypst.isEmpty
            VStack(alignment: .trailing, spacing: 4) {
                Label("AI", systemImage: "sparkles")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.accentColor)
                if computed {
                    MathImageView(typst: entry.resultTypst, dark: colorScheme == .dark)
                        .frame(maxHeight: 120)
                }
                AIAnswerView(
                    text: answer,
                    dark: colorScheme == .dark,
                    font: computed ? .caption : .callout,
                    isSecondary: computed
                )
            }
            .frame(maxWidth: 320, alignment: .trailing)
        } else if entry.isError {
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

    /// NSTextView has no placeholder API; this sits over the container's
    /// inset and lets clicks fall through to the field. "— or ask a question"
    /// is only shown when the calculator's AI fallback is configured and active.
    private var isCalculatorAIActive: Bool {
        aiSettings.chatEnabled && aiSettings.calcAIFallbackEnabled && CalculatorAIFallback.isAvailable()
    }

    private var entryPlaceholder: String {
        isCalculatorAIActive
            ? "Enter an expression — or ask a question"
            : "Enter an expression"
    }

    // MARK: - Entry line

    /// Chat-style input bar: a framed multi-line entry box (like AI Chat's)
    /// with a send button, instead of the TI-89's thin strip. ↩ still
    /// evaluates, ⇧↩ starts a new line, ⌥↩ forces approximate, ↑/↓ recall
    /// history on single-line input, Esc clears or stops.
    private var entryArea: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TIEntryField(
                    text: $session.entryLine,
                    focusTrigger: entryFocusTrigger,
                    pendingCursorOffset: $pendingCursorOffset,
                    onSubmit: { forceApprox in
                        submitEntry(forceApprox: forceApprox)
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
                    .frame(height: 64)

                if session.entryLine.isEmpty {
                    // NSTextView has no placeholder; this sits over the
                    // text container's inset and lets clicks through.
                    Text(entryPlaceholder)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(themeManager.textColor.opacity(0.35))
                        .padding(.top, 2)
                        .padding(.leading, 1)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1))

            if session.busy {
                ProgressView()
                    .scaleEffect(0.7)
                Button {
                    session.interrupt()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Stop this calculation (Esc also stops it)")
            } else {
                Button {
                    submitEntry(forceApprox: false)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .disabled(session.entryLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Evaluate (↩). Hold ⌥↩ for an approximate result (◆Enter); ⇧↩ starts a new line.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func submitEntry(forceApprox: Bool) {
        Task { await session.submit(session.entryLine, forceApprox: forceApprox) }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(session.statusText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(themeManager.textColor.opacity(0.55))
            // Which model answers questions, when the fallback is on — the
            // menu switches it without a trip to Settings. Collapses to the
            // chip icon when the strip is too narrow for the model name.
            if aiSettings.chatEnabled && aiSettings.calcAIFallbackEnabled {
                ViewThatFits(in: .horizontal) {
                    AIModelPickerMenu(feature: .calculator, font: .caption2)
                    AIModelPickerMenu(feature: .calculator, font: .caption2, showsName: false)
                }
            }
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
        // (or a fresh untitled document) can receive them. Markdown files
        // accept the image form, which needs no calculator code.
        let currentURL = editorController.currentFileURL
        let canInsert: Bool = {
            guard let ext = currentURL?.pathExtension.lowercased(), !ext.isEmpty else { return true }
            return ext == "typ" || ext == "note"
        }()
        let canInsertImage = canInsert || editorController.isMarkdownFile

        if let plot = entry.plot {
            let callback = TIPlot.callbackCall(for: plot)
            Section("Insert into document") {
                Button("Chart with sampled points") {
                    insertIntoDocument(TIPlot.documentCall(for: plot))
                }
                .disabled(!canInsert)
                .help("The exact data the calculator sampled, drawn by the document's plot() — compiles everywhere")
                Button(callback == nil
                       ? "Chart as #plot code (uses points — a curve does not translate)"
                       : "Chart as #plot code (resamples in the document)") {
                    insertIntoDocument(TIPlot.callbackCall(for: plot)
                                       ?? TIPlot.documentCallPointsOnly(for: plot))
                }
                .disabled(!canInsert)
                .help(callback == nil
                      ? "A curve uses a name Typst cannot express — inserts the sampled points instead"
                      : "A #plot(…) call the document resamples itself; fails to compile if a curve has a pole inside the range")
                Button("Chart as image") {
                    insertPlotAsImage(plot)
                }
                .disabled(!canInsertImage)
                .help("Saves a PNG next to the document and inserts #image(…)")
            }
            Section("Copy") {
                Button("Copy chart as PNG") { copyPlotAsImage(plot) }
                Button("Copy as plain text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.resultPlain, forType: .string)
                }
                .disabled(entry.resultPlain.isEmpty)
                Button("Copy Typst #plot code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(TIPlot.documentCall(for: plot), forType: .string)
                }
            }
        } else {
            Section("Insert into document") {
                Button("Inline equation  $…$") {
                    insertIntoDocument(CalculatorSession.inlineEquation(entry.resultTypst))
                }
                .disabled(!canInsert || entry.isError || entry.resultTypst.isEmpty)
                Button("Block equation  $ … $") {
                    insertIntoDocument(CalculatorSession.blockEquation(entry.resultTypst))
                }
                .disabled(!canInsert || entry.isError || entry.resultTypst.isEmpty)
                Button("Input = Result") {
                    insertIntoDocument(CalculatorSession.inputEqualsResult(entry))
                }
                .disabled(!canInsert || entry.isError || entry.resultTypst.isEmpty || entry.inputTypst.isEmpty)
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
                Button("Copy AI answer") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.aiAnswer ?? "", forType: .string)
                }
                .disabled(entry.aiAnswer == nil)
            }
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

    /// Renders the chart as a PNG next to the open document and inserts an
    /// `#image(…)` reference — the one import path that works everywhere,
    /// including Markdown and stock Typst with no calculator at all.
    private func insertPlotAsImage(_ plot: CalculatorPlotSpec) {
        guard let data = PlotChartView.pngData(plot) else {
            session.lastStatus = "Could not render the chart image"
            return
        }
        let directory = editorController.currentFileURL?.deletingLastPathComponent()
            ?? editorController.projectRootURL
        guard let directory else {
            session.lastStatus = "No file or project open — cannot save the chart image"
            return
        }
        let fileName = "calculator_plot_\(Int(Date().timeIntervalSince1970)).png"
        let fileURL = directory.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL)
        } catch {
            session.lastStatus = "Could not save the chart image: \(error.localizedDescription)"
            return
        }
        // Saved next to the open file, so the bare name resolves both in the
        // live preview and in stock Typst.
        editorController.insertText("#image(\"\(fileName)\")")
        session.lastStatus = "Saved \(fileName) and inserted the image"
        NotificationCenter.default.post(
            name: .refreshProjectSidebar,
            object: editorController.projectRootURL ?? editorController.currentFileURL)
    }

    private func copyPlotAsImage(_ plot: CalculatorPlotSpec) {
        guard let data = PlotChartView.pngData(plot) else {
            session.lastStatus = "Could not render the chart image"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        session.lastStatus = "Chart copied as PNG"
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

/// Displays an AI response's prose answer, automatically typesetting any
/// inline equations ($...$) with Typst or falling back to native styled text.
struct AIAnswerView: View {
    let text: String
    let dark: Bool
    let font: Font
    let isSecondary: Bool
    @EnvironmentObject var themeManager: ThemeManager

    @State private var image: NSImage?
    @State private var renderFailed = false

    private var hasMathNotation: Bool {
        text.contains("$") || text.contains("\\(") || text.contains("\\[")
            || text.contains("∑") || text.contains("∫") || text.contains("√")
            || text.contains("π") || text.contains("∞") || text.contains("²")
            || text.contains("³") || text.contains("ⁿ") || text.contains("₀")
            || text.contains("ₙ")
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, alignment: .trailing)
                    .help(text)
            } else {
                Text(text)
                    .font(font)
                    .foregroundColor(isSecondary ? .secondary : themeManager.textColor)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
        .task(id: "\(text)|\(dark)|\(isSecondary)") {
            guard hasMathNotation else {
                image = nil
                return
            }
            renderFailed = false
            let markup = CalculatorAIFallback.normalizeAnswerMath(text)
            let fontSize: CGFloat = isSecondary ? 10 : 12
            if let rendered = await CASMathRenderer.shared.renderRichSnippet(
                markup: markup,
                dark: dark,
                fontSize: fontSize,
                maxWidth: 310) {
                image = rendered
            } else {
                renderFailed = true
            }
        }
    }
}

// MARK: - Chart

/// Draws one plotted calculator entry: labelled axes with a nice grid,
/// zero axes when the range spans them, one colored curve per expression
/// (the same palette the document `plot()` uses), and a legend for two or
/// more curves. Y bounds come from the data robustly — percentiles, not
/// raw extremes — so a pole like 1/x at 0 cannot squash the interesting
/// part of the curve.
struct PlotChartView: View {
    let spec: CalculatorPlotSpec
    let dark: Bool

    /// Same colors as `bridge.typ`'s `_plot-palette`, so a curve keeps its
    /// color when the same function is inserted into a document.
    private static let palette: [(red: Double, green: Double, blue: Double)] = [
        (0x3b, 0x82, 0xf6), (0xef, 0x44, 0x44), (0x22, 0xc5, 0x5e),
        (0xa8, 0x55, 0xf7), (0xf5, 0x9e, 0x0b),
    ]

    private var curveColor: Color {
        dark ? .white.opacity(0.85) : Color(red: 0.1, green: 0.1, blue: 0.12)
    }
    private var gridColor: Color { Color.primary.opacity(0.12) }
    private var axisColor: Color { Color.primary.opacity(0.35) }
    private var labelColor: Color { dark ? .white.opacity(0.5) : Color.primary.opacity(0.55) }

    /// The insets around the plot area: room for the y labels on the left
    /// and the x labels below.
    private let inset = EdgeInsets(top: 6, leading: 38, bottom: 16, trailing: 8)

    var body: some View {
        Canvas { context, size in
            let plotWidth = max(10, size.width - inset.leading - inset.trailing)
            let plotHeight = max(10, size.height - inset.top - inset.bottom)
            let bounds = yBounds()
            let span = bounds.hi - bounds.lo

            // Frame
            let frame = CGRect(x: inset.leading, y: inset.top, width: plotWidth, height: plotHeight)
            context.stroke(Path(frame), with: .color(gridColor), lineWidth: 0.5)

            // X ticks: a "nice" step like the document plot().
            let xStep = niceStep(of: (spec.xMax - spec.xMin) / 6)
            var tick = (spec.xMin / xStep).rounded(.up) * xStep
            let font = Font.system(size: 8.5, design: .monospaced)
            while tick <= spec.xMax + 1e-12 {
                let x = px(tick, bounds: bounds, width: plotWidth)
                context.stroke(Path { path in
                    path.move(to: CGPoint(x: x, y: inset.top))
                    path.addLine(to: CGPoint(x: x, y: inset.top + plotHeight))
                }, with: .color(gridColor), lineWidth: 0.5)
                draw(text: Self.label(tick), at: CGPoint(x: x, y: inset.top + plotHeight + 3),
                     color: labelColor, font: font, centered: true, in: context)
                tick += xStep
            }

            // Y grid: nice steps, so labels read as clean numbers.
            let yStep = niceStep(of: span / 5)
            var yTick = (bounds.lo / yStep).rounded(.up) * yStep
            while yTick <= bounds.hi + 1e-12 {
                let y = py(yTick, bounds: bounds, height: plotHeight)
                context.stroke(Path { path in
                    path.move(to: CGPoint(x: inset.leading, y: y))
                    path.addLine(to: CGPoint(x: inset.leading + plotWidth, y: y))
                }, with: .color(gridColor), lineWidth: 0.5)
                draw(text: Self.label(yTick), at: CGPoint(x: inset.leading - 4, y: y - 5),
                     color: labelColor, font: font, centered: false, in: context)
                yTick += yStep
            }

            // Zero axes, when the range spans them.
            if spec.xMin < 0 && spec.xMax > 0 {
                let x = px(0, bounds: bounds, width: plotWidth)
                context.stroke(Path { path in
                    path.move(to: CGPoint(x: x, y: inset.top))
                    path.addLine(to: CGPoint(x: x, y: inset.top + plotHeight))
                }, with: .color(axisColor), lineWidth: 1)
            }
            if bounds.lo < 0 && bounds.hi > 0 {
                let y = py(0, bounds: bounds, height: plotHeight)
                context.stroke(Path { path in
                    path.move(to: CGPoint(x: inset.leading, y: y))
                    path.addLine(to: CGPoint(x: inset.leading + plotWidth, y: y))
                }, with: .color(axisColor), lineWidth: 1)
            }

            // Curves: gaps (NaN or far outside the drawn range) break the
            // segment, so poles do not draw vertical walls.
            for (index, curve) in spec.curves.enumerated() {
                let color = Self.palette[index % Self.palette.count]
                var path = Path()
                var started = false
                for point in curve {
                    guard !point.y.isNaN, point.y.isFinite,
                          point.y >= bounds.lo - span, point.y <= bounds.hi + span else {
                        started = false
                        continue
                    }
                    let location = CGPoint(x: px(point.x, bounds: bounds, width: plotWidth),
                                           y: py(point.y, bounds: bounds, height: plotHeight))
                    if started {
                        path.addLine(to: location)
                    } else {
                        path.move(to: location)
                        started = true
                    }
                }
                let shade = Color(red: color.red / 255, green: color.green / 255, blue: color.blue / 255)
                context.stroke(path, with: .color(shade), lineWidth: 1.4)
            }

            // Legend for multi-curve charts, above the plot area's top-right.
            if spec.curves.count > 1 {
                var y = inset.top + 2
                for (index, expression) in spec.expressions.prefix(5).enumerated() {
                    let color = Self.palette[index % Self.palette.count]
                    let shade = Color(red: color.red / 255, green: color.green / 255, blue: color.blue / 255)
                    context.fill(Path(CGRect(x: inset.leading + plotWidth - 98, y: y + 2, width: 7, height: 2.5)),
                                 with: .color(shade))
                    draw(text: expression, at: CGPoint(x: inset.leading + plotWidth - 88, y: y),
                         color: shade, font: font, centered: false, in: context)
                    y += 12
                }
            }
        }
    }

    // MARK: Geometry

    private struct YBounds {
        let lo: Double
        let hi: Double
    }

    /// Robust vertical range. Outliers (a pole like `1/x` reaching ±160 at
    /// the samples next to zero) must not squash the curve, but real
    /// extremes — a sinc's peak at 1 — must not be clipped either. So the
    /// data range is used as-is unless it reaches far beyond the 2nd–98th
    /// percentile band, which only happens for genuine outliers.
    private func yBounds() -> YBounds {
        let values = spec.curves.flatMap { curve in curve.map(\.y) }
            .filter { !$0.isNaN && $0.isFinite }
            .sorted()
        guard values.count >= 2 else { return YBounds(lo: -1, hi: 1) }
        let dataLow = values[0]
        let dataHigh = values[values.count - 1]
        let pLow = values[min(values.count - 1, Int(Double(values.count) * 0.02))]
        let pHigh = values[min(values.count - 1, Int(Double(values.count) * 0.98))]
        let band = max(pHigh - pLow, 1e-12)
        // A value within this many band-widths of the percentile band is
        // part of the curve, not an outlier.
        let tolerance = 3 * band
        let low = dataLow >= pLow - tolerance ? dataLow : pLow
        let high = dataHigh <= pHigh + tolerance ? dataHigh : pHigh
        var span = high - low
        if span <= 0 { span = max(abs(high), 1) }
        return YBounds(lo: low - span * 0.06, hi: high + span * 0.06)
    }

    private func niceStep(of raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(raw)))
        let normalized = raw / magnitude
        let factor = normalized <= 1 ? 1.0 : (normalized <= 2 ? 2.0 : (normalized <= 5 ? 5.0 : 10.0))
        return factor * magnitude
    }

    private func px(_ x: Double, bounds: YBounds, width: Double) -> CGFloat {
        inset.leading + (x - spec.xMin) / (spec.xMax - spec.xMin) * width
    }

    private func py(_ y: Double, bounds: YBounds, height: Double) -> CGFloat {
        inset.top + (bounds.hi - y) / (bounds.hi - bounds.lo) * height
    }

    /// Tick text: an en-dash for negatives reads better at 8.5pt than "-".
    /// Trailing zeros are trimmed so a nice step prints as "1", not "1.00".
    private static func label(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if abs(value) < 1e-9 { return "0" }
        let text = String(format: "%.4g", value)
        return text.replacingOccurrences(of: "-", with: "−")
    }

    private func draw(text: String, at point: CGPoint, color: Color, font: Font,
                      centered: Bool, in context: GraphicsContext) {
        context.draw(Text(text).font(font).foregroundColor(color), at: point,
                     anchor: centered ? .top : .topLeading)
    }

    // MARK: PNG

    /// The chart as a PNG for the clipboard or the document folder. Rendered
    /// on white with dark text: documents are usually light, and an inserted
    /// image should not flip with the UI theme.
    @MainActor
    static func pngData(_ spec: CalculatorPlotSpec) -> Data? {
        let view = PlotChartView(spec: spec, dark: false)
            .frame(width: 680, height: 400)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }
}

// MARK: - TI-89 menu contents

/// One item of the template menus: label + the text placed on the
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
        TICommand("plot( chart", "plot(sin(x), x, -5, 5)", caretOffset: 5),
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

// MARK: - Entry line (NSTextView)

/// The monospace entry field with TI-89 key handling:
/// ↩ evaluates (⌥↩ forces approximate), ⇧↩ starts a new line, ↑/↓ walk
/// the history on single-line input, Esc clears the line or stops a
/// running calculation.
struct TIEntryField: NSViewRepresentable {
    @Binding var text: String
    let focusTrigger: UUID
    @Binding var pendingCursorOffset: Int?
    let onSubmit: (_ forceApprox: Bool) -> Void
    let onArrowUp: () -> Void
    let onArrowDown: () -> Void
    let onEscape: () -> Void

    /// Sized like the AI Chat input (which uses .callout), but monospaced
    /// for TI syntax.
    private var entryFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic

        let field = EntryTextView()
        field.delegate = context.coordinator
        field.font = entryFont
        field.textColor = .textColor
        field.setAccessibilityLabel("Calculator entry")
        field.isRichText = false
        field.allowsUndo = true
        field.drawsBackground = false
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.autoresizingMask = [.width]
        field.minSize = NSSize(width: 0, height: 0)
        field.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        field.textContainerInset = NSSize(width: 1, height: 2)
        field.textContainer?.widthTracksTextView = true
        field.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // TI syntax must reach the CAS exactly as typed: no curly quotes,
        // dashes or autocorrect substitutions.
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.isAutomaticTextReplacementEnabled = false
        field.isAutomaticSpellingCorrectionEnabled = false
        field.string = text

        field.onSubmit = { [weak coordinator = context.coordinator] forceApprox in
            coordinator?.parent.onSubmit(forceApprox)
        }
        field.onArrowUp = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onArrowUp()
        }
        field.onArrowDown = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onArrowDown()
        }
        field.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onEscape()
        }

        scrollView.documentView = field
        context.coordinator.textView = field
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let field = context.coordinator.textView else { return }
        if field.string != text {
            // Recall, history click and submit replace the text from SwiftUI;
            // put the caret at the end, like the old single-line field.
            let undo = field.undoManager
            undo?.disableUndoRegistration()
            field.string = text
            field.font = entryFont
            field.textColor = .textColor
            undo?.enableUndoRegistration()
            let end = (text as NSString).length
            field.setSelectedRange(NSRange(location: end, length: 0))
            field.scrollRangeToVisible(field.selectedRange())
        }
        if let offset = pendingCursorOffset {
            pendingCursorOffset = nil
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                let clamped = min(offset, (field.string as NSString).length)
                field.setSelectedRange(NSRange(location: clamped, length: 0))
            }
        }
        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                let end = (field.string as NSString).length
                field.setSelectedRange(NSRange(location: end, length: 0))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TIEntryField
        var lastFocusTrigger: UUID?
        weak var textView: EntryTextView?

        init(_ parent: TIEntryField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextView else { return }
            parent.text = field.string
        }
    }

    /// A multi-line text view with TI-89 key handling.
    final class EntryTextView: NSTextView {
        var onSubmit: ((_ forceApprox: Bool) -> Void)?
        var onArrowUp: (() -> Void)?
        var onArrowDown: (() -> Void)?
        var onEscape: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            // Let the input method confirm a composition first (e.g. Return
            // ends a Japanese or Chinese candidate), and never eat Esc while
            // a candidate window is open.
            if hasMarkedText() {
                super.keyDown(with: event)
                return
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 36, 76: // Return, keypad Enter
                if flags.contains(.option) {
                    // ⌥↩ mirrors the TI-89's ◆ENTER (approximate result).
                    onSubmit?(true)
                    return
                }
                if flags.contains(.shift) {
                    // ⇧↩ starts a new line for a longer question.
                    insertNewline(nil)
                    return
                }
                if !flags.contains(.command) {
                    onSubmit?(false)
                    return
                }
            case 53: // Esc
                onEscape?()
                return
            default:
                break
            }
            super.keyDown(with: event)
        }

        override func moveUp(_ sender: Any?) {
            // On a multi-line entry the arrows edit the question; history
            // recall stays on single-line input so ↓ cannot wipe it.
            if hasMarkedText() || string.contains("\n") {
                super.moveUp(sender)
            } else {
                onArrowUp?()
            }
        }

        override func moveDown(_ sender: Any?) {
            if hasMarkedText() || string.contains("\n") {
                super.moveDown(sender)
            } else {
                onArrowDown?()
            }
        }
    }
}
