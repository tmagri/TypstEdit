import XCTest
@testable import TypstEdit

/// The Auto-proceed heuristic: which finished replies count as "work is still
/// left", and the continuation text injected when they do.
final class AIChatAutoProceedTests: XCTestCase {

    // MARK: - Unfinished replies

    func testNextStepsHeadingIsUnfinished() {
        let reply = """
        I updated the introduction and the methods section.

        ## Next steps
        - Move the appendix to the end
        - Regenerate the figures
        """
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished(reply))
    }

    func testBoldMarkdownHeadingIsUnfinished() {
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("Done with chapter 1.\n\n**Next Steps:**\n1. Chapter 2"))
    }

    func testNumberedAndBulletedHeadingsAreUnfinished() {
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("Chapters 1–3 are done.\n\n2. Remaining work\n- Chapter 4"))
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("- Still to do\n- Bibliography"))
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("### What's left\n- Peer review"))
    }

    func testPlainStatementIsUnfinished() {
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("I converted the first two tables, but I still need to convert the third one."))
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("The export step is not yet implemented."))
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("I haven't finished the bibliography yet."))
    }

    func testFinishedReplyIsNotUnfinished() {
        let reply = """
        I finished the whole request: the introduction is rewritten, the appendix moved to the end, and the document compiles cleanly.

        Let me know if you'd like me to also add a table of contents.
        """
        XCTAssertFalse(AIChatAutoProceed.looksUnfinished(reply))
    }

    func testEmptyReplyIsNotUnfinished() {
        XCTAssertFalse(AIChatAutoProceed.looksUnfinished(""))
        XCTAssertFalse(AIChatAutoProceed.looksUnfinished("   \n\n  "))
    }

    func testWordNextStepsInsideProseDoesNotCount() {
        // A heading match must be a whole line, not a phrase buried in text.
        XCTAssertFalse(AIChatAutoProceed.looksUnfinished("The document does not have a next step section, so I left it as is."))
    }

    func testDetectionLooksOnlyAtTheTail() {
        let longHistory = String(repeating: "Paragraph of finished work.\n\n", count: 1_000)
        XCTAssertFalse(AIChatAutoProceed.looksUnfinished(longHistory + "Everything is complete."))
    }

    // MARK: - Ready-for-go-ahead replies

    func testReadyWhenYouAreIsUnfinished() {
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("I've mapped out chapters 4–6. Next step when you're ready."))
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("The outline is ready. Let me know when you're ready and I'll continue."))
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("Everything else is set. Ready when you are."))
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("Say the word and I'll convert the remaining tables."))
    }

    func testReadyProseThatIsNotAHandoffStaysFinished() {
        // "ready" on its own, in ordinary prose, must not hold the run open.
        XCTAssertFalse(AIChatAutoProceed.looksUnfinished("The PDF is ready and the document compiles cleanly."))
        XCTAssertFalse(AIChatAutoProceed.looksUnfinished("All six sections are written and ready for review."))
    }

    // MARK: - Continuation text

    func testUnfinishedContinuationNamesTheRound() {
        let text = AIChatAutoProceed.continuationText(trigger: .unfinished, round: 3, maxRounds: 10)
        XCTAssertTrue(text.contains("round 3 of 10"))
        XCTAssertTrue(text.contains("Auto-proceed"))
        XCTAssertTrue(text.lowercased().contains("continue"))
    }

    func testUnlimitedRoundsOmitTheCap() {
        let text = AIChatAutoProceed.continuationText(trigger: .unfinished, round: 4, maxRounds: 0)
        XCTAssertTrue(text.contains("round 4"))
        XCTAssertFalse(text.contains("round 4 of"))
    }

    func testFailureContinuationIncludesTheErrorAndIsClipped() {
        let longError = String(repeating: "timeout ", count: 200)
        let text = AIChatAutoProceed.continuationText(trigger: .failure(longError), round: 1, maxRounds: 5)
        XCTAssertTrue(text.contains("timeout"))
        XCTAssertTrue(text.contains("…"))
        XCTAssertLessThan(text.count, 1_200)
    }

    func testTriggerFailureFlag() {
        XCTAssertTrue(AIChatAutoProceed.Trigger.failure("boom").isFailure)
        XCTAssertFalse(AIChatAutoProceed.Trigger.unfinished.isFailure)
    }
}
