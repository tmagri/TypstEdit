import XCTest
@testable import TypstEdit

final class ImageCleanupScannerTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageCleanup_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The scanner only looks at extensions, so image files don't need to be
    /// decodable — a few bytes are enough to exist and have a size.
    private func makeImage(_ url: URL, bytes: Int = 16) throws {
        try Data(count: bytes).write(to: url)
    }

    private func unusedPaths(in report: ImageCleanupReport) -> Set<String> {
        Set(report.unusedImages.map { $0.url.lastPathComponent })
    }

    // MARK: - Reference extraction

    func testReferenceExtractionCoversTypstAndMarkdown() {
        let text = """
        #image("figures/a.png")
        #let x = image("b.png")
        ![alt text](c.jpg)
        ![spaces](<my pic.png>)
        """
        let refs = ImageCleanupScanner.imageReferencePaths(in: text)
        XCTAssertTrue(refs.contains("figures/a.png"))
        XCTAssertTrue(refs.contains("b.png"))
        XCTAssertTrue(refs.contains("c.jpg"))
        XCTAssertTrue(refs.contains("my pic.png"))
        XCTAssertEqual(refs.count, 4)
    }

    func testReferenceExtractionIgnoresIdentifiersAndProse() {
        let refs = ImageCleanupScanner.imageReferencePaths(in: #"myimage("nope.png") #render_image("nope2.png")"#)
        XCTAssertFalse(refs.contains("nope.png"))
        XCTAssertFalse(refs.contains("nope2.png"))
    }

    // MARK: - Scan

    func testDetectsUnusedImagesAcrossSyntaxes() throws {
        let root = try makeTempProject()
        try write(#"#image("used-typst.png")"#, to: root.appendingPathComponent("main.typ"))
        try write("# Hello\n\n![chart](used-note.png)", to: root.appendingPathComponent("page.note"))
        try write("![photo](photos/used-md.png)", to: root.appendingPathComponent("readme.md"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("photos"), withIntermediateDirectories: true)

        try makeImage(root.appendingPathComponent("used-typst.png"))
        try makeImage(root.appendingPathComponent("used-note.png"))
        try makeImage(root.appendingPathComponent("photos/used-md.png"))
        try makeImage(root.appendingPathComponent("orphan.png"))
        try makeImage(root.appendingPathComponent("photos/also-orphan.jpg"))

        let report = ImageCleanupScanner.scan(root: root)
        XCTAssertEqual(report.documentCount, 3)
        XCTAssertEqual(report.imageCount, 5)
        XCTAssertEqual(unusedPaths(in: report), ["orphan.png", "also-orphan.jpg"])
        XCTAssertEqual(report.totalUnusedBytes, 32)
    }

    func testWebAndDataReferencesDoNotMarkImagesUsed() throws {
        let root = try makeTempProject()
        try write(#"![web](https://example.com/local.png) #image("data:image/png;base64,AAAA")"#,
                  to: root.appendingPathComponent("main.typ"))
        try makeImage(root.appendingPathComponent("local.png"))

        let report = ImageCleanupScanner.scan(root: root)
        XCTAssertEqual(unusedPaths(in: report), ["local.png"])
    }

    func testSkippedFoldersAreNeverScanned() throws {
        let root = try makeTempProject()
        try write(#"#image("used.png")"#, to: root.appendingPathComponent("main.typ"))
        try makeImage(root.appendingPathComponent("used.png"))

        for folder in ["temp", "backups", "vectorcaches", "Archive"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            try makeImage(root.appendingPathComponent("\(folder)/hidden.png"))
        }

        let report = ImageCleanupScanner.scan(root: root)
        XCTAssertEqual(report.imageCount, 1)
        XCTAssertTrue(report.unusedImages.isEmpty)
    }

    func testDocumentRelativeAndSubfolderReferencesAreHonored() throws {
        let root = try makeTempProject()
        let chapters = root.appendingPathComponent("chapters")
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        // Root-relative reference (Typst compiles with --root <project>).
        try write(#"#image("assets/root-relative.png")"#, to: root.appendingPathComponent("main.typ"))
        // Document-relative reference with a ../ escape.
        try write(#"#image("../assets/doc-relative.png")"#, to: chapters.appendingPathComponent("intro.typ"))

        try makeImage(assets.appendingPathComponent("root-relative.png"))
        try makeImage(assets.appendingPathComponent("doc-relative.png"))
        try makeImage(assets.appendingPathComponent("orphan.png"))

        let report = ImageCleanupScanner.scan(root: root)
        XCTAssertEqual(unusedPaths(in: report), ["orphan.png"])
    }

    func testBareFilenameMatchKeepsImageUsed() throws {
        let root = try makeTempProject()
        let nested = root.appendingPathComponent("deep/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        // The document says "fig.png" without a folder — an image of that name
        // anywhere in the project stays safe even if the path wouldn't resolve.
        try write(#"#image("fig.png")"#, to: root.appendingPathComponent("main.typ"))
        try makeImage(nested.appendingPathComponent("fig.png"))

        let report = ImageCleanupScanner.scan(root: root)
        XCTAssertTrue(report.unusedImages.isEmpty)
    }

    func testPercentEncodedMarkdownReferenceIsDecoded() throws {
        let root = try makeTempProject()
        try write("![shot](my%20photo.png)", to: root.appendingPathComponent("main.md"))
        try makeImage(root.appendingPathComponent("my photo.png"))

        let report = ImageCleanupScanner.scan(root: root)
        XCTAssertTrue(report.unusedImages.isEmpty)
    }

    // MARK: - Actions

    func testArchivePreservesRelativeStructure() throws {
        let root = try makeTempProject()
        let figures = root.appendingPathComponent("figures/charts")
        try FileManager.default.createDirectory(at: figures, withIntermediateDirectories: true)
        try makeImage(figures.appendingPathComponent("a.png"))
        let image = UnusedImage(url: figures.appendingPathComponent("a.png"), fileSize: 16)

        let moved = ImageCleanupScanner.archive([image], into: root)

        XCTAssertEqual(moved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.url.path))
        let archived = ImageCleanupScanner.archiveDirectory(for: root).appendingPathComponent("figures/charts/a.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
    }

    func testTrashRemovesImageFromProject() throws {
        let root = try makeTempProject()
        let url = root.appendingPathComponent("gone.png")
        try makeImage(url)
        let image = UnusedImage(url: url, fileSize: 16)

        let trashed = ImageCleanupScanner.trash([image])

        XCTAssertEqual(trashed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
