import XCTest
@testable import TypstEdit

/// The conversation Find engine: what counts as a hit, how hits are stepped,
/// and the history picker's full-text matching.
final class ConversationSearchTests: XCTestCase {

    private func message(_ role: ChatMessage.Role, _ text: String) -> ChatMessage {
        var message = ChatMessage(role: role)
        message.text = text
        return message
    }

    // MARK: - Matching

    func testFindsEveryOccurrenceCaseInsensitively() {
        let messages = [message(.user, "Nomic nomic NOMIC embeddings")]
        let hits = ConversationSearch.matches(for: "nomic", in: messages)
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits.map(\.occurrence), [0, 1, 2])
    }

    func testIgnoresCaseAndDiacritics() {
        let messages = [message(.assistant, "The café résumé needs an accent")]
        XCTAssertEqual(ConversationSearch.matches(for: "cafe", in: messages).count, 1)
        XCTAssertEqual(ConversationSearch.matches(for: "resume", in: messages).count, 1)
    }

    func testEmptyQueryFindsNothing() {
        let messages = [message(.user, "anything")]
        XCTAssertTrue(ConversationSearch.matches(for: "", in: messages).isEmpty)
        XCTAssertTrue(ConversationSearch.matches(for: "   ", in: messages).isEmpty)
    }

    func testSingleCharacterSearchDoesNotHangOnLargeMessages() {
        // A single character in a large repeated text produces thousands of hits.
        // Must complete instantaneously in O(N) linear time without locking.
        let largeText = String(repeating: "the quick brown fox jumps over the lazy dog\n", count: 200)
        let messages = [message(.assistant, largeText)]
        let start = Date()
        let hits = ConversationSearch.matches(for: "e", in: messages, maxMatches: 500)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(hits.count, 500)
        XCTAssertLessThan(elapsed, 0.5, "searching 1 character took too long: \(elapsed)s")
    }

    func testSearchesToolOutputAndArgumentsAndReasoning() {
        var tool = ChatMessage(role: .toolCall)
        tool.toolName = "reference__read_file"
        tool.toolStatus = .succeeded
        tool.toolOutput = "the secret word is pineapple"
        tool.toolArgumentsJSON = "{\"path\":\"notes/grocery.md\"}"
        var assistant = ChatMessage(role: .assistant)
        assistant.text = "Done."
        assistant.reasoning = "I should recall the kumquat detail."

        XCTAssertEqual(ConversationSearch.matches(for: "pineapple", in: [tool]).count, 1)
        XCTAssertEqual(ConversationSearch.matches(for: "grocery", in: [tool]).count, 1)
        XCTAssertEqual(ConversationSearch.matches(for: "kumquat", in: [assistant]).count, 1)
    }

    func testHitsAreOrderedByTranscriptOrder() {
        let messages = [
            message(.user, "first mention of grape"),
            message(.assistant, "no fruit here"),
            message(.user, "second mention of grape")
        ]
        let hits = ConversationSearch.matches(for: "grape", in: messages)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.map(\.messageID), [messages[0].id, messages[2].id])
    }

    // MARK: - Stepping

    func testSteppingWrapsBothDirections() {
        let messages = [message(.user, "a target b target c")]
        let hits = ConversationSearch.matches(for: "target", in: messages)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(ConversationSearch.stepping(hits, from: 0, forward: true)?.occurrence, 1)
        XCTAssertEqual(ConversationSearch.stepping(hits, from: 1, forward: true)?.occurrence, 0, "should wrap to the first")
        XCTAssertEqual(ConversationSearch.stepping(hits, from: 0, forward: false)?.occurrence, 1, "should wrap to the last")
        XCTAssertNil(ConversationSearch.stepping([], from: 0, forward: true))
    }

    // MARK: - Snippets

    func testSnippetShowsTheHitWithContext() {
        let text = String(repeating: "padding ", count: 30) + "the citation style" + String(repeating: " tail", count: 30)
        let range = text.range(of: "citation style")!
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        let snippet = ConversationSearch.snippet(in: text, around: lower..<upper)
        XCTAssertTrue(snippet.contains("citation style"))
        XCTAssertTrue(snippet.hasPrefix("…"), "cut front should be marked")
        XCTAssertTrue(snippet.hasSuffix("…"), "cut end should be marked")
        XCTAssertLessThan(snippet.count, text.count)
    }

    func testSnippetAtStartHasNoLeadingEllipsis() {
        let text = "citation style comes first, then a long explanation that runs on and on for a while"
        let range = text.range(of: "citation")!
        let snippet = ConversationSearch.snippet(in: text, around: 0..<range.upperBound.utf16Offset(in: text), context: 4)
        XCTAssertFalse(snippet.hasPrefix("…"))
    }
}
