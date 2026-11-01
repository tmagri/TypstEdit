import XCTest
import Foundation
import CSQLite
@testable import TypstEdit

/// Bind-safety regression coverage for the RAG vector index.
///
/// The old code bound Swift temporaries with `SQLITE_STATIC` (a `nil`
/// destructor):
///
/// ```swift
/// sqlite3_bind_text(stmt, 1, (fileKey as NSString).utf8String, -1, nil)
/// ```
///
/// With `SQLITE_STATIC`, SQLite stores the raw pointer and reads it at
/// `sqlite3_step`. The `(fileKey as NSString)` temporary was released at the
/// end of the statement, so every bind on that path could hand SQLite a
/// dangling pointer — silent, intermittent heap corruption on the indexing
/// hot path (one bind per file, plus one per embedded chunk). This kind of
/// damage surfaces much later as a crash in unrelated code, which is why it
/// was never caught by a debugger or a test that merely checks values.
///
/// These tests pin the semantics that make the binds safe:
/// 1. bound values survive temporary lifetimes (SQLite took its own copy);
/// 2. bound blobs round-trip byte-exact, including non-zero-length data;
/// 3. an empty blob binds as a zero-length blob, not SQL NULL.
final class SQLiteBindSafetyTests: XCTestCase {

    private func openDatabase() throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MEMORY
        guard sqlite3_open_v2(":memory:", &db, flags, nil) == SQLITE_OK, let db else {
            throw NSError(domain: "SQLiteBindSafetyTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not open :memory: database"])
        }
        try exec("CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT, hash TEXT, embedding BLOB)", on: db)
        return db
    }

    private func exec(_ sql: String, on db: OpaquePointer) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let reason = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw NSError(domain: "SQLiteBindSafetyTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "exec failed: \(reason)"])
        }
    }

    /// Steps a prepared statement once and returns the columns of the row, or
    /// nil when the query produced no row. Never dereferences column values
    /// after a non-ROW step (`sqlite3_column_text` on a done statement is
    /// documented undefined behaviour, and crashes in practice).
    private func queryRow(_ db: OpaquePointer, _ sql: String) -> [String?]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        var row: [String?] = []
        for c in 0..<Int(sqlite3_column_count(stmt)) {
            if let text = sqlite3_column_text(stmt, Int32(c)) {
                row.append(String(cString: text))
            } else {
                row.append(nil)
            }
        }
        return row
    }

    /// The shape every RAG insert had: bind short-lived strings, drop every
    /// reference to them, step later, and read the value back. With
    /// `SQLITE_TRANSIENT` SQLite copies the bytes at bind time, so what it
    /// later returns is unaffected by the Swift temporary's lifetime.
    func testBoundTextSurvivesTemporaryLifetime() throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO t (path, hash) VALUES (?1, ?2)", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        // Bind through a scope the strings do not outlive.
        do {
            let path = "notes/Genesis.note"
            let hash = "96b7d8dddd626f63"
            stmt?.bind(path, at: 1)
            stmt?.bind(hash, at: 2)
            // `path` and `hash` die here; SQLite must hold its own copies or
            // the step below (and the read-back after it) reads freed memory.
        }
        // Push allocations through the same pool to maximise the chance that
        // any dangling buffer is reused before the step.
        let churn = (0..<512).map { "churn-\($0)-\(String(repeating: "x", count: 64))" }
        XCTAssertTrue(churn.count > 0)

        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        XCTAssertEqual(sqlite3_reset(stmt), SQLITE_OK)

        // Read the row back through a fresh statement.
        let row = try XCTUnwrap(queryRow(db, "SELECT path, hash FROM t WHERE id = 1"))
        XCTAssertEqual(row[0], "notes/Genesis.note")
        XCTAssertEqual(row[1], "96b7d8dddd626f63")
    }

    /// Embeddings are stored as raw float buffers. The blob must round-trip
    /// byte-exact — or every stored vector silently mis-searches.
    func testBoundBlobRoundTripsByteExact() throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        // 512 floats = the local NLEmbedding provider's dimensionality.
        XCTAssertEqual(LocalEmbeddingProvider().dimensions, 512)
        let vector: [Float] = (0..<512).map { Float($0) / 8.0 }
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO t (embedding) VALUES (?1)", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        stmt?.bind(blob: blob, at: 1)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)

        // Read the raw bytes back and compare byte-for-byte, so any splice,
        // shift or truncation fails rather than a float-parsed compare.
        var readStmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT embedding FROM t WHERE id = 1", -1, &readStmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(readStmt) }
        XCTAssertEqual(sqlite3_step(readStmt), SQLITE_ROW)

        let length = Int(sqlite3_column_bytes(readStmt, 0))
        XCTAssertEqual(length, 512 * MemoryLayout<Float>.size, "the full float buffer must be stored")
        if let stored = sqlite3_column_blob(readStmt, 0) {
            let actual = Data(bytes: stored, count: length)
            XCTAssertEqual(actual, blob, "the blob must round-trip byte-exact")
        } else {
            XCTFail("the stored blob pointer must not be NULL")
        }
    }

    /// An empty embedding (e.g. a failed generation) must bind as an empty
    /// blob, not a NULL blob — `sqlite3_bind_blob(…, nil, 0, …)` binds NULL,
    /// which then can't be joined against in vector scans.
    func testEmptyBlobBindsAsZeroBlobNotNULL() throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO t (embedding) VALUES (?1)", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        stmt?.bind(blob: Data(), at: 1)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)

        var readStmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT embedding, typeof(embedding) FROM t WHERE id = 1", -1, &readStmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(readStmt) }
        XCTAssertEqual(sqlite3_step(readStmt), SQLITE_ROW)
        XCTAssertEqual(Int(sqlite3_column_bytes(readStmt, 0)), 0)
        let type = sqlite3_column_text(readStmt, 1).map { String(cString: $0) }
        XCTAssertEqual(type, "blob", "an empty embedding must be a zero-length blob, not SQL NULL")
    }

    /// The destructor sentinel itself: `SQLITE_TRANSIENT` (the copying
    /// destructor the helpers use) versus `nil` (SQLITE_STATIC — the unsafe
    /// pattern the old code had). Pinned so a future refactor can't quietly
    /// revert to NULL.
    func testTransientDestructorIsNotNull() {
        XCTAssertNotNil(sqliteTransient, "the bind helpers must copy (SQLITE_TRANSIENT), not retain (SQLITE_STATIC)")
    }
}
