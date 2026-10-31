import XCTest
@testable import TypstEdit

/// The `ask_question` tool: parsing what a model sends (tolerantly), and the
/// text it gets back once the user has answered, skipped, or dismissed.
@MainActor
final class AgentQuestionTests: XCTestCase {

    // MARK: - Parsing

    func testParsesAFullQuestion() {
        let arguments: [String: Any] = [
            "questions": [[
                "question": "Which structure should the report use?",
                "header": "Structure",
                "options": [
                    ["label": "Chronological (Recommended)", "detail": "Reads as a narrative."],
                    ["label": "Thematic"]
                ],
                "multiple": false
            ]]
        ]

        let questions = AIChatManager.parseQuestions(arguments)
        XCTAssertEqual(questions.count, 1)
        let question = questions[0]
        XCTAssertEqual(question.question, "Which structure should the report use?")
        XCTAssertEqual(question.header, "Structure")
        XCTAssertEqual(question.options.map(\.label), ["Chronological (Recommended)", "Thematic"])
        XCTAssertEqual(question.options[0].detail, "Reads as a narrative.")
        XCTAssertNil(question.options[1].detail)
        XCTAssertTrue(question.options[0].isRecommended)
        XCTAssertFalse(question.options[1].isRecommended)
        XCTAssertFalse(question.multiple)
    }

    func testOptionsMayBeBareStrings() {
        let arguments: [String: Any] = [
            "questions": [[
                "question": "Which?",
                "options": ["First", "  Second  ", ""]
            ]]
        ]
        let question = AIChatManager.parseQuestions(arguments)[0]
        XCTAssertEqual(question.options.map(\.label), ["First", "Second"])
    }

    func testMissingHeaderFallsBackToAGenericTitle() {
        let question = AIChatManager.parseQuestions([
            "questions": [["question": "Which?"]]
        ])[0]
        XCTAssertEqual(question.header, "Question")
        XCTAssertTrue(question.options.isEmpty)
    }

    func testQuestionsWithoutTextAreDropped() {
        let questions = AIChatManager.parseQuestions([
            "questions": [
                ["question": "  "],
                ["header": "no question text"],
                ["question": "Kept?"]
            ]
        ])
        XCTAssertEqual(questions.map(\.question), ["Kept?"])
    }

    func testMalformedArgumentsParseToNothing() {
        XCTAssertTrue(AIChatManager.parseQuestions([:]).isEmpty)
        XCTAssertTrue(AIChatManager.parseQuestions(["questions": "nope"]).isEmpty)
    }

    // MARK: - Pending state

    func testIsCompleteOnlyWhenEveryQuestionHasAnAnswer() {
        let first = AgentQuestion(question: "A?", header: "A", options: [], multiple: false)
        let second = AgentQuestion(question: "B?", header: "B", options: [], multiple: false)
        var pending = PendingQuestion(questions: [first, second], toolCallName: "ask_question")
        XCTAssertFalse(pending.isComplete)
        XCTAssertFalse(pending.hasAnyAnswer)

        pending.answers[first.id] = AgentQuestionAnswer(questionID: first.id, selections: ["yes"])
        XCTAssertFalse(pending.isComplete)
        XCTAssertTrue(pending.hasAnyAnswer)

        pending.answers[second.id] = AgentQuestionAnswer(questionID: second.id, custom: "typed")
        XCTAssertTrue(pending.isComplete)
    }

    func testWhitespaceOnlyCustomAnswerCountsAsSkipped() {
        let question = AgentQuestion(question: "A?", header: "A", options: [], multiple: false)
        let answer = AgentQuestionAnswer(questionID: question.id, custom: "   ")
        XCTAssertTrue(answer.isSkipped)
        XCTAssertNil(answer.text)
    }

    // MARK: - Result text

    func testResultTextQuotesEachAnswerAndKeepsSkippedOnes() {
        let answered = AgentQuestion(question: "Which structure?", header: "S", options: [], multiple: false)
        let skipped = AgentQuestion(question: "Which tone?", header: "T", options: [], multiple: false)

        let text = PendingQuestion.resultText(
            questions: [answered, skipped],
            answers: [answered.id: AgentQuestionAnswer(questionID: answered.id, selections: ["Thematic"])]
        )

        XCTAssertTrue(text.contains("\"Which structure?\"=\"Thematic\""), text)
        XCTAssertTrue(text.contains("\"Which tone?\"=\"Unanswered\""), text)
        XCTAssertTrue(text.hasSuffix("Continue with these answers in mind."), text)
    }

    func testMultipleSelectionsAndATypedAnswerAreJoined() {
        let question = AgentQuestion(question: "Which chapters?", header: "C", options: [], multiple: true)
        let answer = AgentQuestionAnswer(
            questionID: question.id,
            selections: ["Intro", "Results"],
            custom: "and a new appendix"
        )
        XCTAssertEqual(answer.text, "Intro, Results, and a new appendix")
    }

    func testDismissalTellsTheModelToProceedOnAnAssumption() {
        let question = AgentQuestion(question: "Which structure?", header: "S", options: [], multiple: false)
        let text = PendingQuestion.dismissedText(questions: [question])
        XCTAssertTrue(text.contains("dismissed"), text)
        XCTAssertTrue(text.contains("best judgment"), text)
        XCTAssertTrue(text.contains("do not ask again in this run"), text)
        XCTAssertTrue(text.contains("\"Which structure?\""), text)
    }

    // MARK: - Tool gating

    func testQuestionToolIsNotOfferedToTheSubagent() {
        // A subagent has no way to reach the user, so a question would hang.
        XCTAssertFalse(AIChatManager.subagentReadOnlyToolNames.contains("ask_question"))
    }

    func testQuestionToolMutatesNothingSoPlanModeKeepsIt() {
        XCTAssertFalse(AIChatManager.isPlanModeBlockedTool("agent__ask_question"))
    }

    func testQuestionToolSchemaDescribesTheAnswerShape() {
        let tool = AgentHarnessTools.askQuestionTool
        XCTAssertEqual(tool.qualifiedName, "agent__ask_question")
        XCTAssertTrue(tool.description.contains("wait for the answers"), tool.description)
        let properties = tool.inputSchema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["questions"])
    }
}
