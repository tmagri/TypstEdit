import Foundation
import AppKit
import PDFKit
import Vision
import ImageIO
import UniformTypeIdentifiers

/// Pulls positioned text, tables and figure regions out of PDF pages using
/// only Apple frameworks.
///
/// Three paths, picked per page:
/// 1. **Text layer** (PDFKit): exact characters with font names and sizes.
///    Used whenever a page has a usable text layer, which covers almost all
///    born-digital PDFs.
/// 2. **Vision document recognition** (macOS 26+): OCR plus paragraphs,
///    lists and table structure, for scanned pages.
/// 3. **Vision text recognition** (macOS 13+): OCR lines only, for scanned
///    pages on older systems.
///
/// Every coordinate leaving this type is in display space: points, origin at
/// the bottom-left of the crop box, page rotation applied.
enum PDFPageExtractor {

    // MARK: - Geometry

    /// Maps PDF page space to display space (rotation and crop box applied).
    static func displayTransform(for page: PDFPage) -> CGAffineTransform {
        page.transform(for: .cropBox)
    }

    static func displaySize(of page: PDFPage) -> CGSize {
        let rect = page.bounds(for: .cropBox).applying(displayTransform(for: page)).standardized
        return CGSize(width: rect.width.rounded(), height: rect.height.rounded())
    }

    // MARK: - Text Layer

    private struct Glyph {
        var text: String
        var rect: CGRect
        var fontSize: CGFloat
        var isBold: Bool
        var isItalic: Bool
        var isMath: Bool
        var spaceAfter = false
        /// Index of the word in the page text (text-layer words only).
        var order: Int?
    }

    /// Runs from the PDF text layer, or `nil` when the page has no usable
    /// text (scanned page, or text drawn with unmapped glyph encodings).
    ///
    /// Geometry comes from PDFKit selections, which is what PDFKit itself
    /// uses to draw highlights: lines from `selectionsByLine` (vertical
    /// extent), words from `selection(for: range)` (horizontal extent).
    /// `characterBounds` is not used: it returns tight glyph boxes that are
    /// useless for baselines, and its x positions drift in some PDFs.
    ///
    /// `barriers` are vertical rules (table borders): no run crosses one, so
    /// text in neighbouring cells stays apart even when the gap is narrow.
    static func textLayerRuns(for page: PDFPage, barriers: [PDFLatticeTables.Line] = []) -> [PDFTextRun]? {
        guard let attributed = page.attributedString, attributed.length > 0,
              let lines = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine(), !lines.isEmpty
        else { return nil }
        let string = attributed.string as NSString
        let transform = displayTransform(for: page)

        // and other legacy fonts map Hebrew and Greek onto ASCII
        // codes with no Unicode mapping, so their words arrive as gibberish
        // ("tyrb[b" for בעברית). The font that drew a word is only knowable
        // from the content stream, so it is read once when the page uses one.
        let legacy = legacyFragments(for: page)
        var words: [Glyph] = []
        var garbage = 0, visible = 0

        for line in lines {
            let lineRect = line.bounds(for: page).applying(transform).standardized
            guard lineRect.height > 0, lineRect.height < 300 else { continue }
            for r in 0..<line.numberOfTextRanges(on: page) {
                let lineRange = line.range(at: r, on: page)
                guard lineRange.location != NSNotFound, NSMaxRange(lineRange) <= string.length else { continue }
                // PDFKit's page string rejoins words hyphenated across lines
                // ("atten" + "tion" with no separator) while the line ranges
                // still split them. Mark such a break with a soft hyphen so
                // paragraph assembly joins the halves without a space.
                let continuesWord = lineRange.length > 0 && NSMaxRange(lineRange) < string.length
                    && isLetter(string.character(at: NSMaxRange(lineRange) - 1))
                    && isLetter(string.character(at: NSMaxRange(lineRange)))
                let ranges = wordRanges(in: string, range: lineRange)
                for (wordIndex, wordRange) in ranges.enumerated() {
                    var text = string.substring(with: wordRange)
                    if continuesWord && wordIndex == ranges.count - 1 { text += "\u{00AD}" }
                    let scalars = text.unicodeScalars
                    visible += scalars.count
                    garbage += scalars.filter(isGarbageScalar).count

                    guard let selection = page.selection(for: wordRange) else { continue }
                    let box = selection.bounds(for: page).applying(transform).standardized
                    guard box.width > 0, box.height > 0, !box.isNull else { continue }
                    // The word's own selection box: a line-height box like a
                    // highlight. PDFKit's line selections sometimes span
                    // several visual lines (seen on OCR text layers), so the
                    // line box is only a fallback for implausible word boxes.
                    let rect = box.height <= lineRect.height * 1.05 || lineRect.height < box.height * 0.5
                        ? box
                        : CGRect(x: box.minX, y: lineRect.minY, width: box.width, height: lineRect.height)

                    let fonts = fontsUsed(in: attributed, range: wordRange)
                    let primary = fonts.max { $0.count < $1.count }?.font
                    let traits = fontTraits(primary)
                    let mathFontChars = fonts.filter { PDFLayoutAnalyzer.isMathFont($0.font.fontName) }.reduce(0) { $0 + $1.count }
                    let mathChars = max(mathFontChars, scalars.filter(PDFLayoutAnalyzer.isMathScalar).count)

                    // Fake bold draws each word twice with a tiny offset.
                    if let last = words.last, last.text == text,
                       abs(last.rect.minX - rect.minX) < 1, abs(last.rect.minY - rect.minY) < 1 {
                        continue
                    }
                    words.append(Glyph(text: text, rect: rect,
                                       fontSize: effectiveFontSize(font: primary, lineHeight: rect.height),
                                       isBold: traits.bold, isItalic: traits.italic,
                                       isMath: mathChars * 2 >= max(scalars.count, 1), order: wordRange.location))
                }
            }
        }

        guard visible >= 12, words.count >= 3 else { return nil }
        guard Double(garbage) / Double(visible) < 0.1 else { return nil }
        var built = runs(from: words, barriers: barriers)
        if !legacy.isEmpty {
            built = built.map { run in
                var copy = run
                copy.text = replacingLegacy(in: run.text, fragments: legacy)
                return copy
            }.filter { !$0.text.isEmpty }
        }
        return built
    }

