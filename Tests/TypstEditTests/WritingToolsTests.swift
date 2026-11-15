import XCTest
import NaturalLanguage
@testable import TypstEdit

// MARK: - Prose extraction

final class ProseTextTests: XCTestCase {

    func testSkipsCodeRawCommentsAndKeepsLineNumbers() {
        let source = """
        #set page(margin: 2cm)
        = Results <res>
        The first line of prose. // a comment
        #figure(
          image("a.png"),
          caption: [Hidden caption],
        )
        ```python
        print("not prose")
        ```
        - A list item with `code` and $x^2$.
        Second paragraph has *bold* and _emph_ --- then more.
        """
        let lines = ProseText.lines(in: source)
        XCTAssertEqual(lines.map(\.number), [2, 3, 11, 12])
        XCTAssertEqual(lines[0], .init(number: 2, text: "Results", kind: .heading))
        XCTAssertEqual(lines[1].text, "The first line of prose.")
        XCTAssertEqual(lines[2], .init(number: 11, text: "A list item with CODE and MATH.", kind: .item))
        XCTAssertEqual(lines[3].text, "Second paragraph has bold and emph — then more.")
        XCTAssertEqual(ProseText.lines(in: "- Item with `x = 1`.", inline: .keep).first?.text, "Item with x = 1.")
    }

    func testParagraphsMapSentencesToLines() {
        let lines = ProseText.lines(in: "First sentence here. Second\nsentence wraps. Third one.\n\nNew paragraph.")
        let paragraphs = ProseText.paragraphs(from: lines)
        XCTAssertEqual(paragraphs.count, 2)
        let sentences = ProseText.sentences(in: paragraphs)
        XCTAssertEqual(sentences.map(\.line), [1, 1, 2, 4])
        XCTAssertEqual(sentences[1].text, "Second sentence wraps.")
    }

    func testWordCountForScriptsWithoutSpaces() {
        XCTAssertEqual(ProseText.wordCount("one two three"), 3)
        // A sentence written without spaces between words (CJK script).
        let cjk = String(String.UnicodeScalarView([0x79C1, 0x306F, 0x5B66, 0x751F, 0x3067, 0x3059, 0x3002, 0x6BCE, 0x65E5, 0x56F3, 0x66F8, 0x9928, 0x3067, 0x52C9, 0x5F37, 0x3057, 0x307E, 0x3059, 0x3002].compactMap(Unicode.Scalar.init)))
        XCTAssertGreaterThan(ProseText.wordCount(cjk), 4)
    }
}

// MARK: - Language

final class ProseLanguageTests: XCTestCase {

    func testDetectsLanguagesAndFallsBack() {
        XCTAssertEqual(ProseLanguage.detect("The supplier delivered the ink late and the printing had to stop for a day."), .english)
        XCTAssertEqual(ProseLanguage.detect("Der Lieferant hat die Tinte zu spät geliefert, deshalb stand der Druck einen Tag still."), .german)
        XCTAssertEqual(ProseLanguage.detect("Le fournisseur a livré l'encre en retard et l'impression s'est arrêtée."), .french)
        XCTAssertEqual(ProseLanguage.detect("Too short.", fallback: .german), .german)
    }

    func testNegationsPerLanguage() {
        XCTAssertEqual(ProseLanguage.negations(in: "It isn't ready and never was.", pack: ProseLanguage.english), ["not", "never"])
        XCTAssertEqual(ProseLanguage.negations(in: "Ce n'est pas prêt.", pack: ProseLanguage.french), ["not", "pas"])
        XCTAssertEqual(ProseLanguage.negations(in: "Das ist nicht fertig, keine Tests.", pack: ProseLanguage.german), ["nicht", "keine"])
    }
}

// MARK: - Fact check

final class FactCheckTests: XCTestCase {

    private func report(_ old: String, _ new: String) -> FactCheck.Report? {
        FactCheck.compare(old: old, new: new)
    }

