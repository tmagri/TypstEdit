import XCTest
@testable import TypstEdit

/// The Python pane's pure decisions: which files get a terminal, the exact
/// command "Run" types, and the environment the shell starts with.
@MainActor
final class PythonTerminalTests: XCTestCase {

    // MARK: - File classification

    func testPythonFilesGetTheTerminalPane() {
        for name in ["main.py", "gui.pyw", "stubs.pyi", "fast.pyx", "UPPER.PY"] {
            XCTAssertTrue(EditorFileTypes.isPythonFile(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["doc.typ", "README.md", "data.json", "script.sh", "py"] {
            XCTAssertFalse(EditorFileTypes.isPythonFile(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    func testPythonExtensionsStillHighlightAsPython() {
        for ext in EditorFileTypes.pythonExtensions {
            XCTAssertEqual(EditorFileTypes.displayName(for: URL(fileURLWithPath: "/tmp/a.\(ext)")), "Python", ext)
        }
    }

    // MARK: - Run command

    func testShellQuotingSurvivesSpacesQuotesAndUnicode() {
        XCTAssertEqual(PythonTerminalModel.shellQuoted("plain"), "'plain'")
        XCTAssertEqual(PythonTerminalModel.shellQuoted("with space"), "'with space'")
        XCTAssertEqual(PythonTerminalModel.shellQuoted("it's"), "'it'\\''s'")
        XCTAssertEqual(PythonTerminalModel.shellQuoted("$(rm -rf ~)"), "'$(rm -rf ~)'")
        XCTAssertEqual(PythonTerminalModel.shellQuoted("café/π.py"), "'café/π.py'")
    }

    func testRunCommandQuotesThePathAndEndsOptions() {
        let url = URL(fileURLWithPath: "/Users/me/My Project/-odd name's.py")
        XCTAssertEqual(
            PythonTerminalModel.runCommand(for: url),
            "python3 -- '/Users/me/My Project/-odd name'\\''s.py'"
        )
    }

    /// The quoted command must round-trip through a real shell unchanged.
    func testRunCommandRoundTripsThroughShell() throws {
        let path = "/tmp/a b/it's $HOME `x` \"q\".py"
        let quoted = PythonTerminalModel.shellQuoted(path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(quoted)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertEqual(output, path)
    }

    // MARK: - Environment

    func testEnvironmentSetsTerminalVariablesAndKeepsPath() {
        let env = environmentDictionary(base: ["PATH": "/custom/bin", "HOME": "/Users/me", "TERM": "dumb"])
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["HOME"], "/Users/me")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        let path = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        XCTAssertTrue(path.contains("/custom/bin"))
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/bin"))
    }

    func testEnvironmentKeepsAnExistingLanguage() {
        let env = environmentDictionary(base: ["LANG": "de_DE.UTF-8"])
        XCTAssertEqual(env["LANG"], "de_DE.UTF-8")
    }

    func testEnvironmentDoesNotDuplicatePathEntries() {
        let env = environmentDictionary(base: ["PATH": "/usr/bin:/bin"])
        let path = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        XCTAssertEqual(path.filter { $0 == "/usr/bin" }.count, 1)
        XCTAssertEqual(path.filter { $0 == "/bin" }.count, 1)
    }

    func testShellFallsBackToZshWhenShellIsMissing() {
        XCTAssertEqual(PythonTerminalModel.shellPath(base: [:]), "/bin/zsh")
        XCTAssertEqual(PythonTerminalModel.shellPath(base: ["SHELL": "/no/such/shell"]), "/bin/zsh")
        XCTAssertEqual(PythonTerminalModel.shellPath(base: ["SHELL": "/bin/bash"]), "/bin/bash")
    }

    // MARK: - Edit menu routing

    /// With the terminal focused, the Edit menu must not fall back to the
    /// document editor (that copied or pasted into the Python file instead).
    func testEditCommandsGoToAFocusedTerminalNotTheEditor() {
        let terminal = PythonTerminal(onEnd: {})
        for command in ["copy", "paste", "selectAll", "cut", "delete"] {
            var fellBack = false
            NativeEditingCommand.route(command, to: terminal, terminal: terminal) { _ in fellBack = true }
            XCTAssertFalse(fellBack, command)
        }
    }

    func testAppSpecificCommandsStillReachTheDocumentWindow() {
        let terminal = PythonTerminal(onEnd: {})
        var fellBack: String?
        NativeEditingCommand.route("copyAsMarkdown", to: terminal, terminal: terminal) { fellBack = $0 }
        XCTAssertEqual(fellBack, "copyAsMarkdown")
    }

    // MARK: - Helpers

    private func environmentDictionary(base: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in PythonTerminalModel.environment(base: base) {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }
}
