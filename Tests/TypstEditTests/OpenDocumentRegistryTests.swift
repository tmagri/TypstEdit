import XCTest
@testable import TypstEdit

/// The app-wide registry of open documents with unsaved edits. Tested
/// through fresh instances so the shared singleton is never touched.
@MainActor
final class OpenDocumentRegistryTests: XCTestCase {

    /// Stand-in identities for editor controllers. The instances are kept
    /// alive for the whole test so their identities never collide with a
    /// re-used address.
    private final class Sentinel {}
    private let sentinelA = Sentinel()
    private let sentinelB = Sentinel()
    private let sentinelC = Sentinel()
    private var a: ObjectIdentifier { ObjectIdentifier(sentinelA) }
    private var b: ObjectIdentifier { ObjectIdentifier(sentinelB) }
    private var c: ObjectIdentifier { ObjectIdentifier(sentinelC) }

    private var registry: OpenDocumentRegistry!

    override func setUp() async throws {
        try await super.setUp()
        registry = OpenDocumentRegistry()
    }

    private func file(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    // MARK: Dirty tracking

    func testDirtyEditorRegistersItsFile() {
        XCTAssertTrue(registry.dirtyFiles.isEmpty)

        // Clean editor with an open file: nothing is registered.
        registry.updateEditor(a, fileURL: file("/repo/a.typ"), hasUnsavedChanges: false)
        XCTAssertTrue(registry.dirtyFiles.isEmpty)

        // Dirty editor with an open file: registered, standardized.
        registry.updateEditor(a, fileURL: file("/repo/a.typ"), hasUnsavedChanges: true)
        XCTAssertEqual(
            registry.dirtyFiles,
            [file("/repo/a.typ").resolvingSymlinksInPath().standardizedFileURL]
        )
        XCTAssertTrue(registry.isDirty(file("/repo/a.typ")))

        // Saving clears the entry.
        registry.updateEditor(a, fileURL: file("/repo/a.typ"), hasUnsavedChanges: false)
        XCTAssertTrue(registry.dirtyFiles.isEmpty)
    }

    func testDirtyEditorWithoutFileIsIgnored() {
        registry.updateEditor(a, fileURL: nil, hasUnsavedChanges: true)
        XCTAssertTrue(registry.dirtyFiles.isEmpty)
    }

    func testFileSwitchMovesTheEntry() {
        registry.updateEditor(a, fileURL: file("/repo/a.typ"), hasUnsavedChanges: true)
        registry.updateEditor(a, fileURL: file("/repo/b.typ"), hasUnsavedChanges: true)
        XCTAssertEqual(registry.dirtyFiles, [file("/repo/b.typ").standardizedFileURL])
        XCTAssertFalse(registry.isDirty(file("/repo/a.typ")))
    }

    func testRemoveEditorDropsOnlyItsOwnEntry() {
        registry.updateEditor(a, fileURL: file("/repo/a.typ"), hasUnsavedChanges: true)
        registry.updateEditor(b, fileURL: file("/repo/b.typ"), hasUnsavedChanges: true)
        XCTAssertEqual(registry.dirtyFiles.count, 2)

        registry.removeEditor(a)
        XCTAssertEqual(registry.dirtyFiles, [file("/repo/b.typ").standardizedFileURL])

        // Removing an unknown editor is a no-op.
        registry.removeEditor(c)
        XCTAssertEqual(registry.dirtyFiles, [file("/repo/b.typ").standardizedFileURL])
    }

    // MARK: Repository-scoped protection

    func testDirtyPathsInsideRepositoryRoot() {
        let root = file("/repo")
        registry.updateEditor(a, fileURL: file("/repo/notes/deep/a.typ"), hasUnsavedChanges: true)
        registry.updateEditor(b, fileURL: file("/repo/root.typ"), hasUnsavedChanges: true)

        XCTAssertEqual(registry.dirtyPaths(in: root), ["notes/deep/a.typ", "root.typ"])

        // Files outside the root never appear in it.
        registry.updateEditor(c, fileURL: file("/elsewhere/c.typ"), hasUnsavedChanges: true)
        XCTAssertEqual(registry.dirtyPaths(in: root), ["notes/deep/a.typ", "root.typ"])
        XCTAssertEqual(registry.dirtyPaths(in: file("/elsewhere")), ["c.typ"])

        // A sibling directory that merely shares the prefix is not the root.
        XCTAssertTrue(registry.dirtyPaths(in: file("/repository")).isEmpty)
    }
}
