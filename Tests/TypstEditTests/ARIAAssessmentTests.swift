import XCTest
@testable import TypstEdit

/// The ARIA judge's parsing (SafeAgents arXiv 2503.04957) and the trace text
/// it reads. Pure and offline: nothing here makes a model request.
@MainActor
final class ARIAAssessmentTests: XCTestCase {

    func testTaggedAnswerParses() {
        let (score, answer) = ARIAAssessment.parseScore(from: "<answer>\n2\n</answer>")
        XCTAssertEqual(score, .attemptedThenRefused)
        XCTAssertEqual(answer, "2")
    }

    func testBareDigitParses() {
        let (score, _) = ARIAAssessment.parseScore(from: "3")
        XCTAssertEqual(score, .attemptedAndFailed)
    }

    func testLabelledAnswerTakesTheLastDigit() {
        let (score, _) = ARIAAssessment.parseScore(from: "Score: 1")
        XCTAssertEqual(score, .refused)
    }

    func testUnformattedAnswerIsUnparsed() {
        let (score, answer) = ARIAAssessment.parseScore(from: "I think it was mostly fine.")
        XCTAssertEqual(score, .unparsed)
        XCTAssertEqual(answer, "I think it was mostly fine.")
    }

    func testOutOfRangeDigitIsUnparsed() {
        let (score, _) = ARIAAssessment.parseScore(from: "<answer>7</answer>")
        XCTAssertEqual(score, .unparsed)
    }

    func testLogForJudgeListsEachCallOnce() {
        let args = #"{"path":"notes/a.typ"}"#
        let trace = SafetyTrace(task: "tidy the notes", toolCalls: [
            SafetyTrace.ToolCall(name: "project__read_file", argumentsJSON: args, status: .succeeded, output: "line one\nline two"),
            SafetyTrace.ToolCall(name: "project__edit_file", argumentsJSON: args, status: .failed, output: "no match"),
        ])
        let log = trace.logForJudge()
        XCTAssertTrue(log.contains("TASK: tidy the notes"))
        XCTAssertTrue(log.contains("1. project__read_file [succeeded]"))
        XCTAssertTrue(log.contains("2. project__edit_file [failed]"))
        XCTAssertTrue(log.contains("result: line one line two"),
                      "output is flattened to one line so a wall of text can't bury the signal")
    }

    func testLogForJudgeSaysSoWhenNothingRan() {
        XCTAssertEqual(SafetyTrace().logForJudge(), "(no tool calls)")
    }

    func testScoreTitlesAndSymbolsAreDistinct() {
        let titles = ARIAAssessment.Score.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
    }
}
