import XCTest
@testable import TypstEdit

/// The Projects sidebar model end to end: it must keep itself current from the
/// file system, and must not do expensive work (rescans, re-indexing, whole-list
/// rebuilds) when nothing that is on screen actually changed.
@MainActor
final class FileSystemModelLiveUpdateTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        try await super.setUp()
        root = fm.temporaryDirectory
            .appendingPathComponent("FileSystemModelTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? fm.removeItem(at: root) }
        try await super.tearDown()
    }

    private func makeModel() -> FileSystemModel {
        let model = FileSystemModel()
        // These tests watch the tree, not the embedding backend.
        model.indexesProject = false
        model.currentFolder = root
        model.setWatchActive(true)
        return model
    }

    /// Polls the model until `condition` holds, so the tests wait on the work
    /// rather than on a fixed sleep.
    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    // MARK: - Live updates

    func testNewFileAppearsWithoutAnExplicitRefresh() async throws {
        try "= Hi".write(to: root.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        let model = makeModel()
        model.startWatching()

        let showsMain = await waitUntil { model.rootNodes.map(\.name) == ["main.typ"] }
        XCTAssertTrue(showsMain)

        // No `loadFiles()` call here: the watcher has to notice this.
        try "x".write(to: root.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)

        let appeared = await waitUntil { model.rootNodes.map(\.name).contains("new.md") }
        XCTAssertTrue(appeared, "watcher should surface the new file, got \(model.rootNodes.map(\.name))")
    }

    func testDeletedFileDisappearsWithoutAnExplicitRefresh() async throws {
        let file = root.appendingPathComponent("gone.typ")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.startWatching()
        let showsInitialFile = await waitUntil { model.rootNodes.map(\.name) == ["gone.typ"] }
        XCTAssertTrue(showsInitialFile)

        try fm.removeItem(at: file)

        let removedRowIsDropped = await waitUntil { model.rootNodes.isEmpty }
        XCTAssertTrue(removedRowIsDropped,
                      "watcher should drop the removed row, got \(model.rootNodes.map(\.name))")
    }

    func testChangesInsideExpandedFolderShowUp() async throws {
        let chapters = root.appendingPathComponent("chapters", isDirectory: true)
        try fm.createDirectory(at: chapters, withIntermediateDirectories: true)
        try "x".write(to: chapters.appendingPathComponent("one.typ"), atomically: true, encoding: .utf8)

        let model = makeModel()
        model.startWatching()
        let showsFolderRow = await waitUntil { model.rootNodes.map(\.name) == ["chapters"] }
        XCTAssertTrue(showsFolderRow)

        model.loadChildren(for: model.rootNodes[0])
        let folderListsItsFile = await waitUntil { model.rootNodes[0].children?.map(\.name) == ["one.typ"] }
        XCTAssertTrue(folderListsItsFile)

        try "y".write(to: chapters.appendingPathComponent("two.typ"), atomically: true, encoding: .utf8)

        let folderPicksUpNewFile = await waitUntil { model.rootNodes[0].children?.map(\.name) == ["one.typ", "two.typ"] }
        XCTAssertTrue(folderPicksUpNewFile,
                      "an expanded folder must stay live, got \(model.rootNodes[0].children?.map(\.name) ?? [])")
    }

    // MARK: - Cost control

    func testNoOpRefreshDoesNotRepublish() async throws {
        try "x".write(to: root.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        let model = makeModel()
        model.startWatching()
        let treeIsPopulated = await waitUntil { !model.rootNodes.isEmpty }
        XCTAssertTrue(treeIsPopulated)

        let generation = model.refreshGeneration
        let nodes = model.rootNodes
        model.loadFiles()
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Same object state: no republish, so the list and its selection stay
        // exactly where they were.
        XCTAssertEqual(model.refreshGeneration, generation)
        XCTAssertTrue(model.rootNodes.hasSameStructure(as: nodes))
    }

    func testChangesInsideCollapsedFolderDoNotScan() async throws {
        let chapters = root.appendingPathComponent("chapters", isDirectory: true)
        try fm.createDirectory(at: chapters, withIntermediateDirectories: true)

        let model = makeModel()
        model.startWatching()
        let showsFolderRow = await waitUntil { model.rootNodes.map(\.name) == ["chapters"] }
        XCTAssertTrue(showsFolderRow)

        let generation = model.refreshGeneration
        try "x".write(to: chapters.appendingPathComponent("hidden.typ"), atomically: true, encoding: .utf8)
        // Long enough for the watcher's settle delay plus a rescan if one ran.
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertEqual(model.refreshGeneration, generation,
                       "a change inside a collapsed folder must not republish the list")
    }

    func testTransientFoldersAndDotFilesDoNotRepublish() async throws {
        try "x".write(to: root.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        let model = makeModel()
        model.startWatching()
        let treeIsPopulated = await waitUntil { !model.rootNodes.isEmpty }
        XCTAssertTrue(treeIsPopulated)

        let generation = model.refreshGeneration
        try fm.createDirectory(at: root.appendingPathComponent("temp", isDirectory: true),
                               withIntermediateDirectories: true)
        try "cache".write(to: root.appendingPathComponent("temp/scratch.pdf"), atomically: true, encoding: .utf8)
        try "dt".write(to: root.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertEqual(model.refreshGeneration, generation,
                       "compile scratch and Finder noise must never wake the list")
    }

    func testCollapsingStopsRefreshingTheSubtree() async throws {
        let chapters = root.appendingPathComponent("chapters", isDirectory: true)
        try fm.createDirectory(at: chapters, withIntermediateDirectories: true)
        try "x".write(to: chapters.appendingPathComponent("one.typ"), atomically: true, encoding: .utf8)

        let model = makeModel()
        model.startWatching()
        let showsFolderRow = await waitUntil { model.rootNodes.map(\.name) == ["chapters"] }
        XCTAssertTrue(showsFolderRow)
        model.loadChildren(for: model.rootNodes[0])
        let folderExpanded = await waitUntil { model.rootNodes[0].children?.count == 1 }
        XCTAssertTrue(folderExpanded)

        // Let the scan triggered by the expand finish before measuring.
        try? await Task.sleep(nanoseconds: 600_000_000)

        model.noteCollapsed(model.rootNodes[0])
        XCTAssertEqual(model.visibleRows.map(\.node.name), ["chapters"],
                       "a collapsed folder hides its children")

        let generation = model.refreshGeneration
        try "y".write(to: chapters.appendingPathComponent("two.typ"), atomically: true, encoding: .utf8)
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertEqual(model.refreshGeneration, generation,
                       "a change inside a collapsed folder must not republish the list")
    }

    // MARK: - Expanded rows are kept honest across reloads

    func testExpandedFolderSurvivesAnExpansionRacingTheScan() async throws {
        let chapters = root.appendingPathComponent("chapters", isDirectory: true)
        try fm.createDirectory(at: chapters, withIntermediateDirectories: true)
        try "x".write(to: chapters.appendingPathComponent("one.typ"), atomically: true, encoding: .utf8)

        let model = makeModel()
        model.startWatching()
        let showsFolderRow = await waitUntil { model.rootNodes.map(\.name) == ["chapters"] }
        XCTAssertTrue(showsFolderRow)

        // Expand immediately after starting a scan, so the scan may have
        // snapshotted the folder as collapsed.
        model.loadFiles()
        model.loadChildren(for: model.rootNodes[0])

        let folderListsItsFile = await waitUntil { model.rootNodes.first?.children?.map(\.name) == ["one.typ"] }
        XCTAssertTrue(folderListsItsFile,
                      "publishing a scan must not undo the user's expand")
    }

    func testFileWritesAreAnnouncedForTheEditor() async throws {
        let file = root.appendingPathComponent("main.typ")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let model = makeModel()
        var seen: [String] = []
        let token = NotificationCenter.default.addObserver(
            forName: FileSystemModel.projectFilesDidChange, object: nil, queue: .main
        ) { notification in
            guard let urls = notification.object as? [URL] else { return }
            seen.append(contentsOf: urls.map(\.lastPathComponent))
        }
        defer { NotificationCenter.default.removeObserver(token) }

        model.startWatching()
        let treeIsPopulated = await waitUntil { !model.rootNodes.isEmpty }
        XCTAssertTrue(treeIsPopulated)

        try "y".write(to: file, atomically: true, encoding: .utf8)

        let writeWasReported = await waitUntil { seen.contains("main.typ") }
        XCTAssertTrue(writeWasReported,
                      "the editor relies on this to reload the open document instantly")
    }
}
