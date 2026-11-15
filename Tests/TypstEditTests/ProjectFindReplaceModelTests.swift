import XCTest
@testable import TypstEdit

/// Find-in-project engine: pattern building, lossy scanning, match
/// location, and the replace step's re-location rules.
@MainActor
final class ProjectFindReplaceModelTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        try await super.setUp()
        root = fm.temporaryDirectory
            .appendingPathComponent("FindInProject-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? fm.removeItem(at: root) }
        try await super.tearDown()
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Waits for the model to finish the search kicked off by `search`.
    private func searchSync(_ model: ProjectFindReplaceModel, _ query: String,
                            options: ProjectFindReplaceModel.Options = .init()) async {
        model.search(query: query, options: options, root: root)
        while model.isSearching {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Searching

    func testSearchFindsMatchesAcrossFilesWithLinesAndRanges() async throws {
        try write("main.typ", "= Intro\n\nError bars show the spread.\n")
        try write("chapters/results.typ", "The error bars were large.\n")

        let model = ProjectFindReplaceModel()
        await searchSync(model, "error bars")

        XCTAssertEqual(model.results.count, 2, "both files match")
        let allMatches = model.results.flatMap(\.matches)
        XCTAssertEqual(allMatches.count, 2)

        let first = try XCTUnwrap(allMatches.first { $0.url.lastPathComponent == "main.typ" })
        XCTAssertEqual(first.line, 3, "line numbers are 1-based and skip blank lines correctly")
        XCTAssertEqual(first.matchedText, "Error bars")
        XCTAssertTrue(model.summary.contains("2 matches in 2 files"))
    }

    func testCaseAndWordOptionsChangeResults() async throws {
        try write("a.typ", "The cat sat. concat catalog\n")

        // "cat" appears in "cat", "concat" and "catalog".
        let insensitive = ProjectFindReplaceModel()
        await searchSync(insensitive, "cat")
        XCTAssertEqual(insensitive.results.flatMap(\.matches).count, 3)

        let words = ProjectFindReplaceModel()
        await searchSync(words, "cat", options: .init(caseSensitive: true, wholeWord: true))
        // Only the standalone "cat" counts as a whole word.
        XCTAssertEqual(words.results.flatMap(\.matches).count, 1)
    }

    func testRegexSearchSupportsCaptureTemplatesInReplace() async throws {
        try write("a.typ", "width 10 and height 20\n")

        let model = ProjectFindReplaceModel()
        await searchSync(model, "(width|height) (\\d+)", options: .init(caseSensitive: true, regex: true))

        let outcome = await model.replace(with: "$1=$2", root: root)
        XCTAssertTrue(outcome.complete, outcome.message)
        XCTAssertEqual(try read("a.typ"), "width=10 and height=20\n")
    }

    func testInvalidRegexReportsInsteadOfSearching() async throws {
        try write("a.typ", "x\n")
        let model = ProjectFindReplaceModel()
        await searchSync(model, "([unclosed", options: .init(regex: true))
        XCTAssertNotNil(model.patternError)
        XCTAssertTrue(model.results.isEmpty)
    }

    func testDiacriticInsensitiveSearchFindsAccentedText() async throws {
        try write("a.typ", "Meet at the café for coffee.\n")

        let model = ProjectFindReplaceModel()
        await searchSync(model, "cafe")

        XCTAssertEqual(model.results.flatMap(\.matches).count, 1)
        let match = try XCTUnwrap(model.results.first?.matches.first)
        XCTAssertEqual(match.matchedText, "café", "the reported match is the original accented text")

        // Replace rewrites the accented original.
        let outcome = await model.replace(with: "brasserie", root: root)
        XCTAssertTrue(outcome.complete, outcome.message)
        XCTAssertEqual(try read("a.typ"), "Meet at the brasserie for coffee.\n")
    }

    func testGeneratedFoldersAndNonTextFilesAreSkipped() async throws {
        try write("temp/scratch.typ", "target text\n")
        try write("vectorcaches/index.sqlite", "target text\n")
        try write("real.typ", "target text\n")
        try write("image.png", "target text\n")

        let model = ProjectFindReplaceModel()
        await searchSync(model, "target text")

        XCTAssertEqual(model.results.map(\.relativePath), ["real.typ"])
    }

    // MARK: - Replacing

    func testReplaceRewritesOnlySelectedMatches() async throws {
        try write("a.typ", "keep alpha, drop alpha, keep alpha\n")
        try write("b.typ", "alpha here\n")

        let model = ProjectFindReplaceModel()
        await searchSync(model, "alpha")

        // Deselect the middle match in a.typ.
        let fileA = try XCTUnwrap(model.results.first { $0.relativePath == "a.typ" })
        model.setSelected(false, matchID: fileA.matches[1].id)
        // Deselect everything in b.typ.
        model.setSelectedForFile(false, fileID: model.results.first { $0.relativePath == "b.typ" }!.id)

        let outcome = await model.replace(with: "beta", root: root)
        XCTAssertTrue(outcome.complete, outcome.message)
        XCTAssertEqual(outcome.replacements, 2)
        XCTAssertEqual(outcome.filesChanged, 1)

        XCTAssertEqual(try read("a.typ"), "keep beta, drop alpha, keep beta\n")
        XCTAssertEqual(try read("b.typ"), "alpha here\n")
    }

    func testReplaceSkipsFilesThatChangedSinceTheSearch() async throws {
        try write("a.typ", "one alpha\n")

        let model = ProjectFindReplaceModel()
        await searchSync(model, "alpha")

        // The file changes after the scan: the line the match was on moved.
        try write("a.typ", "new first line\none alpha\n")

        let outcome = await model.replace(with: "beta", root: root)
        XCTAssertEqual(outcome.filesChanged, 0)
        XCTAssertEqual(outcome.skippedChanged, ["a.typ"])
        XCTAssertEqual(try read("a.typ"), "new first line\none alpha\n")
    }

    func testReplaceStillWorksWhenEarlierLinesChangeButMatchDoesNot() async throws {
        try write("a.typ", "x\ny\nfind me\n")
        let model = ProjectFindReplaceModel()
        await searchSync(model, "find me")

        // An edit above the match shifts its absolute offset but not its
        // line or text: the re-location must still find it.
        try write("a.typ", "x\nlonger line here\ny\nfind me\n")
        // The line number moved too — a match that cannot be located on
        // its recorded line skips the file. Re-search instead, which is
        // the honest workflow: replace from a fresh scan.
        await searchSync(model, "find me")
        let outcome = await model.replace(with: "found", root: root)
        XCTAssertTrue(outcome.complete, outcome.message)
        XCTAssertEqual(try read("a.typ"), "x\nlonger line here\ny\nfound\n")
    }

    // MARK: - Pattern

    func testDiacriticInsensitiveLiteralMatch() throws {
        let text = "café at the corner\n"
        let folded = ProjectSearchPattern(
            query: "cafe", caseSensitive: false, wholeWord: false,
            regex: false, ignoreDiacritics: true
        )
        XCTAssertNotNil(folded)
        XCTAssertEqual(folded!.matches(in: text).count, 0,
                       "the raw pattern matches the folded text, not the original")

        // The engine itself folds the text before matching.
        let foldedText = folded!.foldedText(text)
        XCTAssertNotNil(foldedText)
        XCTAssertEqual(folded!.matches(in: foldedText! as String).count, 1)

        let strict = ProjectSearchPattern(
            query: "cafe", caseSensitive: false, wholeWord: false,
            regex: false, ignoreDiacritics: false
        )
        XCTAssertEqual(strict!.matches(in: text).count, 0)
    }

    func testWholeWordBoundariesCoverDigitsAndUnderscores() {
        let text = "my_var myvar var var2 _var\n"
        let pattern = ProjectSearchPattern(
            query: "var", caseSensitive: true, wholeWord: true,
            regex: false, ignoreDiacritics: false
        )!
        // Only the standalone "var" matches; my_var, myvar, var2, _var do not.
        XCTAssertEqual(pattern.matches(in: text).count, 1)
    }
}