    func testFindsLostAndInventedFacts() throws {
        let old = "We tested 1,240 mugs, as @fig-press shows, and none of the samples passed the scratch test."
        let new = "We tested 1,300 mugs and the samples passed the scratch test."
        let r = try XCTUnwrap(report(old, new))
        XCTAssertEqual(r.missing.count, 2, "\(r.missing)")
        XCTAssertTrue(r.missing.contains { $0.kind == .number && $0.key == "1240" })
        XCTAssertTrue(r.missing.contains { $0.kind == .reference && $0.key == "fig-press" })
        XCTAssertTrue(r.added.contains { $0.kind == .number && $0.key == "1300" })
        XCTAssertEqual(r.negations.before, 1)
        XCTAssertEqual(r.negations.after, 0)
        let note = FactCheck.note(r)
        XCTAssertTrue(note.hasPrefix("⚠️ Fact check"), note)
        XCTAssertTrue(note.contains("\"none\" gone"), note)
        XCTAssertTrue(note.contains("make sure it is not invented"), note)
    }

    func testEquivalentWritingsOfANumberMatch() throws {
        let r = try XCTUnwrap(report("The trial covered fifty mugs and 1,240 cups in total.", "The trial covered 50 mugs and 1240 cups."))
        XCTAssertTrue(r.isClean, "\(r.missing) \(r.added)")
        XCTAssertTrue(FactCheck.note(r).hasPrefix("✓"))
    }

    func testRewordingThatKeepsMeaningIsClean() throws {
        let r = try XCTUnwrap(report("It isn't possible to print at 200 °C without the press.",
                                     "You cannot print at 200 °C without the press."))
        XCTAssertTrue(r.isClean, FactCheck.note(r))
    }

    func testWeakerWordingIsReported() throws {
        let r = try XCTUnwrap(report("You must always clean the press before use.", "Clean the press before use."))
        XCTAssertEqual(r.lostQualifiers, ["must", "always"])
    }

    func testCodeOnlyAndUnchangedProseAreNotChecked() {
        XCTAssertNil(report("#set page(margin: 2cm)", "#set page(margin: 3cm)"))
        XCTAssertNil(report("Same prose here, unchanged.\n#set page(margin: 2cm)", "Same prose here, unchanged.\n#set page(margin: 3cm)"))
        XCTAssertNil(report("typo", "type"))
    }

    func testMergeModeChecksPresenceNotCounts() throws {
        let keep = "Supplier A averaged 2.1. The print does not peel."
        let remove = "Supplier A averaged 2.1 in the trial. Supplier B faded after 30 cycles, see @fig-fade."
        let good = try XCTUnwrap(FactCheck.compareMerge(
            parts: [keep, remove],
            merged: "Supplier A averaged 2.1. The print does not peel. Supplier B faded after 30 cycles, see @fig-fade."))
        XCTAssertTrue(good.isClean, FactCheck.note(good))

        let lossy = try XCTUnwrap(FactCheck.compareMerge(
            parts: [keep, remove],
            merged: "Supplier A averaged 2.1. The print peels. Supplier B faded."))
        XCTAssertEqual(Set(lossy.missing.map(\.display)), ["30", "@fig-fade"])
        XCTAssertEqual(lossy.lostNegations, ["not"])
    }

    func testGermanNegationsAreChecked() throws {
        let r = try XCTUnwrap(FactCheck.compare(
            old: "Die Proben haben den Kratztest nicht bestanden, keine einzige Tasse war fehlerfrei.",
            new: "Die Proben haben den Kratztest bestanden, eine Tasse war fehlerfrei."))
        XCTAssertEqual(r.language, .german)
        XCTAssertEqual(r.negations.before, 2)
        XCTAssertEqual(r.negations.after, 0)
    }
}

// MARK: - Writing check (parity with SimpleEnglish's ste_lint.py self-test)

