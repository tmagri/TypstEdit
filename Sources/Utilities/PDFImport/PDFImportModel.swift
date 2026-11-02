import Foundation
import CoreGraphics

// MARK: - Import Document Model

/// The intermediate representation every PDF extraction path produces.
///
/// It mirrors the useful "middle JSON": a reading-ordered
/// list of typed blocks with geometry. Keeping layout *between* extraction and
/// emission lets one pass feed the Typst, Markdown and JSON outputs, and lets
/// a new engine drop in without touching the emitters.
///
/// All geometry is in *display space*: PDF points, origin bottom-left of the
/// page's crop box, with page rotation already applied, so "up" is up.
struct PDFImportedDocument: Sendable, Equatable, Codable {
    var sourceName: String = ""
    var pages: [PDFImportedPage] = []
    /// Dominant body font size across the document, in points.
    var bodyFontSize: CGFloat = 11

    var blocks: [PDFImportedBlock] { pages.flatMap(\.blocks) }
}

struct PDFImportedPage: Sendable, Equatable, Codable {
    var index: Int
    var size: CGSize
    var blocks: [PDFImportedBlock] = []
    /// Which path produced this page. Shown in the import summary so a
    /// surprising result can be traced to its source.
    var engine: PDFPageEngine = .textLayer
}

enum PDFPageEngine: String, Sendable, Codable {
    /// PDFKit text layer: exact characters, no model, no OCR error.
    case textLayer
    /// Vision document recognition (macOS 26+): paragraphs, tables, lists.
    case visionDocument
    /// Vision text recognition: lines only, no structure.
    case visionOCR
}

struct PDFImportedBlock: Sendable, Equatable, Codable {
    var kind: PDFBlockKind
    var rect: CGRect
    var content: PDFBlockContent
    /// Average font size of the block's text, when it has text.
    var fontSize: CGFloat? = nil
}

enum PDFBlockKind: Sendable, Equatable, Codable {
    case heading(level: Int)
    case paragraph
    case listItem(depth: Int, ordered: Bool)
    case table
    case figure
    case formula
    /// "Figure 3: …" / "Table 2. …" text. Emitters attach it to the nearest
    /// figure or table instead of printing it as a paragraph.
    case caption
    /// Preformatted text (a framed code or request/response sample). The
    /// content keeps its line breaks and indentation.
    case code(language: String?)
    /// A printed table of contents ("Title ....... 12"). Typst regenerates
    /// it from the headings, so it is emitted as `#outline()`.
    case contents

    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }
}

enum PDFBlockContent: Sendable, Equatable, Codable {
    case text(String)
    case table(PDFTableData)
    case figure(PDFFigure)
    case formula(PDFFormula)

    var plainText: String {
        switch self {
        case .text(let value): return value
        case .table(let table): return table.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case .figure(let figure): return figure.caption ?? ""
        case .formula(let formula): return formula.sourceText
        }
    }
}

/// A rectangular grid of cell text.
struct PDFTableData: Sendable, Equatable, Codable {
    var rows: [[String]]
    /// Leading rows that read as a header (`0` when unsure).
    var headerRows: Int = 1
    var caption: String?
    /// Set when the geometry was irregular (spans, ragged rows, multi-line
    /// cells). Such tables are sent to the AI when it is enabled, and are
    /// also exported as an image so nothing is silently lost.
    var isComplex = false
    /// Image of the table region (relative to the output file), written for
    /// complex tables.
    var imagePath: String?
    /// How the cell text was obtained, for the summary and JSON.
    var source: PDFContentSource = .geometry
    /// Merged cells (ruled tables). The text sits at the span's top-left
    /// position in `rows`; the other covered positions are empty.
    var spans: [PDFCellSpan] = []
    /// Column boundaries in points (ruled tables), used to join a table
    /// that continues on the next page.
    var columnEdges: [CGFloat] = []

    var columnCount: Int { rows.map(\.count).max() ?? 0 }
    var isEmpty: Bool { rows.isEmpty || columnCount == 0 }

    /// Every row padded to `columnCount`.
    var normalizedRows: [[String]] {
        let width = columnCount
        guard width > 0 else { return [] }
        return rows.map { $0.count >= width ? $0 : $0 + Array(repeating: "", count: width - $0.count) }
    }
}

struct PDFCellSpan: Sendable, Equatable, Codable {
    var row: Int
    var column: Int
    var rowSpan: Int
    var columnSpan: Int
}

