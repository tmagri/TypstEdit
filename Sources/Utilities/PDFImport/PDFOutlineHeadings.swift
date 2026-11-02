import Foundation
import PDFKit

/// Uses the PDF's own outline (bookmarks) as the authority on headings.
///
/// Most manuals, books and LaTeX papers carry an outline that names every
/// heading with its level and exact position. When it exists, it decides
/// which blocks are headings and at what level, so nothing depends on font
/// sizes or weights — which OCR, outlined text and substituted fonts make
/// unreliable.
enum PDFOutlineHeadings {

    struct Entry: Equatable {
        var title: String
        var level: Int
        var pageIndex: Int
        /// Destination in display space, when the bookmark has one.
        var point: CGPoint?
    }

    static func entries(of pdf: PDFDocument) -> [Entry] {
        guard let root = pdf.outlineRoot else { return [] }
        var result: [Entry] = []
        func walk(_ item: PDFOutline, level: Int) {
            for i in 0..<item.numberOfChildren {
                guard let child = item.child(at: i) else { continue }
                if let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
                   let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination,
                   let page = destination.page {
                    let index = pdf.index(for: page)
                    var point: CGPoint?
                    let p = destination.point
                    if p.x.isFinite, p.y.isFinite, p.y < 100_000 {
                        point = p.applying(PDFPageExtractor.displayTransform(for: page))
                    }
                    result.append(Entry(title: label, level: level, pageIndex: index, point: point))
                }
                walk(child, level: level + 1)
            }
        }
        walk(root, level: 1)
        return result
    }

    /// Marks the blocks named by the outline as headings at the outline's
    /// level, splitting a heading that was merged with following text, and
    /// inserting headings whose text the page did not yield (outlined glyphs).
    static func apply(_ entries: [Entry], to document: inout PDFImportedDocument) {
        guard !entries.isEmpty else { return }
        let deepest = entries.map(\.level).max() ?? 1
        var outlinedBlocks = Set<[Int]>()

        for entry in entries {
            guard let p = document.pages.firstIndex(where: { $0.index == entry.pageIndex }) else { continue }
            let target = normalize(entry.title)
            guard !target.isEmpty else { continue }
            var blocks = document.pages[p].blocks

            // Candidates whose text starts with the title, nearest the
            // bookmark's position first.
            // Section numbers are compared loosely: the page may print the
            // title without its number (or with a number the outline lacks).
            let bareTarget = withoutNumber(target)
            let candidates = blocks.indices.filter { i in
                guard case .text(let text) = blocks[i].content else { return false }
                switch blocks[i].kind {
                case .paragraph, .heading, .caption, .listItem:
                    let own = normalize(text)
                    return own.hasPrefix(target) || (!bareTarget.isEmpty && withoutNumber(own).hasPrefix(bareTarget))
                default: return false
                }
            }
            let distance = { (i: Int) -> CGFloat in
                guard let point = entry.point else { return 0 }
                return abs(blocks[i].rect.maxY - point.y)
            }
            if let i = candidates.min(by: { distance($0) < distance($1) }), case .text(let text) = blocks[i].content {
                // Words after the title belong to a merged paragraph.
                let printedTitleWords = normalize(text).hasPrefix(target)
                    ? clean(entry.title).split(separator: " ").count
                    : withoutNumber(clean(entry.title)).split(separator: " ").count
                let words = clean(text).split(separator: " ")
                let rest: String? = words.count > printedTitleWords ? words.dropFirst(printedTitleWords).joined(separator: " ") : nil
                blocks[i].kind = .heading(level: min(entry.level, 6))
                blocks[i].content = .text(clean(entry.title))
                if let rest, !rest.isEmpty {
                    var paragraph = blocks[i]
                    paragraph.kind = .paragraph
                    paragraph.content = .text(rest)
                    blocks.insert(paragraph, at: i + 1)
                }
                outlinedBlocks.insert([p, i])
            } else {
                // Not on the page as text: insert it where the bookmark points.
                var heading = PDFImportedBlock(kind: .heading(level: min(entry.level, 6)),
                                               rect: CGRect(origin: entry.point ?? .zero, size: CGSize(width: 1, height: 1)),
                                               content: .text(clean(entry.title)))
                heading.fontSize = nil
                let y = entry.point?.y ?? .infinity
                let position = blocks.firstIndex { $0.rect.maxY <= y + 2 } ?? blocks.count
                blocks.insert(heading, at: position)
                outlinedBlocks.insert([p, position])
            }
            document.pages[p].blocks = blocks
        }

        // Headings the outline does not list sit below its levels.
        for p in document.pages.indices {
            for i in document.pages[p].blocks.indices {
                guard case .heading(let level) = document.pages[p].blocks[i].kind, !outlinedBlocks.contains([p, i]) else { continue }
                document.pages[p].blocks[i].kind = .heading(level: min(max(level, deepest + 1), 6))
            }
        }
    }

    /// Lowercased, whitespace-collapsed, typographic dashes unified.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[–—]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func clean(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// "3.7 CTU Task" → "CTU Task"; "Chapter 2 API" stays as is.
    static func withoutNumber(_ text: String) -> String {
        text.replacingOccurrences(of: #"^\d+(\.\d+)*\.?\s+"#, with: "", options: .regularExpression)
    }
}
