import XCTest
import Darwin
@testable import TypstEdit

/// No process TypstEdit started may outlive it.
final class ChildProcessGuardTests: XCTestCase {
    private typealias Entry = ChildProcessGuard.ProcessEntry
    private let managed = ["/Users/u/Library/Application Support/TypstEdit", "/Applications/TypstEdit.app"]

    func testOnlyOrphanedTypstEditPreviewCompilersMatch() {
        let table = [
            // Left behind by TypstEdit: matches.
            Entry(pid: 10, parent: 1, command: "/Users/u/Library/Application Support/TypstEdit/typst_source/stable_bin/typst watch /x/temp/a.typ.preview.typ /x/temp/a.typ.preview.pdf --root /x"),
            Entry(pid: 11, parent: 1, command: "/Applications/TypstEdit.app/Contents/Resources/bin/typst watch /x/temp/b.note.ab12cd34.preview.typ /x/temp/b.pdf --root /x"),
            // Still owned by a running TypstEdit: not an orphan.
            Entry(pid: 12, parent: 500, command: "/Applications/TypstEdit.app/Contents/Resources/bin/typst watch /x/temp/c.typ.preview.typ /x/c.pdf --root /x"),
            // The user's own typst watch: other binary, no preview file.
            Entry(pid: 13, parent: 1, command: "/Users/u/Desktop/TypstEdit/typst-universal watch wl.typ out.pdf --root ."),
            Entry(pid: 14, parent: 1, command: "/opt/homebrew/bin/typst watch /x/temp/d.typ.preview.typ /x/d.pdf"),
            // A managed binary, but not on a preview file.
            Entry(pid: 15, parent: 1, command: "/Applications/TypstEdit.app/Contents/Resources/bin/typst watch thesis.typ"),
            // Prefix lookalike outside the managed folder.
            Entry(pid: 16, parent: 1, command: "/Applications/TypstEdit.app-old/Contents/Resources/bin/typst watch /x/temp/e.typ.preview.typ"),
        ]
        XCTAssertEqual(ChildProcessGuard.orphanedPreviewCompilers(in: table, managedBinaryPrefixes: managed), [10, 11])
    }

    func testDescendantsIncludeGrandchildren() throws {
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "sleep 30 & wait"]
        try parent.run()
        defer { parent.terminate() }
        let grandchild = try waitForChild(of: parent.processIdentifier)
        defer { kill(grandchild, SIGKILL) }

        let found = ChildProcessGuard.descendants(of: getpid())
        XCTAssertTrue(found.contains(parent.processIdentifier))
        XCTAssertTrue(found.contains(grandchild))
        XCTAssertLessThan(found.firstIndex(of: parent.processIdentifier)!, found.firstIndex(of: grandchild)!)
    }

    /// A stand-in app is killed with SIGKILL (as Force Quit does). Its child
    /// survives as an orphan until the watchdog stops it.
    func testWatchdogStopsChildrenAfterTheAppIsKilled() throws {
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sh")
        app.arguments = ["-c", "sleep 300 & wait"]
        try app.run()
        let child = try waitForChild(of: app.processIdentifier)
        defer { kill(child, SIGKILL) }

        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", ChildProcessGuard.watchdogScript, "typstedit-watchdog", String(app.processIdentifier)]
        try watchdog.run()
        defer { watchdog.terminate() }

        Thread.sleep(forTimeInterval: 1.5) // the watchdog snapshots once a second
        kill(app.processIdentifier, SIGKILL)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(kill(child, 0), 0, "the child outlives a killed parent on its own")

        let deadline = Date().addingTimeInterval(5)
        while kill(child, 0) == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            _ = waitpid(child, nil, WNOHANG)
        }
        XCTAssertNotEqual(kill(child, 0), 0, "the watchdog must stop the orphan")
    }

    private func waitForChild(of parent: pid_t) throws -> pid_t {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let child = ChildProcessGuard.descendants(of: parent).first { return child }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw XCTSkip("child process did not start")
    }
}
