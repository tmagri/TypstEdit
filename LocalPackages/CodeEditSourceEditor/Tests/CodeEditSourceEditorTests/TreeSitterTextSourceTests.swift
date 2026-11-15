import XCTest
import CodeEditTextView
import CodeEditLanguages
@testable import CodeEditSourceEditor

// swiftlint:disable all

/// `TreeSitterTextSource` lets tree-sitter read the document from a background thread. These tests pin the
/// properties that design depends on: chunking is lossless and never splits a surrogate pair, a snapshot is
/// isolated from later edits, a background reader needs no main-thread help once it holds a snapshot, and — the
/// point of the whole exercise — the async, snapshot-backed pipeline highlights exactly like the synchronous one.
@MainActor
final class TreeSitterTextSourceTests: XCTestCase {

    private func makeTextView(_ text: String) -> TextView {
        let textView = Mock.textView()
        textView.setText(text)
        return textView
    }

    /// Concatenates every chunk the way tree-sitter would pull them, from the thread this runs on.
    private func readAll(_ source: TreeSitterTextSource, maxLength: Int = 4096) -> [UInt16] {
        var units: [UInt16] = []
        var byteOffset = 0
        while true {
            guard let chunk = source.chunk(atByteOffset: byteOffset, maxLength: maxLength), !chunk.isEmpty else { break }
            chunk.withUnsafeBytes { raw in units.append(contentsOf: raw.bindMemory(to: UInt16.self)) }
            byteOffset += chunk.count
        }
        return units
    }

    // MARK: - Chunking

    func test_chunksReassembleToTheDocument() {
        let text = String(repeating: "héllo wörld — “quoted” 👋 line\n", count: 600)
        let textView = makeTextView(text)
        let source = TreeSitterTextSource(textView: textView)
        for size in [1, 2, 7, 4096, 100_000] {
            XCTAssertEqual(readAll(source, maxLength: size), Array(text.utf16), "chunk size \(size)")
        }
    }

    func test_chunkNeverEndsBetweenSurrogateHalves() {
        // Put an emoji (a surrogate pair) at every possible offset relative to the chunk boundary.
        for padding in 0..<12 {
            let text = String(repeating: "a", count: padding) + "👋" + String(repeating: "b", count: 40)
            let textView = makeTextView(text)
            let source = TreeSitterTextSource(textView: textView)
            var byteOffset = 0
            var total = 0
            while let chunk = source.chunk(atByteOffset: byteOffset, maxLength: 6), !chunk.isEmpty {
                let units = chunk.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
                XCTAssertFalse(UTF16.isLeadSurrogate(units.last!) && total + units.count < text.utf16.count,
                               "padding \(padding): chunk ends on a lead surrogate")
                total += units.count
                byteOffset += chunk.count
            }
            XCTAssertEqual(total, text.utf16.count, "padding \(padding): no units lost")
        }
    }

    func test_oneUnitChunkIsNeverShortenedToNothing() {
        // An empty chunk means "end of input" to tree-sitter, so a lone lead surrogate must still be returned.
        let textView = makeTextView("👋")
        let source = TreeSitterTextSource(textView: textView)
        let chunk = source.chunk(atByteOffset: 0, maxLength: 1)
        XCTAssertEqual(chunk?.count, 2)
    }

    func test_endOfInputAndOutOfRangeOffsets() {
        let textView = makeTextView("abc")
        let source = TreeSitterTextSource(textView: textView)
        XCTAssertEqual(source.chunk(atByteOffset: 6, maxLength: 4096), Data(), "exactly at the end: empty = EOF")
        XCTAssertNil(source.chunk(atByteOffset: 8, maxLength: 4096), "past the end")
        XCTAssertNil(source.chunk(atByteOffset: -2, maxLength: 4096))
    }

    func test_emptyDocument() {
        let textView = makeTextView("")
        let source = TreeSitterTextSource(textView: textView)
        XCTAssertEqual(source.chunk(atByteOffset: 0, maxLength: 4096), Data())
    }

    // MARK: - Snapshots

