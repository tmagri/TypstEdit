import AppKit
import PDFKit
import UniformTypeIdentifiers

/// File → Import PDF…: converts a PDF to a `.typ` (plus optional Markdown
/// and JSON) with `PDFImporter`, then opens it like the LyX import does.
extension EditorController {

    private enum PDFImportDefaults {
        static let useAI = "pdfImportUseAI"
        static let saveExtras = "pdfImportSaveMarkdownJSON"
    }

    /// - Parameter forceOCR: ignore the PDF's text layer and read every page
    ///   from its image, for garbled text layers or a poor older OCR.
    func importPDF(forceOCR: Bool = false) {
        let aiTarget = PDFImportAI.target()
        let defaults = UserDefaults.standard
        let accessory = PDFImportAccessory(
            aiAvailable: aiTarget != nil,
            aiIsLocal: AISettingsManager.shared.modelContext(for: .generation).isLocal,
            modelName: PDFImportAI.modelDisplayName,
            useAI: defaults.bool(forKey: PDFImportDefaults.useAI),
            saveExtras: defaults.bool(forKey: PDFImportDefaults.saveExtras))

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        panel.title = forceOCR ? "Import PDF (Force OCR)" : "Import PDF"
        if forceOCR {
            panel.message = "Every page is read from its image with on-device OCR; the PDF’s own text is ignored."
        }
        panel.prompt = "Import"
        panel.accessoryView = accessory.view
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let pdfURL = panel.url else { return }

        defaults.set(accessory.useAI, forKey: PDFImportDefaults.useAI)
        defaults.set(accessory.saveExtras, forKey: PDFImportDefaults.saveExtras)

        guard let pageRange = pdfImportPageRange(accessory.pagesText, pdfURL: pdfURL),
              let destination = pdfImportDestination(for: pdfURL),
              let baseName = pdfImportBaseName(for: pdfURL, in: destination.directory) else { return }

        var configured = PDFImporter(sourceURL: pdfURL, outputDirectory: destination.directory, baseName: baseName)
        configured.options.pageRange = pageRange.range
        configured.options.forceOCR = forceOCR
        configured.aiTarget = accessory.useAI ? aiTarget : nil
        let importer = configured
        let saveExtras = accessory.saveExtras
        let openAsProject = destination.openAsProject

        // A visible window with a page counter, because a long import takes
        // minutes and looked like a hang in the toolbar caption.
        let totalPages = PDFDocument(url: pdfURL)?.pageCount ?? 0
        let pages = min(pageRange.range?.upperBound ?? totalPages, totalPages)
        let progress = PDFImportProgress(fileName: pdfURL.lastPathComponent, totalPages: max(pages, 1))
        let task = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await importer.run(progress: progress.progressHandler())
                }.value
                try Task.checkCancellation()
                progress.page = progress.totalPages
                progress.phase = .writing
                let typURL = destination.directory.appendingPathComponent("\(baseName).typ")
                try result.typst.write(to: typURL, atomically: true, encoding: .utf8)
                if saveExtras {
                    try result.markdown.write(to: destination.directory.appendingPathComponent("\(baseName).md"), atomically: true, encoding: .utf8)
                    try result.json.write(to: destination.directory.appendingPathComponent("\(baseName).json"), atomically: true, encoding: .utf8)
                }
                progress.finish(output: typURL)
                self?.finishPDFImport(typURL: typURL, openAsProject: openAsProject, result: result)
            } catch is CancellationError {
                progress.markCancelled()
                self?.showStatus("PDF import cancelled", duration: 4)
            } catch {
                print("[ERROR] PDF import failed: \(error.localizedDescription)")
                progress.fail(error.localizedDescription)
                self?.showStatus("Import failed: \(error.localizedDescription)", duration: 5)
            }
        }
        progress.onCancel = { task.cancel() }
        PDFImportProgressWindow.show(progress)
    }

    private func finishPDFImport(typURL: URL, openAsProject: Bool, result: PDFImportResult) {
        if openAsProject {
            NotificationCenter.default.post(name: .openProjectAndFile, object: typURL)
        } else {
            NotificationCenter.default.post(name: .refreshProjectSidebar, object: nil)
            NotificationCenter.default.post(name: .fileDidCreate, object: typURL)
        }
        showStatus("PDF imported: \(result.summary)", duration: 6)

        guard !result.warnings.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "PDF imported with notes"
        alert.informativeText = result.warnings.prefix(8).joined(separator: "\n")
            + (result.warnings.count > 8 ? "\n…and \(result.warnings.count - 8) more." : "")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private enum PageSelection {
        case all
        case range(ClosedRange<Int>)

        var range: ClosedRange<Int>? {
            if case .range(let range) = self { return range }
            return nil
        }
    }

    /// The pages to import, from the panel's "Pages" field ("201-260", "5",
    /// empty for all). Returns `nil` when the user cancels: on invalid input,
    /// or when declining a long full import.
    private func pdfImportPageRange(_ text: String, pdfURL: URL) -> PageSelection? {
        // Opening is lazy, so this is quick even for a 100 MB book.
        let pageCount = PDFDocument(url: pdfURL)?.pageCount ?? 0
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            // Text-layer pages take about 0.3–0.6 s each, OCR pages more.
            guard pageCount > 150 else { return .all }
            let minutes = max(1, Int((Double(pageCount) * 0.6 / 60).rounded()))
            let alert = NSAlert()
            alert.messageText = "Import all \(pageCount) pages?"
            alert.informativeText = "This takes about \(minutes) minutes and makes a very large Typst file. To import a part, cancel and enter a page range such as 201-260."
            alert.addButton(withTitle: "Import All")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .all : nil
        }

        let numbers = trimmed.split(whereSeparator: { "-–— ".contains($0) }).compactMap { Int($0) }
        let range: ClosedRange<Int>?
        switch numbers.count {
        case 1: range = numbers[0]...numbers[0]
        case 2 where numbers[0] <= numbers[1]: range = numbers[0]...numbers[1]
        default: range = nil
        }
        guard let range, range.lowerBound >= 1, pageCount == 0 || range.lowerBound <= pageCount else {
            let alert = NSAlert()
            alert.messageText = "Invalid page range"
            alert.informativeText = "Enter a page or a range such as 201-260\(pageCount > 0 ? " (the PDF has \(pageCount) pages)" : "")."
            alert.runModal()
            return nil
        }
        return .range(range)
    }

    /// Where the `.typ` goes, mirroring the LyX import: next to the PDF when
    /// it is inside the open project (or no project is open), otherwise the
    /// user chooses between copying into the project and opening the PDF's
    /// folder.
    private func pdfImportDestination(for pdfURL: URL) -> (directory: URL, openAsProject: Bool)? {
        let pdfFolder = pdfURL.deletingLastPathComponent()
        guard let projectRoot = projectRootURL else { return (pdfFolder, true) }
        if pdfURL.standardizedFileURL.path.hasPrefix(projectRoot.standardizedFileURL.path + "/") {
            return (pdfFolder, false)
        }
        let alert = NSAlert()
        alert.messageText = "Import PDF"
        alert.informativeText = "The PDF is outside your current project. Create the Typst file in your project, or next to the PDF and open its folder as a new project?"
        alert.addButton(withTitle: "Add to Project")
        alert.addButton(withTitle: "Open PDF Folder")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return (projectRoot, false)
        case .alertSecondButtonReturn: return (pdfFolder, true)
        default: return nil
        }
    }

    /// The output name, asking before replacing an existing `.typ`.
    private func pdfImportBaseName(for pdfURL: URL, in directory: URL) -> String? {
        let base = pdfURL.deletingPathExtension().lastPathComponent
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.appendingPathComponent("\(base).typ").path) else { return base }

        let alert = NSAlert()
        alert.messageText = "“\(base).typ” already exists"
        alert.informativeText = "Replace it with the new import, or keep both?"
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return base
        case .alertSecondButtonReturn:
            var counter = 2
            while manager.fileExists(atPath: directory.appendingPathComponent("\(base)-\(counter).typ").path) { counter += 1 }
            return "\(base)-\(counter)"
        default:
            return nil
        }
    }
}

