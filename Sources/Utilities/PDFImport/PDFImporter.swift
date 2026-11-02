import Foundation
import PDFKit
import JavaScriptCore

/// Runs a whole PDF import: extract → clean up → lay out → crop → (AI) → emit.
///
/// Call `run` off the main actor. PDFKit objects never leave this type, so
/// the caller only deals with the Sendable result and the files written.
struct PDFImporter: Sendable {
    let sourceURL: URL
    /// Folder the `.typ` is written to; assets go in a sibling folder.
    let outputDirectory: URL
    /// Output file name without extension.
    let baseName: String
    var options: PDFImportOptions = .default
    /// Set (on the main actor) when the user allowed AI for this import.
    var aiTarget: PDFImportAI.Target?

    typealias Progress = @Sendable (String) -> Void

    enum ImportError: LocalizedError {
        case unreadable, locked, empty
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file could not be opened as a PDF."
            case .locked: return "The PDF is password protected."
            case .empty: return "The PDF has no pages in the selected range."
            }
        }
    }

    var assetsFolderName: String { "\(baseName)-assets" }
    var assetsDirectory: URL { outputDirectory.appendingPathComponent(assetsFolderName, isDirectory: true) }

    // MARK: - Run

    func run(progress: Progress = { _ in }) async throws -> PDFImportResult {
        guard let pdf = PDFDocument(url: sourceURL) else { throw ImportError.unreadable }
        if pdf.isLocked && !pdf.unlock(withPassword: "") { throw ImportError.locked }

        let all = 0..<pdf.pageCount
        let range = options.pageRange.map { max($0.lowerBound - 1, 0)..<min($0.upperBound, pdf.pageCount) } ?? all
        guard !range.isEmpty else { throw ImportError.empty }
        var warnings: [String] = []

        // 1. Text per page: the text layer when usable, otherwise OCR.
        var work: [PageWork] = []
        for index in range {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { continue }
            progress("Reading page \(index + 1) of \(pdf.pageCount)…")
            let size = PDFPageExtractor.displaySize(of: page)
            // Autorelease pools per page keep memory flat on long books:
            // PDFKit and CoreGraphics objects are autoreleased. A pool cannot
            // span an `await`, so the OCR path wraps its synchronous parts.
            // Scanned pages go to the image path even when they carry an
            // OCR text layer: trust the picture, not an
            // invisible layer whose geometry (sizes, line boxes) is noise.
            // A scan's text layer, when present, is the scanner's OCR: its
            // text and word positions are good, but its sizes come from word
            // boxes and are noise. Use it, with sizes untrusted. Scans with
            // no layer are read from the image.
            let scanned = PDFPageExtractor.isScannedPage(page)
            // Ruled tables first: their rules also keep text runs from
            // crossing cell borders.
            let layer: (runs: [PDFTextRun], all: [PDFTextRun], tables: [PDFRegion])? = options.forceOCR ? nil : autoreleasepool {
                let rulings = PDFLatticeTables.rulings(page: page, displaySize: size)
                guard var runs = PDFPageExtractor.textLayerRuns(for: page, barriers: rulings.vertical) else { return nil }
                PDFPageExtractor.applyInkWeight(page: page, displaySize: size, runs: &runs, sizesTrusted: !scanned)
                let all = runs
                let lattice = PDFLatticeTables.tables(from: rulings, runs: runs)
                runs = runs.enumerated().filter { !lattice.consumed.contains($0.offset) }.map(\.element)
                return (runs, all, lattice.regions)
            }
            if let layer {
                var item = PageWork(index: index, size: size, runs: layer.runs, presetTables: layer.tables,
                                    engine: .textLayer, sizesTrusted: !scanned)
                item.bodySample = layer.all
                work.append(item)
            } else if let image = autoreleasepool(invoking: { PDFPageExtractor.render(page, scale: 3) }) {
                progress("Recognising text on page \(index + 1)…")
                let ocr = await PDFPageExtractor.recognize(image, page: page, displaySize: size, textLayer: nil)
                var runs = ocr.runs
                if !runs.isEmpty {
                    autoreleasepool { PDFPageExtractor.applyInkWeight(page: page, displaySize: size, runs: &runs, sizesTrusted: false) }
                }
                work.append(PageWork(index: index, size: size, runs: runs, presetTables: ocr.regions,
                                     engine: ocr.engine, sizesTrusted: false, tableRuns: ocr.lines))
                if ocr.runs.isEmpty && ocr.regions.isEmpty { warnings.append("Page \(index + 1): no text found.") }
            } else {
                warnings.append("Page \(index + 1) could not be rendered.")
            }
        }

        // 2. Running headers / page numbers, then the body size.
        if options.removeRunningHeaders {
            // Recognised blocks (scanned pages) take part as stand-in runs,
            // so a running head is dropped whichever path read the page.
            func standIn(_ region: PDFRegion) -> PDFTextRun? {
                guard case .block(let block) = region.kind, case .text(let text) = block.content else { return nil }
                return PDFTextRun(text: text, rect: region.rect, fontSize: block.fontSize ?? 10)
            }
            let combined = work.map { item in item.runs + item.presetTables.compactMap(standIn) }
            let cleaned = PDFLayoutAnalyzer.removeRunningHeaders(pages: combined, pageSizes: work.map(\.size))
            for i in work.indices {
                let kept = Set(cleaned[i].map { "\($0.rect.origin.x),\($0.rect.origin.y)|\($0.text)" })
                let key = { (run: PDFTextRun) in "\(run.rect.origin.x),\(run.rect.origin.y)|\(run.text)" }
                work[i].runs = work[i].runs.filter { kept.contains(key($0)) }
                work[i].presetTables = work[i].presetTables.filter { region in
                    guard let run = standIn(region) else { return true }
                    return kept.contains(key(run))
                }
            }
        }
        let bodySize = PDFLayoutAnalyzer.bodyFontSize(work.flatMap(\.sizeSample))

        // 3. Tables, figures and reading order, page by page.
        var document = PDFImportedDocument(sourceName: sourceURL.lastPathComponent, bodyFontSize: bodySize)
        for item in work {
            try Task.checkCancellation()
            guard let page = pdf.page(at: item.index) else { continue }
            progress("Analysing layout of page \(item.index + 1)…")
            let blocks: [PDFImportedBlock] = autoreleasepool {
                let tables = PDFLayoutAnalyzer.detectTables(in: item.runs, pageSize: item.size)
                var regions = item.presetTables + tables.regions
                var runs = tables.remaining
                // Tables the layout model missed, found on its lines; the
                // recognised paragraphs they cover are dropped.
                if !item.tableRuns.isEmpty {
                    let found = PDFLayoutAnalyzer.detectTables(in: item.tableRuns, pageSize: item.size).regions
                    regions.removeAll { region in
                        guard case .block = region.kind else { return false }
                        return found.contains { PDFPageExtractor.insideFraction(region.rect, $0.rect) > 0.5 }
                    }
                    regions += found
                }
                if options.extractFigures {
                    let figures = PDFPageExtractor.detectFigures(page: page, displaySize: item.size, runs: runs,
                                                                 tableRects: regions.map(\.rect))
                    runs = runs.enumerated().filter { !figures.absorbed.contains($0.offset) }.map(\.element)
                    // Small line-shaped "figures" are often text drawn as
                    // outlines (section numbers, headings): read them back.
                    var recovered: [PDFTextRun] = []
                    for region in figures.regions {
                        if case .figure = region.kind,
                           let text = PDFPageExtractor.textInLineShapedRegion(page: page, rect: region.rect, known: item.sizeSample) {
                            recovered += text
                        } else {
                            regions.append(region)
                        }
                    }
                    // Smaller line-shaped ink: kept only if it reads as text.
                    // Scans have no outlined text and plenty of specks.
                    if item.sizesTrusted {
                        for rect in figures.textCandidates {
                            recovered += PDFPageExtractor.textInLineShapedRegion(page: page, rect: rect, known: item.sizeSample) ?? []
                        }
                    }
                    if !recovered.isEmpty {
                        runs += recovered
                        PDFPageExtractor.applyInkWeight(page: page, displaySize: item.size, runs: &runs, sizesTrusted: item.sizesTrusted)
                    }
                }
                // Books mix body sizes (small-print sections, charts): judge
                // headings against this page's own prose when it has enough.
                let sample = item.bodySample.isEmpty ? runs : item.bodySample
                let pageProse = sample.filter { $0.text.count >= 25 }.reduce(0) { $0 + $1.text.count }
                let pageBody = pageProse >= 600 ? PDFLayoutAnalyzer.bodyFontSize(sample) : bodySize
                // Untrusted sizes: no heading by size at all.
                let factor: CGFloat = !item.sizesTrusted ? 100 : (PDFLayoutAnalyzer.sizeIsReliable(runs) ? 1.15 : 1.8)
                return PDFLayoutAnalyzer.assemblePage(runs: runs, regions: regions, bodyFontSize: pageBody,
                                                      headingSizeFactor: factor)
            }
            document.pages.append(PDFImportedPage(index: item.index, size: item.size, blocks: blocks, engine: item.engine))
        }
        PDFLayoutAnalyzer.finalize(&document)
        // The PDF's bookmarks, when it has them, are the authority on headings.
        PDFOutlineHeadings.apply(PDFOutlineHeadings.entries(of: pdf), to: &document)

        // 4. Crops: figures, complex tables and formulas get images.
        if options.writeAssets {
            progress("Saving figures…")
            try writeCrops(&document, pdf: pdf, warnings: &warnings)
        }

        // 5. AI for formulas and complex tables (opt-in).
        if let aiTarget {
            try await applyAI(&document, pdf: pdf, target: aiTarget, progress: progress, warnings: &warnings)
        }

        progress("Writing Typst…")
        return PDFImportResult(document: document,
                               typst: PDFImportEmitter.typst(document),
                               markdown: PDFImportEmitter.markdown(document),
                               json: PDFImportEmitter.json(document),
                               warnings: warnings)
    }

    private struct PageWork {
        var index: Int
        var size: CGSize
        var runs: [PDFTextRun]
        var presetTables: [PDFRegion]
        var engine: PDFPageEngine
        /// False on scans: sizes come from OCR boxes, so headings must not
        /// be judged by size.
        var sizesTrusted = true
        /// Recognised lines, used only to find tables the layout model
        /// missed (Vision document pages, whose text arrives as blocks).
        var tableRuns: [PDFTextRun] = []
        /// Every text run on the page, table cells included, for judging
        /// the body size: in a manual, table text *is* the body text.
        var bodySample: [PDFTextRun] = []
        var sizeSample: [PDFTextRun] { bodySample.isEmpty ? runs : bodySample }
    }

    // MARK: - Crops

    /// Removes crops a previous import of the same file wrote, so a re-import
    /// never leaves stale images. Only files matching the importer's own
    /// naming pattern are touched.
    private func removeStaleCrops() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: assetsDirectory.path) else { return }
        for name in names where name.range(of: #"^p\d+-(figure|table|equation)\d+\.png$"#, options: .regularExpression) != nil {
            try? manager.removeItem(at: assetsDirectory.appendingPathComponent(name))
        }
    }

    private func writeCrops(_ document: inout PDFImportedDocument, pdf: PDFDocument, warnings: inout [String]) throws {
        removeStaleCrops()
        var created = false
        for p in document.pages.indices {
            let pageIndex = document.pages[p].index
            guard let page = pdf.page(at: pageIndex) else { continue }
            var counters: [String: Int] = [:]

            func crop(_ rect: CGRect, kind: String) -> String? {
                counters[kind, default: 0] += 1
                let name = "p\(pageIndex + 1)-\(kind)\(counters[kind]!).png"
                let padded = rect.insetBy(dx: -1.5, dy: -1.5)
                    .intersection(CGRect(origin: .zero, size: document.pages[p].size))
                guard !padded.isNull,
                      let image = autoreleasepool(invoking: { PDFPageExtractor.render(page, scale: options.cropScale, region: padded) })
                else { return nil }
                do {
                    if !created {
                        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
                        created = true
                    }
                    try PDFPageExtractor.writePNG(image, to: assetsDirectory.appendingPathComponent(name))
                    return "\(assetsFolderName)/\(name)"
                } catch {
                    warnings.append("Could not save \(name): \(error.localizedDescription)")
                    return nil
                }
            }

            for b in document.pages[p].blocks.indices {
                let block = document.pages[p].blocks[b]
                switch block.content {
                case .figure(var figure):
                    guard options.extractFigures else { continue }
                    figure.relativePath = crop(block.rect, kind: "figure")
                    document.pages[p].blocks[b].content = .figure(figure)
                case .table(var table) where table.isComplex:
                    table.imagePath = crop(block.rect, kind: "table")
                    document.pages[p].blocks[b].content = .table(table)
                case .formula(var formula):
                    formula.imagePath = crop(block.rect, kind: "equation")
                    document.pages[p].blocks[b].content = .formula(formula)
                default:
                    continue
                }
            }
        }
    }

    // MARK: - AI

    private enum AIJob: Sendable {
        case formula(page: Int, block: Int, png: Data, hint: String)
        case table(page: Int, block: Int, png: Data, hint: [[String]])
    }

    private enum AIOutcome: Sendable {
        case formula(page: Int, block: Int, latex: String?)
        case table(page: Int, block: Int, rows: [[String]]?)
        case failed(String)
        /// The server was busy or did not answer: stop sending, since more
        /// requests would only queue behind it.
        case unavailable(String)
    }

    private func applyAI(_ document: inout PDFImportedDocument, pdf: PDFDocument, target: PDFImportAI.Target,
                         progress: Progress, warnings: inout [String]) async throws {
        var jobs: [AIJob] = []
        for p in document.pages.indices {
            guard let page = pdf.page(at: document.pages[p].index) else { continue }
            for b in document.pages[p].blocks.indices {
                let block = document.pages[p].blocks[b]
                let region = block.rect.insetBy(dx: -4, dy: -4)
                switch block.content {
                case .formula(let formula):
                    if let image = PDFPageExtractor.render(page, scale: 3, region: region), let png = PDFPageExtractor.pngData(image) {
                        jobs.append(.formula(page: p, block: b, png: png, hint: formula.sourceText))
                    }
                case .table(let table) where table.isComplex:
                    if let image = PDFPageExtractor.render(page, scale: 2.5, region: region), let png = PDFPageExtractor.pngData(image) {
                        jobs.append(.table(page: p, block: b, png: png, hint: table.rows))
                    }
                default:
                    continue
                }
            }
        }
        guard !jobs.isEmpty else { return }

        var outcomes: [AIOutcome] = []
        let total = jobs.count
        var finished = 0
        // Local servers often handle one request at a time: send one at a
        // time, so the import never queues several requests behind the chat.
        let concurrency = target.isLocal ? 1 : max(1, options.aiConcurrency)
        var stoppedBecause: String?
        try await withThrowingTaskGroup(of: AIOutcome.self) { group in
            var next = 0
            func enqueue() {
                guard next < jobs.count, stoppedBecause == nil else { return }
                let job = jobs[next]
                next += 1
                group.addTask { await Self.perform(job, target: target) }
            }
            for _ in 0..<min(concurrency, jobs.count) { enqueue() }
            while let outcome = try await group.next() {
                outcomes.append(outcome)
                finished += 1
                if case .unavailable(let reason) = outcome, stoppedBecause == nil {
                    stoppedBecause = reason
                    progress("AI unavailable — keeping the remaining items as images…")
                } else {
                    progress("AI: \(finished) of \(total) formulas and tables…")
                }
                try Task.checkCancellation()
                enqueue()
            }
        }

        let converter = LatexToTypst()
        var failures = 0
        var firstError: String?
        for outcome in outcomes {
            switch outcome {
            case .formula(let p, let b, let latex):
                guard let latex, case .formula(var formula) = document.pages[p].blocks[b].content else { failures += 1; continue }
                guard let typst = converter.convert(latex) else { failures += 1; continue }
                formula.latex = latex
                formula.typst = typst
                formula.source = .ai
                document.pages[p].blocks[b].content = .formula(formula)
            case .table(let p, let b, let rows):
                guard let rows, case .table(var table) = document.pages[p].blocks[b].content else { failures += 1; continue }
                table.rows = rows
                table.headerRows = 1
                table.source = .ai
                document.pages[p].blocks[b].content = .table(table)
            case .failed(let message), .unavailable(let message):
                failures += 1
                if firstError == nil { firstError = message }
            }
        }
        if let stoppedBecause {
            let notTried = total - outcomes.count
            warnings.append("\(stoppedBecause) The import stopped using AI so it would not wait in the model's queue; "
                + "\(failures + notTried) of \(total) formulas and tables are kept as images. Run the import again when the model is free.")
        } else if failures > 0 {
            var message = "AI could not transcribe \(failures) of \(total) items; they are kept as images."
            if let firstError { message += " First error: \(firstError)" }
            warnings.append(message)
        }
    }

    private static func perform(_ job: AIJob, target: PDFImportAI.Target) async -> AIOutcome {
        do {
            switch job {
            case .formula(let p, let b, let png, let hint):
                return .formula(page: p, block: b, latex: try await PDFImportAI.transcribeFormula(png, hint: hint, target: target))
            case .table(let p, let b, let png, let hint):
                return .table(page: p, block: b, rows: try await PDFImportAI.transcribeTable(png, hint: hint, target: target))
            }
        } catch let error as PDFImportAI.ServerError {
            return .unavailable(error.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - LaTeX → Typst

/// Converts LaTeX math to Typst math with the bundled `tex2typst` (the same
/// converter the equation editor uses), run headless in JavaScriptCore.
/// Falls back to the LyX importer's converter if the script is unavailable.
final class LatexToTypst {
    private lazy var context: JSContext? = {
        guard let url = ModuleResources.main.url(forResource: "tex2typst.min", withExtension: "js")
                ?? ModuleResources.main.url(forResource: "tex2typst.min", withExtension: "js", subdirectory: "Vendor")
                ?? Bundle.main.url(forResource: "tex2typst.min", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.evaluateScript("var window = this;")
        context.evaluateScript(script)
        guard context.objectForKeyedSubscript("tex2typst")?.isUndefined == false else { return nil }
        return context
    }()

    func convert(_ latex: String) -> String? {
        if let context {
            context.exception = nil
            let result = context.objectForKeyedSubscript("tex2typst")?.call(withArguments: [latex])
            if context.exception == nil, let text = result?.toString(), result?.isString == true {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, PDFImportAI.isBalanced(trimmed) { return trimmed }
            }
        }
        let fallback = LyxToTypstConverter.convertLatexMathToTypst(latex).trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }
}
