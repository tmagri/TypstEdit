import XCTest
@testable import TypstEdit

/// The preview compiler runs a long-lived `typst watch` child. These check it
/// never outlives its compiler, and that one document never gets two watches.
@MainActor
final class CompilerProcessLifetimeTests: XCTestCase {

    private var root: URL!
    /// Every watch a test started. Killed in tearDown whatever the outcome, so
    /// a failing assertion can never leave a `typst` process behind.
    private var startedPIDs: Set<pid_t> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompilerProcessLifetimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for pid in startedPIDs { kill(pid, SIGKILL) }
        startedPIDs = []
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    /// `typst` children of this test process.
    private func watchChildren() -> Set<pid_t> {
        Set(ChildProcessGuard.descendants(of: getpid()).filter { pid in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
            return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent == "typst"
        })
    }

    /// Polls with `Task.sleep`, so main-actor work (output handling, the idle
    /// countdown) keeps running while the test waits.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Starts a watch on `doc.typ` and returns the PIDs it added.
    @discardableResult
    private func startWatch(_ compiler: TypstCompiler) async throws -> Set<pid_t> {
        let before = watchChildren()
        let file = root.appendingPathComponent("doc.typ")
        try "= Hello".write(to: file, atomically: true, encoding: .utf8)
        await compiler.updateContent(source: "= Hello", fileURL: file)
        await waitUntil(5) { !watchChildren().subtracting(before).isEmpty }
        let started = watchChildren().subtracting(before)
        startedPIDs.formUnion(started)
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
        await waitUntil(3) { stillRunning(pids).isEmpty }
        XCTAssertTrue(stillRunning(pids).isEmpty, "typst watch outlived its compiler")
    }

    func testStopStopsTheWatchProcess() async throws {
        let compiler = TypstCompiler()
        let pids = try await startWatch(compiler)
        compiler.cleanUp()
        await waitUntil(3) { stillRunning(pids).isEmpty }
        XCTAssertTrue(stillRunning(pids).isEmpty, "cleanUp() left typst watch running")
    }

    /// An open but untouched document must not hold a `typst watch` forever:
    /// after the idle delay the process goes, the preview stays, and the next
    /// edit starts a fresh watch.
    func testIdleWatchStopsAndRestartsOnTheNextEdit() async throws {
        let compiler = TypstCompiler()
        compiler.idleStopDelayOverride = 0.5
        let firstPIDs = try await startWatch(compiler)

        await waitUntil(10) { stillRunning(firstPIDs).isEmpty }
        XCTAssertTrue(stillRunning(firstPIDs).isEmpty, "an idle watch kept running")
        XCTAssertTrue(compiler.isIdleStopped)
        XCTAssertFalse(compiler.isWatching)
        XCTAssertNotNil(compiler.currentShadowPDFURL, "the preview must survive an idle stop")
        XCTAssertEqual(compiler.compilationStatus, "Idle")

        // Editing again brings the compiler back.
        let secondPIDs = try await startWatch(compiler)
        XCTAssertTrue(firstPIDs.isDisjoint(with: secondPIDs))
        XCTAssertTrue(compiler.isWatching)
        XCTAssertFalse(compiler.isIdleStopped)
        compiler.cleanUp()
    }

    /// `0` ("Never") keeps the old behaviour: the watch stays while open.
    func testIdleStopCanBeTurnedOff() async throws {
        let compiler = TypstCompiler()
        compiler.idleStopDelayOverride = 0
        let pids = try await startWatch(compiler)
        await waitUntil(1.5) { stillRunning(pids).isEmpty }
        XCTAssertFalse(stillRunning(pids).isEmpty)
        XCTAssertFalse(compiler.isIdleStopped)
        compiler.cleanUp()
    }

    /// Two compilers for the same window (what a re-created duplicate main
    /// window produced) must not leave two watches on one shadow file.
    func testTwoCompilersOnOneDocumentKeepOnlyOneWatch() async throws {
        let first = TypstCompiler()
        let second = TypstCompiler()
        first.scratchNamespace = "samewindow"
        second.scratchNamespace = "samewindow"

        let firstPIDs = try await startWatch(first)
        let secondPIDs = try await startWatch(second)

        await waitUntil(3) { stillRunning(firstPIDs).isEmpty }
        XCTAssertTrue(stillRunning(firstPIDs).isEmpty, "the older watch on the same file kept running")
        XCTAssertFalse(stillRunning(secondPIDs).isEmpty, "the newest watch must keep the preview alive")
        XCTAssertFalse(first.isWatching)
        XCTAssertTrue(second.isWatching)
        withExtendedLifetime([first, second]) {}
    }
}
