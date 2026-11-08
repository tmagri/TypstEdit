import XCTest
@testable import TypstEdit

/// The preview compiler runs a long-lived `typst watch` child. These check it
/// never outlives the compiler (window closed) or the document (welcome screen).
@MainActor
final class CompilerProcessLifetimeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompilerProcessLifetimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    /// `typst watch` children of this test process.
    private func watchChildren() -> [pid_t] {
        ChildProcessGuard.descendants(of: getpid()).filter { pid in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
            return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent == "typst"
        }
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Starts a watch and returns the PIDs it added.
    private func startWatch(_ compiler: TypstCompiler) async throws -> Set<pid_t> {
        let before = Set(watchChildren())
        let file = root.appendingPathComponent("doc.typ")
        try "= Hello".write(to: file, atomically: true, encoding: .utf8)
        await compiler.updateContent(source: "= Hello", fileURL: file)
        waitUntil(5) { !Set(watchChildren()).subtracting(before).isEmpty }
        let started = Set(watchChildren()).subtracting(before)
        guard !started.isEmpty else { throw XCTSkip("typst binary not available") }
        return started
    }

    private func stillRunning(_ pids: Set<pid_t>) -> Set<pid_t> {
        pids.intersection(watchChildren())
    }

    func testReleasingTheCompilerStopsItsWatchProcess() async throws {
        var compiler: TypstCompiler? = TypstCompiler()
        let pids = try await startWatch(compiler!)
        compiler = nil
        waitUntil(3) { stillRunning(pids).isEmpty }
        XCTAssertTrue(stillRunning(pids).isEmpty, "typst watch outlived its compiler")
    }

    func testStopStopsTheWatchProcess() async throws {
        let compiler = TypstCompiler()
        let pids = try await startWatch(compiler)
        compiler.cleanUp()
        waitUntil(3) { stillRunning(pids).isEmpty }
        XCTAssertTrue(stillRunning(pids).isEmpty, "cleanUp() left typst watch running")
    }
}