    /// Replaces the codes of legacy-font fragments inside a run's text with
    /// their decoded letters.
    ///
    /// The match ignores whitespace: PDFKit splits words where it likes (a
    /// Hebrew run can start mid-word, as in "ytwylkw(Lesëonenu"), so the
    /// fragment's codes are found as a run of characters, not as words.
    static func replacingLegacy(in text: String, fragments: [PDFLegacyFonts.Fragment]) -> String {
        // One fragment at a time. A phrase split into several fragments
        // ("vdq"),("-"),("ynba") keeps the page's visual order inside the run;
        // merging them is not attempted, since their codes are not contiguous
        // in the text PDFKit reports.
        var result = text
        for fragment in fragments {
            guard let encoding = PDFLegacyFonts.encoding(forFont: fragment.font) else { continue }
            let codes = fragment.text.filter { !$0.isWhitespace }
            guard codes.count >= 2 else { continue }
            let decoded = PDFLegacyFonts.decode(fragment.text, as: encoding)
                .trimmingCharacters(in: .whitespaces)
            guard !decoded.isEmpty, let range = whitespaceInsensitiveRange(of: codes, in: result) else { continue }
            result.replaceSubrange(range, with: decoded)
        }
        return result
    }

    /// The range of `haystack` whose non-whitespace characters spell `needle`.
    static func whitespaceInsensitiveRange(of needle: String, in haystack: String) -> Range<String.Index>? {
        let target = Array(needle)
        guard !target.isEmpty else { return nil }
        var index = haystack.startIndex
        while index < haystack.endIndex {
            if haystack[index] == target[0] {
                var cursor = index
                var matched = 0
                var end = index
                while cursor < haystack.endIndex, matched < target.count {
                    let character = haystack[cursor]
                    if !character.isWhitespace {
                        if character != target[matched] { break }
                        matched += 1
                    }
                    end = haystack.index(after: cursor)
                    cursor = end
                }
                if matched == target.count { return index..<end }
            }
            index = haystack.index(after: index)
        }
        return nil
    }

    private static func isLetter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    /// The page's legacy-font fragments, but only when the page uses such a
    /// font at all: the content stream walk costs time on every page, and most
    /// PDFs have none.
    private static func legacyFragments(for page: PDFPage) -> [PDFLegacyFonts.Fragment] {
        guard let pageRef = page.pageRef else { return [] }
        let names = PDFLegacyFonts.fontNames(of: pageRef).values
        guard names.contains(where: {
            PDFLegacyFonts.encoding(forFont: $0) != nil || PDFLegacyFonts.isUndecodedLegacyFont($0)
        }) else { return [] }
        return PDFLegacyFonts.fragments(of: page, displaySize: displaySize(of: page))
    }

    /// The names of fonts on the page that carry no Unicode mapping and are
    /// not decoded here (transliteration and symbol fonts), so the
    /// import can warn that this page's text needs a check.
    static func undecodedLegacyFonts(of page: PDFPage) -> [String] {
        guard let pageRef = page.pageRef else { return [] }
        return Set(PDFLegacyFonts.fontNames(of: pageRef).values.filter(PDFLegacyFonts.isUndecodedLegacyFont))
            .sorted()
    }

