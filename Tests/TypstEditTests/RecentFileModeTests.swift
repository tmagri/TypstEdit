import XCTest
@testable import TypstEdit

/// Open Recent must reopen a file the way it was last used: inside its real
/// project, in the Notes window, or alone with no project — a standalone file
/// must never gain a project (and therefore an index and `vectorcaches/`).
@MainActor
final class RecentFileModeTests: XCTestCase {
    private typealias RecentFile = RecentFilesManager.RecentFile

    private let notesRoot = URL(fileURLWithPath: "/notes")
    private let file = URL(fileURLWithPath: "/work/book/chapters/ch1.typ")
    private let projectRoot = URL(fileURLWithPath: "/work/book")

    private func exists(_ paths: Set<String>) -> (URL) -> Bool {
        { paths.contains($0.path) }
    }

    // MARK: - Reopen target

    func testProjectEntryKeepsItsRealRootForFilesInSubfolders() {
        let entry = RecentFile(url: file, lastModified: Date(), projectRoot: projectRoot, kind: .project)
        XCTAssertEqual(
            entry.openTarget(notebooksRoot: notesRoot, fileExists: exists(["/work/book"])),
            .project(root: projectRoot, file: file))
    }

    func testProjectEntryFallsBackToStandaloneWhenTheFolderIsGone() {
        let entry = RecentFile(url: file, lastModified: Date(), projectRoot: projectRoot, kind: .project)
        // Neither the project nor its folder exists any more.
        XCTAssertEqual(
            entry.openTarget(notebooksRoot: notesRoot, fileExists: exists([])),
            .standalone(file))
    }

    func testProjectEntryFallsBackToStandaloneWhenFileMovedOutOfTheProject() {
        let moved = URL(fileURLWithPath: "/elsewhere/ch1.typ")
        let entry = RecentFile(url: moved, lastModified: Date(), projectRoot: projectRoot, kind: .project)
        XCTAssertEqual(
            entry.openTarget(notebooksRoot: notesRoot, fileExists: exists(["/work/book"])),
            .standalone(moved))
    }

    func testStandaloneEntryNeverBecomesAProject() {
        let entry = RecentFile(url: file, lastModified: Date(), kind: .standalone)
        // Even though its parent folder exists and would look like a project,
        // the recorded mode wins: no index, no chat scope, no vectorcaches/.
        XCTAssertEqual(
            entry.openTarget(notebooksRoot: notesRoot, fileExists: exists(["/work/book/chapters"])),
            .standalone(file))
    }

    func testNotebookPageOpensInTheNotesWindow() {
        let note = URL(fileURLWithPath: "/notes/Physics/a.note")
        let entry = RecentFile(url: note, lastModified: Date(), kind: .notebook)
        XCTAssertEqual(
            entry.openTarget(notebooksRoot: notesRoot),
            .notebook(note))
    }

    func testNotebookOpenedAsProjectReopensAsThatProject() {
        // "Open as Project" on a notebook (e.g. one under Git): the page is
        // recorded with the notebook folder as its root and must come back
        // in that project, not in the Notes window.
        let notebook = URL(fileURLWithPath: "/notes/Physics")
        let page = URL(fileURLWithPath: "/notes/Physics/a.note")
        let entry = RecentFile(url: page, lastModified: Date(), projectRoot: notebook, kind: .project)
        XCTAssertEqual(
            entry.openTarget(notebooksRoot: notesRoot, fileExists: exists(["/notes/Physics"])),
            .project(root: notebook, file: page))
    }

    func testLegacyProjectEntryForANoteStillOpensInNotes() {
        // Older builds recorded Notes-window pages as "project" entries with
        // no root; those keep opening in the Notes window.
        let page = URL(fileURLWithPath: "/notes/Physics/a.note")
        let entry = RecentFile(url: page, lastModified: Date(), kind: .project)
        XCTAssertEqual(
            entry.openTarget(notebooksRoot: notesRoot, fileExists: exists(["/notes/Physics"])),
            .notebook(page))
    }

    func testNoteMovedOutOfTheNotebooksFolderOpensStandalone() {
        let note = URL(fileURLWithPath: "/work/book/a.note")
        let entry = RecentFile(url: note, lastModified: Date(), kind: .notebook)
        XCTAssertEqual(
            entry.openTarget(notebooksRoot: notesRoot),
            .standalone(note))
    }

    // MARK: - Recording

