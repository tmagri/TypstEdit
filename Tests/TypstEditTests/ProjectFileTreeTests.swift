import XCTest
@testable import TypstEdit

/// The Projects sidebar keeps itself current from a file-system watcher. These
/// cover the pure parts that decide *what* to re-read and *when* the list
/// needs to republish — the logic that keeps an idle project cheap.
final class ProjectFileTreeTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("ProjectFileTreeTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeDirectory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeFile(_ relativePath: String, contents: String = "x") throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Loading

    func testLoadDirectorySortsDirectoriesFirstAndSkipsGeneratedFolders() throws {
        try makeFile("b.typ")
        try makeFile("a.md")
        try makeDirectory("chapters")
        try makeDirectory("temp")
        try makeDirectory("backups")
        try makeFile(".hidden.typ")

        let nodes = ProjectTreeLoader.loadDirectory(at: root)
        XCTAssertEqual(nodes.map(\.name), ["chapters", "a.md", "b.typ"])
        // Directories get a placeholder listing so the row can show a chevron.
        XCTAssertEqual(nodes.first?.children, [])
    }

    func testLoadDirectoryDoesNotRecurse() throws {
        try makeDirectory("outer/inner")
        try makeFile("outer/inner/deep.typ")

        let nodes = ProjectTreeLoader.loadDirectory(at: root)
        let outer = try XCTUnwrap(nodes.first)
        XCTAssertEqual(outer.children, [], "subdirectory contents must load on demand only")
    }

    func testNodeIdentityIsTheURLEvenWhenChildrenChange() throws {
        try makeDirectory("chapters")
        let before = try XCTUnwrap(ProjectTreeLoader.loadDirectory(at: root).first)

        var after = before
        after.children = [FileNode(url: root.appendingPathComponent("chapters/x.typ"),
                                   name: "x.typ", isDirectory: false, children: nil)]

        // Same row, so SwiftUI can reuse it…
        XCTAssertEqual(before, after)
        XCTAssertEqual(before.hashValue, after.hashValue)
        // …but the list still knows there is new content to render.
        XCTAssertFalse(before.hasSameStructure(as: after))
    }

    // MARK: - What a reload re-reads

    func testOnlyExpandedFoldersAreReloaded() throws {
        try makeDirectory("a/deep")
        try makeDirectory("b")

        let tree = ProjectTreeLoader.loadDirectory(at: root)
        let a = try XCTUnwrap(tree.first { $0.name == "a" })
        let b = try XCTUnwrap(tree.first { $0.name == "b" })

        XCTAssertTrue(ProjectTreeLoader.loadedDirectories(in: tree, expanded: []).isEmpty)
        XCTAssertEqual(ProjectTreeLoader.loadedDirectories(in: tree, expanded: [a.url]), [a.url])
        XCTAssertEqual(ProjectTreeLoader.loadedDirectories(in: tree, expanded: [a.url, b.url]),
                       [a.url, b.url],
                       "collapsed folders must not cost a directory listing")
    }

    func testNestedExpandedFoldersAreReloadedShallowestFirst() throws {
        try makeDirectory("a/deep")
        let deep = try makeFile("a/deep/deep.typ").deletingLastPathComponent()
        let a = deep.deletingLastPathComponent()

        let expansions: Set<URL> = [deep, a]
        let tree = ProjectTreeLoader.buildTree(root: root, reloading: expansions)

        let aNode = try XCTUnwrap(tree.first { $0.url == a })
        let deepNode = try XCTUnwrap(aNode.children?.first { $0.url == deep })
        XCTAssertEqual(deepNode.children?.map(\.name), ["deep.typ"],
                       "a child must be refilled after its parent, not before")
    }

    func testBuildTreePicksUpAddedAndRemovedFiles() throws {
        let chapters = try makeDirectory("chapters")
        try makeFile("chapters/one.typ")
        var tree = ProjectTreeLoader.buildTree(root: root, reloading: [chapters])
        XCTAssertEqual(tree.first?.children?.map(\.name), ["one.typ"])

        try makeFile("chapters/two.typ")
        try fm.removeItem(at: chapters.appendingPathComponent("one.typ"))
        tree = ProjectTreeLoader.buildTree(root: root, reloading: [chapters])
        XCTAssertEqual(tree.first?.children?.map(\.name), ["two.typ"])
    }

    func testCollapsingAFolderDropsItsCachedListing() throws {
        try makeDirectory("chapters/deeper")
        try makeFile("chapters/one.typ")
        let chapters = root.appendingPathComponent("chapters", isDirectory: true)

        var tree = ProjectTreeLoader.buildTree(root: root, reloading: [chapters])
        XCTAssertEqual(tree.first?.children?.count, 2)

        tree = ProjectTreeLoader.droppingChildren(of: chapters, in: tree)
        // Back to the on-demand placeholder: the disclosure chevron survives,
        // but no rows are held for a subtree that is not on screen.
        XCTAssertEqual(tree.first?.children, [])
        XCTAssertTrue(tree.first?.isDirectory == true)
    }

    // MARK: - Visible rows

    func testVisibleRowsFlattenOnlyExpandedSubtrees() throws {
        try makeDirectory("a/b")
        try makeFile("a/b/deep.typ")
        try makeFile("a/one.typ")
        try makeFile("root.typ")

        let a = root.appendingPathComponent("a", isDirectory: true)
        let b = a.appendingPathComponent("b", isDirectory: true)

        let collapsed = ProjectTreeLoader.buildTree(root: root, reloading: [])
        XCTAssertEqual(ProjectTreeLoader.visibleRows(in: collapsed, expanded: []).map(\.node.name),
                       ["a", "root.typ"])

        let expanded = ProjectTreeLoader.buildTree(root: root, reloading: [a])
        let rows = ProjectTreeLoader.visibleRows(in: expanded, expanded: [a])
        XCTAssertEqual(rows.map(\.node.name), ["a", "b", "one.typ", "root.typ"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 0])
        XCTAssertEqual(rows.map(\.isExpanded), [true, false, false, false])

        let deep = ProjectTreeLoader.buildTree(root: root, reloading: [a, b])
        let deepRows = ProjectTreeLoader.visibleRows(in: deep, expanded: [a, b])
        XCTAssertEqual(deepRows.map(\.node.name), ["a", "b", "deep.typ", "one.typ", "root.typ"])
        XCTAssertEqual(deepRows.map(\.depth), [0, 1, 2, 1, 0])
    }

    // MARK: - Change filtering

    func testGeneratedAndHiddenPathsAreIgnored() {
        let project = root!
        XCTAssertTrue(ProjectTreeLoader.isIgnoredPath(project.appendingPathComponent("temp/x.typ"), inProject: project))
        XCTAssertTrue(ProjectTreeLoader.isIgnoredPath(project.appendingPathComponent("backups/x.zip"), inProject: project))
        XCTAssertTrue(ProjectTreeLoader.isIgnoredPath(project.appendingPathComponent("vectorcaches/project_index.sqlite"), inProject: project))
        XCTAssertTrue(ProjectTreeLoader.isIgnoredPath(project.appendingPathComponent(".git/index"), inProject: project))
        XCTAssertTrue(ProjectTreeLoader.isIgnoredPath(project.appendingPathComponent(".typstedit/config.json"), inProject: project))
        XCTAssertTrue(ProjectTreeLoader.isIgnoredPath(project.appendingPathComponent(".DS_Store"), inProject: project))

        XCTAssertFalse(ProjectTreeLoader.isIgnoredPath(project.appendingPathComponent("main.typ"), inProject: project))
        XCTAssertFalse(ProjectTreeLoader.isIgnoredPath(project.appendingPathComponent("chapters/tempest.typ"), inProject: project),
                       "only an exact folder name is generated — a prefix must not be")
        XCTAssertFalse(ProjectTreeLoader.isIgnoredPath(project, inProject: project),
                       "the project root itself always matters")
    }

    func testOnlyIndexableExtensionsTriggerIndexMaintenance() {
        XCTAssertTrue(RAGManager.isIndexableFile(root.appendingPathComponent("a.typ")))
        XCTAssertTrue(RAGManager.isIndexableFile(root.appendingPathComponent("a.NOTE")))
        XCTAssertFalse(RAGManager.isIndexableFile(root.appendingPathComponent("a.pdf")))
        XCTAssertFalse(RAGManager.isIndexableFile(root.appendingPathComponent("a.png")))
    }
}

