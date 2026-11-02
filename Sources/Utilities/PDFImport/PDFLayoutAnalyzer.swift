import Foundation
import CoreGraphics

/// Turns positioned text runs into reading-ordered, typed blocks.
///
/// Pure geometry: no PDFKit, no Vision, no I/O. The extractors feed it runs
/// in display space (origin bottom-left, y grows upward) and it decides what
/// is a heading, a paragraph, a list, a table or a formula, and in what order
/// a human reads them. Everything here is deterministic and unit-tested
/// against synthetic pages (see `PDFLayoutAnalyzerTests`).
enum PDFLayoutAnalyzer {

    // MARK: - Lines

    /// Runs on one baseline, joined left to right.
    struct Line: Equatable {
        var text: String
        var rect: CGRect
        var fontSize: CGFloat
        var isBold: Bool
        var mathScore: Double
        var isTitle: Bool
        /// Starts with a number set apart from the text ("5   Flavius…"): a
        /// margin paragraph number, which always starts a new paragraph.
        var leadingNumber = false
    }

    // MARK: - Running Headers & Page Numbers

    /// Removes text that repeats in the top or bottom margin band across
    /// pages (running heads, footers, journal names) and bare page numbers.
    ///
    /// A run counts as repeating when its text, with digits normalised, sits
    /// in the same band on at least 40% of pages (and at least two).
    static func removeRunningHeaders(pages: [[PDFTextRun]], pageSizes: [CGSize]) -> [[PDFTextRun]] {
        precondition(pages.count == pageSizes.count)
        let bandFraction: CGFloat = 0.085

        func band(_ run: PDFTextRun, _ size: CGSize) -> String? {
            if run.rect.minY >= size.height * (1 - bandFraction) { return "top" }
            if run.rect.maxY <= size.height * bandFraction { return "bottom" }
            return nil
        }

        var pagesContaining: [String: Set<Int>] = [:]
        for (pageIndex, runs) in pages.enumerated() {
            for run in runs {
                guard let place = band(run, pageSizes[pageIndex]) else { continue }
                pagesContaining["\(place)|\(marginKey(run.text))", default: []].insert(pageIndex)
            }
        }
        let threshold = max(2, Int((Double(pages.count) * 0.4).rounded(.up)))

        let repeating = pages.enumerated().map { pageIndex, runs in
            runs.filter { run in
                guard let place = band(run, pageSizes[pageIndex]) else { return true }
                if isPageNumber(run.text) { return false }
                guard pages.count >= 2 else { return true }
                let count = pagesContaining["\(place)|\(marginKey(run.text))"]?.count ?? 0
                return count < threshold
            }
        }
        return removeEdgeRows(pages: repeating, pageSizes: pageSizes, bandFraction: bandFraction)
    }

    /// Running heads whose text changes on every page ("1 Samuel (1:1-4:22)
    /// 147", chapter titles, OCR-garbled heads) never repeat verbatim, but
    /// they sit in the same place: a short top (or bottom) row in the margin
    /// band, set apart from the body by a gap. When most pages have such a
    /// row, it is the running head or foot on all of them.
    static func removeEdgeRows(pages: [[PDFTextRun]], pageSizes: [CGSize], bandFraction: CGFloat) -> [[PDFTextRun]] {
        guard pages.count >= 3 else { return pages }

        func edgeRow(_ runs: [PDFTextRun], size: CGSize, top: Bool) -> Set<Int>? {
            let rows = groupIntoRows(runs)
            guard rows.count >= 4 else { return nil }
            let row = top ? rows[0] : rows[rows.count - 1]
            let neighbour = top ? rows[1] : rows[rows.count - 2]
            let inBand = top ? row.rect.minY >= size.height * (1 - bandFraction) : row.rect.maxY <= size.height * bandFraction
            let text = row.members.map { runs[$0].text }.joined(separator: " ")
            let gap = top ? row.rect.minY - neighbour.rect.maxY : neighbour.rect.minY - row.rect.maxY
            guard inBand, text.count <= 90, gap >= row.rect.height * 0.6 else { return nil }
            return Set(row.members)
        }

        var result = pages
        for top in [true, false] {
            let found = pages.indices.map { edgeRow(pages[$0], size: pageSizes[$0], top: top) }
            guard Double(found.compactMap { $0 }.count) >= Double(pages.count) * 0.6 else { continue }
            for index in pages.indices {
                guard let members = found[index] else { continue }
                let drop = Set(members.map { pages[index][$0] }.map(\.rect.origin).map { "\($0.x),\($0.y)" })
                result[index] = result[index].filter { !drop.contains("\($0.rect.origin.x),\($0.rect.origin.y)") }
            }
        }
        return result
    }

    /// Lowercased, whitespace-collapsed, digits replaced, so "Page 3" and
    /// "Page 14" or "Chapter 2 — Methods 17" compare equal across pages.
    static func marginKey(_ text: String) -> String {
        let lowered = text.lowercased()
            .replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return lowered.trimmingCharacters(in: .whitespaces)
    }