    /// Ranges of whitespace-separated words inside `range`.
    private static func wordRanges(in string: NSString, range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var start: Int?
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            let composed = string.rangeOfComposedCharacterSequence(at: index)
            let isSpace = string.substring(with: composed).allSatisfy { $0.isWhitespace || $0.isNewline }
            if isSpace {
                if let s = start { result.append(NSRange(location: s, length: composed.location - s)); start = nil }
            } else if start == nil {
                start = composed.location
            }
            index = NSMaxRange(composed)
        }
        if let s = start, end > s { result.append(NSRange(location: s, length: end - s)) }
        return result
    }

    /// Fonts in `range` with the number of characters set in each.
    private static func fontsUsed(in attributed: NSAttributedString, range: NSRange) -> [(font: NSFont, count: Int)] {
        var result: [(font: NSFont, count: Int)] = []
        attributed.enumerateAttribute(.font, in: range) { value, subrange, _ in
            if let font = value as? NSFont { result.append((font, subrange.length)) }
        }
        return result
    }

    /// Replacement characters, private-use code points and control codes
    /// mean the font has no usable Unicode mapping: OCR does better.
    private static func isGarbageScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xF0B7, 0xF0A7, 0xF076, 0xF0D8, 0xF0FC: return false   // Word's Symbol/Wingdings bullets
        case 0xFFFD, 0xE000...0xF8FF, 0x0000...0x0008, 0x000E...0x001F: return true
        default: return false
        }
    }

    private static func fontTraits(_ font: NSFont?) -> (bold: Bool, italic: Bool) {
        guard let font else { return (false, false) }
        let name = font.fontName.lowercased()
        let symbolic = font.fontDescriptor.symbolicTraits
        let bold = symbolic.contains(.bold)
            || (["bold", "black", "heavy", "semibold", "demi", "cmbx", "-bd"].contains { name.contains($0) } && !name.contains("light"))
        let italic = symbolic.contains(.italic)
            || ["italic", "oblique", "cmti", "cmsl"].contains { name.contains($0) }
        return (bold, italic)
    }

    /// The reported point size, unless the text matrix scaled it (common in
    /// generated PDFs: a 1 pt font scaled ×10); then estimated from the line.
    private static func effectiveFontSize(font: NSFont?, lineHeight: CGFloat) -> CGFloat {
        if let size = font?.pointSize, size >= 3, lineHeight > 0 {
            let ratio = lineHeight / size
            if ratio > 0.7 && ratio < 2.6 { return size }
        }
        return max(lineHeight / 1.25, 1)
    }

    /// Groups glyphs into baselines, then splits each baseline at gaps wider
    /// than a word space. A two-column line yields two runs; a table row
    /// yields one run per cell.
    private static func runs(from glyphs: [Glyph], barriers: [PDFLatticeTables.Line] = []) -> [PDFTextRun] {
        var rows = groupGlyphRows(glyphs)
        mergeScriptRows(&rows)

        // The page's ordinary word space, so the tight-column split below is
        // relative to how this PDF spaces words (OCR boxes jitter).
        var spaces: [CGFloat] = []
        for row in rows {
            let sorted = row.sorted { $0.rect.minX < $1.rect.minX }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                let gap = b.rect.minX - a.rect.maxX
                if gap > 0, gap < max(a.fontSize, b.fontSize) * 0.9 { spaces.append(gap) }
            }
        }
        spaces.sort()
        let wordSpace = spaces.isEmpty ? 0 : spaces[spaces.count / 2]

        var result: [PDFTextRun] = []
        for row in rows {
            for piece in splitAtBarriers(row.sorted { $0.rect.minX < $1.rect.minX }, barriers: barriers) {
                for segment in splitRow(piece, wordSpace: wordSpace) {
                    result.append(contentsOf: runs(fromSegment: segment))
                }
            }
        }
        return result
    }

    /// Splits a baseline wherever a vertical rule runs between two words.
    private static func splitAtBarriers(_ words: [Glyph], barriers: [PDFLatticeTables.Line]) -> [[Glyph]] {
        guard !barriers.isEmpty, words.count > 1 else { return [words] }
        var pieces: [[Glyph]] = [[words[0]]]
        for (previous, word) in zip(words, words.dropFirst()) {
            let y = word.rect.midY
            let blocked = barriers.contains { line in
                line.position > previous.rect.maxX - 1 && line.position < word.rect.minX + 1
                    && line.start <= y && y <= line.end
            }
            if blocked { pieces.append([word]) } else { pieces[pieces.count - 1].append(word) }
        }
        return pieces
    }

    /// Splits one baseline into runs in two passes. Gaps wider than 0.9 em
    /// always split (page columns, wide table gaps). Inside each piece, gaps
    /// wider than 0.55 em and 2.5 ordinary word spaces split too (tight
    /// table columns), unless the piece's spacing is uniform — justified
    /// prose stretches every space alike, while a table row mixes word
    /// spaces with wider cell gaps.
    private static func splitRow(_ words: [Glyph], wordSpace: CGFloat) -> [[Glyph]] {
        func split(_ words: [Glyph], threshold: (Glyph, Glyph) -> CGFloat) -> [[Glyph]] {
            var pieces: [[Glyph]] = []
            for word in words {
                if let previous = pieces.last?.last, word.rect.minX - previous.rect.maxX > threshold(previous, word) {
                    pieces.append([word])
                } else if pieces.isEmpty {
                    pieces.append([word])
                } else {
                    pieces[pieces.count - 1].append(word)
                }
            }
            return pieces
        }
        let em = { (a: Glyph, b: Glyph) in max(a.fontSize, b.fontSize) }
        // Pass 1: gutter-sized gaps only. OCR layers sometimes shrink word
        // boxes, making every space in a line look wide, so a plain 0.9 em
        // rule would cut such lines into single words.
        let rowGaps = zip(words, words.dropFirst()).map { $1.rect.minX - $0.rect.maxX }.filter { $0 > 0 }.sorted()
        let rowMedian = rowGaps.isEmpty ? 0 : rowGaps[rowGaps.count / 2]
        let gutter = { (a: Glyph, b: Glyph) -> CGFloat in
            min(em(a, b) * 1.4, max(em(a, b) * 0.9, rowMedian * 3))
        }
        return split(words, threshold: gutter).flatMap { piece -> [[Glyph]] in
            let gaps = zip(piece, piece.dropFirst()).map { $1.rect.minX - $0.rect.maxX }.filter { $0 > 0 }.sorted()
            if gaps.count >= 3, let median = gaps.dropFirst(gaps.count / 2).first, let widest = gaps.last,
               widest < median * 1.5 {
                return [piece]
            }
            return split(piece) { max(em($0, $1) * 0.55, wordSpace * 2.5) }
        }
    }

    /// The words of one segment in reading order. A right-to-left line is
    /// extracted in visual (drawn) order, so its words are put back into
    /// logical order. Left-to-right lines are left as they are.
    private static func orderedWords(_ words: [Glyph]) -> [Glyph] {
        guard TextScript.isRightToLeftLine(words.map(\.text).joined(separator: " ")) else { return words }
        return words.reversed()
    }

    /// The same reordering on plain words, so it can be tested without a PDF.
    nonisolated static func readingOrderedWords(_ words: [String]) -> [String] {
        TextScript.isRightToLeftLine(words.joined(separator: " ")) ? words.reversed() : words
    }

    /// One run from the words of one segment, joined with single spaces.
    /// Words normally read left to right; when they sit on visibly different
    /// lines (two tight lines merged into one row, as in a two-line table
    /// cell), the PDF's text order is used instead.
    private static func runs(fromSegment segment: [Glyph]) -> [PDFTextRun] {
        var words = segment
        let mids = words.map(\.rect.midY)
        if let low = mids.min(), let high = mids.max(), let height = words.map(\.rect.height).min(),
           high - low > height * 0.3, words.allSatisfy({ $0.order != nil }) {
            words.sort { $0.order! < $1.order! }
        }
        // Right-to-left text reaches us in the order the glyphs are drawn:
        // the words of an Arabic or Hebrew line are reversed. Restore them.
        words = Self.orderedWords(words)
        let text = words.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        let sizes = words.map(\.fontSize).sorted()
        let count = Double(words.count)
        let mathShare = Double(words.filter(\.isMath).count) / count
        var run = PDFTextRun(
            text: text,
            rect: words.reduce(CGRect.null) { $0.union($1.rect) },
            fontSize: sizes[sizes.count / 2],
            isBold: Double(words.filter(\.isBold).count) / count >= 0.8,
            isItalic: Double(words.filter(\.isItalic).count) / count >= 0.8,
            mathScore: max(mathShare, PDFLayoutAnalyzer.mathSymbolFraction(text)))
        run.textOrder = words.compactMap(\.order).min()
        return [run]
    }

    private static func groupGlyphRows(_ glyphs: [Glyph]) -> [[Glyph]] {
        let sorted = glyphs.sorted { $0.rect.midY > $1.rect.midY }
        var rows: [[Glyph]] = []
        var reference: CGRect = .null
        for glyph in sorted {
            if !reference.isNull,
               abs(glyph.rect.midY - reference.midY) <= 0.35 * max(reference.height, glyph.rect.height) {
                rows[rows.count - 1].append(glyph)
                // Keep the tallest glyph as the reference, so a run of small
                // glyphs cannot drag the baseline.
                if glyph.rect.height > reference.height { reference = glyph.rect }
            } else {
                rows.append([glyph])
                reference = glyph.rect
            }
        }
        return rows
    }

    /// Superscripts, subscripts and footnote marks sort into rows of their
    /// own; fold each into the full-size row it overlaps.
    private static func mergeScriptRows(_ rows: inout [[Glyph]]) {
        func height(_ row: [Glyph]) -> CGFloat {
            let heights = row.map(\.rect.height).sorted()
            return heights[heights.count / 2]
        }
        func band(_ row: [Glyph]) -> CGRect { row.reduce(CGRect.null) { $0.union($1.rect) } }

        var i = 0
        while i < rows.count {
            let row = rows[i]
            let small = height(row)
            let neighbours = [i - 1, i + 1].filter { rows.indices.contains($0) }
            if let target = neighbours.first(where: { n in
                small < height(rows[n]) * 0.8
                    && PDFLayoutAnalyzer.verticalOverlap(band(row), band(rows[n])) > 0
                    && horizontallyNear(band(row), band(rows[n]))
            }) {
                rows[target].append(contentsOf: row)
                rows.remove(at: i)
                if target < i { i -= 1 }
                continue
            }
            i += 1
        }
    }

    private static func horizontallyNear(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX <= b.maxX + 4 && b.minX <= a.maxX + 4
    }

    // MARK: - Rendering

    /// Renders the page (or a display-space region of it) to an RGB image.
    static func render(_ page: PDFPage, scale: CGFloat, region: CGRect? = nil) -> CGImage? {
        let size = displaySize(of: page)
        let area = (region ?? CGRect(origin: .zero, size: size)).integral
        let width = Int(area.width * scale), height = Int(area.height * scale)
        guard width > 0, height > 0, width * height < 40_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -area.minX, y: -area.minY)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: - OCR

    struct OCRPage {
        /// Lines for the layout analyzer (plain text recognition only).
        var runs: [PDFTextRun]
        /// Tables and recognised blocks, already structured.
        var regions: [PDFRegion]
        var engine: PDFPageEngine
        /// Recognised lines, for finding tables the layout model missed.
        var lines: [PDFTextRun] = []
    }

    /// Reads a scanned page from its image: a layout model
    /// (Vision document recognition, macOS 26+) supplies the structure, and
    /// the text comes from the page's OCR layer when it has one (`textLayer`)
    /// — often a better OCR than a fresh pass — or from Vision otherwise.
    /// Older systems fall back to the text layer, or to line OCR plus the
    /// layout analyzer.
    static func recognize(_ image: CGImage, page: PDFPage, displaySize: CGSize, textLayer: [PDFTextRun]?) async -> OCRPage {
        if #available(macOS 26.0, *) {
            if let result = try? await recognizeDocument(image, page: page, displaySize: displaySize, textLayer: textLayer),
               !result.regions.isEmpty {
                return result
            }
        }
        if let textLayer, !textLayer.isEmpty {
            return OCRPage(runs: textLayer, regions: [], engine: .textLayer)
        }
        return OCRPage(runs: recognizeText(image, displaySize: displaySize), regions: [], engine: .visionOCR)
    }

    static func recognizeText(_ image: CGImage, displaySize: CGSize) -> [PDFTextRun] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX * displaySize.width, y: box.minY * displaySize.height,
                              width: box.width * displaySize.width, height: box.height * displaySize.height)
            return ocrRun(text, rect: rect, isTitle: false)
        }
    }

    @available(macOS 26.0, *)
    static func recognizeDocument(_ image: CGImage, page: PDFPage, displaySize: CGSize,
                                  textLayer: [PDFTextRun]?) async throws -> OCRPage {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = true
        request.barcodeDetectionOptions.enabled = false
        let observations = try await request.perform(on: image, orientation: nil)
        guard let document = observations.first?.document else {
            return OCRPage(runs: [], regions: [], engine: .visionDocument)
        }

        var tables: [PDFRegion] = []
        for table in document.tables {
            let rect = table.boundingRegion.boundingBox.toImageCoordinates(displaySize, origin: .lowerLeft)
            let cells = table.rows.flatMap { $0 }
            let rowCount = (cells.map(\.rowRange.upperBound).max() ?? -1) + 1
            let columnCount = (cells.map(\.columnRange.upperBound).max() ?? -1) + 1
            guard rowCount >= 1, columnCount >= 1 else { continue }
            var grid = Array(repeating: Array(repeating: "", count: columnCount), count: rowCount)
            var spans = false
            for cell in cells {
                let text = cell.content.text.transcript.replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                grid[cell.rowRange.lowerBound][cell.columnRange.lowerBound] = text
                if cell.rowRange.count > 1 || cell.columnRange.count > 1 { spans = true }
            }
            var data = PDFTableData(rows: grid)
            data.source = .vision
            data.isComplex = spans
            tables.append(PDFRegion(kind: .table(data), rect: rect))
        }

        // Paragraphs and list items, each with its lines (for weight and size).
        struct Unit { var rect: CGRect; var transcript: String; var lines: [RecognizedTextObservation]; var listItem: Bool }
        var units: [Unit] = []
        for list in document.lists {
            for item in list.items {
                let text = item.content.text
                // Vision reports the marker ("1.", "•") apart from the item
                // text; put it back so the item is typed as a list item.
                let marker = item.markerString.trimmingCharacters(in: .whitespaces)
                let transcript = marker.isEmpty ? item.itemString : marker + " " + item.itemString
                units.append(Unit(rect: text.boundingRegion.boundingBox.toImageCoordinates(displaySize, origin: .lowerLeft),
                                  transcript: transcript, lines: text.lines, listItem: true))
            }
        }
        // Paragraphs not already covered by a table, a list item, or an
        // earlier paragraph (Vision's groupings can overlap).
        var taken = tables.map(\.rect) + units.map(\.rect)
        for paragraph in document.paragraphs {
            let rect = paragraph.boundingRegion.boundingBox.toImageCoordinates(displaySize, origin: .lowerLeft)
            guard !taken.contains(where: { insideFraction(rect, $0) > 0.5 || insideFraction($0, rect) > 0.8 }) else { continue }
            units.append(Unit(rect: rect, transcript: paragraph.transcript, lines: paragraph.lines, listItem: false))
            taken.append(rect)
        }

        // Visual weight per recognised line.
        var lineRuns: [PDFTextRun] = []
        var owner: [Int] = []
        for (index, unit) in units.enumerated() {
            for line in unit.lines {
                lineRuns.append(ocrRun(line.transcript, rect: line.boundingBox.toImageCoordinates(displaySize, origin: .lowerLeft),
                                       isTitle: line.isTitle))
                owner.append(index)
            }
        }
        applyInkWeight(page: page, displaySize: displaySize, runs: &lineRuns, sizesTrusted: false)

        var usedWords = Set<Int>()
        var regions = tables
        for (index, unit) in units.enumerated() {
            let mine = lineRuns.indices.filter { owner[$0] == index }.map { lineRuns[$0] }
            let chars = max(mine.reduce(0) { $0 + $1.text.count }, 1)
            let boldChars = mine.filter(\.isBold).reduce(0) { $0 + $1.text.count }
            let sizes = mine.map(\.fontSize).sorted()
            var text = unit.listItem ? unit.transcript : fill(unit.rect, from: textLayer, used: &usedWords)
                ?? PDFLayoutAnalyzer.joinLines(unit.transcript.components(separatedBy: .newlines))
            if unit.listItem, let layered = fill(unit.rect, from: textLayer, used: &usedWords) { text = layered }
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let block = PDFLayoutAnalyzer.recognisedBlock(
                text: text, rect: unit.rect, fontSize: sizes.isEmpty ? 10 : sizes[sizes.count / 2],
                isTitle: mine.contains(where: \.isTitle), isBold: boldChars * 10 >= chars * 8,
                lineCount: max(mine.count, 1))
            regions.append(PDFRegion(kind: .block(block), rect: unit.rect))
        }
        return OCRPage(runs: [], regions: regions, engine: .visionDocument, lines: lineRuns)
    }

    /// The text-layer words inside `rect`, in reading order, or `nil` when
    /// there are none. Each word is used once.
    private static func fill(_ rect: CGRect, from layer: [PDFTextRun]?, used: inout Set<Int>) -> String? {
        guard let layer, !layer.isEmpty else { return nil }
        let area = rect.insetBy(dx: -2, dy: -2)
        let inside = layer.indices.filter { !used.contains($0) && area.contains(CGPoint(x: layer[$0].rect.midX, y: layer[$0].rect.midY)) }
        guard !inside.isEmpty else { return nil }
        used.formUnion(inside)
        let words = inside.map { layer[$0] }
        let lines = PDFLayoutAnalyzer.groupIntoRows(words).map { row in row.members.map { words[$0].text }.joined(separator: " ") }
        return PDFLayoutAnalyzer.joinLines(lines)
    }

    /// OCR boxes hug the glyphs, so the box height is close to the font size.
    private static func ocrRun(_ text: String, rect: CGRect, isTitle: Bool) -> PDFTextRun {
        PDFTextRun(text: text, rect: rect, fontSize: max((rect.height * 0.85 * 2).rounded() / 2, 4),
                   mathScore: PDFLayoutAnalyzer.mathSymbolFraction(text), isTitle: isTitle)
    }

    // MARK: - Scanned Pages

    /// True when the page draws a large image shaped like the page: a scan.
    /// Its text layer, if any, is invisible OCR whose geometry (sizes in
    /// particular) cannot be trusted.
    static func isScannedPage(_ page: PDFPage) -> Bool {
        guard let dictionary = page.pageRef?.dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        var xObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return false }
        let pageSize = displaySize(of: page)
        let pageAspect = pageSize.width / max(pageSize.height, 1)
        let rotated = 1 / max(pageAspect, 0.01)

        final class Finding { var found = false; var aspects: (CGFloat, CGFloat) = (0, 0) }
        let finding = Finding()
        finding.aspects = (pageAspect, rotated)
        CGPDFDictionaryApplyFunction(xObjects, { _, object, info in
            guard let info else { return }
            let finding = Unmanaged<Finding>.fromOpaque(info).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard !finding.found, CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let streamDictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            var width: CGPDFInteger = 0, height: CGPDFInteger = 0
            guard CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Image",
                  CGPDFDictionaryGetInteger(streamDictionary, "Width", &width),
                  CGPDFDictionaryGetInteger(streamDictionary, "Height", &height),
                  width * height >= 1_000_000 else { return }
            let aspect = CGFloat(width) / CGFloat(max(height, 1))
            if abs(aspect - finding.aspects.0) < finding.aspects.0 * 0.06
                || abs(aspect - finding.aspects.1) < finding.aspects.1 * 0.06 {
                finding.found = true
            }
        }, Unmanaged.passUnretained(finding).toOpaque())
        return finding.found
    }

    // MARK: - Visual Weight (bold)

    /// Marks bold runs by stroke width.
    ///
    /// PDFKit reports most embedded fonts under a substitute name (often
    /// "Helvetica"), so font traits rarely reveal bold. Instead this measures
    /// the stems: the median length of horizontal runs of dark pixels across
    /// a word is its vertical stroke width. Divided by the font size it is
    /// independent of size, and bold faces run about 1.5–2× regular, so each
    /// run is compared with the body text.
    ///
    /// With `sizesTrusted == false` (scans), stroke width is compared at the
    /// page's typical size instead of each run's own: OCR box sizes are noise
    /// and would make the ratio noise too.
    static func applyInkWeight(page: PDFPage, displaySize: CGSize, runs: inout [PDFTextRun], sizesTrusted: Bool = true) {
        guard runs.count >= 4 else { return }
        let scale: CGFloat = 3
        let width = Int(displaySize.width * scale), height = Int(displaySize.height * scale)
        guard width > 0, height > 0, width * height < 30_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return }

        let pageSize: CGFloat = {
            let sizes = runs.map(\.fontSize).sorted()
            return sizes.isEmpty ? 10 : sizes[sizes.count / 2]
        }()
        /// Typical stroke width in pixels, per point of font size. Each
        /// horizontal run of ink is weighted by pixel coverage, so the
        /// antialiased edges give sub-pixel precision; a trimmed mean then
        /// ignores serifs and joins.
        func stemRatio(_ run: PDFTextRun) -> Double? {
            guard run.text.filter(\.isLetter).count >= 2 else { return nil }
            let rect = run.rect
            let x0 = max(Int(rect.minX * scale), 0), x1 = min(Int(rect.maxX * scale), width)
            let rowTop = max(height - Int(rect.maxY * scale), 0), rowBottom = min(height - Int(rect.minY * scale), height)
            guard x1 > x0 + 3, rowBottom > rowTop + 3 else { return nil }
            let size = sizesTrusted ? run.fontSize : pageSize
            // Horizontal bars (T, E, underlines) are long; skip them.
            let longest = Double(max(size, run.rect.height / 1.25) * scale) * 0.4
            var widths: [Double] = []
            for row in rowTop..<rowBottom {
                let base = row * width
                var coverage = 0.0
                var darkest: UInt8 = 255
                for x in x0...x1 {
                    let value = x < x1 ? data[base + x] : 255
                    if value < 220 {
                        coverage += Double(255 - value) / 255
                        darkest = min(darkest, value)
                    } else if coverage > 0 {
                        // Only strokes with a solid core: faint fringes of
                        // neighbouring glyphs are not stems.
                        if darkest < 110 && coverage <= longest { widths.append(coverage) }
                        coverage = 0
                        darkest = 255
                    }
                }
            }
            guard widths.count >= 8 else { return nil }
            widths.sort()
            let core = widths[(widths.count / 4)..<(widths.count * 3 / 4)]
            return core.reduce(0, +) / Double(core.count) / Double(max(size, 1))
        }

        let values = runs.map(stemRatio)
        // Body reference: the most common size, by characters (every run
        // when sizes are untrusted).
        let body = PDFLayoutAnalyzer.bodyFontSize(runs)
        let reference = runs.indices.compactMap {
            !sizesTrusted || abs(runs[$0].fontSize - body) < 0.75 ? values[$0] : nil
        }.sorted()
        guard reference.count >= 3 else { return }
        let regular = reference[reference.count / 2]
        guard regular > 0 else { return }
        // Stroke widths on scans vary with ink and paper, so bold must also
        // stand out from this page's own spread (robust: median absolute
        // deviation scaled to a standard deviation).
        let deviations = reference.map { abs($0 - regular) }.sorted()
        let spread = deviations[deviations.count / 2] * 1.4826
        let threshold = max(regular * 1.3, regular + spread * 3.5)
        for i in runs.indices {
            if let value = values[i], value >= threshold { runs[i].isBold = true }
        }
    }

    /// Text drawn as outlines (no text layer for it — common for section
    /// numbers, logos-as-text, and some generators' headings) looks like a
    /// small figure. This reads such a region with OCR and returns text runs
    /// when it is clearly text, or `nil` to keep it as a figure.
    ///
    /// `known` is text already on the page: it is painted out first, so OCR
    /// reads only the ink that is not text yet.
    static func textInLineShapedRegion(page: PDFPage, rect: CGRect, known: [PDFTextRun]) -> [PDFTextRun]? {
        let scale: CGFloat = 4
        let area = rect.insetBy(dx: -2, dy: -2)
        guard rect.height <= 80, rect.width >= rect.height * 1.2,
              let rendered = render(page, scale: scale, region: area),
              let context = CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for run in known where run.rect.intersects(area) {
            let r = run.rect.insetBy(dx: -1, dy: -1)
            context.fill(CGRect(x: (r.minX - area.integral.minX) * scale, y: (r.minY - area.integral.minY) * scale,
                                width: r.width * scale, height: r.height * scale))
        }
        guard let image = context.makeImage() else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results, !results.isEmpty else { return nil }
        // `render` crops to the integral rectangle; map boxes back through it.
        let crop = area.integral
        var runs: [PDFTextRun] = []
        var covered: CGFloat = 0
        for observation in results {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.5,
                  candidate.string.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            let box = observation.boundingBox
            let r = CGRect(x: crop.minX + box.minX * crop.width, y: crop.minY + box.minY * crop.height,
                           width: box.width * crop.width, height: box.height * crop.height)
            covered += r.width * r.height
            runs.append(ocrRun(candidate.string, rect: r, isTitle: false))
        }
        guard !runs.isEmpty, covered >= rect.width * rect.height * 0.35 else { return nil }
        return runs
    }

    // MARK: - Figure Detection

    struct FigureDetection {
        var regions: [PDFRegion]
        /// Runs inside figures (axis labels, legends) or complex tables.
        var absorbed: Set<Int>
        /// Ink too small to be a figure but shaped like a line of text: text
        /// drawn as outlines (a heading or section number). Offered to OCR,
        /// dropped when it does not read as text.
        var textCandidates: [CGRect] = []
    }

    /// Finds figures as ink that is not explained by text.
    ///
    /// Renders the page at 1 px per point, paints every text run and table
    /// white, and looks for connected blobs of what remains. That catches
    /// embedded photos and vector charts alike, with no model.
    static func detectFigures(page: PDFPage, displaySize: CGSize, runs: [PDFTextRun], tableRects: [CGRect]) -> FigureDetection {
        let width = Int(displaySize.width), height = Int(displaySize.height)
        guard width > 20, height > 20,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return FigureDetection(regions: [], absorbed: []) }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .cropBox, to: context)
        context.setFillColor(gray: 1, alpha: 1)
        for run in runs { context.fill(run.rect.insetBy(dx: -1.5, dy: -1.5)) }
        for rect in tableRects { context.fill(rect.insetBy(dx: -3, dy: -3)) }

        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return FigureDetection(regions: [], absorbed: [])
        }
        let pixels = UnsafeBufferPointer(start: data, count: width * height)

        // Background from a sparse sample, so tinted scans still work.
        var sample: [UInt8] = []
        sample.reserveCapacity(4096)
        stride(from: 0, to: pixels.count, by: max(1, pixels.count / 4096)).forEach { sample.append(pixels[$0]) }
        sample.sort()
        let background = Int(sample[sample.count / 2])
        let inkThreshold = UInt8(clamping: min(background - 35, 232))

        // Coarse occupancy grid: 4×4 pt cells.
        let cell = 4
        let gridW = (width + cell - 1) / cell, gridH = (height + cell - 1) / cell
        var ink = [Bool](repeating: false, count: gridW * gridH)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where pixels[row + x] < inkThreshold {
                ink[(y / cell) * gridW + x / cell] = true
            }
        }

        // Dilate by two cells so a chart's separate strokes join up.
        let radius = 2
        var grown = [Bool](repeating: false, count: ink.count)
        for gy in 0..<gridH {
            for gx in 0..<gridW where ink[gy * gridW + gx] {
                for dy in -radius...radius {
                    let ny = gy + dy
                    guard ny >= 0, ny < gridH else { continue }
                    for dx in -radius...radius {
                        let nx = gx + dx
                        if nx >= 0, nx < gridW { grown[ny * gridW + nx] = true }
                    }
                }
            }
        }

        // Connected components; each box is measured on the undilated ink.
        var seen = [Bool](repeating: false, count: ink.count)
        var boxes: [(rect: CGRect, density: Double, rules: Int)] = []
        for start in grown.indices where grown[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            var inkCells = 0
            var members: [Int] = []
            while let current = stack.popLast() {
                members.append(current)
                let gx = current % gridW, gy = current / gridW
                if ink[current] {
                    inkCells += 1
                    minX = min(minX, gx); maxX = max(maxX, gx); minY = min(minY, gy); maxY = max(maxY, gy)
                }
                for (nx, ny) in [(gx - 1, gy), (gx + 1, gy), (gx, gy - 1), (gx, gy + 1)]
                where nx >= 0 && nx < gridW && ny >= 0 && ny < gridH {
                    let next = ny * gridW + nx
                    if grown[next] && !seen[next] { seen[next] = true; stack.append(next) }
                }
            }
            guard inkCells > 0 else { continue }
            let cellsW = maxX - minX + 1, cellsH = maxY - minY + 1
            // Exact pixel bounds of the ink inside the component's cells, so
            // a crop does not reach into a caption a few points away.
            var px0 = Int.max, px1 = Int.min, py0 = Int.max, py1 = Int.min
            for y in (minY * cell)..<min((maxY + 1) * cell, height) {
                let row = y * width
                for x in (minX * cell)..<min((maxX + 1) * cell, width) where pixels[row + x] < inkThreshold {
                    px0 = min(px0, x); px1 = max(px1, x); py0 = min(py0, y); py1 = max(py1, y)
                }
            }
            guard px0 <= px1, py0 <= py1 else { continue }
            // Bitmap rows run top-down; display space runs bottom-up.
            let rect = CGRect(x: CGFloat(px0), y: CGFloat(height - py1 - 1),
                              width: CGFloat(px1 - px0 + 1), height: CGFloat(py1 - py0 + 1))
            let density = Double(inkCells) / Double(cellsW * cellsH)
            boxes.append((rect, density, ruleCount(ink, gridW: gridW, minX: minX, maxX: maxX, minY: minY, maxY: maxY)))
        }

        let pageArea = displaySize.width * displaySize.height
        var regions: [PDFRegion] = []
        var absorbed = Set<Int>()
        var textCandidates: [CGRect] = []
        for box in boxes {
            let rect = box.rect
            if rect.width < 36 || rect.height < 24 || rect.width * rect.height < pageArea * 0.004 {
                // Shaped like a word or line of text (not a bullet, rule
                // fragment or speck): worth one OCR attempt.
                if rect.height >= 6, rect.height <= 30, rect.width >= 20, rect.width >= rect.height * 1.5, box.density >= 0.08 {
                    textCandidates.append(rect)
                }
                continue
            }
            guard rect.width >= 36, rect.height >= 24, min(rect.width, rect.height) >= 12,
                  rect.width * rect.height >= pageArea * 0.004,
                  rect.width * rect.height <= pageArea * 0.92,
                  box.density >= 0.03 else { continue }

            let expanded = rect.insetBy(dx: -4, dy: -4)
            let inside = runs.indices.filter { insideFraction(runs[$0].rect, expanded) >= 0.6 }
            let chars = inside.reduce(0) { $0 + runs[$1].text.count }
            let textArea = inside.reduce(CGFloat(0)) { $0 + runs[$1].rect.width * runs[$1].rect.height }
            let textCoverage = textArea / (rect.width * rect.height)

            // A gridded table: several full-width rules AND several rows of
            // multiple short cells. A framed chart has rules too, but its
            // labels sit along the axes, not in rows of cells.
            if box.rules >= 3, inside.count >= 6 {
                let lengths = inside.map { runs[$0].text.count }.sorted()
                let cellRows = PDFLayoutAnalyzer.groupIntoRows(inside.map { runs[$0] }).filter { $0.members.count >= 2 }.count
                if lengths[lengths.count / 2] <= 30, cellRows >= 3 {
                    regions.append(PDFRegion(kind: .complexTable(cellText: inside.map { runs[$0] }), rect: rect))
                    absorbed.formUnion(inside)
                    continue
                }
            }
            // Shaded boxes full of prose are text, not figures.
            if chars >= 250 && textCoverage >= 0.2 { continue }
            regions.append(PDFRegion(kind: .figure, rect: rect))
            absorbed.formUnion(inside)
        }
        // Largest first, a few per page: outlined headings are few, and each
        // attempt is an OCR pass.
        let candidates = Array(textCandidates.sorted { $0.width * $0.height > $1.width * $1.height }.prefix(6))
        return FigureDetection(regions: regions, absorbed: absorbed, textCandidates: candidates)
    }

    /// Number of separate horizontal rules: grid rows with ink across most
    /// of the box, counting adjacent rows as one rule.
    private static func ruleCount(_ ink: [Bool], gridW: Int, minX: Int, maxX: Int, minY: Int, maxY: Int) -> Int {
        let width = maxX - minX + 1
        guard width >= 10 else { return 0 }
        var rules = 0
        var previousWasRule = false
        for gy in minY...maxY {
            var filled = 0
            for gx in minX...maxX where ink[gy * gridW + gx] { filled += 1 }
            let isRule = Double(filled) >= Double(width) * 0.8
            if isRule && !previousWasRule { rules += 1 }
            previousWasRule = isRule
        }
        return rules
    }

    /// Share of `rect`'s area that lies inside `container`.
    static func insideFraction(_ rect: CGRect, _ container: CGRect) -> CGFloat {
        let area = rect.width * rect.height
        guard area > 0 else { return container.contains(CGPoint(x: rect.midX, y: rect.midY)) ? 1 : 0 }
        let overlap = rect.intersection(container)
        return overlap.isNull ? 0 : (overlap.width * overlap.height) / area
    }
}
