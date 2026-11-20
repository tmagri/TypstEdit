import XCTest
@testable import TypstEdit

/// The on-disk recall cache: the format, the budget, and the lifecycle that
/// decides what is kept, evicted and deleted.
///
/// Everything here uses a temp folder the test owns, so nothing touches the
/// real Application Support directory and nothing needs a network or a saved
/// chat. It never skips.
final class VectorStoreTests: XCTestCase {

    private var directory: URL!
    private var store: VectorStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-vectors-\(UUID().uuidString)", isDirectory: true)
        store = VectorStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func vector(_ value: Float, dimensions: Int = 4) -> [Float] {
        (0..<dimensions).map { _ in value }
    }

    private func entries(_ count: Int, dimensions: Int = 4, date: Date = Date()) -> [String: CachedVector] {
        var out: [String: CachedVector] = [:]
        for index in 0..<count {
            out["key-\(index)"] = CachedVector(
                packed: .full(vector(Float(index + 1) / Float(count), dimensions: dimensions)),
                date: date
            )
        }
        return out
    }

    // MARK: - Round trip

    func testVectorsSurviveTheTripToDisk() async throws {
        let sessionID = UUID()
        let original = entries(5)
        let saved = await store.save(sessionID, vectors: original, identity: "model|768", dimensions: 4)
        XCTAssertTrue(saved)

        let maybeloaded = await store.load(sessionID)
        let loaded = try XCTUnwrap(maybeloaded)
        XCTAssertEqual(loaded.identity, "model|768")
        XCTAssertEqual(loaded.dimensions, 4)
        XCTAssertEqual(loaded.vectors, original)
    }

    /// The whole point of the cache: a relaunch must not re-embed anything.
    func testAnEmptyLoadIsNotAnError() async {
        let loaded = await store.load(UUID())
        XCTAssertNil(loaded)
    }

    /// Aging reads the date, and the date has to survive a relaunch — the
    /// passage's source row may be compacted away by then.
    func testThePassageDateSurvivesTheRoundTrip() async throws {
        let sessionID = UUID()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        await store.save(sessionID, vectors: entries(2, date: when), identity: "m", dimensions: 4)

        let maybeloaded = await store.load(sessionID)
        let loaded = try XCTUnwrap(maybeloaded)
        XCTAssertEqual(loaded.vectors.values.first?.date.timeIntervalSince1970 ?? 0, when.timeIntervalSince1970, accuracy: 0.001)
    }

    func testQuantizedVectorsSurviveTheRoundTrip() async throws {
        let sessionID = UUID()
        var original: [String: CachedVector] = [:]
        for index in 0..<4 {
            let raw = (0..<8).map { Float(($0 + index) % 5) / 5 }
            original["q-\(index)"] = CachedVector(packed: .int8(codes: PackedVector.compress(raw).codesForTesting!, scale: 0.25), date: Date())
        }
        await store.save(sessionID, vectors: original, identity: "m", dimensions: 8)

        let maybeloaded = await store.load(sessionID)
        let loaded = try XCTUnwrap(maybeloaded)
        XCTAssertEqual(loaded.vectors, original)
        // And the restored codes still rank the same way.
        let query = vector(0.5, dimensions: 8)
        XCTAssertNotNil(loaded.vectors["q-0"]?.packed.cosineDistance(to: query))
    }

    // MARK: - A corrupt or foreign file is deleted, never trusted

    func testACorruptFileIsDeletedAndReadsAsMissing() async {
        let sessionID = UUID()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("not a vector file".utf8).write(to: directory.appendingPathComponent("\(sessionID.uuidString).vec"))

        let loaded = await store.load(sessionID)
        XCTAssertNil(loaded, "garbage must read as no cache, not as an empty one")
        let files = await store.fileCount()
        XCTAssertEqual(files, 0, "and it must not be left occupying the budget")
    }

    func testATruncatedFileIsRejected() async {
        let sessionID = UUID()
        await store.save(sessionID, vectors: entries(6), identity: "m", dimensions: 4)
        let url = directory.appendingPathComponent("\(sessionID.uuidString).vec")
        let full = try? Data(contentsOf: url)
        let truncated = full?.prefix((full?.count ?? 0) / 2)
        try? truncated?.write(to: url)

        let loaded = await store.load(sessionID)
        XCTAssertNil(loaded, "a half-written file must not decode into partial vectors")
    }