/// The open panel's options: AI for formulas and complex tables, and the
/// extra Markdown/JSON outputs.
@MainActor
private final class PDFImportAccessory {
    let view: NSView
    private let aiBox: NSButton
    private let extrasBox: NSButton
    private let pagesField: NSTextField

    var useAI: Bool { aiBox.isEnabled && aiBox.state == .on }
    var saveExtras: Bool { extrasBox.state == .on }
    var pagesText: String { pagesField.stringValue }

    init(aiAvailable: Bool, aiIsLocal: Bool, modelName: String, useAI: Bool, saveExtras: Bool) {
        pagesField = NSTextField(string: "")
        pagesField.placeholderString = "All, or a range such as 201-260"
        pagesField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let pagesRow = NSStackView(views: [NSTextField(labelWithString: "Pages:"), pagesField])
        pagesRow.orientation = .horizontal
        pagesRow.spacing = 6

        aiBox = NSButton(checkboxWithTitle: "Use AI for formulas and complex tables", target: nil, action: nil)
        aiBox.state = aiAvailable && useAI ? .on : .off
        aiBox.isEnabled = aiAvailable
        extrasBox = NSButton(checkboxWithTitle: "Also save Markdown and JSON", target: nil, action: nil)
        extrasBox.state = saveExtras ? .on : .off

        let note: String
        if !aiAvailable {
            note = "Turn on AI Chat in Settings to enable. Without AI, formulas and irregular tables are kept as images."
        } else if aiIsLocal {
            note = "Uses \(modelName), one request at a time. The model must accept images; anything it cannot read stays an image. If the model stays busy (for example with a chat), the import does not wait in its queue: the remaining items stay images."
        } else {
            note = "Sends cropped images of formulas and tables to \(modelName). Anything the model cannot read stays an image."
        }
        let label = NSTextField(wrappingLabelWithString: note)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 420

        let stack = NSStackView(views: [pagesRow, aiBox, label, extrasBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        stack.setCustomSpacing(12, after: pagesRow)
        stack.setCustomSpacing(12, after: label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.frame = NSRect(origin: .zero, size: stack.fittingSize)
        view = container
    }
}