    /// `add` is the write side of the mode: it must classify by real state and
    /// never keep a project root on a standalone or notebook entry.
    func testAddRecordsModeAndStripsIrrelevantRoots() {
        let manager = RecentFilesManager.shared
        let defaults = UserDefaults.standard
        let key = "recentFiles"
        let saved = defaults.data(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
            manager.recentFiles = []
        }

        let inProject = URL(fileURLWithPath: "/work/book/chapters/ch1.typ")
        let standalone = URL(fileURLWithPath: "/loose/notes.typ")
        let note = URL(fileURLWithPath: "/notes/Physics/a.note")

        manager.clearAll()
        manager.add(url: inProject, projectRoot: projectRoot)
        manager.add(url: standalone)
        manager.add(url: note, inNotebook: true)

        XCTAssertEqual(manager.recentFiles.map(\.url), [note, standalone, inProject])
        XCTAssertEqual(manager.recentFiles.map(\.kind), [.notebook, .standalone, .project])

        let projectEntry = manager.recentFiles[2]
        XCTAssertEqual(projectEntry.projectRoot, projectRoot)
        XCTAssertTrue(projectEntry.isProject)

        // A standalone file records no project root at all — so reopening it
        // cannot make its folder a project (no index, no vectorcaches/).
        XCTAssertNil(manager.recentFiles[1].projectRoot)
        XCTAssertNil(manager.recentFiles[0].projectRoot)
    }

    func testAddUpdatesTheModeWhenTheSameFileIsOpenedOtherwise() {
        let manager = RecentFilesManager.shared
        let defaults = UserDefaults.standard
        let key = "recentFiles"
        let saved = defaults.data(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
            manager.recentFiles = []
        }

        let other = URL(fileURLWithPath: "/loose/other.typ")

        manager.clearAll()
        manager.add(url: file, projectRoot: projectRoot)
        manager.add(url: other)
        XCTAssertEqual(manager.recentFiles.first?.url, other)

        // Same file opened on its own later: one entry, moved to the top,
        // and still a Project entry with its root (never downgraded).
        manager.add(url: file)
        XCTAssertEqual(manager.recentFiles.count, 2)
        XCTAssertEqual(manager.recentFiles.first?.url, file)
        XCTAssertEqual(manager.recentFiles.first?.kind, .project)
        XCTAssertEqual(manager.recentFiles.first?.projectRoot, projectRoot)

        // A different project does replace the root.
        let wider = URL(fileURLWithPath: "/work")
        manager.add(url: file, projectRoot: wider)
        XCTAssertEqual(manager.recentFiles.first?.projectRoot, wider)
    }

    func testNotesWindowNeverDowngradesANotebookOpenedAsProject() {
        let manager = RecentFilesManager.shared
        let defaults = UserDefaults.standard
        let key = "recentFiles"
        let saved = defaults.data(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
            manager.recentFiles = []
        }
        let notebook = URL(fileURLWithPath: "/notes/Physics")
        let page = URL(fileURLWithPath: "/notes/Physics/a.typ")
        let plainNote = URL(fileURLWithPath: "/notes/Physics/b.note")

        manager.clearAll()
        manager.add(url: page, projectRoot: notebook)
        // The Notes window then opens or saves the same page.
        manager.add(url: page, inNotebook: true)
        XCTAssertEqual(manager.recentFiles.count, 1)
        XCTAssertEqual(manager.recentFiles.first?.kind, .project)
        XCTAssertEqual(manager.recentFiles.first?.projectRoot, notebook)
        XCTAssertEqual(
            manager.recentFiles.first?.openTarget(notebooksRoot: notesRoot, fileExists: exists(["/notes/Physics"])),
            .project(root: notebook, file: page))

        // A page never used in project mode is still a Note.
        manager.add(url: plainNote, inNotebook: true)
        XCTAssertEqual(manager.recentFiles.first?.kind, .notebook)
    }

    // MARK: - Project folder entries

    func testFolderEntryReopensTheProjectWithNoFile() {
        let notebook = URL(fileURLWithPath: "/notes/Physics")
        let entry = RecentFile(url: notebook, lastModified: Date(), projectRoot: notebook, kind: .project)
        XCTAssertTrue(entry.isFolder)
        XCTAssertEqual(entry.iconName, "folder.fill")
        XCTAssertEqual(
            entry.openTarget(notebooksRoot: notesRoot, fileExists: exists(["/notes/Physics"])),
            .project(root: notebook, file: nil))
    }

    func testFolderEntryForADeletedFolderIsMissing() {
        let entry = RecentFile(url: projectRoot, lastModified: Date(), projectRoot: projectRoot, kind: .project)
        XCTAssertEqual(
            entry.openTarget(notebooksRoot: notesRoot, fileExists: exists([])),
            .missing)
    }