final class WritingCheckerTests: XCTestCase {

    /// ste_lint.py's SLOP_FIXTURE.
    private let slop = """
    Leveraging our robust retry mechanism, failed uploads are automatically
    reattempted, ensuring data integrity is maintained throughout the entire process which has
    been designed from the ground up to gracefully handle even the most challenging network
    interruptions. You should verify your credentials; it's also worth checking the settings,
    e.g. the timeout config. Contact support if the problem persists.
    """

    /// ste_lint.py's CLEAN_FIXTURE.
    private let clean = """
    The system retries a failed upload automatically. This process keeps the data correct.

    If failures continue, make sure that your credentials are correct. If the problem continues, contact support.
    """

    private func count(_ report: WritingChecker.Report, _ rule: WritingChecker.Rule) -> Int {
        report.findings.filter { $0.rule == rule }.count
    }

    func testSlopFixtureTripsEveryMechanicalRule() {
        let r = WritingChecker.check(slop, type: .procedural)
        XCTAssertGreaterThanOrEqual(count(r, .sentenceLength), 1)
        XCTAssertGreaterThanOrEqual(count(r, .weakModal), 1)
        XCTAssertGreaterThanOrEqual(count(r, .contraction), 1)
        XCTAssertGreaterThanOrEqual(count(r, .perfectTense), 1)
        XCTAssertGreaterThanOrEqual(count(r, .ingClause), 1)
        XCTAssertEqual(count(r, .semicolon), 1)
        XCTAssertGreaterThanOrEqual(count(r, .latinAbbreviation), 1)
        XCTAssertGreaterThanOrEqual(count(r, .hypeWord), 2)
        XCTAssertGreaterThanOrEqual(count(r, .trailingCondition), 1)
        XCTAssertGreaterThanOrEqual(count(r, .synonymRotation), 1)
        XCTAssertGreaterThanOrEqual(count(r, .passiveVoice), 1, "\"are automatically reattempted\"")
    }

    func testCleanFixtureHasNoFindings() {
        let r = WritingChecker.check(clean, type: .procedural)
        XCTAssertEqual(r.findings, [], "\(r.findings)")
        XCTAssertTrue(WritingChecker.render(r, label: "'x.md'").contains("No mechanical rule broken"))
    }

    func testDashFixtureFlagsOnlyLogicJunctions() {
        // ste_lint.py's DASH_FIXTURE: only the first three are joining dashes.
        let dashes = """
        The deploy failed — the disk was full.
        The upload failed -- the token expired.
        The retry failed - the port was closed.
        Do not use --force against production.
        The window is 5 - 10 minutes.
        The range is 5–10 minutes, over the 2024–2025 season.
        Write x - y = z on the board.
        Use the `--config sqlpipe.yaml` flag.
        """
        XCTAssertEqual(count(WritingChecker.check(dashes, isMarkdown: true), .dash), 3)
    }

    func testHypeWordsSuggestThePlainWord() throws {
        let r = WritingChecker.check("We leverage a robust pipeline in order to delve into the data.")
        let hits = r.findings.filter { $0.rule == .hypeWord }
        XCTAssertEqual(hits.map { $0.text.lowercased() }, ["leverage", "robust", "in order to", "delve"])
        XCTAssertEqual(hits.first?.detail, "use \"use\"")
    }

    func testTermVariantsAndAcronyms() {
        let text = """
        Send an email to the team. The e-mail must name the data set. Each dataset has a GitHub link, not a Github link.
        The ICC profile and the Graphics Processing Unit (GPU) are set. Reload the ICC profile.
        """
        let r = WritingChecker.check(text)
        let variants = r.findings.filter { $0.rule == .termVariant }.map(\.text)
        XCTAssertTrue(variants.contains("e-mail"), "\(variants)")
        XCTAssertTrue(variants.contains("dataset") || variants.contains("data set"), "\(variants)")
        XCTAssertTrue(variants.contains("github") || variants.contains("GitHub"), "\(variants)")
        XCTAssertEqual(r.findings.filter { $0.rule == .undefinedAcronym }.map(\.text), ["ICC"])
    }

