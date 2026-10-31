import XCTest
@testable import TypstEdit

/// Redirecting tool names models carry over from other harnesses onto the
/// tools this app actually offers.
final class ToolAliasesTests: XCTestCase {

    private let offered = [
        "project__read_file",
        "project__write_file",
        "project__edit_file",
        "project__list_files",
        "project__grep_project",
        "project__web_fetch",
        "python__run",
        "agent__update_plan",
        "agent__delegate_task"
    ]

    // MARK: - A valid name is never touched

    func testAValidQualifiedNameIsLeftAlone() {
        for name in offered {
            XCTAssertNil(ToolAliases.resolve(name, against: offered), "should not redirect \(name)")
        }
    }

    func testAnUnknownNameWithNoAliasIsLeftToFailHonestly() {
        // A fuzzy guess here could run the wrong tool, which is worse than an
        // error the model can read.
        XCTAssertNil(ToolAliases.resolve("delete_everything", against: offered))
        XCTAssertNil(ToolAliases.resolve("project__explode", against: offered))
    }

    // MARK: - Aliases resolve

    func testBashResolvesToThePythonRunTool() {
        XCTAssertEqual(ToolAliases.resolve("bash", against: offered), "python__run")
        XCTAssertEqual(ToolAliases.resolve("shell", against: offered), "python__run")
        XCTAssertEqual(ToolAliases.resolve("python", against: offered), "python__run")
    }

    func testEditingAliasesResolveToTheClosestTool() {
        XCTAssertEqual(ToolAliases.resolve("str_replace_editor", against: offered), "project__edit_file")
        XCTAssertEqual(ToolAliases.resolve("search_replace", against: offered), "project__edit_file")
        XCTAssertEqual(ToolAliases.resolve("create_file", against: offered), "project__write_file")
        XCTAssertEqual(ToolAliases.resolve("write", against: offered), "project__write_file")
    }

    func testReadingAndSearchAliasesResolve() {
        XCTAssertEqual(ToolAliases.resolve("view", against: offered), "project__read_file")
        XCTAssertEqual(ToolAliases.resolve("cat", against: offered), "project__read_file")
        XCTAssertEqual(ToolAliases.resolve("grep", against: offered), "project__grep_project")
        XCTAssertEqual(ToolAliases.resolve("glob", against: offered), "project__list_files")
    }

    func testTodoAliasesResolveToThePlanTool() {
        XCTAssertEqual(ToolAliases.resolve("todo_write", against: offered), "agent__update_plan")
        XCTAssertEqual(ToolAliases.resolve("todowrite", against: offered), "agent__update_plan")
    }

    // MARK: - Namespaces

    func testAnAliasKeepsTheNamespaceTheModelUsed() {
        let withCustomServer = offered + ["local__run", "local__read_file"]
        // `local__bash` should stay in the `local` server, not jump to
        // `python__run`.
        XCTAssertEqual(ToolAliases.resolve("local__bash", against: withCustomServer), "local__run")
    }

    func testASuffixOnlyAliasPicksTheOfferedTool() {
        // No namespace at all: the alias alone has to find the target.
        XCTAssertEqual(ToolAliases.resolve("bash", against: offered), "python__run")
    }

    func testAWrongNamespaceForARealToolIsCorrected() {
        // The tool exists, but under a different server than the model used.
        XCTAssertEqual(
            ToolAliases.resolve("project2__read_file", against: offered),
            "project__read_file"
        )
    }

    // MARK: - Matching rules

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(ToolAliases.resolve("BASH", against: offered), "python__run")
        XCTAssertEqual(ToolAliases.resolve("Todo_Write", against: offered), "agent__update_plan")
    }

    func testPlainNameStripsTheNamespace() {
        XCTAssertEqual(ToolAliases.plainName("project__read_file"), "read_file")
        XCTAssertEqual(ToolAliases.plainName("read_file"), "read_file")
    }

    func testNoAliasWhenTheTargetToolIsNotOffered() {
        // Edit tools are withheld in Plan mode, so `str_replace_editor` must
        // not resolve to a tool that isn't there.
        let readOnly = ["project__read_file", "project__list_files"]
        XCTAssertNil(ToolAliases.resolve("str_replace_editor", against: readOnly))
        XCTAssertNil(ToolAliases.resolve("grep", against: readOnly))
        // Aliases that do have a live target still work.
        XCTAssertEqual(ToolAliases.resolve("cat", against: readOnly), "project__read_file")
    }

    func testEmptyCandidateListResolvesNothing() {
        XCTAssertNil(ToolAliases.resolve("bash", against: []))
    }

    // MARK: - Redirect note

    func testRedirectNoteNamesBothTools() {
        let note = ToolAliases.redirectNote(called: "bash", ran: "python__run")
        XCTAssertTrue(note.contains("\"bash\""), note)
        XCTAssertTrue(note.contains("\"python__run\""), note)
        XCTAssertTrue(note.contains("next time"), note)
    }

    func testEveryAliasTargetIsAPlausibleToolName() {
        // Guards against a typo in the table that could never resolve.
        let targets = Set(ToolAliases.byPlainName.values)
        XCTAssertTrue(targets.contains("run"))
        XCTAssertTrue(targets.contains("edit_file"))
        XCTAssertTrue(targets.contains("read_file"))
        for target in targets {
            XCTAssertFalse(target.contains("__"), "aliases should target a plain name, got \(target)")
            XCTAssertFalse(target.isEmpty)
        }
    }
}
