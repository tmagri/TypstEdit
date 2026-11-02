import Foundation
import PDFKit

/// Ruled ("lattice") tables, rebuilt from the lines that draw them.
///
/// Manuals, specifications, forms and invoices draw every cell border. Those
/// lines carry the whole structure — including merged cells — so this reads
/// them directly instead of guessing columns from text alignment, the same
/// idea as Camelot's lattice mode and table pipeline:
///
/// 1. Render the page and find long horizontal and vertical ink runs.
/// 2. Group touching lines into tables; their positions give the grid.
/// 3. A missing inner border merges two grid cells: rowspan / colspan.
/// 4. Words are assigned to cells by position.
enum PDFLatticeTables {

    struct Line: Equatable {
        /// The fixed coordinate (y for horizontal, x for vertical), in points.
        var position: CGFloat
        /// Extent along the line, in points.
        var start: CGFloat
        var end: CGFloat
    }

    struct Rulings {
        var horizontal: [Line] = []
        var vertical: [Line] = []
        var isEmpty: Bool { horizontal.isEmpty || vertical.isEmpty }
    }

    // MARK: - Ruling Lines

    /// Long thin ink runs on the page. Glyph strokes are short, so a minimum
    /// length (15 pt across, 10 pt down) leaves only drawn rules.
    static func rulings(page: PDFPage, displaySize: CGSize) -> Rulings {
        let scale: CGFloat = 2
        let width = Int(displaySize.width * scale), height = Int(displaySize.height * scale)
        guard width > 0, height > 0, width * height < 30_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return Rulings() }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return Rulings() }
        let dark: UInt8 = 200

        var horizontal: [(y: Int, x0: Int, x1: Int)] = []
        let minAcross = Int(15 * scale)
        for y in 0..<height {
            let base = y * width
            var start = -1
            for x in 0...width {
                let isDark = x < width && data[base + x] < dark
                if isDark { if start < 0 { start = x } } else if start >= 0 {
                    if x - start >= minAcross { horizontal.append((y, start, x - 1)) }
                    start = -1
                }
            }
        }
        // Row-major with one open run per column: the bitmap is read in
        // memory order (a column-by-column walk is cache-hostile).
        var vertical: [(x: Int, y0: Int, y1: Int)] = []
        let minDown = Int(10 * scale)
        var openSince = [Int](repeating: -1, count: width)
        for y in 0...height {
            let base = y * width
            for x in 0..<width {
                let isDark = y < height && data[base + x] < dark
                if isDark {
                    if openSince[x] < 0 { openSince[x] = y }
                } else if openSince[x] >= 0 {
                    if y - openSince[x] >= minDown { vertical.append((x, openSince[x], y - 1)) }
                    openSince[x] = -1
                }
            }
        }

        // Merge the pixel rows (columns) of one thick or antialiased rule.
        // Bitmap rows run top-down; display space runs bottom-up.
        let h = merge(horizontal.map { (Int($0.y), $0.x0, $0.x1) }).map {
            Line(position: displaySize.height - CGFloat($0.position) / scale,
                 start: CGFloat($0.start) / scale, end: CGFloat($0.end + 1) / scale)
        }
        let v = merge(vertical.map { (Int($0.x), $0.y0, $0.y1) }).map {
            Line(position: CGFloat($0.position) / scale,
                 start: displaySize.height - CGFloat($0.end + 1) / scale, end: displaySize.height - CGFloat($0.start) / scale)
        }
        return Rulings(horizontal: h, vertical: v)
    }

    /// Joins segments on neighbouring pixel lines that overlap.
    private static func merge(_ segments: [(Int, Int, Int)]) -> [(position: CGFloat, start: Int, end: Int)] {
        var lines: [(first: Int, last: Int, start: Int, end: Int)] = []
        for (position, start, end) in segments.sorted(by: { $0.0 < $1.0 }) {
            if let i = lines.lastIndex(where: { position - $0.last <= 2 && min($0.end, end) - max($0.start, start) > (end - start) / 2 }) {
                lines[i].last = position
                lines[i].start = min(lines[i].start, start)
                lines[i].end = max(lines[i].end, end)
            } else {
                lines.append((position, position, start, end))
            }
        }
        return lines.map { (CGFloat($0.first + $0.last) / 2, $0.start, $0.end) }
    }

    // MARK: - Tables

    struct Detection {
        var regions: [PDFRegion]
        var consumed: Set<Int>
    }

    /// Tables from touching rules, with words assigned to their cells.
    static func tables(from rulings: Rulings, runs: [PDFTextRun]) -> Detection {
        guard !rulings.isEmpty else { return Detection(regions: [], consumed: []) }
        let h = rulings.horizontal, v = rulings.vertical
        let tolerance: CGFloat = 2

        // Union horizontal and vertical rules that cross or touch.
        var parent = Array(0..<(h.count + v.count))
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for (i, hl) in h.enumerated() {
            for (j, vl) in v.enumerated()
            where vl.position >= hl.start - tolerance && vl.position <= hl.end + tolerance
                && hl.position >= vl.start - tolerance && hl.position <= vl.end + tolerance {
                parent[find(i)] = find(h.count + j)
            }
        }
        var clusters: [Int: (h: [Line], v: [Line])] = [:]
        for i in h.indices { clusters[find(i), default: ([], [])].h.append(h[i]) }
        for j in v.indices { clusters[find(h.count + j), default: ([], [])].v.append(v[j]) }

        var regions: [PDFRegion] = []
        var consumed = Set<Int>()
        for var cluster in clusters.values where cluster.v.count >= 2 && !cluster.h.isEmpty {
            // A frame cut by the page break has no top (or bottom) rule:
            // close it where the side rules end.
            if cluster.h.count == 1, let rule = cluster.h.first {
                let top = cluster.v.map(\.end).max()!, bottom = cluster.v.map(\.start).min()!
                let missing = abs(rule.position - top) < abs(rule.position - bottom) ? bottom : top
                guard abs(missing - rule.position) >= 16 else { continue }
                cluster.h.append(Line(position: missing, start: rule.start, end: rule.end))
            }
            guard let table = buildTable(h: cluster.h, v: cluster.v, runs: runs, consumed: &consumed) else { continue }
            regions.append(table)
        }
        return Detection(regions: regions, consumed: consumed)
    }

    // MARK: - Framed Code

    /// A single framed cell whose lines read as code (braces, brackets,
    /// `"key": value`, an HTTP request line) becomes a preformatted block
    /// with line breaks and indentation rebuilt from geometry. Other frames
    /// are callout boxes: `nil`, and their text flows normally.
    private static func codeFrame(_ frame: CGRect, runs: [PDFTextRun], consumed: inout Set<Int>) -> PDFRegion? {
        let inside = runs.indices.filter { !consumed.contains($0) && frame.contains(CGPoint(x: runs[$0].rect.midX, y: runs[$0].rect.midY)) }
        guard inside.count >= 2 else { return nil }
        let words = inside.map { runs[$0] }
        let rows = PDFLayoutAnalyzer.groupIntoRows(words)
        let size = words.map(\.fontSize).sorted()[words.count / 2]
        let charWidth = max(size * 0.5, 1)
        let left = words.map(\.rect.minX).min() ?? frame.minX
        let pitch = PDFLayoutAnalyzer.median(zip(rows, rows.dropFirst()).map { $0.rect.midY - $1.rect.midY }.filter { $0 > 0 }) ?? size * 1.3

        var lines: [String] = []
        var previous: CGRect?
        for row in rows {
            if let previous, previous.midY - row.rect.midY > pitch * 1.6 { lines.append("") }
            var line = String(repeating: " ", count: max(0, Int((words[row.members[0]].rect.minX - left) / charWidth + 0.5)))
            var end: CGFloat?
            for member in row.members {
                let word = words[member]
                if let end { line += String(repeating: " ", count: min(8, max(1, Int((word.rect.minX - end) / charWidth + 0.5)))) }
                line += word.text
                end = word.rect.maxX
            }
            lines.append(line)
            previous = row.rect
        }
        let codeLike = lines.filter { $0.range(of: #"[{}\[\];=]|":\s|^\s*(GET|POST|PUT|DELETE|PATCH|HEAD) \S"#, options: .regularExpression) != nil }.count
        guard lines.count >= 2, codeLike * 10 >= lines.count * 3 else { return nil }

        consumed.formUnion(inside)
        let text = lines.joined(separator: "\n")
        let isJSON = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        var block = PDFImportedBlock(kind: .code(language: isJSON ? "json" : nil), rect: frame, content: .text(text))
        block.fontSize = size
        return PDFRegion(kind: .block(block), rect: frame)
    }

    private static func positions(_ values: [CGFloat]) -> [CGFloat] {
        var result: [CGFloat] = []
        for value in values.sorted() {
            if let last = result.last, value - last < 3 { continue }
            result.append(value)
        }
        return result
    }

    private static func buildTable(h: [Line], v: [Line], runs: [PDFTextRun], consumed: inout Set<Int>) -> PDFRegion? {
        let xs = positions(v.map(\.position))
        let ys = positions(h.map(\.position)).reversed() as [CGFloat]  // top to bottom
        let rows = ys.count - 1, columns = xs.count - 1
        guard rows >= 1, columns >= 1 else { return nil }
        let rect = CGRect(x: xs[0], y: ys[ys.count - 1], width: xs[xs.count - 1] - xs[0], height: ys[0] - ys[ys.count - 1])
        guard rect.width >= 40, rect.height >= 16 else { return nil }

        func hasVertical(at x: CGFloat, covering y: CGFloat) -> Bool {
            v.contains { abs($0.position - x) < 3 && $0.start - 2 <= y && y <= $0.end + 2 }
        }
        func hasHorizontal(at y: CGFloat, covering x: CGFloat) -> Bool {
            h.contains { abs($0.position - y) < 3 && $0.start - 2 <= x && x <= $0.end + 2 }
        }

        // Merge grid cells wherever the border between them is missing.
        var parent = Array(0..<(rows * columns))
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for r in 0..<rows {
            let midY = (ys[r] + ys[r + 1]) / 2
            for c in 0..<columns {
                let midX = (xs[c] + xs[c + 1]) / 2
                if c + 1 < columns, !hasVertical(at: xs[c + 1], covering: midY) { parent[find(r * columns + c)] = find(r * columns + c + 1) }
                if r + 1 < rows, !hasHorizontal(at: ys[r + 1], covering: midX) { parent[find(r * columns + c)] = find((r + 1) * columns + c) }
            }
        }
        var groups: [Int: (r0: Int, r1: Int, c0: Int, c1: Int)] = [:]
        for r in 0..<rows {
            for c in 0..<columns {
                let root = find(r * columns + c)
                if let g = groups[root] {
                    groups[root] = (min(g.r0, r), max(g.r1, r), min(g.c0, c), max(g.c1, c))
                } else {
                    groups[root] = (r, r, c, c)
                }
            }
        }
        // A single frame (one cell) is a box around text, not a table: a
        // code sample, or a callout whose text flows normally.
        guard groups.count >= 2 else { return codeFrame(rect, runs: runs, consumed: &consumed) }

        var grid = Array(repeating: Array(repeating: "", count: columns), count: rows)
        var spans: [PDFCellSpan] = []
        var used = Set<Int>()
        var headerBold = true
        var headerHasText = false
        for g in groups.values {
            let cell = CGRect(x: xs[g.c0], y: ys[g.r1 + 1], width: xs[g.c1 + 1] - xs[g.c0], height: ys[g.r0] - ys[g.r1 + 1])
            let inside = runs.indices.filter { !consumed.contains($0) && !used.contains($0)
                && cell.contains(CGPoint(x: runs[$0].rect.midX, y: runs[$0].rect.midY)) }
            used.formUnion(inside)
            let words = inside.map { runs[$0] }
            // The PDF's own text order is reliable inside a cell; geometry
            // can merge the tight lines of a two-line cell ("Data / Type").
            let lines: [String]
            if words.allSatisfy({ $0.textOrder != nil }) {
                lines = words.sorted { $0.textOrder! < $1.textOrder! }.map(\.text)
            } else {
                lines = PDFLayoutAnalyzer.groupIntoRows(words).map { row in row.members.map { words[$0].text }.joined(separator: " ") }
            }
            grid[g.r0][g.c0] = PDFLayoutAnalyzer.joinLines(lines)
            if g.r1 > g.r0 || g.c1 > g.c0 {
                spans.append(PDFCellSpan(row: g.r0, column: g.c0, rowSpan: g.r1 - g.r0 + 1, columnSpan: g.c1 - g.c0 + 1))
            }
            if g.r0 == 0, !words.isEmpty {
                headerHasText = true
                if !words.allSatisfy(\.isBold) { headerBold = false }
            }
        }
        guard !used.isEmpty else { return nil }
        consumed.formUnion(used)

        var table = PDFTableData(rows: grid, headerRows: headerBold && headerHasText ? 1 : 0)
        table.spans = spans.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
        table.columnEdges = xs
        table.isComplex = false
        return PDFRegion(kind: .table(table), rect: rect)
    }
}