struct PDFFigure: Sendable, Equatable, Codable {
    /// The cropped image on disk, relative to the output `.typ`'s folder.
    var relativePath: String?
    var caption: String?
}

struct PDFFormula: Sendable, Equatable, Codable {
    /// Whatever text the extractor found (often garbled for math fonts).
    var sourceText: String
    var latex: String?
    var typst: String?
    /// Image crop, used when no reliable math transcription exists.
    var imagePath: String?
    var source: PDFContentSource = .geometry
}

enum PDFContentSource: String, Sendable, Codable {
    case geometry
    case vision
    case ai
}

// MARK: - Options & Result

struct PDFImportOptions: Sendable, Equatable {
    /// Crop figures to PNG files next to the generated `.typ`.
    var extractFigures = true
    /// Send display formulas and complex tables to the configured AI model.
    /// It is the only step that can leave the machine, so it is opt-in.
    var useAI = false
    /// Drop running headers, footers and page numbers that repeat.
    var removeRunningHeaders = true
    /// Render scale for crops (2 ≈ 144 dpi).
    var cropScale: CGFloat = 2
    /// Page range (1-based, inclusive). `nil` imports every page.
    var pageRange: ClosedRange<Int>?
    /// Maximum concurrent AI requests.
    var aiConcurrency = 3
    /// Ignore the PDF's text layer and read every page from its image
    /// (Vision). For text layers that are garbled or a poor older OCR.
    var forceOCR = false
    /// Write figure, table and formula crops as PNG files. Off for reading
    /// a PDF's text only (the chat's `read_pdf`), which writes nothing.
    var writeAssets = true

    static let `default` = PDFImportOptions()
}

struct PDFImportResult: Sendable {
    var document: PDFImportedDocument
    var typst: String
    var markdown: String
    var json: String
    var warnings: [String] = []

    var summary: String {
        let blocks = document.blocks
        let pages = document.pages.count
        var parts = ["\(pages) page\(pages == 1 ? "" : "s")"]
        func add(_ count: Int, _ noun: String) {
            if count > 0 { parts.append("\(count) \(noun)\(count == 1 ? "" : "s")") }
        }
        add(blocks.filter(\.kind.isHeading).count, "heading")
        add(blocks.filter { $0.kind == .table }.count, "table")
        add(blocks.filter { $0.kind == .figure }.count, "figure")
        add(blocks.filter { $0.kind == .formula }.count, "formula")
        let ocr = document.pages.filter { $0.engine != .textLayer }.count
        if ocr > 0 { parts.append("\(ocr) page\(ocr == 1 ? "" : "s") via OCR") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Text Runs

/// A horizontally contiguous piece of text on one baseline.
///
/// Extractors split each visual line wherever the gap between words is wider
/// than a normal space, so a two-column line becomes two runs and a table row
/// becomes one run per cell. Every later stage (tables, reading order,
/// paragraphs) works on runs, which keeps that logic independent of whether
/// the text came from the PDF text layer or from OCR.
struct PDFTextRun: Sendable, Equatable {
    var text: String
    var rect: CGRect
    /// Dominant font size in points. OCR estimates it from the line height.
    var fontSize: CGFloat
    var isBold = false
    var isItalic = false
    /// Fraction (0…1) of characters set in a math font or that are math
    /// symbols. Display formulas score high; prose with an inline `x` scores low.
    var mathScore: Double = 0
    /// Vision's document recogniser marked this line as a title.
    var isTitle = false
    /// Position of the run's first character in the page's text, when it
    /// came from the text layer: the PDF's own reading order, which is
    /// reliable inside a table cell even where geometry is ambiguous.
    var textOrder: Int?

    init(text: String, rect: CGRect, fontSize: CGFloat, isBold: Bool = false,
         isItalic: Bool = false, mathScore: Double = 0, isTitle: Bool = false) {
        self.text = text
        self.rect = rect
        self.fontSize = fontSize
        self.isBold = isBold
        self.isItalic = isItalic
        self.mathScore = mathScore
        self.isTitle = isTitle
    }
}

/// A table or figure region found before reading order is computed. It
/// occupies space in the XY-cut like a big run, and becomes one block.
struct PDFRegion: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case table(PDFTableData)
        case figure
        /// Ruled region full of short text that did not resolve to a clean
        /// grid. Becomes a complex table (AI) or an image.
        case complexTable(cellText: [PDFTextRun])
        /// A block a layout model already recognised (a Vision paragraph,
        /// title or list item on a scanned page), placed by reading order.
        case block(PDFImportedBlock)
    }
    var kind: Kind
    var rect: CGRect
}
