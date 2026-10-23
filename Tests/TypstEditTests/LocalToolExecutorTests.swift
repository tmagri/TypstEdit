import XCTest
@testable import TypstEdit

/// Behavior of the built-in chat tools: paged reads, exact-match edits with the
/// read-before-edit invariant, case-insensitive grep, and the Python sandbox.
@MainActor
final class LocalToolExecutorTests: XCTestCase {

    private var workDir: URL!
    private var executor: LocalToolExecutor!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalToolExecutorTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        executor = LocalToolExecutor()
        executor.scope = .project(root: workDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Helpers

    private func write(_ name: String, _ text: String, encoding: String.Encoding = .utf8) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    private func read(_ path: String) throws -> String { try String(contentsOf: workDir.appendingPathComponent(path), encoding: .utf8) }

    @discardableResult
    private func run(_ tool: String, _ args: [String: Any], approve: Bool = true) async throws -> String {
        try await executor.execute(toolName: tool, arguments: args) { _ in approve }
    }

    private func assertThrows(_ expected: (LocalToolError) -> Bool,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected a LocalToolError", file: file, line: line)
        } catch let error as LocalToolError {
            XCTAssertTrue(expected(error), "unexpected error: \(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }
    }

    // MARK: - Reading

    func testSmallFileComesBackWholeWithoutPagingNoise() async throws {
        try write("small.typ", "= Title\n\nBody")
        let out = try await run("read_file", ["path": "small.typ"])
        XCTAssertEqual(out, "= Title\n\nBody")
    }

    func testLargeFileIsWindowedWithOffsetHeader() async throws {
        let lines = (1...900).map { "line \($0)" }.joined(separator: "\n")
        try write("big.typ", lines)

        let first = try await run("read_file", ["path": "big.typ"])
        XCTAssertTrue(first.hasPrefix("[lines 1-400 of 900 in 'big.typ']"), first.prefix(80).description)
        XCTAssertTrue(first.contains("call again with offset: 401"))
        XCTAssertTrue(first.contains("line 400"))
        XCTAssertFalse(first.contains("line 401"))

        let second = try await run("read_file", ["path": "big.typ", "offset": 401, "limit": 10])
        XCTAssertTrue(second.hasPrefix("[lines 401-410 of 900"), second.prefix(80).description)
        XCTAssertTrue(second.contains("line 410"))
    }

    func testOffsetPastEndExplainsInsteadOfCrashing() async throws {
        try write("short.typ", "a\nb")
        let out = try await run("read_file", ["path": "short.typ", "offset": 99])
        XCTAssertTrue(out.contains("only has 2 lines"), out)
    }

    func testFileOverRewriteLimitIsStillReadableAndEditable() async throws {
        // ~600 KB: above write_file's 300 KB diff cap, below the scan cap.
        let filler = String(repeating: "x", count: 90)
        let lines = (1...6_000).map { "\($0): \(filler)" }
        try write("huge.typ", lines.joined(separator: "\n"))

        let window = try await run("read_file", ["path": "huge.typ", "limit": 5])
        XCTAssertTrue(window.hasPrefix("[lines 1-5 of 6000 in 'huge.typ']"), window.prefix(60).description)

        _ = try await run("read_file", ["path": "huge.typ", "offset": 3_000, "limit": 1])
        let edited = try await run("edit_file", [
            "path": "huge.typ", "old_string": "3000: \(filler)", "new_string": "3000: CHANGED"
        ])
        XCTAssertTrue(edited.contains("1 place"), edited)
        XCTAssertTrue(try read("huge.typ").contains("3000: CHANGED"))

        // Whole-file rewrite of a file that big is refused with a hint.
        await assertThrows({ if case .fileTooLarge = $0 { return true }; return false }) {
            try await self.run("write_file", ["path": "huge.typ", "content": "gone"])
        }
    }

    // MARK: - Read-before-edit invariant

    func testEditRequiresPriorRead() async throws {
        try write("doc.typ", "alpha\nbeta\n")
        await assertThrows({ if case .fileNotReadYet = $0 { return true }; return false }) {
            try await self.run("edit_file", ["path": "doc.typ", "old_string": "alpha", "new_string": "gamma"])
        }
        XCTAssertEqual(try read("doc.typ"), "alpha\nbeta\n")
    }

    func testOverwritingExistingFileRequiresPriorRead() async throws {
        try write("doc.typ", "alpha")
        await assertThrows({ if case .fileNotReadYet = $0 { return true }; return false }) {
            try await self.run("write_file", ["path": "doc.typ", "content": "beta"])
        }
    }

    func testCreatingNewFileNeedsNoPriorRead() async throws {
        let out = try await run("write_file", ["path": "nested/new.typ", "content": "hello"])
        XCTAssertTrue(out.contains("Wrote"))
        XCTAssertEqual(try read("nested/new.typ"), "hello")
    }

    // MARK: - Editing

    func testAmbiguousEditIsRejected() async throws {
        try write("doc.typ", "same\nmiddle\nsame\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        await assertThrows({ if case .editAmbiguous(_, let count) = $0 { return count == 2 }; return false }) {
            try await self.run("edit_file", ["path": "doc.typ", "old_string": "same", "new_string": "other"])
        }
        XCTAssertEqual(try read("doc.typ"), "same\nmiddle\nsame\n")
    }

    func testReplaceAllEditsEveryOccurrence() async throws {
        try write("doc.typ", "same\nmiddle\nsame\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        _ = try await run("edit_file", [
            "path": "doc.typ", "old_string": "same", "new_string": "other", "replace_all": true
        ])
        XCTAssertEqual(try read("doc.typ"), "other\nmiddle\nother\n")
    }

    func testUniqueEditAppliesAndIsApprovedWithSnippet() async throws {
        try write("doc.typ", "one\ntwo\nthree\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        var seen: PendingApprovalKind?
        let out = try await executor.execute(toolName: "edit_file", arguments: [
            "path": "doc.typ", "old_string": "two", "new_string": "TWO!"
        ]) { kind in
            seen = kind
            return true
        }

        XCTAssertEqual(try read("doc.typ"), "one\nTWO!\nthree\n")
        XCTAssertTrue(out.contains("1 place"))
        guard case .fileEdit(let path, let old, let new, let occurrences)? = seen else {
            return XCTFail("expected a .fileEdit approval, got \(String(describing: seen))")
        }
        XCTAssertEqual(path, "doc.typ")
        XCTAssertEqual(old, "two")
        XCTAssertEqual(new, "TWO!")
        XCTAssertEqual(occurrences, 1)
    }

    func testDeniedEditLeavesFileUntouched() async throws {
        try write("doc.typ", "one\ntwo\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        await assertThrows({ if case .approvalDenied = $0 { return true }; return false }) {
            try await self.run("edit_file", ["path": "doc.typ", "old_string": "two", "new_string": "2"], approve: false)
        }
        XCTAssertEqual(try read("doc.typ"), "one\ntwo\n")
    }

    func testEditPreservesCRLFLineEndings() async throws {
        let url = workDir.appendingPathComponent("crlf.typ")
        try Data("one\r\ntwo\r\nthree\r\n".utf8).write(to: url)

        _ = try await run("read_file", ["path": "crlf.typ"])
        _ = try await run("edit_file", ["path": "crlf.typ", "old_string": "one\ntwo", "new_string": "one\n2"])

        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "one\r\n2\r\nthree\r\n")
    }

    func testEditMissingTextNamesTheToolAndHints() async throws {
        try write("doc.typ", "alpha\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        await assertThrows({ if case .editNoMatch = $0 { return true }; return false }) {
            try await self.run("edit_file", ["path": "doc.typ", "old_string": "nope", "new_string": "x"])
        }
    }

    func testFileChangedSinceReadIsDetected() async throws {
        let url = try write("doc.typ", "alpha\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        // Simulate the user saving an edit behind the chat's back.
        try "alpha changed\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)

        await assertThrows({ if case .fileChangedSinceRead = $0 { return true }; return false }) {
            try await self.run("edit_file", ["path": "doc.typ", "old_string": "alpha", "new_string": "x"])
        }
    }

    func testNewMessageResetsReadTracking() async throws {
        try write("doc.typ", "alpha\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        executor.beginRequest()
        await assertThrows({ if case .fileNotReadYet = $0 { return true }; return false }) {
            try await self.run("edit_file", ["path": "doc.typ", "old_string": "alpha", "new_string": "x"])
        }
    }

    // MARK: - Grep

    func testGrepIsCaseInsensitiveByDefault() async throws {
        try write("a.typ", "The Mug is White\nother\n")
        try write("sub/b.md", "another mug line\n")

        let out = try await run("grep_project", ["pattern": "mug"])
        XCTAssertTrue(out.contains("a.typ:1:"), out)
        XCTAssertTrue(out.contains("sub/b.md:1:"), out)
    }

    func testGrepCaseSensitiveOptInExcludesDifferentCase() async throws {
        try write("a.typ", "The Mug is White\nmug here\n")
        let out = try await run("grep_project", ["pattern": "mug", "case_sensitive": true])
        XCTAssertFalse(out.contains("The Mug"), out)
        XCTAssertTrue(out.contains("mug here"), out)
    }

    func testGrepLiteralTreatsRegexCharactersLiterally() async throws {
        try write("a.typ", "cost: $12.50 (net)\nplain line\n")
        let out = try await run("grep_project", ["pattern": "$12.50 (net)", "literal": true])
        XCTAssertTrue(out.contains("cost: $12.50 (net)"), out)
    }

    func testGrepGlobFiltersFiles() async throws {
        try write("a.typ", "target\n")
        try write("b.md", "target\n")
        let out = try await run("grep_project", ["pattern": "target", "glob": "*.typ"])
        XCTAssertTrue(out.contains("a.typ"), out)
        XCTAssertFalse(out.contains("b.md"), out)
    }

    func testGrepSkipsExcludedDirectories() async throws {
        try write("visible.typ", "needle\n")
        try write("backups/old.typ", "needle\n")
        let out = try await run("grep_project", ["pattern": "needle"])
        XCTAssertTrue(out.contains("visible.typ"), out)
        XCTAssertFalse(out.contains("backups"), out)
    }

    func testGrepInvalidRegexReportsIt() async throws {
        await assertThrows({ if case .invalidArguments = $0 { return true }; return false }) {
            try await self.run("grep_project", ["pattern": "("])
        }
    }

    // MARK: - Markdown → Typst conversion

    func testConvertMarkdownToTypstUsesTheSharedConverter() async throws {
        let out = try await run("convert_markdown_to_typst", ["markdown": "**bold** and *italic*"])
        XCTAssertEqual(out, AICompletionService.shared.sanitizeMarkdownToTypst("**bold** and *italic*"))
        XCTAssertTrue(out.contains("bold"))
    }

    func testConvertMarkdownToTypstRequiresNonEmptyInput() async throws {
        let out = try await run("convert_markdown_to_typst", ["markdown": ""])
        XCTAssertTrue(out.contains("markdown is required"), out)
    }

    // MARK: - Typst check

    private func requireTypst() throws -> String {
        guard let path = TypstUpdater.shared.resolveActiveTypstPath() else {
            throw XCTSkip("No typst binary available on this machine.")
        }
        return path
    }

    func testRunTypstCheckRequiresSourceOrPath() async throws {
        let out = try await run("run_typst_check", [:])
        XCTAssertTrue(out.contains("Provide either"), out)
    }

    func testRunTypstCheckOnGoodSourceCompiles() async throws {
        _ = try requireTypst()
        let out = try await run("run_typst_check", ["source": "= Hello\n\nWorld"])
        XCTAssertTrue(out.contains("Compiled successfully"), out)
    }

    func testRunTypstCheckOnBadSourceReportsTheCompilerError() async throws {
        _ = try requireTypst()
        let out = try await run("run_typst_check", ["source": "#undefinedFunctionCall()"])
        XCTAssertTrue(out.contains("Compile failed"), out)
    }

    func testRunTypstCheckWithPathCompilesTheRealFileInPlace() async throws {
        _ = try requireTypst()
        try write("doc.typ", "= Title\n\nBody text")
        let out = try await run("run_typst_check", ["path": "doc.typ"])
        XCTAssertTrue(out.contains("Compiled successfully"), out)
    }

    func testRunTypstCheckWithMissingPathReportsNotFound() async throws {
        _ = try requireTypst()
        let out = try await run("run_typst_check", ["path": "nope.typ"])
        XCTAssertTrue(out.contains("File not found"), out)
    }

    // MARK: - Automatic post-edit validation

    func testEditFileAppendsPassingValidationNote() async throws {
        _ = try requireTypst()
        try write("doc.typ", "= Title\n\nalpha\n")
        _ = try await run("read_file", ["path": "doc.typ"])
        let out = try await run("edit_file", ["path": "doc.typ", "old_string": "alpha", "new_string": "beta"])
        XCTAssertTrue(out.contains("Typst check: compiles cleanly"), out)
    }

    func testWriteFileAppendsFailingValidationNoteWithoutThrowing() async throws {
        _ = try requireTypst()
        let out = try await run("write_file", ["path": "broken.typ", "content": "#undefinedFunctionCall()"])
        XCTAssertTrue(out.contains("Wrote"), out)
        XCTAssertTrue(out.contains("⚠️ Typst check"), out)
        XCTAssertTrue(out.contains("Compile failed"), out)
        // Advisory only — the file is still written even though it doesn't compile.
        XCTAssertEqual(try read("broken.typ"), "#undefinedFunctionCall()")
    }

    func testValidationNoteIsSkippedWhenDisabled() async throws {
        _ = try requireTypst()
        executor.autoValidateTypstEdits = false
        let out = try await run("write_file", ["path": "untouched.typ", "content": "#undefinedFunctionCall()"])
        XCTAssertFalse(out.contains("Typst check"), out)
    }

    func testValidationNoteIsSkippedForNonTypFiles() async throws {
        _ = try requireTypst()
        let out = try await run("write_file", ["path": "notes.md", "content": "# Just markdown"])
        XCTAssertFalse(out.contains("Typst check"), out)
    }

    // MARK: - Prompt shaping / plan round-trip

    func testBuildPromptExcludesCompactedAndToolCalls() {
        let history = [
            ChatMessage(role: .user, text: "old question", isCompacted: true),
            ChatMessage(role: .assistant, text: "old answer", isCompacted: true),
            ChatMessage(role: .assistant, text: "[Summary of earlier conversation]\n\nThey wanted X.", isSummary: true),
            ChatMessage(role: .user, text: "new question"),
            ChatMessage(role: .toolCall, toolName: "project__read_file", toolStatus: .succeeded)
        ]
        let prompt = AIChatManager.buildPrompt(history: history, userText: "follow up")

        XCTAssertFalse(prompt.contains("old question"))
        XCTAssertFalse(prompt.contains("old answer"))
        XCTAssertFalse(prompt.contains("project__read_file"))
        XCTAssertTrue(prompt.contains("They wanted X."))
        XCTAssertTrue(prompt.contains("User: new question"))
        XCTAssertTrue(prompt.hasSuffix("User: follow up"))
    }

    func testPlanIsRebuiltFromTranscript() {
        let args = #"{"items":[{"content":"Read the file","status":"completed"},{"content":"Rewrite section 2","status":"in_progress"}]}"#
        let messages = [
            ChatMessage(role: .user, text: "do it"),
            ChatMessage(role: .toolCall, toolName: "agent__update_plan", toolArgumentsJSON: args, toolStatus: .succeeded)
        ]
        let plan = AgentHarnessTools.plan(from: messages)
        XCTAssertEqual(plan.map(\.content), ["Read the file", "Rewrite section 2"])
        XCTAssertEqual(plan.map(\.status), [.completed, .inProgress])
    }

    // MARK: - Python sandbox

    func testSandboxedPythonCanWriteScratchButNotTheProject() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw XCTSkip("python3 or sandbox-exec unavailable")
        }
        executor.pythonToolEnabled = true
        executor.pythonSandboxEnabled = true

        let projectPath = workDir.path
        let code = """
        import os
        open(os.path.join(os.environ["TMPDIR"], "ok.txt"), "w").write("ok")
        print("SCRATCH_OK")
        try:
            open("\(projectPath)/bad.txt", "w").write("bad")
            print("PROJECT_WRITE_ALLOWED")
        except Exception:
            print("PROJECT_WRITE_DENIED")
        """
        let out = try await run("run", ["code": code])
        XCTAssertTrue(out.contains("SCRATCH_OK"), out)
        XCTAssertTrue(out.contains("PROJECT_WRITE_DENIED"), out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.appendingPathComponent("bad.txt").path))
    }
}
