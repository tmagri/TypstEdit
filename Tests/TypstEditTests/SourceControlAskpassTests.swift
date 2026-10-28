import XCTest
@testable import TypstEdit

/// Askpass script generation (no dialog is ever shown), environment wiring,
/// network timeouts and cancellation.
@MainActor
final class SourceControlAskpassTests: XCTestCase {

    private let ws = GitTestWorkspace()
    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        ws.cleanup()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceControlAskpassTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// Synchronous process helper for validating the generated script.
    private func runProcess(_ path: String, _ arguments: [String]) throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Script body

    func testScriptBodyIsPromptSafeAndArgvDriven() throws {
        let body = GitAskpass.scriptBody()
        XCTAssertTrue(body.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(body.contains("/usr/bin/osascript"), "uses osascript")
        XCTAssertTrue(body.contains("item 1 of argv"), "the prompt is passed as an osascript argument")
        XCTAssertTrue(body.contains("\"$PROMPT\""), "the prompt is passed as a shell argument, never interpolated")
        XCTAssertTrue(body.contains("with hidden answer"), "password/passphrase prompts hide the answer")
        XCTAssertTrue(body.contains("*[Pp]assword*"), "password prompts are detected")
        XCTAssertTrue(body.contains("*[Pp]assphrase*"), "passphrase prompts are detected")
        XCTAssertTrue(body.contains("yes/no"), "host key prompts get yes/no buttons")
        XCTAssertTrue(body.contains("exit 1"), "cancelling the dialog exits 1")
        XCTAssertFalse(body.contains("%@"), "no format-string interpolation")
        XCTAssertFalse(body.contains("display dialog \""), "the prompt must not be embedded in the AppleScript source")
        XCTAssertFalse(body.contains(">>"), "never redirects output to a file")
        XCTAssertFalse(body.lowercased().contains("echo \"$PROMPT\""), "never echoes the prompt")
    }

    func testScriptBodyPassesShellSyntaxCheck() throws {
        let dir = try makeTempDir()
        let script = dir.appendingPathComponent("askpass.sh")
        try GitAskpass.scriptBody().write(to: script, atomically: true, encoding: .utf8)
        // `sh -n` validates syntax without executing anything.
        let result = try runProcess("/bin/sh", ["-n", script.path])
        XCTAssertEqual(result.code, 0, "script must be syntactically valid sh: \(result.output)")
    }

    func testScriptBodyWritesPromptHeartbeatBesideItself() throws {
        let body = GitAskpass.scriptBody()
        XCTAssertTrue(body.contains("askpass-activity"), "the script records prompt activity so the timeout can restart")
        XCTAssertTrue(body.contains("${0%/*}"), "the heartbeat is written next to the script itself")
        // The heartbeat contains only the script's pid — never the prompt or answer.
        XCTAssertFalse(body.contains("> \"$PROMPT\""))
        XCTAssertFalse(body.contains(">>"), "never redirects output to a file")
    }

    func testActivityFileURLLivesBesideTheScript() {
        let script = URL(fileURLWithPath: "/tmp/example-dir/askpass.sh")
        XCTAssertEqual(
            GitAskpass.activityFileURL(forScript: script),
            URL(fileURLWithPath: "/tmp/example-dir/askpass-activity")
        )
    }

    func testInstallCreatesUniqueExecutableScriptWithSafePermissions() throws {
        let first = try XCTUnwrap(GitAskpass.installAskpassScript())
        let second = try XCTUnwrap(GitAskpass.installAskpassScript())
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        XCTAssertNotEqual(first.path, second.path, "each install gets a unique location")
        for url in [first, second] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            XCTAssertEqual(permissions & 0o777, 0o700, "script permissions must be 0700")
            let directory = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            let directoryPermissions = (directory[.posixPermissions] as? NSNumber)?.intValue ?? -1
            XCTAssertEqual(directoryPermissions & 0o777, 0o700, "directory permissions must be 0700")
            let content = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(content, GitAskpass.scriptBody())
        }
    }

    func testEnvironmentPointsGitAndSshAtTheScript() {
        let script = URL(fileURLWithPath: "/tmp/example-askpass.sh")
        let environment = GitAskpass.environment(for: script)
        XCTAssertEqual(environment["GIT_ASKPASS"], script.path)
        XCTAssertEqual(environment["SSH_ASKPASS"], script.path)
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(environment.count, 3)
    }

    // MARK: Dialogs are impossible in tests

    func testTestEnvironmentCannotShowAnyDialog() async throws {
        // The shared test runner points git and ssh askpass at /usr/bin/false.
        XCTAssertEqual(GitTestWorkspace.isolatedEnvironment["GIT_ASKPASS"], "/usr/bin/false")
        XCTAssertEqual(GitTestWorkspace.isolatedEnvironment["SSH_ASKPASS"], "/usr/bin/false")
        XCTAssertEqual(GitTestWorkspace.isolatedEnvironment["SSH_ASKPASS_REQUIRE"], "never")

        let repo = try await ws.makeRepo()
        let manager = await ws.makeManager(root: repo)
        XCTAssertFalse(manager.isAskpassEnabled)
        let network = manager.makeNetworkGit()
        // With dialogs disabled the manager adds nothing, so the test's
        // /usr/bin/false overrides stay in charge: any prompt fails instead
        // of showing a dialog.
        XCTAssertEqual(network.runner.environmentOverrides["GIT_ASKPASS"], "/usr/bin/false")
        XCTAssertEqual(network.runner.environmentOverrides["SSH_ASKPASS"], "/usr/bin/false")
        XCTAssertEqual(network.runner.environmentOverrides["SSH_ASKPASS_REQUIRE"], "never")
    }