    /// Runs `work` on a background thread while the main run loop keeps spinning, so the snapshot hop is served.
    private func onBackground<T>(_ work: @escaping @Sendable () -> T) -> T {
        let done = expectation(description: "background work")
        nonisolated(unsafe) var result: T?
        Thread.detachNewThread {
            result = work()
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return result!
    }

    func test_snapshotMatchesLiveText() {
        let text = String(repeating: "snapshot — “text” 👋\n", count: 500)
        let textView = makeTextView(text)
        let source = TreeSitterTextSource(textView: textView)
        let live = readAll(source)
        let snapshotted: [UInt16] = onBackground {
            source.withSnapshot { TreeSitterTextSourceTests.readAllNonisolated(source) }
        }
        XCTAssertEqual(snapshotted, live)
        XCTAssertEqual(snapshotted, Array(text.utf16))
    }

    nonisolated static func readAllNonisolated(_ source: TreeSitterTextSource) -> [UInt16] {
        var units: [UInt16] = []
        var byteOffset = 0
        while let chunk = source.chunk(atByteOffset: byteOffset, maxLength: 4096), !chunk.isEmpty {
            chunk.withUnsafeBytes { units.append(contentsOf: $0.bindMemory(to: UInt16.self)) }
            byteOffset += chunk.count
        }
        return units
    }

    func test_snapshotIsIsolatedFromLaterEdits() {
        let textView = makeTextView(String(repeating: "original text\n", count: 200))
        let source = TreeSitterTextSource(textView: textView)
        let original = Array(textView.string.utf16)

        let captured = DispatchSemaphore(value: 0)
        let edited = DispatchSemaphore(value: 0)
        let finished = expectation(description: "reader finished")
        nonisolated(unsafe) var seen: [UInt16] = []
        Thread.detachNewThread {
            source.withSnapshot {
                captured.signal()
                edited.wait()                       // the main thread rewrites the document meanwhile
                seen = TreeSitterTextSourceTests.readAllNonisolated(source)
            }
            finished.fulfill()
        }
        // Wait for the snapshot hop to be served, then change the live text under the reader.
        while captured.wait(timeout: .now()) != .success { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        textView.replaceCharacters(in: NSRange(location: 0, length: 8), with: "EDITED!!! and longer")
        edited.signal()
        wait(for: [finished], timeout: 10)

        XCTAssertNotEqual(Array(textView.string.utf16), original, "the live text did change")
        XCTAssertEqual(seen, original, "the reader must see the text as of the snapshot")
    }

    func test_readingWithASnapshotNeverHopsToTheMainThread() {
        // Deterministic: every fallback hop is counted, so any main-thread dependence while a snapshot is
        // installed is an assertion failure, with no timing involved.
        let textView = makeTextView(String(repeating: "no main thread needed — 👋\n", count: 3000))
        let source = TreeSitterTextSource(textView: textView)
        let expected = Array(textView.string.utf16)

        let seen: [UInt16] = onBackground {
            source.withSnapshot {
                let units = TreeSitterTextSourceTests.readAllNonisolated(source)
                _ = source.string(in: NSRange(location: 0, length: 10))
                _ = source.string(in: NSRange(location: 100, length: 50))
                return units
            }
        }
        XCTAssertEqual(seen, expected)
        XCTAssertEqual(source.mainThreadFallbackCount, 0,
                       "reads made while holding a snapshot must not touch the main thread")
    }

    func test_withoutASnapshotReadsStillWorkViaTheMainThread() {
        // Safety net: code that has not adopted `withSnapshot` keeps the old (hopping) behaviour.
        let text = "fallback path ✓"
        let textView = makeTextView(text)
        let source = TreeSitterTextSource(textView: textView)
        let units: [UInt16] = onBackground { TreeSitterTextSourceTests.readAllNonisolated(source) }
        XCTAssertEqual(units, Array(text.utf16))
        XCTAssertGreaterThan(source.mainThreadFallbackCount, 0, "this path is supposed to hop (and be counted)")
    }

    func test_snapshotsOfDifferentSourcesDoNotLeakIntoEachOther() {
        let first = TreeSitterTextSource(textView: makeTextView("first document"))
        let secondView = makeTextView("second")
        let second = TreeSitterTextSource(textView: secondView)
        let units: [UInt16] = onBackground {
            first.withSnapshot { TreeSitterTextSourceTests.readAllNonisolated(second) }   // `second` has no snapshot of its own here
        }
        XCTAssertEqual(units, Array("second".utf16), "must not read `first`'s snapshot")
    }

    // MARK: - Sync / async parity

    private func noteDocument() -> String {
        var parts: [String] = []
        for i in 0..<120 {
            parts.append("# Heading \(i)\n")
            parts.append("Some *prose* with “quotes” and 👋 emoji, plus #strong[Typst] and $x^2$ math \(i).\n")
            if i % 5 == 0 {
                parts.append("#set page(\n  margin: 1cm,\n)\n#let f\(i) = (n) => {\n  n + \(i)\n}\n")
            }
            if i % 7 == 0 { parts.append("```swift\nlet x = \(i)\n```\n") }
        }
        return parts.joined(separator: "\n")
    }

    /// Reads `state` through the executor, which is what serializes access to it. Polling the property directly
    /// from the test thread while the executor assigns it is a data race (Thread Sanitizer reports it).
    private func clientIsSetUp(_ client: TreeSitterClient) -> Bool {
        if case .success(let ready) = client.executor.execSync({ client.state != nil }) { return ready }
        return false   // an operation is still running
    }

    private func awaitState(_ client: TreeSitterClient) {
        let deadline = Date().addingTimeInterval(10)
        while !clientIsSetUp(client), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(clientIsSetUp(client), "client never finished setting up")
        // Setup replaces `state` once; let any trailing queued work drain.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func highlights(_ client: TreeSitterClient, in textView: TextView, range: NSRange) -> [HighlightRange] {
        var result: [HighlightRange] = []
        var got = false
        client.queryHighlightsFor(textView: textView, range: range) { outcome in
            if case .success(let h) = outcome { result = h }
            got = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !got, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(got, "query never completed")
        return result.sorted { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
    }

    func test_asyncSnapshotPipelineHighlightsLikeTheSynchronousOne() {
        let savedLimit = TreeSitterClient.Constants.maxSyncContentLength
        defer { TreeSitterClient.Constants.maxSyncContentLength = savedLimit }

        let text = noteDocument()
        XCTAssertGreaterThan(text.utf16.count, 8000)

        func run(async: Bool) -> (before: [HighlightRange], after: [HighlightRange]) {
            // `maxSyncContentLength = 0` forces every operation onto the background executor.
            TreeSitterClient.Constants.maxSyncContentLength = async ? 0 : Int.max
            let textView = makeTextView(text)
            let client = Mock.treeSitterClient(forceSync: !async)
            client.setUp(textView: textView, codeLanguage: .note)
            awaitState(client)
            let whole = NSRange(location: 0, length: textView.textStorage.length)
            let before = highlights(client, in: textView, range: whole)

            // Edit in the middle (turns a heading into a paragraph), then re-query.
            let editAt = (text as NSString).range(of: "# Heading 60").location
            let range = NSRange(location: editAt, length: 2)
            textView.replaceString(in: range, with: "")
            var applied = false
            client.applyEdit(textView: textView, range: range, delta: -range.length) { _ in applied = true }
            let deadline = Date().addingTimeInterval(10)
            while !applied, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertTrue(applied, "edit never completed (async: \(async))")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let after = highlights(client, in: textView, range: NSRange(location: 0, length: textView.textStorage.length))
            return (before, after)
        }

        let sync = run(async: false)
        let async = run(async: true)

        XCTAssertFalse(sync.before.isEmpty, "the document should produce highlights")
        XCTAssertEqual(async.before.count, sync.before.count, "initial highlight count")
        XCTAssertEqual(async.before.map { "\($0.range.location),\($0.range.length),\($0.capture)" },
                       sync.before.map { "\($0.range.location),\($0.range.length),\($0.capture)" },
                       "initial highlights differ between the sync and async pipelines")
        XCTAssertEqual(async.after.map { "\($0.range.location),\($0.range.length),\($0.capture)" },
                       sync.after.map { "\($0.range.location),\($0.range.length),\($0.capture)" },
                       "highlights after an edit differ between the sync and async pipelines")
        XCTAssertNotEqual(sync.before.map { "\($0.range.location)" }, sync.after.map { "\($0.range.location)" },
                          "the edit should have changed the highlights (otherwise this test proves nothing)")
    }

    // MARK: - Adaptive sync / async routing

    /// Applies one edit and reports whether its completion had already run when `applyEdit` returned. A
    /// synchronous edit completes before returning; a background edit cannot.
    private func completesBeforeReturning(editBudget: TimeInterval) -> Bool {
        let savedBudget = TreeSitterClient.Constants.maxSyncEditDuration
        let savedLength = TreeSitterClient.Constants.maxSyncContentLength
        defer {
            TreeSitterClient.Constants.maxSyncEditDuration = savedBudget
            TreeSitterClient.Constants.maxSyncContentLength = savedLength
        }
        TreeSitterClient.Constants.maxSyncEditDuration = editBudget
        TreeSitterClient.Constants.maxSyncContentLength = Int.max   // only the measured cost may force async

        let text = noteDocument()
        let textView = makeTextView(text)
        let client = Mock.treeSitterClient()
        client.setUp(textView: textView, codeLanguage: .note)
        awaitState(client)

        let range = NSRange(location: 40, length: 0)
        textView.replaceString(in: range, with: "x")
        var completedInline = false
        var completed = false
        client.applyEdit(textView: textView, range: range, delta: 1) { _ in completed = true }
        completedInline = completed
        // Let the (possibly background) edit finish so it cannot leak into the next test.
        let deadline = Date().addingTimeInterval(10)
        while !completed, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(completed, "the edit must complete either way")
        return completedInline
    }

    func test_slowEditsMoveToTheBackgroundExecutor() {
        // A zero budget means any measured edit cost is "too slow": the seeded setup cost already exceeds it.
        XCTAssertFalse(completesBeforeReturning(editBudget: 0),
                       "with a zero budget the edit must run asynchronously")
    }

    func test_cheapEditsStayOnTheMainThread() {
        // A generous budget keeps edits synchronous so small documents get immediately-correct colors.
        XCTAssertTrue(completesBeforeReturning(editBudget: 60),
                      "with a generous budget the edit must complete synchronously")
    }
}
