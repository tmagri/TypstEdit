import XCTest
@testable import TypstEdit

/// The Python tool's sudo tier: the elevation gate, the approval kind, the
/// askpass plumbing and the helper script itself.
///
/// Nothing here runs the real `sudo`. The plumbing is exercised through a
/// fake `sudo` executable that only reports what it received, and the
/// helper's AppleScript is compiled (not run), so no password dialog can
/// appear. `testInteractiveRealSudo` is the one exception: it runs only with
/// `TYPSTEDIT_INTERACTIVE_SUDO=1` and needs a person to type the password.
@MainActor
final class PythonSudoTests: XCTestCase {

    private var workDir: URL!
    private var executor: LocalToolExecutor!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PythonSudoTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        executor = LocalToolExecutor()
        executor.scope = .project(root: workDir)
        executor.pythonToolEnabled = true
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func requirePython() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("python3 unavailable")
        }
    }

    private func askpassDirectories() -> Set<String> {
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        return Set(names.filter { $0.hasPrefix("typstedit-askpass-") })
    }

    /// Runs `code` and records the approval kind the executor asked about.
    private func run(_ code: String, approve: Bool = true) async throws -> (output: String, kinds: [PendingApprovalKind]) {
        var kinds: [PendingApprovalKind] = []
        let output = try await executor.execute(toolName: "run", arguments: ["code": code]) { kind in
            kinds.append(kind)
            return approve
        }
        return (output, kinds)
    }

    private func elevationFlag(_ kind: PendingApprovalKind?) -> Bool? {
        if case .runPython(_, let wantsElevation)? = kind { return wantsElevation }
        return nil
    }

    /// A stand-in `sudo`: checks that it was called with `-A` and that
    /// SUDO_ASKPASS names an existing executable, then prints what it saw.
    private func makeFakeSudo() throws -> URL {
        let bin = workDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("sudo")
        try """
        #!/bin/sh
        if [ "$1" != "-A" ]; then echo "FAKE_SUDO no-A"; exit 2; fi
        if [ -z "$SUDO_ASKPASS" ]; then echo "FAKE_SUDO no-askpass"; exit 3; fi
        if [ ! -x "$SUDO_ASKPASS" ]; then echo "FAKE_SUDO askpass-not-executable"; exit 4; fi
        echo "FAKE_SUDO ok askpass=$SUDO_ASKPASS"
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        return fake
    }

    // MARK: - Detector

    func testDetectorFlagsEveryCommonElevationSpelling() {
        let flagged = [
            "os.system('sudo id')",
            "os.system('SUDO id')",
            "subprocess.run(['sudo', '-A', 'id'])",
            "subprocess.run(['/usr/bin/sudo', 'id'])",
            "subprocess.run(\"sudo\\tid\", shell=True)",
            "os.system('echo hi && sudo -A true')",
            "cmd = 'do shell script \"id\" with administrator privileges'",
            "cmd = 'with ADMINISTRATOR   privileges'",
            "cmd = '''with administrator\n privileges'''",
            "# this needs sudo\nprint(1)",
        ]
        for code in flagged {
            XCTAssertTrue(LocalToolExecutor.codeWantsElevation(code), "not flagged: \(code)")
        }
    }

    func testDetectorIgnoresLookalikes() {
        let plain = [
            "print('pseudo code')",
            "print('sudoku solver')",
            "print(os.environ.get('SUDO_USER'))",
            "open('/etc/sudoers.d/README').read()",
            "print('administrator')",
            "print('privileges')",
            "import subprocess; subprocess.run(['id'])",
        ]
        for code in plain {
            XCTAssertFalse(LocalToolExecutor.codeWantsElevation(code), "false positive: \(code)")
        }
    }

    // MARK: - Gate

    /// The opt-in is checked first: with sudo off the refusal is the same
    /// whatever the sandbox setting, and no approval card is shown.
    func testSudoOffRefusesBeforeApprovalInBothSandboxModes() async {
        executor.pythonSudoEnabled = false
        for sandbox in [true, false] {
            executor.pythonSandboxEnabled = sandbox
            var asked = false
            do {
                _ = try await executor.execute(toolName: "run", arguments: ["code": "import os; os.system('sudo id')"]) { _ in
                    asked = true
                    return true
                }
                XCTFail("sandbox=\(sandbox): expected a refusal")
            } catch LocalToolError.elevationDisabled {
                // expected
            } catch {
                XCTFail("sandbox=\(sandbox): expected elevationDisabled, got \(error)")
            }
            XCTAssertFalse(asked, "sandbox=\(sandbox): no approval card for a refused run")
        }
    }

    func testSudoOnWithSandboxRefusesBeforeApproval() async {
        executor.pythonSudoEnabled = true
        executor.pythonSandboxEnabled = true
        var asked = false
        do {
            _ = try await executor.execute(toolName: "run", arguments: ["code": "os.system('sudo id')"]) { _ in
                asked = true
                return true
            }
            XCTFail("expected a refusal")
        } catch LocalToolError.elevationBlockedBySandbox {
            // expected
        } catch {
            XCTFail("expected elevationBlockedBySandbox, got \(error)")
        }
        XCTAssertFalse(asked)
    }

    /// Turning sudo on must not change ordinary runs: a plain script still
    /// runs (sandboxed here) and is not marked as elevated.
    func testSudoOnLeavesOrdinarySandboxedRunsAlone() async throws {
        try requirePython()
        executor.pythonSudoEnabled = true
        executor.pythonSandboxEnabled = true
        let (output, kinds) = try await run("print('plain run')")
        XCTAssertTrue(output.contains("plain run"), output)
        XCTAssertTrue(output.contains("Sandboxed run"), output)
        XCTAssertFalse(output.contains("Elevated run"), output)
        XCTAssertEqual(elevationFlag(kinds.first), false)
    }

    func testApprovalKindCarriesTheElevationFlag() async throws {
        try requirePython()
        executor.pythonSudoEnabled = true
        executor.pythonSandboxEnabled = false

        let elevated = try await run("if False:\n    import os; os.system('sudo id')\nprint('x')")
        XCTAssertEqual(elevated.kinds.count, 1)
        XCTAssertEqual(elevationFlag(elevated.kinds.first), true)

        let plain = try await run("print('x')")
        XCTAssertEqual(elevationFlag(plain.kinds.first), false)
    }

    /// A denied elevated run never launches and leaves no helper on disk.
    func testDeniedElevatedRunLeavesNothingBehind() async throws {
        executor.pythonSudoEnabled = true
        executor.pythonSandboxEnabled = false
        let before = askpassDirectories()
        do {
            _ = try await run("import os; os.system('sudo id')", approve: false)
            XCTFail("expected approvalDenied")
        } catch LocalToolError.approvalDenied {
            // expected
        }
        XCTAssertEqual(askpassDirectories(), before, "a denied run must not write an askpass helper")
    }

    // MARK: - Plumbing (fake sudo)

    /// The full path a real `sudo -A` takes, up to the point where it would
    /// call the helper: the script sees SUDO_ASKPASS, the helper exists and
    /// is executable while the run is going on, and is gone afterwards.
    func testElevatedRunHandsAWorkingAskpassToSudoAndCleansUp() async throws {
        try requirePython()
        executor.pythonSudoEnabled = true
        executor.pythonSandboxEnabled = false
        let fake = try makeFakeSudo()
        let before = askpassDirectories()

        let code = """
        import subprocess
        r = subprocess.run([\(String(reflecting: fake.path)), '-A', 'id', '-u'], capture_output=True, text=True)
        print(r.stdout.strip())
        print('exit', r.returncode)
        """
        let (output, kinds) = try await run(code)

        XCTAssertEqual(elevationFlag(kinds.first), true)
        XCTAssertTrue(output.contains("FAKE_SUDO ok askpass="), output)
        XCTAssertTrue(output.contains("exit 0"), output)
        XCTAssertTrue(output.contains("Elevated run"), output)
        XCTAssertFalse(output.contains("Sandboxed run"), output)

        let askpassPath = output
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("FAKE_SUDO ok askpass=") }?
            .replacingOccurrences(of: "FAKE_SUDO ok askpass=", with: "")
        let path = try XCTUnwrap(askpassPath)
        XCTAssertTrue(path.hasSuffix("/askpass"), path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the helper must be deleted after the run")
        XCTAssertEqual(askpassDirectories(), before, "no askpass folder may linger")
    }

    /// An askpass inherited from the app's own environment must never reach
    /// an ordinary (unflagged) script: only the gate hands one out.
    func testInheritedAskpassIsScrubbedFromOrdinaryRuns() async throws {
        try requirePython()
        executor.pythonSudoEnabled = true
        executor.pythonSandboxEnabled = false
        let previous = ProcessInfo.processInfo.environment["SUDO_ASKPASS"]
        setenv("SUDO_ASKPASS", "/tmp/inherited-askpass", 1)
        defer {
            if let previous { setenv("SUDO_ASKPASS", previous, 1) } else { unsetenv("SUDO_ASKPASS") }
        }
        let (output, _) = try await run(#"import os; print(os.environ.get("SUDO_ASKPASS", "NONE"))"#)
        XCTAssertTrue(output.contains("NONE"), "inherited SUDO_ASKPASS leaked: \(output)")
    }

    // MARK: - Helper script

    func testAskpassScriptIsValidShell() throws {
        let script = LocalToolExecutor.askpassScript()
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"), "the shebang must be the first bytes: \(script.prefix(20).debugDescription)")

        let dir = try LocalToolExecutor.writeAskpassHelper()
        defer { try? FileManager.default.removeItem(at: dir) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", dir.appendingPathComponent("askpass").path]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "sh -n failed: \(err)")
    }

    /// Compiles (does not run) the AppleScript the helper passes to
    /// osascript, so a syntax slip is caught without a dialog appearing.
    func testAskpassAppleScriptCompiles() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/osacompile") else {
            throw XCTSkip("osacompile unavailable")
        }
        let script = LocalToolExecutor.askpassScript()
        let regex = try NSRegularExpression(pattern: #"-e '([^']*)'"#)
        let ns = script as NSString
        let statements = regex.matches(in: script, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        XCTAssertEqual(statements.count, 2, "expected the dialog and the result statements: \(statements)")
        XCTAssertTrue(statements.last == "text returned of result", "\(statements)")

        let output = workDir.appendingPathComponent("askpass.scpt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = statements.flatMap { ["-e", $0] } + ["-o", output.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "AppleScript does not compile: \(err)")
    }

    func testEachHelperIsFreshAndPrivate() throws {
        let a = try LocalToolExecutor.writeAskpassHelper()
        let b = try LocalToolExecutor.writeAskpassHelper()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        XCTAssertNotEqual(a, b, "every run needs its own helper folder")
        for dir in [a, b] {
            let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
            XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o700)
            XCTAssertEqual(attrs[.ownerAccountID] as? Int, Int(getuid()))
        }
    }

    // MARK: - Tool description

    func testToolDescriptionAdvertisesSudoOnlyWhenItCanWork() {
        func description(sudo: Bool, sandbox: Bool) -> String {
            executor.pythonSudoEnabled = sudo
            executor.pythonSandboxEnabled = sandbox
            return executor.toolDescriptors().first { $0.serverName == LocalToolExecutor.pythonNamespace && $0.name == "run" }?.description ?? ""
        }
        XCTAssertTrue(description(sudo: true, sandbox: false).contains("sudo -A"))
        XCTAssertTrue(description(sudo: true, sandbox: true).contains("unusable while the sandbox is on"))
        XCTAssertFalse(description(sudo: false, sandbox: false).contains("sudo"))
        XCTAssertFalse(description(sudo: false, sandbox: true).contains("sudo"))
    }

    // MARK: - Real sudo (manual)

    /// Runs the real `sudo -A` through the real helper. Opt-in only: a
    /// password dialog appears and a person must type the admin password.
    /// `-k` ignores cached credentials, so the dialog always shows.
    ///
    ///     TYPSTEDIT_INTERACTIVE_SUDO=1 swift test --filter PythonSudoTests/testInteractiveRealSudo
    func testInteractiveRealSudo() async throws {
        guard ProcessInfo.processInfo.environment["TYPSTEDIT_INTERACTIVE_SUDO"] == "1" else {
            throw XCTSkip("set TYPSTEDIT_INTERACTIVE_SUDO=1 to run (needs a person at the password dialog)")
        }
        try requirePython()
        executor.pythonSudoEnabled = true
        executor.pythonSandboxEnabled = false
        let code = """
        import subprocess
        r = subprocess.run(['sudo', '-k', '-A', '/usr/bin/id', '-u'], capture_output=True, text=True)
        print('uid', r.stdout.strip(), 'exit', r.returncode, r.stderr.strip())
        """
        let (output, _) = try await run(code)
        XCTAssertTrue(output.contains("uid 0 exit 0"), output)
    }
}
