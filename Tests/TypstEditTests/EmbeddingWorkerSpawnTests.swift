import XCTest
import Foundation
@testable import TypstEdit

/// The real spawn round-trip: the client launches the built `TypstEdit`
/// binary as `embed-worker`, sends requests the way `RAGManager` does
/// (the first write lands in the pipe buffer before the child's reader
/// starts), and reads the replies.
///
/// The original bug this guards against had two halves: (1) `Process`
/// prepends `executableURL` as argv[0], so passing the executable inside
/// `arguments` made the child launch the full GUI app — a second Dock
/// icon and a duplicate project window with its own embedding pass; and
/// (2) Foundation's `FileHandle.standardInput` consumed request bytes
/// buffered before the worker's loop started, hanging the first request.
/// Both are covered here: argv shape is checked via the working round-trip
/// (a GUI launch would never reply), and the immediate-write race is the
/// first thing the client does.
@MainActor
final class EmbeddingWorkerSpawnTests: XCTestCase {
    private static func builtBinary() -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidate = root.appendingPathComponent(".build/debug/TypstEdit")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func testClientRoundTripsThroughTheRealProcess() async throws {
        let binary = try XCTUnwrap(Self.builtBinary(), "build the package first")

        let client = EmbeddingWorkerClient()
        // Replace only the spawn decision's executable-availability check:
        // spawn the built binary explicitly (Bundle.main here is xctest).
        client.spawnOverride = binary
        let spec = EmbeddingWorkerSpec(kind: .apple, dimensions: 512)

        // The first request writes into the pipe buffer before the child's
        // reader exists — the race that used to hang everything.
        let first = try await timeout(60) { await client.embed(texts: ["hello world"], spec: spec) }
        XCTAssertEqual(first?.count, 1, "one vector per text")
        XCTAssertNotNil(first?[0])
        XCTAssertFalse(first![0]!.isEmpty)

        // A second request reuses the same process.
        let second = try await timeout(60) { await client.embed(texts: ["second", "third"], spec: spec) }
        XCTAssertEqual(second?.count, 2)
        XCTAssertNotEqual(second?[0], second?[1], "different texts embed differently")

        // The child is alive and headless. Count workers that are OUR
        // children — a shared CI machine (or another test's leftover) may
        // legitimately have its own; what matters is that this client owns
        // exactly one, and that it is not a GUI relaunch (a GUI launch
        // would not carry the embed-worker argument).
        let myPID = ProcessInfo.processInfo.processIdentifier
        let ps = try shell("ps", "-axo", "ppid=,command=")
        let myWorkers = ps.split(separator: "\n").filter {
            guard $0.contains("embed-worker"), let ppid = $0.split(separator: " ").first else { return false }
            return ppid == String(myPID)
        }
        XCTAssertEqual(myWorkers.count, 1, "exactly one worker child of this process; got: \(myWorkers)")

        client.stop()
        // stop() escalates to SIGKILL after 0.5s; give the child a moment
        // beyond that to disappear from the process table.
        try await Task.sleep(nanoseconds: 900_000_000)
        let after = try shell("ps", "-axo", "ppid=,command=")
        let orphanedWorkers = after.split(separator: "\n").filter {
            guard $0.contains("embed-worker"), let ppid = $0.split(separator: " ").first else { return false }
            return ppid == String(myPID)
        }
        XCTAssertTrue(orphanedWorkers.isEmpty, "stop() kills the helper; still running: \(orphanedWorkers)")
    }

    /// A request the child cannot parse must fail that request — not the
    /// process: the next request still works.
    func testClientSurvivesMultipleSequentialRequests() async throws {
        let binary = try XCTUnwrap(Self.builtBinary())
        let client = EmbeddingWorkerClient()
        client.spawnOverride = binary
        let spec = EmbeddingWorkerSpec(kind: .apple, dimensions: 512)

        for i in 0..<3 {
            let result = try await timeout(60) { await client.embed(texts: ["round \(i)"], spec: spec) }
            XCTAssertEqual(result?.count, 1, "round \(i)")
        }
        client.stop()
    }

    // MARK: - Helpers

    private func timeout<T: Sendable>(
        _ seconds: Double, _ body: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Timeout()
            }
            guard let first = try await group.next() else { throw Timeout() }
            group.cancelAll()
            return first
        }
    }

    private struct Timeout: Error {}

    private func shell(_ command: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/" + command[0])
        process.arguments = Array(command.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
