import XCTest
@testable import TypstEdit

/// Image attachments in AI Chat: the pure sizing/fitting rules, how a turn's
/// attachments survive into the request, and the transcript shapes that carry
/// them (folding, titles, persistence, retention for follow-ups). The picker,
/// paste and drop paths are AppKit-bound and exercised by the app itself.
@MainActor
final class ChatImageTests: XCTestCase {

    private func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    private func attachment(width: Int = 40, height: Int = 30, bytes: Int = 0) -> ChatImage {
        // `bytes` pads the base64, which is what the size budget measures.
        let padding = bytes > 0 ? String(repeating: "A", count: bytes) : ""
        return ChatImage(mediaType: "image/png", base64: "AAAA" + padding, width: width, height: height)
    }

    // MARK: - Encoding

    func testImageIsDownsizedAndReencoded() throws {
        let image = try ChatImageLoader.make(from: png(width: 4_000, height: 3_000))
        XCTAssertLessThanOrEqual(max(image.width, image.height), ChatImageLoader.maxLongEdge)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertFalse(image.base64.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: image.base64))
    }

    func testDataURLCarriesTheMediaType() {
        let image = attachment()
        XCTAssertTrue(image.dataURL.hasPrefix("data:image/png;base64,"))
    }

    func testUnreadableDataThrows() {
        XCTAssertThrowsError(try ChatImageLoader.make(from: Data("not an image".utf8)))
    }

    // MARK: - Limits

    func testFitKeepsTheCountLimit() {
        let images = (0..<9).map { _ in attachment() }
        let fit = ChatImageLoader.fit(images)
        XCTAssertEqual(fit.accepted.count, ChatImageLoader.maxPerMessage)
        XCTAssertEqual(fit.droppedForCount, 9 - ChatImageLoader.maxPerMessage)
        XCTAssertEqual(fit.droppedForSize, 0)
    }

    func testFitKeepsTheByteBudget() {
        // Each image is exactly a quarter of the budget's worth of base64, so
        // only four fit — the padding is what the budget measures.
        let budget = 4_000
        let images = (0..<6).map { _ in attachment(bytes: budget / 4 - 4) }
        let fit = ChatImageLoader.fit(images, limit: 6, byteBudget: budget)
        XCTAssertEqual(fit.accepted.count, 4)
        XCTAssertEqual(fit.droppedForSize, 2)
    }

    func testFitOfNothingIsEmpty() {
        XCTAssertTrue(ChatImageLoader.fit([]).accepted.isEmpty)
    }

    // MARK: - Prompt Shapes

    func testFoldedTextMarksAttachments() {
        let user = ChatMessage(role: .user, text: "look", images: [attachment(), attachment()])
        XCTAssertEqual(AIChatManager.foldedText(for: user), "[2 images attached]\nlook")
    }

    func testFoldedTextCoversAnImageOnlyTurn() {
        let user = ChatMessage(role: .user, text: "", images: [attachment()])
        XCTAssertEqual(AIChatManager.foldedText(for: user), "[image attached]")
    }

    func testFoldedTextLeavesPlainTurnsAlone() {
        XCTAssertEqual(AIChatManager.foldedText(for: ChatMessage(role: .user, text: "hi")), "hi")
    }

    // MARK: - Retention

    func testRetainedImagesComeFromRecentTurns() {
        let messages = [
            ChatMessage(role: .user, text: "old", images: [attachment()]),
            ChatMessage(role: .assistant, text: "ok"),
            ChatMessage(role: .user, text: "newer", images: [attachment()]),
            ChatMessage(role: .assistant, text: "ok"),
            ChatMessage(role: .user, text: "follow up"),
        ]
        let retained = AIChatManager.retainedImages(in: messages)
        // Both of the last two image turns, and the text-only turn being sent
        // is not counted against the bound.
        XCTAssertEqual(retained.count, 2)
    }

    func testRetainedImagesAreEmptyForTheFirstTurn() {
        let messages = [ChatMessage(role: .user, text: "look", images: [attachment()])]
        XCTAssertTrue(AIChatManager.retainedImages(in: messages).isEmpty,
                      "the turn being sent is its own attachments, not a retained one")
    }

    func testRetainedImagesStopAtTheBound() {
        let messages = (0..<5).map { index in
            ChatMessage(role: .user, text: "turn \(index)", images: [attachment()])
        }
        let retained = AIChatManager.retainedImages(in: messages, maxTurns: 2)
        XCTAssertEqual(retained.count, 2, "only the two most recent image turns ride along")
    }

    func testRetainedImagesSkipCompactedTurns() {
        var old = ChatMessage(role: .user, text: "old", images: [attachment()])
        old.isCompacted = true
        let messages = [
            old,
            ChatMessage(role: .user, text: "current"),
        ]
        XCTAssertTrue(AIChatManager.retainedImages(in: messages).isEmpty)
    }

    func testRetainedImagesIgnoreToolRowsAndSummaries() {
        var summary = ChatMessage(role: .assistant, text: "summary", images: [attachment()])
        summary.isSummary = true
        let messages = [
            summary,
            ChatMessage(role: .toolCall, text: "", images: [attachment()]),
            ChatMessage(role: .user, text: "current"),
        ]
        XCTAssertTrue(AIChatManager.retainedImages(in: messages).isEmpty)
    }

    // MARK: - Titles

    func testFallbackTitleFromAnImageOnlyMessage() {
        let messages = [ChatMessage(role: .user, text: "", images: [attachment()])]
        XCTAssertEqual(AIChatSessionStore.fallbackTitle(from: messages), "Image chat")
    }

    func testFallbackTitlePrefersText() {
        let messages = [ChatMessage(role: .user, text: "fix the table", images: [attachment()])]
        XCTAssertEqual(AIChatSessionStore.fallbackTitle(from: messages), "fix the table")
    }

    // MARK: - Persistence

    func testImagesSurviveARecordRoundTrip() throws {
        let image = attachment(width: 320, height: 200)
        let record = ChatSessionRecord(
            id: UUID(),
            title: "t",
            titleIsAutoGenerated: false,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            messages: [ChatMessage(role: .user, text: "look", images: [image])]
        )
        let data = try AIChatSessionStore.encodeRecord(record)
        let decoded = AIChatSessionStore.decodeRecord(from: data)
        XCTAssertEqual(decoded?.messages.first?.attachments.count, 1)
        XCTAssertEqual(decoded?.messages.first?.attachments.first?.width, 320)
    }

    func testOlderTranscriptWithoutImagesStillDecodes() throws {
        // A conversation saved before attachments existed has no `images` key
        // in its messages. Encoding a plain message produces exactly that
        // shape (the optional is omitted), so decoding it must give "no
        // attachments" rather than failing the whole transcript.
        let message = ChatMessage(role: .user, text: "hi")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(message)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("images"), "nil attachments must not be written")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChatMessage.self, from: data)
        XCTAssertFalse(decoded.hasImages)
        XCTAssertTrue(decoded.attachments.isEmpty)
    }

    // MARK: - Queue & Draft

    func testDropQueuedReturnsItsImages() {
        let chat = AIChatManager()
        chat.enqueue("with a picture", images: [attachment()])
        chat.dropQueued(chat.pendingQueued[0].id)
        XCTAssertTrue(chat.pendingQueued.isEmpty)
        XCTAssertEqual(chat.draftImages.count, 1)
    }

    func testImageMessageQueuesInsteadOfSteering() async {
        // A steer is delivered as a note on a tool result, which cannot carry
        // pixels — so an image sent mid-turn has to wait for its own turn.
        let chat = AIChatManager()
        chat.isGenerating = true
        await chat.sendMessage("look at this", images: [attachment()], as: .steer)
        XCTAssertTrue(chat.pendingQueued.count == 1)
        XCTAssertNil(chat.messages.last(where: { $0.role == .user && $0.hasImages }),
                     "it must not sit in the transcript as an exchange the model never got")
    }

    func testSteerQueuedHoldsAnImageMessageUntilTheTurnEnds() {
        let chat = AIChatManager()
        chat.isGenerating = true
        chat.enqueue("look at this", images: [attachment()])
        let id = chat.pendingQueued[0].id
        chat.steerQueued(id)
        XCTAssertEqual(chat.pendingQueued.count, 1, "still waiting, at the front")
        XCTAssertEqual(chat.pendingQueued[0].id, id)
        XCTAssertFalse(chat.messages.contains { $0.hasImages })
    }

    func testTextOnlySendStillSteers() async {
        let chat = AIChatManager()
        chat.isGenerating = true
        await chat.sendMessage("text only", as: .steer)
        XCTAssertTrue(chat.pendingQueued.isEmpty)
        XCTAssertEqual(chat.messages.last?.text, "text only")
    }
}