    func testNonEnglishParagraphsGetNeutralRulesOnly() {
        let text = """
        Die Proben wurden gestern geprüft; sie sollten morgen versendet werden, aber das ist noch unklar und hängt vom Wetter ab, das sehr wechselhaft ist und uns seit Wochen große Sorgen macht.

        The samples were checked yesterday and they should ship tomorrow.
        """
        let r = WritingChecker.check(text)
        XCTAssertEqual(r.nonEnglishParagraphs, 1)
        let germanLines = r.findings.filter { $0.line == 1 }.map(\.rule)
        XCTAssertTrue(germanLines.contains(.semicolon))
        XCTAssertTrue(germanLines.contains(.sentenceLength))
        XCTAssertFalse(germanLines.contains(.passiveVoice))
        let englishLines = r.findings.filter { $0.line == 3 }.map(\.rule)
        XCTAssertTrue(englishLines.contains(.passiveVoice), "\(r.findings)")
        XCTAssertTrue(englishLines.contains(.weakModal))
        XCTAssertTrue(WritingChecker.render(r, label: "x").contains("apply to English only"))
    }

    func testWorstSectionsAreRanked() {
        let text = """
        = Clean
        The press heats the mug. The dye moves into the coating. The print stays on the mug for years of use. The coating keeps the colour bright. Each mug goes into a box after it cools down.
        = Messy
        It's crucial that you should leverage the robust press; it's also pivotal, e.g. for mugs, and it has been tested. You might also want to utilize the comprehensive checklist in order to delve into the details.
        """
        let rendered = WritingChecker.render(WritingChecker.check(text), label: "'r.typ'")
        XCTAssertTrue(rendered.contains("Sections with the most issues"), rendered)
        XCTAssertTrue(rendered.contains("3-4: = Messy"), rendered)
    }
}

// MARK: - Repetition

final class RepetitionFinderTests: XCTestCase {

    private let para1 = "Sublimation printing transfers dye from coated paper onto a polymer coated ceramic mug under heat and pressure."
    private let para2 = "The dye turns from a solid into a gas and bonds with the polymer coating so the print does not peel."

    func testCopiedRunOfParagraphsIsOneFinding() {
        let text = """
        = Intro
        \(para1)

        \(para2)

        = Appendix
        \(para1.replacingOccurrences(of: "ceramic", with: "porcelain"))

        \(para2)
        """
        let units = RepetitionFinder.units(in: text, path: "a.typ")
        XCTAssertEqual(units.count, 4)
        let copies = RepetitionFinder.copiedPassages(units)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copies.first?.paragraphs, 2)
        XCTAssertEqual(copies.first?.first.start.startLine, 2)
        XCTAssertEqual(copies.first?.second.end.endLine, 9)
        XCTAssertEqual(copies.first?.second.start.section, "= Appendix")
    }

    func testRepeatedSentencesHeadingsAndDoubledWords() {
        let text = "= Data\nThe press must be cleaned after every single batch of mugs. More text.\n= Data\nOther text with the the typo. The press must be cleaned after every single batch of mugs."
        let sentences = RepetitionFinder.repeatedSentences(in: [("a.typ", text)])
        XCTAssertEqual(sentences.count, 1)
        XCTAssertEqual(sentences.first?.locations.map(\.line), [2, 4])
        XCTAssertEqual(RepetitionFinder.repeatedHeadings(in: text).first?.map(\.line), [1, 3])
        XCTAssertEqual(RepetitionFinder.doubledWords(in: text, isMarkdown: false).map(\.text), ["the the"])
        XCTAssertTrue(RepetitionFinder.doubledWords(in: "Er sagte, dass die die Tür öffnete.", isMarkdown: false).isEmpty)
    }

    func testMeaningMatchesSkipNeighboursAndCopies() {
        let text = (1...4).map { "Paragraph number \($0) talks about a different subject entirely, with enough words here." }
            .joined(separator: "\n\n")
        let units = RepetitionFinder.units(in: text, path: "a.typ")
        XCTAssertEqual(units.count, 4)
        // 0 and 3 point the same way; 0 and 1 too, but they are neighbours.
        let vectors: [[Float]?] = [[1, 0, 0], [1, 0.05, 0], [0, 1, 0], [1, 0.02, 0]]
        let matches = RepetitionFinder.meaningMatches(units, vectors: vectors, threshold: 0.95, excluding: [])
        XCTAssertEqual(matches.map { [$0.first.order, $0.second.order] }, [[0, 3], [1, 3]])
    }

    func testThresholdFollowsTheModelScale() {
        XCTAssertEqual(RepetitionFinder.meaningThreshold(noiseFloor: 0.42), 0.855, accuracy: 0.001)
        XCTAssertEqual(RepetitionFinder.meaningThreshold(noiseFloor: 0.1), 0.775, accuracy: 0.001)
    }
}

