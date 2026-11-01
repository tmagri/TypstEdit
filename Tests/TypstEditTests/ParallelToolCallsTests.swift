import XCTest
@testable import TypstEdit

/// Concurrent read-only tool calls: which calls are eligible, that the work
/// really overlaps rather than queueing on the main actor, and that the
/// read-before-edit ledger ends up the same as a sequential round.
@MainActor
final class ParallelToolCallsTests: XCTestCase {

    private var workDir: URL!
    private var executor: LocalToolExecutor!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParallelToolCallsTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        executor = LocalToolExecutor()
        executor.scope = .project(root: workDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    @discardableResult
    private func write(_ name: String, _ text: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Eligibility

    func testOnlyReadOnlyProjectToolsAreEligible() {
        XCTAssertTrue(ParallelToolCalls.isSafe("project__read_file"))
        XCTAssertTrue(ParallelToolCalls.isSafe("project__grep_project"))
        XCTAssertTrue(ParallelToolCalls.isSafe("project__read_skill_file"))
    }

    func testWritersAndApprovalToolsAreNotEligible() {
        // A parallel write batch would make the transcript order and the
        // approval order non-deterministic.
        for name in ["project__edit_file", "project__write_file", "project__apply_patch",
                     "project__move_lines", "project__export_document", "project__copy_files",
                     "project__create_folder", "python__run"] {
            XCTAssertFalse(ParallelToolCalls.isSafe(name), "\(name) must not be batched")
        }
        // web_fetch is a read, but every call raises an approval prompt — a
        // blocking interaction, not work that benefits from overlapping.
        XCTAssertFalse(ParallelToolCalls.isSafe("project__web_fetch"))
        // search_project needs the main-actor RAG index.
        XCTAssertFalse(ParallelToolCalls.isSafe("project__search_project"))
        // run_typst_check writes a temp file and loads the CPU.
        XCTAssertFalse(ParallelToolCalls.isSafe("project__run_typst_check"))
    }

    func testMCPAndAgentToolsAreNeverEligible() {
        // Another server's tools may hold a lock or share one connection.
        XCTAssertFalse(ParallelToolCalls.isSafe("github__search_code"))
        XCTAssertFalse(ParallelToolCalls.isSafe("agent__update_plan"))
        XCTAssertFalse(ParallelToolCalls.isSafe("agent__delegate_task"))
        XCTAssertFalse(ParallelToolCalls.isSafe("git__git_status"))
    }

    // MARK: - Grouping

    func testConsecutiveSafeCallsFormOneGroup() {
        let groups = ParallelToolCalls.groups(for: [
            "project__read_file", "project__read_file", "project__grep_project"
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].indices, [0, 1, 2])
        XCTAssertTrue(groups[0].isParallel)
    }

    func testAWriterSplitsTheRoundAndKeepsOrder() {
        // The write must not overtake the read before it, nor the read after.
        let groups = ParallelToolCalls.groups(for: [
            "project__read_file", "project__edit_file", "project__read_file", "project__read_file"
        ])
        XCTAssertEqual(groups.map(\.indices), [[0], [1], [2, 3]])
        XCTAssertFalse(groups[0].isParallel)
        XCTAssertFalse(groups[1].isParallel)
        XCTAssertTrue(groups[2].isParallel)
    }

    func testASingleSafeCallIsNotTreatedAsParallel() {
        let groups = ParallelToolCalls.groups(for: ["project__read_file"])
        XCTAssertEqual(groups.count, 1)
        XCTAssertFalse(groups[0].isParallel)
    }

    func testEmptyRoundProducesNoGroups() {
        XCTAssertTrue(ParallelToolCalls.groups(for: []).isEmpty)
    }

    // MARK: - Planning

    func testReadFilePlanResolvesInsideTheScope() throws {
        try write("doc.typ", "hello\n")
        let plan = try executor.readOnlyPlan(toolName: "read_file", arguments: ["path": "doc.typ"])
        guard case .readFile(let url, let label, _, _, let outline, _, _, _)? = plan else {
            return XCTFail("expected a readFile plan, got \(String(describing: plan))")
        }
        XCTAssertEqual(label, "doc.typ")
        XCTAssertFalse(outline)
        XCTAssertTrue(url.path.hasPrefix(workDir.path))
    }

    func testPlanRefusesAPathOutsideTheScope() {
        // The security boundary is shared with the sequential path, so this
        // must fail at plan time rather than inside a task group.
        XCTAssertThrowsError(try executor.readOnlyPlan(
            toolName: "read_file",
            arguments: ["path": "../../etc/passwd"]
        )) { error in
            guard case LocalToolError.pathEscapesScope = error else {
                return XCTFail("expected .pathEscapesScope, got \(error)")
            }
        }
    }

    func testPlanRejectsAnInvalidRegexUpFront() {
        XCTAssertThrowsError(try executor.readOnlyPlan(
            toolName: "grep_project",
            arguments: ["pattern": "[unterminated"]
        )) { error in
            guard case LocalToolError.invalidArguments = error else {
                return XCTFail("expected .invalidArguments, got \(error)")
            }
        }
    }

    func testUnbatchableToolsPlanToNil() throws {
        XCTAssertNil(try executor.readOnlyPlan(toolName: "write_file", arguments: ["path": "a", "content": "b"]))
        XCTAssertNil(try executor.readOnlyPlan(toolName: "web_fetch", arguments: ["url": "https://example.com"]))
        XCTAssertNil(try executor.readOnlyPlan(toolName: "run_typst_check", arguments: ["source": "x"]))
    }

    // MARK: - Running the batch

    func testBatchReadsEveryFileAndKeepsResultsKeyedByIndex() async throws {
        for index in 1...4 {
            try write("file\(index).typ", "contents of \(index)\n")
        }
        let plans: [(index: Int, plan: ReadOnlyToolPlan)] = try (1...4).map { index in
            let plan = try XCTUnwrap(executor.readOnlyPlan(
                toolName: "read_file",
                arguments: ["path": "file\(index).typ"]
            ))
            // Deliberately non-contiguous indices: the caller's numbering is
            // the round's position, which a batch need not start at zero.
            return (index * 10, plan)
        }

        let results = await executor.runReadOnlyBatch(plans)
        XCTAssertEqual(results.count, 4)
        for index in 1...4 {
            guard case .success(let outcome)? = results[index * 10] else {
                return XCTFail("missing result for index \(index * 10)")
            }
            XCTAssertTrue(outcome.output.contains("contents of \(index)"), outcome.output)
        }
    }

    func testBatchSatisfiesReadBeforeEditForEveryFile() async throws {
        try write("a.typ", "alpha\n")
        try write("b.typ", "beta\n")
        let plans: [(index: Int, plan: ReadOnlyToolPlan)] = try ["a.typ", "b.typ"].enumerated().map {
            ($0.offset, try XCTUnwrap(executor.readOnlyPlan(toolName: "read_file", arguments: ["path": $0.element])))
        }

        _ = await executor.runReadOnlyBatch(plans)

        // Both files must now be editable without a fresh read — the ledger
        // the batch wrote back is what makes the concurrent path equivalent
        // to a sequential one.
        let edited = try await executor.execute(
            toolName: "edit_file",
            arguments: ["path": "a.typ", "old_string": "alpha", "new_string": "ALPHA"]
        ) { _ in true }
        XCTAssertTrue(edited.contains("1 place"), edited)

        let second = try await executor.execute(
            toolName: "edit_file",
            arguments: ["path": "b.typ", "old_string": "beta", "new_string": "BETA"]
        ) { _ in true }
        XCTAssertTrue(second.contains("1 place"), second)
    }

    func testAnOutlineReadDoesNotSatisfyReadBeforeEdit() async throws {
        try write("doc.typ", "= Heading\nbody\n")
        let plan = try XCTUnwrap(executor.readOnlyPlan(
            toolName: "read_file",
            arguments: ["path": "doc.typ", "outline": true]
        ))
        _ = await executor.runReadOnlyBatch([(0, plan)])

        // An outline shows structure, not the exact text an edit must match.
        do {
            _ = try await executor.execute(
                toolName: "edit_file",
                arguments: ["path": "doc.typ", "old_string": "body", "new_string": "x"]
            ) { _ in true }
            XCTFail("an outline must not satisfy read-before-edit")
        } catch let error as LocalToolError {
            guard case .fileNotReadYet = error else {
                return XCTFail("expected .fileNotReadYet, got \(error)")
            }
        }
    }

    func testOneFailingReadDoesNotDiscardTheOthers() async throws {
        try write("real.typ", "here\n")
        let good = try XCTUnwrap(executor.readOnlyPlan(toolName: "read_file", arguments: ["path": "real.typ"]))
        // A file that exists at plan time but not at read time: the plan is
        // valid, the read fails.
        let missingURL = workDir.appendingPathComponent("ghost.typ")
        let bad = ReadOnlyToolPlan.readFile(
            url: missingURL,
            label: "ghost.typ",
            offset: nil, limit: nil, outline: false,
            maxBytes: 1_000_000, defaultLineLimit: 400, maxLineLimit: 2_000
        )

        let results = await executor.runReadOnlyBatch([(0, good), (1, bad)])
        guard case .success = results[0] else { return XCTFail("the good read should succeed") }
        guard case .failure(let message)? = results[1] else {
            return XCTFail("the missing file should fail")
        }
        XCTAssertTrue(message.contains("ghost.typ"), message)
    }

    func testEmptyBatchIsANoOp() async {
        let results = await executor.runReadOnlyBatch([])
        XCTAssertTrue(results.isEmpty)
    }

    /// The point of the whole exercise: the reads must actually overlap.
    ///
    /// The baseline is the same batch API driven one plan at a time, so the
    /// per-call overhead cancels out and what remains is the concurrency. A
    /// serial implementation fails this: it would measure roughly the same
    /// either way.
    func testBatchRunsConcurrentlyRatherThanSerially() async throws {
        // Large enough that reading and decoding dominates the measurement.
        let body = String(repeating: "lorem ipsum dolor sit amet\n", count: 40_000)
        let count = 6
        for index in 0..<count {
            try write("big\(index).typ", body)
        }

        func freshPlans() throws -> [(index: Int, plan: ReadOnlyToolPlan)] {
            try (0..<count).map { index in
                (index, try XCTUnwrap(executor.readOnlyPlan(
                    toolName: "read_file",
                    arguments: ["path": "big\(index).typ", "limit": 5]
                )))
            }
        }

        // Warm the file cache so the comparison measures scheduling, not the
        // first read of each file from disk.
        _ = await executor.runReadOnlyBatch(try freshPlans())

        // Baseline: the same work, one plan per batch.
        let serialStart = Date()
        for plan in try freshPlans() {
            _ = await executor.runReadOnlyBatch([plan])
        }
        let serial = Date().timeIntervalSince(serialStart)

        let parallelStart = Date()
        let results = await executor.runReadOnlyBatch(try freshPlans())
        let parallel = Date().timeIntervalSince(parallelStart)

        XCTAssertEqual(results.count, count)
        // With `maxConcurrent` of 4 and six reads, the ideal is about half the
        // serial time. 0.8 is loose enough for a loaded machine and still
        // fails outright if the work queued on one thread.
        XCTAssertLessThan(
            parallel,
            serial * 0.8,
            "parallel (\(parallel)s) should beat serial (\(serial)s) — the batch may not be overlapping"
        )
    }

    func testConcurrencyIsCapped() {
        // A dozen simultaneous opens trade one bottleneck for another on a
        // slow or networked disk.
        XCTAssertGreaterThan(ParallelToolCalls.maxConcurrent, 1)
        XCTAssertLessThanOrEqual(ParallelToolCalls.maxConcurrent, 8)
    }

    // MARK: - Grep through the batch

    func testGrepRunsThroughTheBatch() async throws {
        try write("one.typ", "the mug is white\n")
        try write("two.typ", "another mug line\n")
        let plan = try XCTUnwrap(executor.readOnlyPlan(
            toolName: "grep_project",
            arguments: ["pattern": "mug"]
        ))
        let results = await executor.runReadOnlyBatch([(0, plan)])
        guard case .success(let outcome)? = results[0] else {
            return XCTFail("grep should succeed")
        }
        XCTAssertTrue(outcome.output.contains("one.typ:1:"), outcome.output)
        XCTAssertTrue(outcome.output.contains("two.typ:1:"), outcome.output)
        // A grep reads nothing in the read-before-edit sense.
        XCTAssertNil(outcome.readFilePath)
    }
}