    func testManagerWithAskpassEnabledPointsAtGeneratedScript() async throws {
        let repo = try await ws.makeRepo()
        let manager = SourceControlManager(runner: ws.runner)
        manager.isAskpassEnabled = true
        await manager.setProjectRoot(repo)
        let network = manager.makeNetworkGit()
        let scriptPath = try XCTUnwrap(network.runner.environmentOverrides["GIT_ASKPASS"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scriptPath))
        XCTAssertEqual(network.runner.environmentOverrides["SSH_ASKPASS"], scriptPath)
        XCTAssertEqual(network.runner.environmentOverrides["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(network.timeout, 300, accuracy: 0.01)
        XCTAssertNotEqual(scriptPath, "/usr/bin/false")
        // The runner watches the askpass heartbeat so the timeout pauses
        // while a credential dialog is open.
        let activityPath = try XCTUnwrap(network.askpassActivityURL?.path)
        XCTAssertTrue(activityPath.hasSuffix("/askpass-activity"))
        XCTAssertTrue(activityPath.hasPrefix((scriptPath as NSString).deletingLastPathComponent))
    }

    // MARK: Network timeout

    func testNetworkRunnerTimesOutAndKillsProcess() async throws {
        let dir = try makeTempDir()
        let slow = dir.appendingPathComponent("slow.sh")
        try "#!/bin/sh\n/bin/sleep 30 >/dev/null 2>&1\nexit 0\n"
            .write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)

        let network = NetworkGitRunner(runner: GitRunner(executableURL: slow), timeout: 0.5)
        let start = Date()
        do {
            _ = try await network.run([], in: dir)
            XCTFail("expected a timeout error")
        } catch let error as GitError {
            guard case .timedOut(let seconds) = error else { throw error }
            XCTAssertEqual(seconds, 1)
            XCTAssertEqual(
                error.localizedDescription,
                "The network operation did not finish within 1 second and was cancelled."
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "the hung process is killed, not awaited")
    }

    /// A script that outlives the timeout but receives askpass heartbeats (as
    /// the credential dialog would) must finish: every touch restarts the
    /// countdown. The test touches the heartbeat itself, so the result does
    /// not depend on how precisely the machine can sleep.
    func testNetworkTimeoutRestartsWhileAskpassHeartbeatIsTouched() async throws {
        let dir = try makeTempDir()
        let activity = dir.appendingPathComponent("askpass-activity")
        let done = dir.appendingPathComponent("done")
        let slow = dir.appendingPathComponent("slow-with-heartbeat.sh")
        // Runs until the test creates `done`, well past the 2 s timeout.
        try """
        #!/bin/sh
        while [ ! -f "\(done.path)" ]; do /bin/sleep 0.05; done
        exit 0
        """
            .write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)

        let network = NetworkGitRunner(
            runner: GitRunner(executableURL: slow),
            timeout: 2.0,
            askpassActivityURL: activity
        )
        let start = Date()
        let runTask = Task {
            try await network.run([], in: dir)
        }
        // 12 touches x 0.25 s = ~3 s of dialog time, past the 2 s deadline.
        // A gap would have to exceed 2 s for this test to fail spuriously.
        for touch in 0..<12 {
            try Data("\(touch)\n".utf8).write(to: activity)
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        try Data().write(to: done)
        let result = try await runTask.value
        XCTAssertEqual(result.exitCode, 0, "the heartbeat restarts the timeout, so the command completes")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 2.0, "the script really ran past the original deadline")
        XCTAssertLessThan(elapsed, 20)
    }

    /// The same long script without a watched heartbeat still times out.
    func testNetworkTimeoutStillAppliesWithoutHeartbeat() async throws {
        let dir = try makeTempDir()
        let slow = dir.appendingPathComponent("slow-without-heartbeat.sh")
        try "#!/bin/sh\n/bin/sleep 5\nexit 0\n"
            .write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)

        let network = NetworkGitRunner(
            runner: GitRunner(executableURL: slow),
            timeout: 1.0,
            askpassActivityURL: dir.appendingPathComponent("askpass-activity")
        )
        let start = Date()
        do {
            _ = try await network.run([], in: dir)
            XCTFail("expected a timeout error")
        } catch let error as GitError {
            guard case .timedOut = error else { throw error }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4, "the hung process is killed at the deadline")
    }

    // MARK: Cancellation

    func testCancelCurrentOperationCancelsRunningOperation() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("x", to: "a.typ", in: repo)
        let manager = await ws.makeManager(root: repo)

        let start = Date()
        let task = Task {
            _ = await manager.perform(label: "Waiting…", touchesWorkingTree: false) { _, _ in
                while true {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(manager.isBusy)
        XCTAssertEqual(manager.currentOperation, "Waiting…")

        manager.cancelCurrentOperation()
        _ = await task.value
        XCTAssertFalse(manager.isBusy)
        XCTAssertNil(manager.currentOperation)
        XCTAssertNil(manager.errorMessage)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)

        // The manager is usable again afterwards.
        let ok = await manager.perform(label: "Quick…", touchesWorkingTree: false) { root, runner in
            _ = try await runner.run(["rev-parse", "--show-toplevel"], in: root)
        }
        XCTAssertTrue(ok)
    }
}
