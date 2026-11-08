import AppKit

/// Turns Typst math snippets into SVG images for the calculator history,
/// using the same bundled `typst` binary the preview pane uses. Caching is
/// keyed on (snippet, color) so scrolling back through history is instant.
actor CASMathRenderer {
    static let shared = CASMathRenderer()

    private let cache = NSCache<NSString, NSImage>()
    private let scratchRoot: URL
    /// Rendered snippets are kept bounded *by count* before, which says nothing
    /// about size: a rendered chart can be several megabytes. A byte budget
    /// and a memory-pressure purge keep the history cache honest.
    private static let maxCacheBytes = 24 * 1024 * 1024
    private var cachedBytes = 0
    /// Written once in `init`, read in `deinit`; matches the pattern used for
    /// notification tokens elsewhere in the app.
    nonisolated(unsafe) private var memoryObserver: NSObjectProtocol?

    init() {
        let base = NSTemporaryDirectory()
        scratchRoot = URL(fileURLWithPath: base).appendingPathComponent("TypstEditCalc", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        cache.countLimit = 512
        cache.totalCostLimit = Self.maxCacheBytes
        MemoryPressureMonitor.shared.start()
        memoryObserver = NotificationCenter.default.addObserver(
            forName: MemoryPressureMonitor.willFreeMemory,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.purgeCache() }
        }
    }

    deinit {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }

    /// Drops every rendered snippet; the next look at the history re-renders
    /// the rows that are visible.
    func purgeCache() {
        cache.removeAllObjects()
        cachedBytes = 0
    }

    /// Stores an image with its approximate pixel cost, so NSCache evicts by
    /// real size rather than by count.
    private func store(_ image: NSImage, forKey key: NSString) {
        let cost = Int(image.size.width * image.size.height * 4)
        cachedBytes += cost
        cache.setObject(image, forKey: key, cost: cost)
        if cachedBytes > Self.maxCacheBytes {
            purgeCache()
        }
    }

    /// Compiles a Typst math snippet to an image. Returns nil when the
    /// bundled typst is missing or the snippet fails to compile — callers
    /// then fall back to plain monospace text.
    func image(typst math: String, dark: Bool) async -> NSImage? {
        let clean = Self.cleanMathPayload(math)
        let key = "\(dark ? "d" : "l")|\(clean)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let typstPath = Self.resolveTypstPath() else { return nil }

        let source = Self.documentSource(math: clean, dark: dark)

        let work = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let inputURL = work.appendingPathComponent("math.typ")
        let outputURL = work.appendingPathComponent("math.svg")
        guard (try? source.write(to: inputURL, atomically: true, encoding: .utf8)) != nil else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        process.arguments = ["compile", inputURL.path, outputURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: outputURL.path) else { return nil }
        guard let image = NSImage(contentsOf: outputURL) else { return nil }

        store(image, forKey: key)
        return image
    }

    /// Renders text with inline or display math ($...$) into a rendered vector snippet.
    func renderRichSnippet(markup: String, dark: Bool, fontSize: CGFloat = 11, maxWidth: CGFloat = 310) async -> NSImage? {
        let key = "rt|\(dark ? "d" : "l")|\(fontSize)|\(maxWidth)|\(markup)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let typstPath = Self.resolveTypstPath() else { return nil }

        let fill = dark ? "ffffff" : "000000"
        let source = """
        #set page(width: \(maxWidth)pt, height: auto, margin: (x: 2pt, y: 2pt), fill: none)
        #set text(fill: rgb("\(fill)"), size: \(fontSize)pt)
        #set par(justify: false, leading: 0.5em)
        #align(right)[
          \(markup)
        ]
        """

        let work = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let inputURL = work.appendingPathComponent("doc.typ")
        let outputURL = work.appendingPathComponent("doc.svg")
        guard (try? source.write(to: inputURL, atomically: true, encoding: .utf8)) != nil else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        process.arguments = ["compile", inputURL.path, outputURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: outputURL.path) else { return nil }
        guard let image = NSImage(contentsOf: outputURL) else { return nil }

        store(image, forKey: key)
        return image
    }

    /// Strips surrounding math delimiters if already present.
    nonisolated static func cleanMathPayload(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("$$") && text.hasSuffix("$$") && text.count >= 4 {
            text = String(text.dropFirst(2).dropLast(2))
        } else if text.hasPrefix("$") && text.hasSuffix("$") && text.count >= 2 {
            text = String(text.dropFirst(1).dropLast(1))
        } else if text.hasPrefix("\\[") && text.hasSuffix("\\]") && text.count >= 4 {
            text = String(text.dropFirst(2).dropLast(2))
        } else if text.hasPrefix("\\(") && text.hasSuffix("\\)") && text.count >= 4 {
            text = String(text.dropFirst(2).dropLast(2))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The page must be transparent: Typst's default white SVG page hides
    /// the white equation glyphs used in dark mode.
    nonisolated static func documentSource(math: String, dark: Bool) -> String {
        let fill = dark ? "ffffff" : "000000"
        let clean = cleanMathPayload(math)
        return """
        #set page(width: auto, height: auto, margin: 4pt, fill: none)
        #set text(fill: rgb("\(fill)"), size: 12pt)
        $ \(clean) $
        """
    }

    /// Mirrors TypstCompiler's lookup so both always use the same binary.
    nonisolated static func resolveTypstPath() -> String? {
        if let resourcePath = Bundle.enclosingAppBundle.resourcePath {
            let bundled = "\(resourcePath)/bin/typst"
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }
        let paths = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("typst-aarch64-apple-darwin/typst").path,
            NSString(string: "~/Desktop/TypstEdit/typst-aarch64-apple-darwin/typst").expandingTildeInPath,
            "/opt/homebrew/bin/typst",
            "/usr/local/bin/typst",
            "/usr/bin/typst",
            NSString(string: "~/bin/typst").expandingTildeInPath,
            NSString(string: "~/.cargo/bin/typst").expandingTildeInPath,
        ]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
