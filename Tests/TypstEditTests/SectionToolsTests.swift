import XCTest
@testable import TypstEdit

// MARK: - Section lookup by heading name

final class SectionLookupTests: XCTestCase {

    private let document = """
    = Methods <methods>
    Intro to methods.
    == Data
    Method data.
    == Analysis
    Steps.
    = Results
    == Data
    Result data.
    = Appendix: “Raw” tables
    Tables.
    """

    private func found(_ query: String) -> DocumentOutline.Entry? {
        if case .found(let entry) = DocumentOutline.findSection(query, in: document) { return entry }
        return nil
    }

    func testTitleAndHeadingFormsMatch() {
        XCTAssertEqual(found("Analysis")?.line, 5)
        XCTAssertEqual(found("analysis")?.line, 5)
        XCTAssertEqual(found("== Analysis")?.line, 5)
        XCTAssertEqual(found("Results")?.endLine, 9)
    }

    func testLabelAndTrailingLabelAreHandled() {
        XCTAssertEqual(found("<methods>")?.line, 1)
        XCTAssertEqual(found("Methods")?.line, 1, "the trailing <methods> label is not part of the title")
    }

    func testTypographicQuotesFold() {
        XCTAssertEqual(found("Appendix: \"Raw\" tables")?.line, 10)
    }

    func testPrefixMatchWhenUnique() {
        XCTAssertEqual(found("Appendix")?.line, 10)
    }

    func testDuplicateNamesAreAmbiguousUntilParentIsGiven() {
        guard case .ambiguous(let entries) = DocumentOutline.findSection("Data", in: document) else {
            return XCTFail("expected ambiguous")
        }
        XCTAssertEqual(entries.map(\.line), [3, 8])
        XCTAssertEqual(found("Results > Data")?.line, 8)
        XCTAssertEqual(found("Methods > Data")?.line, 3)
    }

    func testHeadingLevelNarrowsTheMatch() {
        XCTAssertNil(found("= Data"), "no level-1 heading is called Data")
    }

    func testNotFoundSuggestsClosestHeadings() {
        guard case .notFound(let suggestions) = DocumentOutline.findSection("Raw data tables", in: document) else {
            return XCTFail("expected notFound")
        }
        XCTAssertFalse(suggestions.isEmpty)
        let message: String
        switch DocumentOutline.resolveSection("Raw data tables", in: document, path: "doc.typ") {
        case .success: return XCTFail("expected failure")
        case .failure(let error): message = error.message
        }
        XCTAssertTrue(message.contains("No heading in 'doc.typ'"), message)
        XCTAssertTrue(message.contains("10-11: = Appendix"), message)
    }

    func testAmbiguousMessageExplainsHowToPick() {
        guard case .failure(let error) = DocumentOutline.resolveSection("Data", in: document, path: "doc.typ") else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.message.contains("3-4: == Data"), error.message)
        XCTAssertTrue(error.message.contains("8-9: == Data"), error.message)
        XCTAssertTrue(error.message.contains("Parent > Data"), error.message)
    }
}

// MARK: - Reference checking

final class ReferenceCheckerTests: XCTestCase {