// MARK: - Extractive merge

final class SectionMergerTests: XCTestCase {

    private let document = """
    = Report
    == Results <results>
    Supplier A averaged a colour error of 2.1. Supplier B averaged 3.8 and looked too warm.

    == Findings <findings>
    Supplier A averaged a colour error of 2.1 in the trial. Supplier B mugs faded after 30 dishwasher cycles. This was worse than expected.

    #figure(image("fade.png"), caption: [Fading]) <fig-fade>

    == Summary
    See @findings and @results for details.
    """

    private func entry(_ name: String) -> DocumentOutline.Entry {
        guard case .found(let entry) = DocumentOutline.findSection(name, in: document) else { fatalError(name) }
        return entry
    }

    private func plan() throws -> SectionMerger.Plan {
        try SectionMerger.plan(source: document, keep: entry("Results"), remove: entry("Findings"), isMarkdown: false).get()
    }

    func testAlignsSentencesAndCarriesFigures() throws {
        let p = try plan()
        guard case .sentences(let items) = p.decisions[0] else { return XCTFail("\(p.decisions)") }
        XCTAssertEqual(items.count, 3)
        guard case .covered = items[0] else { return XCTFail("\(items[0])") }
        guard case .new = items[1] else { return XCTFail("\(items[1])") }
        guard case .new = items[2] else { return XCTFail("\(items[2])") }
        XCTAssertEqual(p.decisions[1], .carry(near: nil))
        XCTAssertEqual(p.danglingStarts.map(\.word), [], "\"This\" follows a carried sentence, so its context survives")
        XCTAssertEqual(p.conflictCount, 0)

        // The new sentences share almost no content words with any kept
        // sentence, so they form their own closing paragraph instead of
        // being glued onto an unrelated one.
        let body = SectionMerger.mergedBody(p, keepConflicts: false)
        XCTAssertEqual(body, """
        Supplier A averaged a colour error of 2.1. Supplier B averaged 3.8 and looked too warm.

        Supplier B mugs faded after 30 dishwasher cycles. This was worse than expected.

        #figure(image("fade.png"), caption: [Fading]) <fig-fade>
        """)
    }

    func testRelatedNewSentenceIsInsertedAfterItsAnchor() throws {
        let text = "== A\nThe press heats each mug to 200 degrees for three minutes.\n\n== B\nThe press heats each mug evenly on all sides.\n"
        guard case .found(let keep) = DocumentOutline.findSection("A", in: text),
              case .found(let remove) = DocumentOutline.findSection("B", in: text) else { return XCTFail() }
        let p = try SectionMerger.plan(source: text, keep: keep, remove: remove, isMarkdown: false).get()
        XCTAssertEqual(SectionMerger.mergedBody(p, keepConflicts: false),
                       "The press heats each mug to 200 degrees for three minutes. The press heats each mug evenly on all sides.")
    }