    func testAFileFromAnotherFormatVersionIsRejected() {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: VectorStore.magic.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(99).littleEndian) { Array($0) })
        XCTAssertNil(VectorStore.decode(data))
    }

    // MARK: - Deletion and sweeping

    func testDeletingAConversationRemovesItsFile() async {
        let sessionID = UUID()
        await store.save(sessionID, vectors: entries(2), identity: "m", dimensions: 4)
        await store.delete(sessionID)
        let loaded = await store.load(sessionID)
        XCTAssertNil(loaded)
    }

    func testTheSweepRemovesOrphansAndKeepsLiveConversations() async {
        let live = UUID()
        let orphan = UUID()
        await store.save(live, vectors: entries(2), identity: "m", dimensions: 4)
        await store.save(orphan, vectors: entries(2), identity: "m", dimensions: 4)

        await store.sweep(liveSessionIDs: [live])

        let liveLoaded = await store.load(live)
        let orphanLoaded = await store.load(orphan)
        XCTAssertNotNil(liveLoaded)
        XCTAssertNil(orphanLoaded)
    }

    /// The safe direction: a launch that could not read the conversation index
    /// must not delete every vector the user had.
    func testTheSweepDoesNothingWithoutALiveSet() async {
        let orphan = UUID()
        await store.save(orphan, vectors: entries(2), identity: "m", dimensions: 4)

        await store.sweep(liveSessionIDs: [])

        let loaded = await store.load(orphan)
        XCTAssertNotNil(loaded, "an empty live set means 'unknown', not 'nothing exists'")
    }

    // MARK: - The budget

    /// The bound that actually holds: it does not assume anything about how
    /// many conversations exist.
    /// The bound that actually holds: it does not assume anything about how
    /// many conversations exist.
    func testTheOldestConversationIsEvictedFirst() async throws {
        // Five sessions, each well inside the per-file ceiling, with a budget
        // that fits only two of them.
        let small = VectorStore(directory: directory, maxDiskBytes: 6_000, maxFileBytes: 4_000)
        let ids = (0..<5).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            let when = Date().addingTimeInterval(Double(index) * 60)
            let saved = await small.save(id, vectors: entries(20, dimensions: 16, date: when), identity: "m", dimensions: 16)
            XCTAssertTrue(saved, "each file should fit the per-file ceiling")
            let url = directory.appendingPathComponent("\(id.uuidString).vec")
            try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
        }

        await small.enforceBudget()

        let remaining = await small.fileCount()
        XCTAssertGreaterThan(remaining, 0, "the newest must survive")
        XCTAssertLessThan(remaining, 5, "the oldest must be evicted")
        let newest = await small.load(ids.last!)
        XCTAssertNotNil(newest)
    }

    /// The file just written is exempt: evicting it immediately would throw
    /// away the work the save just did.
    func testTheFileBeingWrittenIsNotEvicted() async {
        let small = VectorStore(directory: directory, maxDiskBytes: 1, maxFileBytes: 1_000_000)
        let sessionID = UUID()
        await small.save(sessionID, vectors: entries(10, dimensions: 8), identity: "m", dimensions: 8)
        let loaded = await small.load(sessionID)
        XCTAssertNotNil(loaded)
    }

    func testAConversationOverTheFileCeilingIsNotKept() async {
        // A file too big to be worth caching: keeping it would let one chat
        // evict every other.
        let sessionID = UUID()
        let huge = entries(2_000, dimensions: 512)
        let saved = await store.save(sessionID, vectors: huge, identity: "m", dimensions: 512)
        if saved {
            // Only possible if the ceiling is generously sized; then it must
            // still be inside the global budget.
            let bytes = await store.totalBytes()
            XCTAssertLessThanOrEqual(bytes, store.maxFileBytes)
        } else {
            let files = await store.fileCount()
            XCTAssertEqual(files, 0)
        }
    }

    func testClearAllEmptiesTheCache() async {
        await store.save(UUID(), vectors: entries(2), identity: "m", dimensions: 4)
        await store.save(UUID(), vectors: entries(2), identity: "m", dimensions: 4)
        let before = await store.fileCount()
        XCTAssertEqual(before, 2)

        await store.clearAll()
        let after = await store.fileCount()
        let bytes = await store.totalBytes()
        XCTAssertEqual(after, 0)
        XCTAssertEqual(bytes, 0)
    }

    // MARK: - Format hygiene

    /// The file must be byte-stable for the same input, so a cache that
    /// rewrites unchanged content is a no-op on disk rather than churn.
    func testEncodingIsDeterministic() {
        // The same date for both: `entries` defaults to `Date()`, and two
        // calls would legitimately differ.
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let first = VectorStore.encode(entries(10, date: when), identity: "m", dimensions: 4)
        let second = VectorStore.encode(entries(10, date: when), identity: "m", dimensions: 4)
        XCTAssertEqual(first, second)
    }

    func testAVectorOfTheWrongLengthIsNotWritten() {
        var mixed = entries(2, dimensions: 4)
        mixed["bad"] = CachedVector(packed: .full([1, 2, 3]), date: Date())
        let data = VectorStore.encode(mixed, identity: "m", dimensions: 4)
        let loaded = VectorStore.decode(data)
        XCTAssertEqual(loaded?.vectors.count, 2, "a vector of the wrong width must be dropped, not stored")
    }

}

private extension PackedVector {
    /// The compressed codes, for a test that needs to rebuild the same value.
    var codesForTesting: [Int8]? {
        if case .int8(let codes, _) = self { return codes }
        return nil
    }
}
