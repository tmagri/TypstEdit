import XCTest
@testable import TypstEdit

/// The bounded, lock-free read helper the semantic index and find-in-project
/// scan through.
final class LossyFileReaderTests: XCTestCase {
    private var url: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        try await super.setUp()
        url = fm.temporaryDirectory.appendingPathComponent("lossy-\(UUID().uuidString).txt")
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: url)
        try await super.tearDown()
    }

    func testReadsWholeFile() throws {
        try "hello world".data(using: .utf8)!.write(to: url)
        let reading = try XCTUnwrap(LossyFileReader.read(url, maxBytes: 1024))
        XCTAssertEqual(String(data: reading.data, encoding: .utf8), "hello world")
        XCTAssertFalse(reading.truncated)
    }

    func testTruncatesAndReportsAtTheCap() throws {
        let payload = String(repeating: "a", count: 100)
        try payload.data(using: .utf8)!.write(to: url)

        let reading = try XCTUnwrap(LossyFileReader.read(url, maxBytes: 10))
        XCTAssertEqual(reading.data.count, 10)
        XCTAssertTrue(reading.truncated)

        // A cap exactly the file's size is not truncation.
        let exact = try XCTUnwrap(LossyFileReader.read(url, maxBytes: payload.utf8.count))
        XCTAssertFalse(exact.truncated)
    }

    func testMissingFileYieldsNil() {
        let missing = fm.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID()).txt")
        XCTAssertNil(LossyFileReader.read(missing, maxBytes: 100))
    }

    func testEmptyFileYieldsNil() throws {
        try Data().write(to: url)
        XCTAssertNil(LossyFileReader.read(url, maxBytes: 100))
    }

    /// The read must not lock the file: a writer holding the file open
    /// (as an atomic save does, or another app) does not block the read.
    /// This exercises the read against a file held open for writing.
    func testReadWhileFileIsOpenForWriting() throws {
        let handle = try FileHandle(forWritingTo: {
            try fm.createFile(atPath: url.path, contents: nil)
            return url
        }())
        defer { try? handle.close() }

        try handle.write(contentsOf: Data("partial content".utf8))
        let reading = try XCTUnwrap(LossyFileReader.read(url, maxBytes: 1024))
        XCTAssertEqual(String(data: reading.data, encoding: .utf8), "partial content")
    }
}