    static func isPageNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 16 else { return false }
        let patterns = [
            #"^(page\s*)?\d{1,4}(\s*(of|/)\s*\d{1,4})?$"#,
            #"^[-–—]\s*\d{1,4}\s*[-–—]$"#,
            #"^[ivxlcdm]{1,7}$"#,
        ]
        return patterns.contains {
            trimmed.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    // MARK: - Table Detection

    struct TableDetection {
        var regions: [PDFRegion]
        /// Runs that were not consumed by a table.
        var remaining: [PDFTextRun]
    }

    /// Finds tables laid out as aligned columns of short text.
    ///
    /// Works on runs, not lines: the extractor already split each baseline at
    /// wide gaps, so a table row arrives as one run per cell. Two-column prose
    /// also produces two runs per baseline; it is rejected because its
    /// "cells" are long, which is what `isProseColumn` checks.
    static func detectTables(in allRuns: [PDFTextRun], pageSize: CGSize) -> TableDetection {
        guard allRuns.count >= 6 else { return TableDetection(regions: [], remaining: allRuns) }

        // Term–description tables first: their multi-line cells would
        // otherwise be read as a list of terms followed by prose.
        let terms = detectTermTables(in: allRuns, pageSize: pageSize)
        let gutter = pageGutter(allRuns, pageSize: pageSize)
        let runs = terms.remaining
        let rows = groupIntoRows(runs)
        let medianHeight = median(rows.map { $0.rect.height }) ?? 10
        var consumed = Set<Int>()
        var regions: [PDFRegion] = []
        // A row is table-like when it has two or more short, cell-like runs.
        // Counting runs alone fails on two-column pages, where every
        // baseline holds two long prose runs.
        let isCellRow = { (row: Row) in row.members.filter { isCellLike(runs[$0], pageWidth: pageSize.width) }.count >= 2 }

        var start = 0
        while start < rows.count {
            guard isCellRow(rows[start]) else { start += 1; continue }
            // Grow a run of rows: cell rows, allowing one other row at a time
            // (merged cells, wrapped cell text).
            var end = start
            var singlesInARow = 0
            var next = start + 1
            while next < rows.count {
                let gap = rows[next - 1].rect.minY - rows[next].rect.maxY
                guard gap <= medianHeight * 2.2 else { break }
                if isCellRow(rows[next]) {
                    singlesInARow = 0
                    end = next
                } else {
                    singlesInARow += 1
                    if singlesInARow > 1 { break }
                }
                next += 1
            }

            let group = Array(rows[start...end])
            if let table = buildTable(group, runs: runs, pageSize: pageSize, gutter: gutter) {
                regions.append(table.region)
                consumed.formUnion(table.consumed)
                start = end + 1
            } else if let complex = complexTableCandidate(group, runs: runs, pageSize: pageSize, gutter: gutter) {
                // Clearly tabular but irregular (multi-level headers, spans):
                // keep it together so the AI or an image can handle it,
                // instead of emitting the cells as jumbled paragraphs.
                regions.append(complex.region)
                consumed.formUnion(complex.consumed)
                start = end + 1
            } else {
                start += 1
            }
        }

        let remaining = runs.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
        return TableDetection(regions: terms.regions + regions, remaining: remaining)
    }

    /// Finds two-column "term | description" tables: short labels in a left
    /// column, each starting a description of one or more lines at a fixed
    /// x on the right (site charts, glossaries, CV-style layouts).
    ///
    /// Guards against look-alikes: hanging-indent lists (the label is a bare
    /// marker), numbered paragraphs (continuation lines return to the left
    /// edge rather than the description column), and two page columns (the
    /// description column starts left of the page centre).
    static func detectTermTables(in runs: [PDFTextRun], pageSize: CGSize) -> TableDetection {
        let rows = groupIntoRows(runs)
        let medianHeight = median(rows.map { $0.rect.height }) ?? 10

        // (label run, first description run) when a row opens an entry.
        func pair(_ row: Row) -> (label: Int, description: Int)? {
            guard row.members.count >= 2 else { return nil }
            let label = row.members[0], description = row.members[1]
            let l = runs[label], d = runs[description]
            guard l.text.count <= 30, !isBareMarker(l.text), l.rect.width < pageSize.width * 0.3,
                  d.text.count >= 20, d.rect.minX - l.rect.maxX >= 6,
                  d.rect.minX < pageSize.width * 0.45 else { return nil }
            return (label, description)
        }

        var consumed = Set<Int>()
        var regions: [PDFRegion] = []
        var i = 0
        while i < rows.count {
            guard let first = pair(rows[i]) else { i += 1; continue }
            let labelX = runs[first.label].rect.minX
            let descriptionX = runs[first.description].rect.minX
            var entries: [(label: [String], description: [String])] = []
            var used: [Int] = []
            var j = i
            var pairs = 0
            while j < rows.count {
                if j > i, rows[j - 1].rect.minY - rows[j].rect.maxY > medianHeight * 1.5 { break }
                let row = rows[j]
                if let p = pair(row), abs(runs[p.label].rect.minX - labelX) < 4,
                   abs(runs[p.description].rect.minX - descriptionX) < 4 {
                    let description = row.members.dropFirst().map { runs[$0].text }.joined(separator: " ")
                    entries.append(([runs[p.label].text], [description]))
                    pairs += 1
                } else if j > i, row.members.allSatisfy({ runs[$0].rect.minX >= descriptionX - 4 }),
                          abs(runs[row.members[0]].rect.minX - descriptionX) < 4 {
                    entries[entries.count - 1].description.append(row.members.map { runs[$0].text }.joined(separator: " "))
                } else if j > i, row.members.allSatisfy({ runs[$0].rect.maxX < descriptionX - 2 }),
                          abs(runs[row.members[0]].rect.minX - labelX) < 4, row.members.count == 1 {
                    // A wrapped label line.
                    entries[entries.count - 1].label.append(runs[row.members[0]].text)
                } else if j > i, row.members.count >= 2,
                          runs[row.members[0]].rect.maxX < descriptionX - 2,
                          abs(runs[row.members[0]].rect.minX - labelX) < 4,
                          abs(runs[row.members[1]].rect.minX - descriptionX) < 4 {
                    // Wrapped label beside a description line.
                    entries[entries.count - 1].label.append(runs[row.members[0]].text)
                    entries[entries.count - 1].description.append(row.members.dropFirst().map { runs[$0].text }.joined(separator: " "))
                } else {
                    break
                }
                used.append(contentsOf: row.members)
                j += 1
            }
            guard pairs >= 3 else { i += 1; continue }

            var grid = entries.map { [joinLines($0.label), joinLines($0.description)] }
            var rect = used.map { runs[$0].rect }.reduce(CGRect.null) { $0.union($1) }
            var headerRows = 0
            // A two-cell row just above, aligned with both columns, is the header.
            if i > 0, rows[i - 1].members.count == 2,
               abs(runs[rows[i - 1].members[0]].rect.minX - labelX) < 6,
               abs(runs[rows[i - 1].members[1]].rect.minX - descriptionX) < 6,
               rows[i - 1].members.allSatisfy({ runs[$0].text.count <= 30 }) {
                grid.insert(rows[i - 1].members.map { runs[$0].text }, at: 0)
                used.append(contentsOf: rows[i - 1].members)
                rect = rect.union(rows[i - 1].rect)
                headerRows = 1
            }
            var table = PDFTableData(rows: grid, headerRows: headerRows)
            table.isComplex = false
            regions.append(PDFRegion(kind: .table(table), rect: rect))
            consumed.formUnion(used)
            i = j
        }
        let remaining = runs.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
        return TableDetection(regions: regions, remaining: remaining)
    }

    struct Row {
        var members: [Int]  // indices into the run array, sorted by minX
        var rect: CGRect
    }

    /// Groups runs that share a baseline, top to bottom.
    static func groupIntoRows(_ runs: [PDFTextRun]) -> [Row] {
        let order = runs.indices.sorted { runs[$0].rect.midY > runs[$1].rect.midY }
        var rows: [Row] = []
        for index in order {
            let rect = runs[index].rect
            if var last = rows.last, verticalOverlap(last.rect, rect) >= 0.5 * min(last.rect.height, rect.height) {
                last.members.append(index)
                last.rect = last.rect.union(rect)
                rows[rows.count - 1] = last
            } else {
                rows.append(Row(members: [index], rect: rect))
            }
        }
        for i in rows.indices {
            rows[i].members.sort { runs[$0].rect.minX < runs[$1].rect.minX }
        }
        return rows
    }

    private struct BuiltTable {
        var region: PDFRegion
        var consumed: Set<Int>
    }

    /// Short enough to be a table cell rather than a line of prose. A bare
    /// list marker ("•", "1.") is not a cell: a hanging-indent list would
    /// otherwise read as a two-column table.
    static func isCellLike(_ run: PDFTextRun, pageWidth: CGFloat) -> Bool {
        run.text.count <= 40 && run.rect.width < pageWidth * 0.35 && !isBareMarker(run.text)
    }

    static func isBareMarker(_ text: String) -> Bool {
        // Outline labels: "(E)", "(ii)", "(IV)", "B.", "12)", and OCR's
        // mangled numerals ("(hi)" for "(iii)").
        if text.range(of: #"^\(?([A-Za-z]{1,4}|\d{1,3})[.)]$"#, options: .regularExpression) != nil { return true }
        guard let marker = listMarker(in: text + " ") else { return false }
        return marker.length >= text.count
    }

    private static func buildTable(_ group: [Row], runs: [PDFTextRun], pageSize: CGSize, gutter: ClosedRange<CGFloat>?) -> BuiltTable? {
        let cellLike = { (index: Int) in isCellLike(runs[index], pageWidth: pageSize.width) }
        let multiCellRows = group.filter { $0.members.filter(cellLike).count >= 2 }
        guard multiCellRows.count >= 2, group.count >= 3 else { return nil }

        // Column intervals come from the cell-like runs of the body rows
        // (skipping the header when there are enough rows, so a wide header
        // cell cannot merge two data columns). Prose beside the table never
        // shapes the columns.
        let basisRows = multiCellRows.count >= 3 ? Array(multiCellRows.dropFirst()) : multiCellRows
        var columns = mergeIntervals(basisRows.flatMap { $0.members.filter(cellLike).map { runs[$0].rect.minX...runs[$0].rect.maxX } })
        guard columns.count >= 2 else { return nil }

        // Drop prose columns (body text of a neighbouring page column that
        // happens to share baselines with the table).
        let proseColumns = columns.indices.filter { column in
            let texts = group.flatMap { $0.members }.filter { columnIndex(of: runs[$0].rect, in: columns) == column }.map { runs[$0].text }
            return isProseColumn(texts, width: columns[column].upperBound - columns[column].lowerBound, pageWidth: pageSize.width)
        }
        if !proseColumns.isEmpty {
            columns = columns.enumerated().filter { !proseColumns.contains($0.offset) }.map(\.element)
            guard columns.count >= 2 else { return nil }
        }
        guard !arePageColumns(columns, pageSize: pageSize, gutter: gutter) else { return nil }
        guard !containsProse(group, runs: runs, span: columns[0].lowerBound...columns[columns.count - 1].upperBound) else { return nil }

        var isComplex = false
        var consumed = Set<Int>()
        var grid: [[String]] = []
        var rowRects: [CGRect] = []
        var cellRuns = 0
        var joinedCells = 0
        var sparseRows = 0

        for row in group {
            var cells = Array(repeating: "", count: columns.count)
            var used = false
            for member in row.members {
                let rect = runs[member].rect
                let overlapping = columns.indices.filter { overlap(rect.minX...rect.maxX, columns[$0]) > 0 }
                // Runs outside every column (a dropped prose column, text in
                // the next page column) are not part of the table.
                guard !overlapping.isEmpty, let column = columnIndex(of: rect, in: columns) else { continue }
                if overlapping.count > 1 { isComplex = true }  // spanning cell
                if !cells[column].isEmpty { joinedCells += 1 }
                cells[column] = cells[column].isEmpty ? runs[member].text : cells[column] + " " + runs[member].text
                consumed.insert(member)
                cellRuns += 1
                used = true
            }
            guard used else { continue }

            // A row filling only some cells straight under a full row is a
            // wrapped continuation: fold it into the row above.
            let filled = cells.filter { !$0.isEmpty }.count
            if let previous = rowRects.last, filled * 2 <= columns.count, cells[0].isEmpty,
               previous.minY - row.rect.maxY < row.rect.height * 0.6 {
                for column in cells.indices where !cells[column].isEmpty {
                    let above = grid[grid.count - 1][column]
                    grid[grid.count - 1][column] = above.isEmpty ? cells[column] : above + " " + cells[column]
                }
                let used = row.members.filter(consumed.contains).map { runs[$0].rect }.reduce(CGRect.null) { $0.union($1) }
                rowRects[rowRects.count - 1] = previous.union(used)
                continue
            }
            if filled == 1 && columns.count > 2 { sparseRows += 1 }
            grid.append(cells)
            // Only the cells this table used, so the region cannot reach
            // into a neighbouring page column.
            rowRects.append(row.members.filter(consumed.contains).map { runs[$0].rect }.reduce(CGRect.null) { $0.union($1) })
        }

        guard grid.count >= 3 || (grid.count >= 2 && columns.count >= 3) else { return nil }
        let totalCells = grid.count * columns.count
        let nonEmpty = grid.flatMap { $0 }.filter { !$0.isEmpty }.count
        let fill = Double(nonEmpty) / Double(max(totalCells, 1))
        guard fill >= 0.5 else { return nil }
        if fill < 0.75 || joinedCells > grid.count { isComplex = true }
        // Rows with one lone cell are section labels or spanning cells.
        // Rows that only held neighbouring prose never reach the grid.
        if sparseRows > 1 { isComplex = true }

        let rect = rowRects.reduce(rowRects[0]) { $0.union($1) }
        var table = PDFTableData(rows: grid, headerRows: headerRowCount(grid, runs: runs, firstRow: group[0]))
        table.isComplex = isComplex
        return BuiltTable(region: PDFRegion(kind: .table(table), rect: rect), consumed: consumed)
    }

    /// Four or more rows of several short runs that did not form a clean
    /// grid. Prose never qualifies: its runs are long.
    private static func complexTableCandidate(_ group: [Row], runs: [PDFTextRun], pageSize: CGSize, gutter: ClosedRange<CGFloat>?) -> BuiltTable? {
        let cellLike = { (index: Int) in isCellLike(runs[index], pageWidth: pageSize.width) }
        let multi = group.filter { $0.members.filter(cellLike).count >= 2 }
        guard multi.count >= 4 else { return nil }
        let members = group.flatMap(\.members).filter(cellLike)
        let columns = mergeIntervals(members.map { runs[$0].rect.minX...runs[$0].rect.maxX })
        guard !arePageColumns(columns, pageSize: pageSize, gutter: gutter),
              let first = columns.first, let last = columns.last,
              !containsProse(group, runs: runs, span: first.lowerBound...last.upperBound) else { return nil }
        let lengths = members.map { runs[$0].text.count }.sorted()
        guard lengths[lengths.count / 2] <= 24 else { return nil }
        let rect = group.reduce(CGRect.null) { $0.union($1.rect) }
        guard rect.width >= pageSize.width * 0.25 else { return nil }
        return BuiltTable(region: PDFRegion(kind: .complexTable(cellText: members.map { runs[$0] }), rect: rect),
                          consumed: Set(members))
    }

    /// Table cells are short. When two or more rows carry a prose-length
    /// line inside the table's horizontal span, the "table" is justified
    /// prose split at wide spaces (common with jittery OCR word boxes).
    static func containsProse(_ group: [Row], runs: [PDFTextRun], span: ClosedRange<CGFloat>) -> Bool {
        let inSpan = group.flatMap(\.members).filter {
            overlap(runs[$0].rect.minX...runs[$0].rect.maxX, span) > runs[$0].rect.width * 0.5
        }
        let proseRows = group.filter { row in
            row.members.contains { inSpan.contains($0) && runs[$0].text.count >= 45 }
        }.count
        if proseRows >= 2 { return true }
        // Cells begin with a capital, digit or symbol. Pieces starting with
        // lowercase words ("in", "the", "over to") are cut from sentences.
        let lowercase = inSpan.filter { runs[$0].text.first?.isLowercase == true }.count
        return inSpan.count >= 4 && Double(lowercase) / Double(inSpan.count) > 0.3
    }

    /// Two "columns" split at the page's own gutter are the page columns
    /// holding short lines (an outline, a list, an index), not a table.
    /// Without a known gutter, two half-page-wide columns split near the
    /// centre count as page columns.
    static func arePageColumns(_ columns: [ClosedRange<CGFloat>], pageSize: CGSize, gutter: ClosedRange<CGFloat>? = nil) -> Bool {
        guard columns.count == 2 else { return false }
        if let gutter {
            return columns[0].upperBound <= gutter.upperBound && columns[1].lowerBound >= gutter.lowerBound
        }
        let wide = columns.allSatisfy { $0.upperBound - $0.lowerBound > pageSize.width * 0.25 }
        let split = (columns[0].upperBound + columns[1].lowerBound) / 2
        return wide && abs(split - pageSize.width / 2) < pageSize.width * 0.1
    }

    /// The vertical strip in the middle of the page that (almost) no text
    /// crosses, when the page is set in two columns with real prose on both
    /// sides. `nil` for single-column pages.
    static func pageGutter(_ runs: [PDFTextRun], pageSize: CGSize) -> ClosedRange<CGFloat>? {
        guard runs.count >= 20, pageSize.width > 100 else { return nil }
        let low = Int(pageSize.width * 0.3), high = Int(pageSize.width * 0.7)
        let allowed = max(1, runs.count / 50)
        var best: ClosedRange<Int>?
        var start: Int?
        for x in low...high {
            let crossing = runs.reduce(0) { $0 + ($1.rect.minX < CGFloat(x) && $1.rect.maxX > CGFloat(x) ? 1 : 0) }
            if crossing <= allowed {
                if start == nil { start = x }
            } else if let s = start {
                if x - s > (best.map { $0.upperBound - $0.lowerBound } ?? 0) { best = s...(x - 1) }
                start = nil
            }
        }
        if let s = start, high - s > (best.map { $0.upperBound - $0.lowerBound } ?? 0) { best = s...high }
        guard let gap = best, gap.upperBound - gap.lowerBound >= 6 else { return nil }
        // Both sides must carry prose, or this is just a margin.
        let mid = CGFloat(gap.lowerBound + gap.upperBound) / 2
        let prose = runs.filter { $0.text.count >= 25 }
        let left = prose.filter { $0.rect.maxX <= mid }.reduce(0) { $0 + $1.text.count }
        let right = prose.filter { $0.rect.minX >= mid }.reduce(0) { $0 + $1.text.count }
        guard left >= 300, right >= 300 else { return nil }
        return CGFloat(gap.lowerBound)...CGFloat(gap.upperBound)
    }

    /// Long, wide cells are prose, not a table column.
    static func isProseColumn(_ texts: [String], width: CGFloat, pageWidth: CGFloat) -> Bool {
        guard !texts.isEmpty else { return false }
        let lengths = texts.map(\.count).sorted()
        let medianLength = lengths[lengths.count / 2]
        return medianLength > 32 && width > pageWidth * 0.28
    }

    /// One header row unless the first row looks like data (mostly numbers).
    private static func headerRowCount(_ grid: [[String]], runs: [PDFTextRun], firstRow: Row) -> Int {
        guard let first = grid.first else { return 0 }
        if firstRow.members.allSatisfy({ runs[$0].isBold }) { return 1 }
        let numeric = first.filter { $0.range(of: #"^[\s\d.,%$€£+\-−()]+$"#, options: .regularExpression) != nil }.count
        return numeric * 2 > first.filter { !$0.isEmpty }.count ? 0 : 1
    }

    static func mergeIntervals(_ intervals: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        let sorted = intervals.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<CGFloat>] = []
        for interval in sorted {
            if let last = merged.last, interval.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, interval.upperBound)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static func columnIndex(of rect: CGRect, in columns: [ClosedRange<CGFloat>]) -> Int? {
        let span = rect.minX...rect.maxX
        var best: (index: Int, amount: CGFloat)?
        for (index, column) in columns.enumerated() {
            let amount = overlap(span, column)
            if amount > (best?.amount ?? 0) { best = (index, amount) }
        }
        if let best { return best.index }
        // No overlap (a header cell in a gutter): nearest column.
        return columns.indices.min { abs(columns[$0].lowerBound - rect.midX) < abs(columns[$1].lowerBound - rect.midX) }
    }

    // MARK: - Reading Order (recursive XY-cut)

    /// Returns indices of `rects` in reading order.
    ///
    /// Recursively splits the region at the widest vertical whitespace strip
    /// (columns, read left then right) and otherwise at the widest horizontal
    /// strip (read top then bottom). A vertical cut is only taken when both
    /// sides overlap vertically, so a short last line and a heading beside it
    /// are not mistaken for two columns.
    static func readingOrder(_ rects: [CGRect], minGutter: CGFloat) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(rects.count)
        cut(Array(rects.indices), rects, minGutter, &result, depth: 0)
        return result
    }

    private static func cut(_ indices: [Int], _ rects: [CGRect], _ minGutter: CGFloat, _ out: inout [Int], depth: Int) {
        if indices.count <= 1 || depth > 200 {
            out.append(contentsOf: leafOrder(indices, rects))
            return
        }
        if let vertical = verticalCut(indices, rects, minGutter) {
            // A centred author line or note straddling the gutter at the top
            // or bottom of the region is read on its own, not split between
            // the columns.
            if let (top, bottom) = centredEdgeBand(indices, rects, gutter: vertical.gutter) {
                cut(top, rects, minGutter, &out, depth: depth + 1)
                cut(bottom, rects, minGutter, &out, depth: depth + 1)
                return
            }
            cut(vertical.left, rects, minGutter, &out, depth: depth + 1)
            cut(vertical.right, rects, minGutter, &out, depth: depth + 1)
            return
        }
        if let (top, bottom) = horizontalCut(indices, rects) {
            cut(top, rects, minGutter, &out, depth: depth + 1)
            cut(bottom, rects, minGutter, &out, depth: depth + 1)
            return
        }
        out.append(contentsOf: leafOrder(indices, rects))
    }

    private static func leafOrder(_ indices: [Int], _ rects: [CGRect]) -> [Int] {
        indices.sorted { a, b in
            let ra = rects[a], rb = rects[b]
            if verticalOverlap(ra, rb) >= 0.5 * min(ra.height, rb.height) { return ra.minX < rb.minX }
            return ra.midY > rb.midY
        }
    }

    private struct VerticalCut {
        var left: [Int]
        var right: [Int]
        var gutter: ClosedRange<CGFloat>
    }

    private static func verticalCut(_ indices: [Int], _ rects: [CGRect], _ minGutter: CGFloat) -> VerticalCut? {
        let sorted = indices.sorted { rects[$0].minX < rects[$1].minX }
        var reach = rects[sorted[0]].maxX
        var best: (position: Int, width: CGFloat, gutter: ClosedRange<CGFloat>)?
        for position in 1..<sorted.count {
            let rect = rects[sorted[position]]
            let gap = rect.minX - reach
            if gap >= minGutter, gap > (best?.width ?? 0) {
                let left = Array(sorted[..<position]), right = Array(sorted[position...])
                if sidesOverlapVertically(left, right, rects, minGutter: minGutter) { best = (position, gap, reach...rect.minX) }
            }
            reach = max(reach, rect.maxX)
        }
        guard let best else { return nil }
        return VerticalCut(left: Array(sorted[..<best.position]), right: Array(sorted[best.position...]), gutter: best.gutter)
    }

    /// The topmost or bottommost band (up to the first full-width gap) when it
    /// has short items on both sides of the gutter, centred on the region and
    /// not starting at the left column's edge — the shape of an author line
    /// or a centred note. Body lines fill their column; column headings start
    /// at the column edge; neither qualifies.
    private static func centredEdgeBand(_ indices: [Int], _ rects: [CGRect], gutter: ClosedRange<CGFloat>) -> ([Int], [Int])? {
        let region = indices.map { rects[$0] }.reduce(CGRect.null) { $0.union($1) }
        let sorted = indices.sorted { rects[$0].maxY > rects[$1].maxY }
        var gaps: [Int] = []
        var floor = rects[sorted[0]].minY
        for position in 1..<sorted.count {
            let rect = rects[sorted[position]]
            if floor - rect.maxY > 0.5 { gaps.append(position) }
            floor = min(floor, rect.minY)
        }
        let leftWidth = max(gutter.lowerBound - region.minX, 1)
        let rightWidth = max(region.maxX - gutter.upperBound, 1)

        func qualifies(_ band: ArraySlice<Int>) -> Bool {
            let items = band.map { rects[$0] }
            let left = items.filter { $0.maxX <= gutter.lowerBound + 0.5 }
            let right = items.filter { $0.minX >= gutter.upperBound - 0.5 }
            guard !left.isEmpty, !right.isEmpty, left.count + right.count == items.count, items.count <= 6 else { return false }
            guard left.allSatisfy({ $0.width < leftWidth * 0.6 && $0.minX > region.minX + leftWidth * 0.15 }),
                  right.allSatisfy({ $0.width < rightWidth * 0.6 }) else { return false }
            let band = items.reduce(CGRect.null) { $0.union($1) }
            return abs(band.midX - region.midX) < region.width * 0.1
        }
        if let first = gaps.first, qualifies(sorted[..<first]) {
            return (Array(sorted[..<first]), Array(sorted[first...]))
        }
        if let last = gaps.last, qualifies(sorted[last...]) {
            return (Array(sorted[..<last]), Array(sorted[last...]))
        }
        return nil
    }

    /// Both sides must overlap vertically and be wide enough to be columns.
    /// The width bar keeps hanging-indent list markers ("1.", "•") and
    /// right-hand equation numbers with their lines.
    private static func sidesOverlapVertically(_ left: [Int], _ right: [Int], _ rects: [CGRect], minGutter: CGFloat) -> Bool {
        let l = left.map { rects[$0] }.reduce(CGRect.null) { $0.union($1) }
        let r = right.map { rects[$0] }.reduce(CGRect.null) { $0.union($1) }
        let minimumWidth = minGutter * 6
        guard l.width >= minimumWidth, r.width >= minimumWidth else { return false }
        return verticalOverlap(l, r) >= 0.5 * min(l.height, r.height)
    }

    private static func horizontalCut(_ indices: [Int], _ rects: [CGRect]) -> ([Int], [Int])? {
        let sorted = indices.sorted { rects[$0].maxY > rects[$1].maxY }
        var floor = rects[sorted[0]].minY
        var best: (position: Int, height: CGFloat)?
        for position in 1..<sorted.count {
            let rect = rects[sorted[position]]
            let gap = floor - rect.maxY
            if gap > 0.5, gap > (best?.height ?? 0) { best = (position, gap) }
            floor = min(floor, rect.minY)
        }
        guard let best else { return nil }
        return (Array(sorted[..<best.position]), Array(sorted[best.position...]))
    }

    // MARK: - Page Assembly

    /// Builds the blocks of one page.
    ///
    /// - Parameters:
    ///   - runs: text not consumed by tables or figures.
    ///   - regions: tables and figures, each read as one unit.
    ///   - bodyFontSize: the document's dominant body size, for headings.
    ///   - headingSizeFactor: how much larger than body a line must be to
    ///     count as a heading by size alone; raised on pages whose sizes are
    ///     unreliable (see `sizeIsReliable`).
    static func assemblePage(runs: [PDFTextRun], regions: [PDFRegion], bodyFontSize: CGFloat,
                             headingSizeFactor: CGFloat = 1.15) -> [PDFImportedBlock] {
        let rects = runs.map(\.rect) + regions.map(\.rect)
        guard !rects.isEmpty else { return [] }
        let gutter = max(6, 0.6 * bodyFontSize)
        let order = readingOrder(rects, minGutter: gutter)

        var blocks: [PDFImportedBlock] = []
        var pending: [PDFTextRun] = []
        func flush() {
            guard !pending.isEmpty else { return }
            blocks.append(contentsOf: textBlocks(from: buildLines(pending), bodyFontSize: bodyFontSize,
                                                 headingSizeFactor: headingSizeFactor))
            pending.removeAll()
        }
        for index in order {
            if index < runs.count {
                pending.append(runs[index])
            } else {
                flush()
                blocks.append(block(for: regions[index - runs.count]))
            }
        }
        flush()
        return blocks
    }

    private static func block(for region: PDFRegion) -> PDFImportedBlock {
        switch region.kind {
        case .table(let table):
            return PDFImportedBlock(kind: .table, rect: region.rect, content: .table(table))
        case .figure:
            return PDFImportedBlock(kind: .figure, rect: region.rect, content: .figure(PDFFigure()))
        case .complexTable(let cellRuns):
            var table = PDFTableData(rows: groupIntoRows(cellRuns).map { row in row.members.map { cellRuns[$0].text } })
            table.isComplex = true
            return PDFImportedBlock(kind: .table, rect: region.rect, content: .table(table))
        case .block(let block):
            return block
        }
    }

    /// Types a paragraph that a layout model recognised (scanned pages).
    /// The layout model is trusted for the grouping; this only decides the
    /// kind from the text and from signals that survive OCR — the model's
    /// title flag, visual weight, captions, markers and numbering. Box-height
    /// font sizes are not used: on scans they depend on the letters.
    static func recognisedBlock(text: String, rect: CGRect, fontSize: CGFloat, isTitle: Bool,
                                isBold: Bool, lineCount: Int) -> PDFImportedBlock {
        var block: PDFImportedBlock
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let short = lineCount <= 2 && trimmed.count <= 120 && !trimmed.hasSuffix(".")
        if isCaption(trimmed) {
            block = PDFImportedBlock(kind: .caption, rect: rect, content: .text(trimmed))
        } else if ((isTitle || isBold) && short && trimmed.contains(where: \.isLetter)) || isCapitalsHeading(trimmed) {
            block = PDFImportedBlock(kind: .heading(level: 1), rect: rect, content: .text(trimmed))
        } else if let marker = listMarker(in: trimmed), !(marker.ordered && trimmed.count > 300) {
            let body = marker.ordered ? trimmed : String(trimmed.dropFirst(marker.length)).trimmingCharacters(in: .whitespaces)
            block = PDFImportedBlock(kind: .listItem(depth: 0, ordered: marker.ordered), rect: rect, content: .text(body))
        } else {
            block = PDFImportedBlock(kind: .paragraph, rect: rect, content: .text(trimmed))
        }
        block.fontSize = (fontSize * 2).rounded() / 2
        return block
    }

    /// Joins runs that share a baseline and follow each other left to right.
    static func buildLines(_ runs: [PDFTextRun]) -> [Line] {
        var lines: [Line] = []
        var members: [PDFTextRun] = []
        func flush() {
            guard !members.isEmpty else { return }
            let chars = members.reduce(0) { $0 + max($1.text.count, 1) }
            let weighted = { (value: (PDFTextRun) -> Double) in
                members.reduce(0.0) { $0 + value($1) * Double(max($1.text.count, 1)) } / Double(chars)
            }
            lines.append(Line(
                text: members.map(\.text).joined(separator: " "),
                rect: members.reduce(CGRect.null) { $0.union($1.rect) },
                fontSize: CGFloat(weighted { Double($0.fontSize) }),
                isBold: weighted { $0.isBold ? 1 : 0 } >= 0.8,
                mathScore: weighted { $0.mathScore },
                isTitle: members.contains(where: \.isTitle),
                leadingNumber: members.count >= 2
                    && members[0].text.range(of: #"^\d{1,3}$"#, options: .regularExpression) != nil
                    && members[1].text.first?.isLetter == true))
            members.removeAll()
        }
        for run in runs {
            if let last = members.last,
               verticalOverlap(last.rect, run.rect) >= 0.5 * min(last.rect.height, run.rect.height),
               run.rect.minX >= last.rect.minX {
                members.append(run)
            } else {
                flush()
                members.append(run)
            }
        }
        flush()
        return lines
    }

    // MARK: - Paragraphs, Headings, Lists, Formulas

    private enum LineRole: Equatable {
        case heading, formula, listStart, body
    }

    static func textBlocks(from lines: [Line], bodyFontSize: CGFloat, headingSizeFactor: CGFloat = 1.15) -> [PDFImportedBlock] {
        guard !lines.isEmpty else { return [] }
        let typicalGap = typicalLineGap(lines)
        let column = lines.reduce(CGRect.null) { $0.union($1.rect) }
        var blocks: [PDFImportedBlock] = []
        var current: [Line] = []
        var currentRole: LineRole = .body

        func flush() {
            guard !current.isEmpty else { return }
            blocks.append(makeBlock(current, role: currentRole))
            current.removeAll()
        }

        // Headings are short. Four or more consecutive heading-like lines are
        // body text set in another size (or all in bold), not headings.
        var roles = lines.map { classify($0, bodyFontSize: bodyFontSize, sizeFactor: headingSizeFactor) }
        var start = 0
        while start < roles.count {
            guard roles[start] == .heading else { start += 1; continue }
            var end = start
            while end < roles.count, roles[end] == .heading { end += 1 }
            if end - start >= 4 {
                for i in start..<end where !lines[i].isTitle { roles[i] = .body }
            }
            start = end
        }
        // Headings stand apart. A "heading" line packed between body lines
        // at ordinary line spacing is part of a paragraph: on scans a line
        // dense with bold lemmas passes the weight test, and OCR box heights
        // jitter enough to look 15–30% larger. Clearly larger type is kept.
        for i in roles.indices where roles[i] == .heading && !lines[i].isTitle
            && lines[i].fontSize < bodyFontSize * headingSizeFactor * 1.2 && i > 0 && i + 1 < lines.count {
            let above = lines[i - 1].rect.minY - lines[i].rect.maxY
            let below = lines[i].rect.minY - lines[i + 1].rect.maxY
            let packed = { (gap: CGFloat) in gap >= -1 && gap <= typicalGap * 1.4 + 0.5 }
            if packed(above), packed(below), roles[i - 1] != .heading, roles[i + 1] != .heading {
                roles[i] = .body
            }
        }

        for (index, line) in lines.enumerated() {
            var role = roles[index]
            if role == .body, isDisplayFormula(line, column: column, bodyFontSize: bodyFontSize,
                                               previous: index > 0 ? lines[index - 1] : nil,
                                               next: index + 1 < lines.count ? lines[index + 1] : nil,
                                               typicalGap: typicalGap) {
                role = .formula
            }
            if let previous = current.last,
               continues(previous: previous, next: line, role: role, currentRole: currentRole,
                         firstLine: current[0], typicalGap: typicalGap, lineCount: current.count) {
                current.append(line)
                continue
            }
            flush()
            current = [line]
            currentRole = role
        }
        flush()
        return blocks
    }

    private static func classify(_ line: Line, bodyFontSize: CGFloat, sizeFactor: CGFloat = 1.15) -> LineRole {
        let sizesReliable = sizeFactor <= 1.2
        let text = line.text.trimmingCharacters(in: .whitespaces)
        if isFormulaLine(line) { return .formula }
        // "Table 1: …" is a caption even when it is bold or set larger.
        if isCaption(text) { return .body }
        if line.isTitle { return .heading }
        // Bullets win over bold: a bold bullet item is still a list item.
        // Numbered markers fall through so "1. Introduction" can be a heading.
        if let marker = listMarker(in: text), !marker.ordered { return .listStart }
        // "2.1 Results": a short numbered line in bold or slightly larger
        // type. OCR font sizes are noisy, so the size bar is lower here.
        if text.count <= 80, !text.hasSuffix("."),
           text.range(of: #"^\d{1,2}(\.\d{1,2}){0,3}\.?\s+\p{Lu}"#, options: .regularExpression) != nil,
           line.isBold || (sizesReliable && line.fontSize >= bodyFontSize * 1.05) {
            return .heading
        }
        if isCapitalsHeading(text) { return .heading }
        let larger = line.fontSize >= bodyFontSize * sizeFactor
        let boldStandalone = line.isBold && text.count <= 90 && !text.hasSuffix(".")
            && (!sizesReliable || line.fontSize >= bodyFontSize * 0.95)
        if (larger || boldStandalone) && text.count <= 160 && text.contains(where: \.isLetter) { return .heading }
        if listMarker(in: text) != nil { return .listStart }
        return .body
    }

    static func isFormulaLine(_ line: Line) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, text.count <= 220 else { return false }
        if line.mathScore >= 0.6 { return true }
        let hasRelation = text.range(of: #"[=<>≤≥≈≠∝∈⊂→]"#, options: .regularExpression) != nil
        return line.mathScore >= 0.35 && hasRelation
    }

    /// A short line set in capitals ("BIBLIOGRAPHY", "TERMS OF PAYMENT"):
    /// the oldest heading convention, and one that survives OCR, where size
    /// and weight may not.
    static func isCapitalsHeading(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        guard letters.count >= 4, text.count <= 60, !text.hasSuffix("."),
              text.split(separator: " ").count <= 8 else { return false }
        // Words, not "KEY: value" pairs (HTTP headers, form fields).
        let visible = text.filter { !$0.isWhitespace }
        guard Double(letters.count) / Double(max(visible.count, 1)) >= 0.75,
              text.dropLast().contains(":") == false else { return false }
        return Double(letters.filter(\.isUppercase).count) / Double(letters.count) >= 0.85
    }

    /// A display formula by its placement, for PDFs whose math letters reach
    /// the text layer as plain ASCII (TeX's CMMI "E = mc 2"): a short line
    /// centred in its column, set apart from the text around it, in body
    /// size, with a relation or operator — or ending in an equation number.
    static func isDisplayFormula(_ line: Line, column: CGRect, bodyFontSize: CGFloat,
                                 previous: Line?, next: Line?, typicalGap: CGFloat) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        guard column.width > 100, text.count >= 3, text.count <= 140,
              line.fontSize <= bodyFontSize * 1.2 else { return false }
        let numbered = text.range(of: #"\(\d{1,3}(\.\d{1,3})?[a-z]?\)$"#, options: .regularExpression) != nil
        let body = numbered ? text.replacingOccurrences(of: #"\s*\(\d{1,3}(\.\d{1,3})?[a-z]?\)$"#, with: "", options: .regularExpression) : text
        let hasMath = body.range(of: #"[=<>≤≥≈≠∝∑∫∏√±∓→⇒∂∇∞]"#, options: .regularExpression) != nil
            || line.mathScore >= 0.15
        guard hasMath else { return false }
        // Prose with an "=" in it is a sentence, not a display.
        let words = body.split(separator: " ").filter { $0.count >= 4 && $0.allSatisfy(\.isLetter) }
        guard words.count <= 3, !body.hasSuffix(":") else { return false }

        let centred = abs(line.rect.midX - column.midX) < column.width * 0.12 && line.rect.width < column.width * 0.8
        guard centred || numbered else { return false }
        // Displays are set off: not glued to a full-width line on both sides.
        let gapAbove = previous.map { $0.rect.minY - line.rect.maxY } ?? .infinity
        let gapBelow = next.map { line.rect.minY - $0.rect.maxY } ?? .infinity
        return gapAbove > typicalGap * 1.2 || gapBelow > typicalGap * 1.2 || numbered
    }

    private static func continues(previous: Line, next: Line, role: LineRole, currentRole: LineRole,
                                  firstLine: Line, typicalGap: CGFloat, lineCount: Int) -> Bool {
        // Jumped up (new column or page region): never the same block here;
        // cross-column continuation is handled at document level.
        if next.rect.maxY > previous.rect.minY + previous.rect.height * 0.5 { return false }
        let gap = previous.rect.minY - next.rect.maxY
        let size = max(previous.fontSize, 1)

        switch currentRole {
        case .formula:
            return role == .formula && gap < size * 1.2
        case .heading:
            return role == .heading && lineCount < 3 && abs(next.fontSize - previous.fontSize) < 0.8
                && previous.isBold == next.isBold && gap < size * 0.9
        case .listStart, .body:
            guard role == .body, !next.leadingNumber else { return false }
            if abs(next.fontSize - previous.fontSize) > max(1, previous.fontSize * 0.15) { return false }
            if gap > max(typicalGap * 1.6, typicalGap + size * 0.35) { return false }
            // A blank line's worth of space is a paragraph break in any
            // typography, even with nothing to compare against.
            if gap > size { return false }

            // Right-to-left text is aligned on its right edge, so "indent"
            // and "short last line" are measured from the right.
            let rightToLeft = TextScript.isRightToLeftLine(previous.text)
                || TextScript.isRightToLeftLine(firstLine.text)
            let right = max(previous.rect.maxX, firstLine.rect.maxX, next.rect.maxX)
            let left = min(previous.rect.minX, firstLine.rect.minX)
            let width = max(right - left, 1)
            let endsSentence = previous.text.range(of: #"[.!?:]["”’)]?$"#, options: .regularExpression) != nil
            // A short line ending a sentence closes the paragraph.
            let trailingEdge = rightToLeft ? previous.rect.minX - left : right - previous.rect.maxX
            if endsSentence, trailingEdge > width * 0.15 { return false }

            // First-line indent starts a new paragraph (list continuations are
            // indented under the marker, so lists are exempt).
            if currentRole == .body {
                let indent: CGFloat = rightToLeft
                    ? firstLine.rect.maxX - next.rect.maxX
                    : next.rect.minX - firstLine.rect.minX
                let deeperThanPrevious: CGFloat = rightToLeft
                    ? previous.rect.maxX - next.rect.maxX
                    : next.rect.minX - previous.rect.minX
                if indent > size * 0.8, deeperThanPrevious > size * 0.8 { return false }
            }

            // A list item continues on lines indented under its text. A line
            // back at the marker's position continues it only after a full
            // line (lists without a hanging indent, or an indented first
            // line); after a short line it is the paragraph after the list.
            if currentRole == .listStart {
                let atMarker: Bool = rightToLeft
                    ? next.rect.maxX > firstLine.rect.maxX - size * 0.5
                    : next.rect.minX < firstLine.rect.minX + size * 0.5
                if atMarker {
                    return rightToLeft ? previous.rect.minX <= left + width * 0.1
                                       : previous.rect.maxX >= right - width * 0.1
                }
            }
            return true
        }
    }

    private static func makeBlock(_ lines: [Line], role: LineRole) -> PDFImportedBlock {
        var block = makeBlockContent(lines, role: role)
        let size = lines.reduce(0) { $0 + $1.fontSize } / CGFloat(lines.count)
        block.fontSize = (size * 2).rounded() / 2
        return block
    }

    private static func makeBlockContent(_ lines: [Line], role: LineRole) -> PDFImportedBlock {
        let rect = lines.reduce(CGRect.null) { $0.union($1.rect) }
        let text = joinLines(lines.map(\.text))
        switch role {
        case .heading:
            // Level is provisional; `assignHeadingLevels` fixes it doc-wide.
            return PDFImportedBlock(kind: .heading(level: 1), rect: rect, content: .text(text))
        case .formula:
            let source = lines.map(\.text).joined(separator: "\n")
            return PDFImportedBlock(kind: .formula, rect: rect, content: .formula(PDFFormula(sourceText: source)))
        case .listStart:
            let marker = listMarker(in: text)
            // A long lettered or numbered "item" is a labelled subsection
            // ("(a) Birth of Samuel (1:1-2:11). The skilfully told…"). Keep
            // it as a paragraph so its label survives: a Typst enum would
            // renumber it "1.", breaking references to "(a)".
            if marker?.ordered == true, text.count > 300 {
                return PDFImportedBlock(kind: .paragraph, rect: rect, content: .text(text))
            }
            // Ordered items keep their label ("3.", "(IV)", "(a)") in the
            // text: books cross-reference them, and a list that continues
            // from the previous page must not restart at 1. The emitters
            // render the label. Bullets are dropped.
            let body = marker.map { $0.ordered ? text : String(text.dropFirst($0.length)).trimmingCharacters(in: .whitespaces) } ?? text
            return PDFImportedBlock(kind: .listItem(depth: 0, ordered: marker?.ordered ?? false), rect: rect, content: .text(body))
        case .body:
            if isCaption(text) {
                return PDFImportedBlock(kind: .caption, rect: rect, content: .text(text))
            }
            return PDFImportedBlock(kind: .paragraph, rect: rect, content: .text(text))
        }
    }

    /// The vertical gap between consecutive lines of one paragraph: the
    /// lower quartile of gaps between lines of similar size. (The median
    /// fails on documents of short paragraphs, where paragraph gaps are the
    /// majority.)
    static func typicalLineGap(_ lines: [Line]) -> CGFloat {
        var gaps: [CGFloat] = []
        for (a, b) in zip(lines, lines.dropFirst()) {
            let gap = a.rect.minY - b.rect.maxY
            if gap >= 0, gap < a.fontSize * 2, abs(a.fontSize - b.fontSize) < 1 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return lines.first.map { $0.fontSize * 0.3 } ?? 3 }
        gaps.sort()
        return gaps[gaps.count / 4]
    }

    /// Joins wrapped lines, undoing end-of-line hyphenation.
    ///
    /// A line ending in a soft hyphen (U+00AD, also set by the text-layer
    /// extractor when PDFKit reports a word split across lines) always joins
    /// without a space. A visible hyphen joins only when the next line starts
    /// in lowercase, so "well-" + "Known" keeps its hyphen.
    static func joinLines(_ lines: [String]) -> String {
        var result = ""
        var pendingSoftBreak = false
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let softBreak = trimmed.hasSuffix("\u{00AD}")
            let line = trimmed.replacingOccurrences(of: "\u{00AD}", with: "")
            guard !line.isEmpty else { continue }
            defer { pendingSoftBreak = softBreak }
            if result.isEmpty { result = line; continue }
            if pendingSoftBreak {
                result += line
            } else if let last = result.last, let first = line.first,
                      TextScript.joinsWithoutSpace(after: last, before: first) {
                // A Chinese, Japanese or Thai sentence split by the line
                // wrapping is one word run: no space at the break.
                result += line
            } else if result.hasSuffix("-"), result.dropLast().last?.isNumber == true, line.first?.isNumber == true {
                // A range broken after its dash ("1:1-" / "4:1a") keeps the
                // dash and loses the space.
                result += line
            } else if let last = result.last, last == "-" || last == "¬",
                      result.dropLast().last?.isLetter == true,
                      line.first?.isLowercase == true {
                result.removeLast()
                result += line
            } else {
                result += " " + line
            }
        }
        return result
    }

    struct ListMarker: Equatable {
        var length: Int
        var ordered: Bool
        var number: Int?
    }

    static func listMarker(in text: String) -> ListMarker? {
        let patterns: [(String, Bool)] = [
            // Includes the Symbol/Wingdings private-use bullets Word writes
            // (U+F0B7, U+F0A7, U+F076, U+F0D8, U+F0FC).
            (#"^[•●○◦▪■□‣∙·▸►➢✓✔\-–—*\x{F0B7}\x{F0A7}\x{F076}\x{F0D8}\x{F0FC}]\s+"#, false),
            (#"^\(?(\d{1,3})[.)]\s+"#, true),
            (#"^\(?[a-z][)]\s+"#, true),
            (#"^\([a-z]\)\s+"#, true),
            (#"^\(?(?:i|ii|iii|iv|v|vi|vii|viii|ix|x)\)\s+"#, true),
            // Outline labels: "(A)", "(IV)".
            (#"^\([A-Z]\)\s+"#, true),
            (#"^\((?:I|II|III|IV|V|VI|VII|VIII|IX|X|XI|XII)\)\s+"#, true),
        ]
        for (pattern, ordered) in patterns {
            guard let range = text.range(of: pattern, options: .regularExpression) else { continue }
            let marker = String(text[range])
            let number = Int(marker.filter(\.isNumber))
            // "3. " followed by lowercase prose is more likely a sentence
            // fragment than a list item; numbered headings are caught earlier.
            return ListMarker(length: text.distance(from: text.startIndex, to: range.upperBound), ordered: ordered, number: number)
        }
        return nil
    }

    static func isCaption(_ text: String) -> Bool {
        text.range(of: #"^(figure|fig\.|table|tab\.|chart|exhibit|listing|plate|scheme)\s*[0-9IVX]+[a-z]?\s*[.:|—–-]"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Math Scoring

    /// Fraction of characters that are mathematical symbols. Extractors that
    /// know font names combine this with the math-font share.
    static func mathSymbolFraction(_ text: String) -> Double {
        var total = 0, math = 0
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            total += 1
            if isMathScalar(scalar) { math += 1 }
        }
        return total == 0 ? 0 : Double(math) / Double(total)
    }

    static func isMathScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // Greek letters are not evidence of mathematics: Greek is a language
        // written in these letters, and Greek math arrives in a math font
        // (`isMathFont`) or as math alphanumerics below.
        case 0x2070...0x209F: return true          // super/subscripts
        case 0x2100...0x214F: return true          // letterlike (ℝ, ℏ)
        case 0x2190...0x21FF: return true          // arrows
        case 0x2200...0x22FF: return true          // operators
        case 0x2300...0x23FF: return true          // misc technical (⌈ ⎛)
        case 0x27C0...0x27EF, 0x2980...0x2AFF: return true
        case 0x1D400...0x1D7FF: return true        // math alphanumerics
        default: return "=+<>^|∑∫√±×÷∂∇∞".unicodeScalars.contains(scalar)
        }
    }

    /// Font names used for mathematics in TeX, Word and common math fonts.
    static func isMathFont(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let markers = ["cmmi", "cmsy", "cmex", "msam", "msbm", "math", "symbol", "stix", "esint",
                       "rsfs", "eufm", "mt extra", "mtextra", "euclid", "lmmono-math", "txsy", "pxsy"]
        return markers.contains { lowered.contains($0) }
    }

    // MARK: - Document-Level Passes

    /// False when prose lines on a page disagree widely about their size —
    /// typical of OCR text layers, where the size comes from word boxes
    /// whose height depends on the letters (digits and capitals are taller).
    /// Headings by size alone are then not trusted.
    static func sizeIsReliable(_ runs: [PDFTextRun]) -> Bool {
        let sizes = runs.filter { $0.text.count >= 25 }.map { Double($0.fontSize) }
        guard sizes.count >= 8 else { return true }
        let mean = sizes.reduce(0, +) / Double(sizes.count)
        let variance = sizes.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(sizes.count)
        return mean > 0 && variance.squareRoot() / mean <= 0.2
    }

    /// The size most body characters are set in. Only prose-length runs
    /// vote: a page of small-type chart cells must not redefine "body" and
    /// turn every real paragraph into a heading.
    static func bodyFontSize(_ runs: [PDFTextRun]) -> CGFloat {
        let prose = runs.filter { $0.text.count >= 25 }
        let voters = prose.reduce(0) { $0 + $1.text.count } >= 200 ? prose : runs
        var histogram: [Int: Int] = [:]
        for run in voters { histogram[Int((run.fontSize * 2).rounded()), default: 0] += run.text.count }
        guard let mode = histogram.max(by: { $0.value < $1.value })?.key else { return 11 }
        return CGFloat(mode) / 2
    }

    /// Final clean-up across pages: heading levels, captions, list depths,
    /// paragraphs split by a column or page break.
    static func finalize(_ document: inout PDFImportedDocument) {
        assignHeadingLevels(&document)
        mergeContinuedTables(&document)
        mergeContinuedCode(&document)
        markContents(&document)
        mergeContinuedParagraphs(&document)
        attachCaptions(&document)
        assignListDepths(&document)
    }

    /// Numbered headings ("2.3 Results") use their numbering depth; others
    /// rank by size, largest first.
    static func assignHeadingLevels(_ document: inout PDFImportedDocument) {
        var sizes: Set<Int> = []
        for page in document.pages {
            for block in page.blocks where block.kind.isHeading { sizes.insert(sizeKey(block)) }
        }
        let ranked = sizes.sorted(by: >)
        for p in document.pages.indices {
            for b in document.pages[p].blocks.indices where document.pages[p].blocks[b].kind.isHeading {
                let block = document.pages[p].blocks[b]
                let text = block.content.plainText
                let level: Int
                if let match = text.range(of: #"^\d+(\.\d+){0,4}(?=\.?\s+\S)"#, options: .regularExpression) {
                    level = text[match].split(separator: ".").count
                } else {
                    level = (ranked.firstIndex(of: sizeKey(block)) ?? 0) + 1
                }
                document.pages[p].blocks[b].kind = .heading(level: min(max(level, 1), 4))
            }
        }
    }

    /// Font size in half points; falls back to box height for blocks built
    /// without size information.
    private static func sizeKey(_ block: PDFImportedBlock) -> Int {
        Int(((block.fontSize ?? block.rect.height / 1.2) * 2).rounded())
    }

    /// Joins a ruled table that ends a page with the one that opens the next
    /// page when their column borders match: one table broken by the page.
    /// The continuation may lack leading columns — a tall cell (a row label
    /// spanning many rows) that keeps going without rules of its own; those
    /// cells are extended down. A repeated header row is dropped.
    static func mergeContinuedTables(_ document: inout PDFImportedDocument) {
        var p = 0
        while p + 1 < document.pages.count {
            // The next page that still has blocks (a merge can empty one).
            guard let q = document.pages.indices.first(where: { $0 > p && !document.pages[$0].blocks.isEmpty }) else { break }
            guard let lastIndex = document.pages[p].blocks.indices.last,
                  case .table(var first) = document.pages[p].blocks[lastIndex].content,
                  let next = document.pages[q].blocks.first,
                  case .table(var second) = next.content,
                  !first.columnEdges.isEmpty, !second.columnEdges.isEmpty,
                  second.columnEdges.count <= first.columnEdges.count,
                  zip(first.columnEdges.suffix(second.columnEdges.count), second.columnEdges).allSatisfy({ abs($0 - $1) < 3 })
            else {
                p = q
                continue
            }
            if first.headerRows > 0, second.rows.first == first.rows.first {
                second.rows.removeFirst()
                second.spans = second.spans.filter { $0.row > 0 }.map { var s = $0; s.row -= 1; return s }
            }
            let missing = first.columnEdges.count - second.columnEdges.count
            let lastRow = first.rows.count - 1

            // A row broken by the page: the continuation opens with an empty
            // key column and few filled cells. Append them to the last row.
            if let opening = second.rows.first, opening.count > 1, lastRow >= 0,
               opening[0].isEmpty, opening[1].isEmpty {
                let filled = opening.indices.filter { !opening[$0].isEmpty }
                if !filled.isEmpty, filled.count * 2 <= opening.count {
                    for i in filled {
                        let column = i + missing
                        guard column < first.rows[lastRow].count else { continue }
                        let above = first.rows[lastRow][column]
                        first.rows[lastRow][column] = above.isEmpty ? opening[i] : joinLines([above, opening[i]])
                    }
                    second.rows.removeFirst()
                    second.spans = second.spans.compactMap { span in
                        var s = span
                        if s.row == 0 {
                            guard s.rowSpan > 1 else { return nil }
                            s.rowSpan -= 1
                        } else {
                            s.row -= 1
                        }
                        return s
                    }
                }
            }
            if missing > 0 {
                second.rows = second.rows.map { Array(repeating: "", count: missing) + $0 }
                second.spans = second.spans.map { var s = $0; s.column += missing; return s }
                // Extend the cells that cover the last row in those columns.
                for column in 0..<missing {
                    if let i = first.spans.firstIndex(where: { $0.column <= column && column < $0.column + $0.columnSpan
                        && $0.row <= lastRow && lastRow < $0.row + $0.rowSpan }) {
                        if first.spans[i].column == column { first.spans[i].rowSpan += second.rows.count }
                    } else {
                        first.spans.append(PDFCellSpan(row: lastRow, column: column, rowSpan: 1 + second.rows.count, columnSpan: 1))
                    }
                }
            }
            let offset = first.rows.count
            first.rows += second.rows
            first.spans += second.spans.map { var s = $0; s.row += offset; return s }
            document.pages[p].blocks[lastIndex].content = .table(first)
            document.pages[q].blocks.removeFirst()
            // Stay on this page while the table keeps going.
            if !document.pages[q].blocks.isEmpty { p = q }
        }
    }

    /// Paragraphs made of dot-leader entries ("Overview ........ 3") are a
    /// printed table of contents.
    static func markContents(_ document: inout PDFImportedDocument) {
        let leader = try! NSRegularExpression(pattern: #"(\.\s?){4,}\s*[0-9ivxlc]+"#)
        for p in document.pages.indices {
            for i in document.pages[p].blocks.indices {
                guard document.pages[p].blocks[i].kind == .paragraph,
                      case .text(let text) = document.pages[p].blocks[i].content else { continue }
                let leaders = leader.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
                if leaders >= 2 || (leaders == 1 && text.count < 120) {
                    document.pages[p].blocks[i].kind = .contents
                }
            }
            // Its "Contents" heading goes with it: `#outline()` titles itself.
            for i in document.pages[p].blocks.indices.dropLast()
            where document.pages[p].blocks[i + 1].kind == .contents && document.pages[p].blocks[i].kind.isHeading {
                if case .text(let text) = document.pages[p].blocks[i].content,
                   text.range(of: #"^(table of )?contents$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    document.pages[p].blocks[i].kind = .contents
                }
            }
        }
    }

    /// Joins a code sample that ends one page with the one opening the next.
    static func mergeContinuedCode(_ document: inout PDFImportedDocument) {
        var p = 0
        while p + 1 < document.pages.count {
            guard let q = document.pages.indices.first(where: { $0 > p && !document.pages[$0].blocks.isEmpty }) else { break }
            if let lastIndex = document.pages[p].blocks.indices.last,
               case .code = document.pages[p].blocks[lastIndex].kind,
               case .text(let a) = document.pages[p].blocks[lastIndex].content,
               case .code = document.pages[q].blocks[0].kind,
               case .text(let b) = document.pages[q].blocks[0].content {
                document.pages[p].blocks[lastIndex].content = .text(a + "\n" + b)
                document.pages[q].blocks.removeFirst()
                if !document.pages[q].blocks.isEmpty { p = q }
                continue
            }
            p = q
        }
    }

    /// Joins a paragraph that ends mid-sentence with the next paragraph when
    /// that one starts in lowercase (a column or page break split it).
    static func mergeContinuedParagraphs(_ document: inout PDFImportedDocument) {
        var flat: [(page: Int, block: PDFImportedBlock)] = []
        for page in document.pages { for block in page.blocks { flat.append((page.index, block)) } }
        var merged: [(page: Int, block: PDFImportedBlock)] = []
        for item in flat {
            if let last = merged.last, last.block.kind == .paragraph, item.block.kind == .paragraph,
               case .text(let a) = last.block.content, case .text(let b) = item.block.content,
               a.range(of: #"[.!?:;"”)\]]$"#, options: .regularExpression) == nil,
               b.first?.isLowercase == true {
                merged[merged.count - 1].block.content = .text(joinLines([a, b]))
                continue
            }
            merged.append(item)
        }
        for p in document.pages.indices {
            document.pages[p].blocks = merged.filter { $0.page == document.pages[p].index }.map(\.block)
        }
    }

    /// Moves caption text into the adjacent figure or table: tables look
    /// above first, figures below first, as in most typesetting styles.
    static func attachCaptions(_ document: inout PDFImportedDocument) {
        for p in document.pages.indices {
            var blocks = document.pages[p].blocks
            var used = Set<Int>()
            for i in blocks.indices {
                let kind = blocks[i].kind
                guard kind == .figure || kind == .table else { continue }
                let prefersAbove = kind == .table
                let candidates = prefersAbove ? [i - 1, i + 1] : [i + 1, i - 1]
                guard let c = candidates.first(where: { blocks.indices.contains($0) && blocks[$0].kind == .caption && !used.contains($0) }),
                      case .text(let caption) = blocks[c].content else { continue }
                used.insert(c)
                switch blocks[i].content {
                case .figure(var figure):
                    figure.caption = caption
                    blocks[i].content = .figure(figure)
                case .table(var table):
                    table.caption = caption
                    blocks[i].content = .table(table)
                default: break
                }
            }
            // Unlabelled captions ("Monthly volume by quarter"): a short line
            // centred right under a figure that has none yet.
            for i in blocks.indices where blocks[i].kind == .figure {
                guard case .figure(var figure) = blocks[i].content, figure.caption == nil,
                      blocks.indices.contains(i + 1), !used.contains(i + 1),
                      blocks[i + 1].kind == .paragraph || blocks[i + 1].kind == .caption,
                      case .text(let text) = blocks[i + 1].content else { continue }
                let picture = blocks[i].rect, line = blocks[i + 1].rect
                let size = blocks[i + 1].fontSize ?? 10
                let gap = picture.minY - line.maxY
                // Centred under the figure, or flush with its left edge.
                let aligned = abs(line.midX - picture.midX) < picture.width * 0.25 || abs(line.minX - picture.minX) < 6
                guard text.count <= 160, gap >= -1, gap < size * 2.5, aligned,
                      line.width <= picture.width * 1.2 else { continue }
                figure.caption = text
                blocks[i].content = .figure(figure)
                used.insert(i + 1)
            }
            for i in blocks.indices where blocks[i].kind == .caption && !used.contains(i) {
                blocks[i].kind = .paragraph
            }
            document.pages[p].blocks = blocks.enumerated().filter { !used.contains($0.offset) }.map(\.element)
        }
    }

    /// Nesting depth from marker indentation within each run of list items.
    static func assignListDepths(_ document: inout PDFImportedDocument) {
        for p in document.pages.indices {
            var blocks = document.pages[p].blocks
            var i = 0
            while i < blocks.count {
                guard case .listItem = blocks[i].kind else { i += 1; continue }
                var j = i
                while j < blocks.count, case .listItem = blocks[j].kind { j += 1 }
                let indents = Array(Set(blocks[i..<j].map { Int(($0.rect.minX / 6).rounded()) })).sorted()
                for k in i..<j {
                    guard case .listItem(_, let ordered) = blocks[k].kind else { continue }
                    let depth = indents.firstIndex(of: Int((blocks[k].rect.minX / 6).rounded())) ?? 0
                    blocks[k].kind = .listItem(depth: min(depth, 3), ordered: ordered)
                }
                i = j
            }
            document.pages[p].blocks = blocks
        }
    }

    // MARK: - Geometry Helpers

    static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }

    static func overlap(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> CGFloat {
        max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
    }

    static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