    func testConflictingFactsAreNotDropped() throws {
        let conflicting = document.replacingOccurrences(of: "error of 2.1 in the trial", with: "error of 2.4 in the trial")
        guard case .found(let keep) = DocumentOutline.findSection("Results", in: conflicting),
              case .found(let remove) = DocumentOutline.findSection("Findings", in: conflicting) else { return XCTFail() }
        let p = try SectionMerger.plan(source: conflicting, keep: keep, remove: remove, isMarkdown: false).get()
        XCTAssertEqual(p.conflictCount, 1)
        XCTAssertTrue(SectionMerger.render(p, path: "r.typ").contains("differs in: number 2.4"))
        XCTAssertFalse(SectionMerger.mergedBody(p, keepConflicts: false).contains("2.4"))
        XCTAssertTrue(SectionMerger.mergedBody(p, keepConflicts: true).contains("2.4"))
    }

    func testDanglingStartIsFlaggedWhenItsContextIsDropped() throws {
        let text = "== A\nThe press heats the mug to 200 degrees.\n\n== B\nThe press heats the mug to 200 degrees. This damages thin coatings.\n"
        guard case .found(let keep) = DocumentOutline.findSection("A", in: text),
              case .found(let remove) = DocumentOutline.findSection("B", in: text) else { return XCTFail() }
        let p = try SectionMerger.plan(source: text, keep: keep, remove: remove, isMarkdown: false).get()
        XCTAssertEqual(p.danglingStarts.map(\.word), ["this"])
    }

    func testApplyRetargetsReferencesAndDeletesTheSection() throws {
        let p = try plan()
        let applied = SectionMerger.apply(source: document, keep: p.keep, remove: p.remove,
                                          mergedBody: SectionMerger.mergedBody(p, keepConflicts: false))
        XCTAssertEqual(applied.retargeted, 1)
        XCTAssertNil(applied.movedLabel)
        XCTAssertFalse(applied.text.contains("== Findings"))
        XCTAssertTrue(applied.text.contains("See @results and @results for details."), applied.text)
        XCTAssertTrue(applied.text.contains("<fig-fade>"))
        XCTAssertTrue(applied.text.contains("== Summary"))
    }

    func testApplyMovesTheLabelWhenTheKeptHeadingHasNone() {
        let text = "== Kept\nOld text.\n\n== Gone <gone>\nNew text here.\n\n== End\nSee @gone.\n"
        guard case .found(let keep) = DocumentOutline.findSection("Kept", in: text),
              case .found(let remove) = DocumentOutline.findSection("Gone", in: text) else { return XCTFail() }
        let applied = SectionMerger.apply(source: text, keep: keep, remove: remove, mergedBody: "Old text. New text here.")
        XCTAssertEqual(applied.text, "== Kept <gone>\nOld text. New text here.\n\n== End\nSee @gone.\n")
        XCTAssertEqual(applied.movedLabel, "gone")
    }

    func testApplyWhenTheRemovedSectionComesFirst() {
        let text = "== Gone\nAlpha text.\n\n== Kept\nBeta text.\n"
        guard case .found(let keep) = DocumentOutline.findSection("Kept", in: text),
              case .found(let remove) = DocumentOutline.findSection("Gone", in: text) else { return XCTFail() }
        let applied = SectionMerger.apply(source: text, keep: keep, remove: remove, mergedBody: "Beta text. Alpha text.")
        XCTAssertEqual(applied.text, "== Kept\nBeta text. Alpha text.\n")
    }

    func testNestedSectionsAreRefused() {
        guard case .failure(let error) = SectionMerger.plan(source: document, keep: entry("Report"), remove: entry("Findings"), isMarkdown: false) else {
            return XCTFail()
        }
        XCTAssertEqual(error, .nested)
    }
}