    private func report(_ files: [String: String], bib: String? = nil) -> ReferenceChecker.Report {
        var report = ReferenceChecker.Report()
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            ReferenceChecker.scanTypst(text, path: path, into: &report)
        }
        if let bib { report.bibliographyKeys = ReferenceChecker.bibliographyKeys(in: bib, isYAML: false) }
        return report
    }

    func testFindsUndefinedReferenceWithSuggestion() {
        let text = """
        #figure(rect(), caption: [Overview]) <fig-overview>
        As @fig-overveiw shows, and see @fig-overview.
        """
        let r = report(["main.typ": text])
        XCTAssertEqual(r.labels["fig-overview"]?.count, 1)
        XCTAssertEqual(r.references["fig-overview"]?.count, 1, "the sentence-ending dot is not part of the name")
        let rendered = ReferenceChecker.render(r, scopeLabel: "the project")
        XCTAssertTrue(rendered.contains("@fig-overveiw at main.typ:2 — did you mean @fig-overview?"), rendered)
    }

    func testIgnoresEmailsPackagesCommentsAndRaw() {
        let text = """
        #import "@preview/cetz:0.2.0": canvas
        Mail me at someone@example.com.
        // @commented-out
        /* @block
        still @block */
        `@inline-raw`
        ```
        @fenced
        ```
        See https://example.com/@user for more.
        """
        let r = report(["main.typ": text])
        XCTAssertTrue(r.references.isEmpty, "\(r.references.keys)")
    }

    func testDuplicateAndUnusedLabels() {
        let r = report([
            "a.typ": "= Intro <intro>\nSee @intro.",
            "b.typ": "= Again <intro>\n= Lonely <lonely>",
        ])
        let rendered = ReferenceChecker.render(r, scopeLabel: "the project")
        XCTAssertTrue(rendered.contains("Duplicate labels (1)"), rendered)
        XCTAssertTrue(rendered.contains("<intro> at a.typ:1, b.typ:1"), rendered)
        XCTAssertTrue(rendered.contains("Unused labels (1)"), rendered)
        XCTAssertTrue(rendered.contains("<lonely> at b.typ:2"), rendered)
    }

    func testRefAndLinkCallsAreUsesNotDefinitions() {
        let r = report(["main.typ": "= Part <part>\n#ref(<part>) and #link(<part>)[here]"])
        XCTAssertEqual(r.labels["part"]?.count, 1)
        XCTAssertEqual(r.references["part"]?.count, 2)
    }

    func testCitationsResolveAgainstBibliography() {
        let bib = """
        @article{knuth1984, title = {Literate Programming}}
        @book{lamport94,
          title = {LaTeX}}
        @comment{ignored, x}
        """
        let r = report(["main.typ": "As @knuth1984 argued.\n#bibliography(\"refs.bib\")"], bib: bib)
        XCTAssertEqual(r.bibliographyKeys, ["knuth1984", "lamport94"])
        XCTAssertEqual(r.bibliographyFiles.first?.path, "refs.bib")
        let rendered = ReferenceChecker.render(r, scopeLabel: "the project")
        XCTAssertFalse(rendered.contains("Undefined references"), rendered)
        XCTAssertTrue(rendered.contains("never cited (1)"), rendered)
        XCTAssertTrue(rendered.contains("lamport94"), rendered)
    }

    func testHayagrivaKeys() {
        let yaml = "smith2020:\n  type: article\n  title: Things\njones:\n  type: book\n"
        XCTAssertEqual(ReferenceChecker.bibliographyKeys(in: yaml, isYAML: true), ["smith2020", "jones"])
    }

    func testCleanDocumentSaysSo() {
        let r = report(["main.typ": "= A <a>\nSee @a."])
        XCTAssertTrue(ReferenceChecker.render(r, scopeLabel: "x").contains("No undefined references"))
    }

    func testEditDistance() {
        XCTAssertEqual(ReferenceChecker.editDistance("kitten", "sitting", cap: 10), 3)
        XCTAssertEqual(ReferenceChecker.editDistance("same", "same", cap: 10), 0)
        XCTAssertEqual(ReferenceChecker.editDistance("", "abc", cap: 10), 3)
        XCTAssertEqual(ReferenceChecker.editDistance("short", "a-much-longer-name", cap: 3), 3)
    }
}

// MARK: - Section ranking

final class SectionFinderTests: XCTestCase {

    private let text = """
    = Introduction
    This report studies coffee mug printing.
    = Error analysis
    We compute error bars from repeated measurements.
    = Colour management
    Profiles keep printed colours consistent; measurement errors are rare.
    """

    func testKeywordRankingPrefersHeadingMatches() {
        let candidates = SectionFinder.candidates(in: text, path: "r.typ")
        XCTAssertEqual(candidates.count, 3)
        let hits = SectionFinder.rank(query: "how are errors measured", candidates: candidates, limit: 5)
        XCTAssertEqual(hits.first?.candidate.title, "Error analysis")
        XCTAssertFalse(hits.contains { $0.candidate.title == "Introduction" })
    }

    func testMeaningScoreBlendsIn() {
        let candidates = SectionFinder.candidates(in: text, path: "r.typ")
        // A fake embedding space where only the colour section is close.
        let vectors: [[Float]?] = [[1, 0], [1, 0], [0, 1]]
        let hits = SectionFinder.rank(query: "printer profiles", candidates: candidates,
                                      queryVector: [0, 1], vectors: vectors, limit: 5)
        XCTAssertEqual(hits.first?.candidate.title, "Colour management")
        XCTAssertNotNil(hits.first?.meaningScore)
    }

    func testNoMatchRendersAdvice() {
        let rendered = SectionFinder.render([], query: "zebras", sectionCount: 3, fileCount: 1, method: .keywordsOnly)
        XCTAssertTrue(rendered.contains("No section matches"), rendered)
    }

    func testMeaningIsRescaledWithinTheSearch() {
        // Two models with very different cosine ranges give the same order.
        let candidates = SectionFinder.candidates(in: text, path: "r.typ")
        for offset: Float in [0, 5] {
            let vectors: [[Float]?] = [[1, offset], [1, offset + 0.2], [1, offset + 1]]
            let hits = SectionFinder.rank(query: "zzz", candidates: candidates,
                                          queryVector: [1, offset + 1], vectors: vectors, limit: 3)
            XCTAssertEqual(hits.first?.candidate.title, "Colour management")
            XCTAssertEqual(hits.first?.meaningScore ?? 0, 1, accuracy: 1e-6)
        }
    }

    func testMeaningOnlyHitsMustStandOut() {
        let candidates = SectionFinder.candidates(in: text, path: "r.typ")
        // All equally (un)related: nothing stands out, nothing is returned.
        let vectors: [[Float]?] = [[1, 0], [1, 0], [1, 0]]
        XCTAssertTrue(SectionFinder.rank(query: "zzz", candidates: candidates,
                                         queryVector: [0, 1], vectors: vectors, limit: 3).isEmpty)
    }

    func testTermsDropStopwordsAndStem() {
        XCTAssertEqual(SectionFinder.terms("The errors of measuring"), ["error", "measur"])
    }
}