/// The FSEvents layer: batching, structure classification, and teardown.
final class ProjectDirectoryWatcherTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("ProjectWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private var watcherRoot: URL { root }

    func testWatcherReportsCreatedFileAsStructural() throws {
        let expectation = expectation(description: "create reported")
        var observed: [DirectoryChange] = []
        let watcher = DirectoryWatcher(root: root, latency: 0.05, settleDelay: 0.1) { changes in
            observed.append(contentsOf: changes)
            expectation.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }

        try "hello".write(to: root.appendingPathComponent("new.typ"), atomically: true, encoding: .utf8)

        wait(for: [expectation], timeout: 10)
        let created = observed.first { $0.url.lastPathComponent == "new.typ" }
        XCTAssertNotNil(created, "expected a change for the new file, got \(observed.map(\.url.lastPathComponent))")
        XCTAssertTrue(created?.changesParentListing ?? false)
    }

    func testWatcherSeesNestedChanges() throws {
        let nested = root.appendingPathComponent("chapters", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)

        let expectation = expectation(description: "nested file reported")
        var observed: [DirectoryChange] = []
        let watcher = DirectoryWatcher(root: root, latency: 0.05, settleDelay: 0.1) { changes in
            observed.append(contentsOf: changes)
            if changes.contains(where: { $0.url.lastPathComponent == "deep.typ" }) {
                expectation.fulfill()
            }
        }
        watcher.start()
        defer { watcher.stop() }

        try "x".write(to: nested.appendingPathComponent("deep.typ"), atomically: true, encoding: .utf8)

        wait(for: [expectation], timeout: 10)
    }

    func testStopIsIdempotentAndSilencesDelivery() throws {
        let watcher = DirectoryWatcher(root: root, latency: 0.05, settleDelay: 0.1) { _ in
            XCTFail("a stopped watcher must not deliver")
        }
        watcher.start()
        watcher.stop()
        watcher.stop()

        try "x".write(to: root.appendingPathComponent("late.typ"), atomically: true, encoding: .utf8)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
}
