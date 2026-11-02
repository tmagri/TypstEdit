import Foundation
import PDFKit

/// Reads a PDF as Markdown for an AI model, with the PDF importer: shared by
/// AI Chat's `read_pdf` tool and the MCP server's `read_pdf`.
///
/// Nothing is written (no figure files), at most `maxPages` pages are read
/// per call, and recent results are cached so a model paging through one
/// with `offset` does not convert the same pages again.
enum PDFReader {
    static let defaultPages = 20
    static let maxPages = 40

    struct Reading: Sendable {
        var markdown: String
        var summary: String
        var warnings: [String]
    }

    enum ReadError: LocalizedError {
        case notAPDF(String), unreadable(String), locked(String), badPages(String)
        var errorDescription: String? {
            switch self {
            case .notAPDF(let path): return "'\(path)' is not a PDF."
            case .unreadable(let path): return "'\(path)' could not be opened as a PDF."
            case .locked(let path): return "'\(path)' is password protected."
            case .badPages(let message): return message
            }
        }
    }

    /// The page count of a readable, unlocked PDF.
    static func pageCount(of url: URL, label: String) throws -> Int {
        guard url.pathExtension.lowercased() == "pdf" else { throw ReadError.notAPDF(label) }
        guard let document = PDFDocument(url: url) else { throw ReadError.unreadable(label) }
        guard !document.isLocked else { throw ReadError.locked(label) }
        return document.pageCount
    }

    /// The pages a call covers: `raw` ("5", "12-30"), or the first
    /// `defaultCount` pages. Ranges over `maximum` pages are cut, and with
    /// `defaultCount == nil` a PDF over `maximum` pages needs a range. The
    /// note tells the model how to continue.
    static func pageRange(_ raw: String?, pageCount: Int, defaultCount: Int?, maximum: Int, label: String) throws -> (ClosedRange<Int>, String) {
        var range: ClosedRange<Int>
        var note = ""
        if let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let numbers = raw.split(whereSeparator: { "-–— ".contains($0) }).compactMap { Int($0) }
            guard (1...2).contains(numbers.count), numbers[0] >= 1, numbers.last! >= numbers[0] else {
                throw ReadError.badPages("pages must be a page or a range such as \"12-30\"; got \"\(raw)\".")
            }
            guard numbers[0] <= pageCount else {
                throw ReadError.badPages("'\(label)' has \(pageCount) pages; page \(numbers[0]) does not exist.")
            }
            range = numbers[0]...min(numbers.last!, pageCount)
        } else if let defaultCount {
            range = 1...min(pageCount, defaultCount)
            if pageCount > defaultCount {
                note = " The PDF has \(pageCount) pages; pass pages (for example \"\(defaultCount + 1)-\(min(pageCount, defaultCount * 2))\") to read more."
            }
        } else {
            guard pageCount <= maximum else {
                throw ReadError.badPages("'\(label)' has \(pageCount) pages. Pass pages, at most \(maximum) per call, for example \"1-\(maximum)\".")
            }
            range = 1...pageCount
        }
        if range.count > maximum {
            let end = range.lowerBound + maximum - 1
            note += " Only pages \(range.lowerBound)-\(end) were read (at most \(maximum) per call); continue from page \(end + 1)."
            range = range.lowerBound...end
        }
        return (range, note)
    }

    /// The importer's Markdown for `range`, from the cache when the file is
    /// unchanged.
    static func read(_ url: URL, pages range: ClosedRange<Int>, forceOCR: Bool = false) async throws -> Reading {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.standardizedFileURL.path)|\(modified)|\(range)|\(forceOCR)"
        if let cached = cache.value(for: key) { return cached }

        var importer = PDFImporter(sourceURL: url, outputDirectory: FileManager.default.temporaryDirectory, baseName: "read-pdf")
        importer.options.pageRange = range
        importer.options.writeAssets = false
        importer.options.forceOCR = forceOCR
        let result = try await importer.run()
        let reading = Reading(markdown: result.markdown, summary: result.summary, warnings: result.warnings)
        cache.store(reading, for: key)
        return reading
    }

    /// The first line of a result: what was read, and how to read more.
    static func header(label: String, range: ClosedRange<Int>, pageCount: Int, reading: Reading, note: String) -> String {
        var header = "PDF '\(label)', pages \(range.lowerBound)-\(range.upperBound) of \(pageCount) (\(reading.summary)).\(note)"
        if !reading.warnings.isEmpty { header += "\nNotes: " + reading.warnings.joined(separator: " ") }
        return header
    }

    private static let cache = Cache()

    /// A few recent readings; small, because each is a whole page range.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Reading] = [:]
        private var order: [String] = []

        func value(for key: String) -> Reading? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }

        func store(_ reading: Reading, for key: String) {
            lock.lock(); defer { lock.unlock() }
            if entries[key] == nil { order.append(key) }
            entries[key] = reading
            while order.count > 6 { entries[order.removeFirst()] = nil }
        }
    }
}