    func testFileEntryIsNotAFolderEntry() {
        let entry = RecentFile(url: file, lastModified: Date(), projectRoot: projectRoot, kind: .project)
        XCTAssertFalse(entry.isFolder)
        XCTAssertEqual(entry.iconName, "folder")
    }

    func testOpeningAFileReplacesItsProjectFolderEntry() {
        let manager = RecentFilesManager.shared
        let defaults = UserDefaults.standard
        let key = "recentFiles"
        let saved = defaults.data(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
            manager.recentFiles = []
        }
        let other = URL(fileURLWithPath: "/work/other")

        manager.clearAll()
        manager.addProjectFolder(other)
        manager.addProjectFolder(projectRoot)
        // Opening the same folder again keeps one entry, at the top.
        manager.addProjectFolder(URL(fileURLWithPath: "/work/book/"))
        XCTAssertEqual(manager.recentFiles.count, 2)
        XCTAssertTrue(manager.recentFiles[0].isFolder)

        // A file of the project replaces the project's folder entry only.
        manager.add(url: file, projectRoot: projectRoot)
        XCTAssertEqual(manager.recentFiles.map(\.url), [file, other])
        XCTAssertFalse(manager.recentFiles[0].isFolder)
        XCTAssertTrue(manager.recentFiles[1].isFolder)

        // A standalone file never removes a project folder entry.
        manager.add(url: URL(fileURLWithPath: "/work/other/x.typ"))
        XCTAssertTrue(manager.recentFiles.contains { $0.isFolder && $0.url == other })
    }

    // MARK: - Persistence

    private func decoded(from json: String) throws -> RecentFile {
        try JSONDecoder().decode(RecentFile.self, from: Data(json.utf8))
    }

    func testDecodesCurrentSchema() throws {
        let entry = try decoded(from: """
        {"url":"file:///work/book/ch1.typ","lastModified":0,
         "kind":"project","projectRoot":"file:///work/book/"}
        """)
        XCTAssertEqual(entry.kind, .project)
        XCTAssertEqual(entry.projectRoot?.path, "/work/book")
    }

    func testDecodesLegacyIsProjectBool() throws {
        let flatFile = URL(fileURLWithPath: "/work/book/ch1.typ")
        let projectEntry = try decoded(from: """
        {"url":"file:///work/book/ch1.typ","lastModified":0,"isProject":true}
        """)
        XCTAssertEqual(projectEntry.kind, .project)
        // Old entries could not store the root; for a file at the top of the
        // project, its folder is that root.
        XCTAssertNil(projectEntry.projectRoot)
        guard case .project(let root, let opened) = projectEntry.openTarget(
            notebooksRoot: notesRoot,
            fileExists: exists(["/work/book"])) else {
            return XCTFail("Expected a project reopen")
        }
        XCTAssertTrue(ProjectWindowRouter.isSameFolder(root, URL(fileURLWithPath: "/work/book")))
        XCTAssertEqual(opened, flatFile)

        let fileEntry = try decoded(from: """
        {"url":"file:///work/book/ch1.typ","lastModified":0,"isProject":false}
        """)
        XCTAssertEqual(fileEntry.kind, .standalone)
    }

    func testDecodesOldestSchemaAsProject() throws {
        // Before modes existed every entry was a project entry.
        let entry = try decoded(from: """
        {"url":"file:///work/book/main.typ","lastModified":0}
        """)
        XCTAssertEqual(entry.kind, .project)
    }

    func testRoundTripKeepsModeAndRoot() throws {
        let original = RecentFile(
            url: file,
            lastModified: Date(timeIntervalSince1970: 1000),
            projectRoot: projectRoot,
            kind: .project)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(RecentFile.self, from: data)
        XCTAssertEqual(restored.url, original.url)
        XCTAssertEqual(restored.kind, .project)
        XCTAssertEqual(restored.projectRoot, original.projectRoot)
        XCTAssertEqual(restored.lastModified, original.lastModified)
    }

    func testEncodesLegacyKeyForOlderBuilds() throws {
        let entry = RecentFile(url: file, lastModified: Date(), kind: .standalone)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        XCTAssertEqual(json?["isProject"] as? Bool, false)
    }

    func testKindLabels() {
        XCTAssertEqual(RecentFile(url: file, lastModified: Date(), kind: .project).kindLabel, "Project")
        XCTAssertEqual(RecentFile(url: file, lastModified: Date(), kind: .standalone).kindLabel, "File")
        XCTAssertEqual(RecentFile(url: file, lastModified: Date(), kind: .notebook).kindLabel, "Note")
    }
}
