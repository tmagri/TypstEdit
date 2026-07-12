import XCTest
@testable import TypstEdit

final class SafeDirectoryManagerTests: XCTestCase {
    func testBackupDirectoryDoesNotNestInsideBackups() {
        let fileURL = URL(fileURLWithPath: "/tmp/project/backups/note.typ")
        let dir = SafeDirectoryManager.safeBackupDirectory(for: fileURL, projectRoot: nil)
        XCTAssertEqual(dir.path, "/tmp/project/backups")
    }

    func testTempDirectoryDoesNotNestInsideTemp() {
        let projectURL = URL(fileURLWithPath: "/tmp/project/temp")
        let dir = SafeDirectoryManager.safeTempDirectory(in: projectURL)
        XCTAssertEqual(dir.path, "/tmp/project/temp")
    }

    func testVectorCachesDirectoryDoesNotNestInsideVectorCaches() {
        let projectURL = URL(fileURLWithPath: "/tmp/project/vectorcaches")
        let dir = SafeDirectoryManager.safeVectorcachesDirectory(in: projectURL)
        XCTAssertEqual(dir?.path, "/tmp/project/vectorcaches")
    }

    func testBackupForFileInTempIsSkippedResolution() {
        // When a file lives in a protected directory such as `temp`, we must not
        // create backups nor route them to an external backups folder. The safe
        // resolver returns the file's parent so callers can decide to skip creating
        // backups entirely.
        let fileURL = URL(fileURLWithPath: "/tmp/project/temp/file.typ")
        let dir = SafeDirectoryManager.safeBackupDirectory(for: fileURL, projectRoot: nil)
        XCTAssertEqual(dir.path, "/tmp/project/temp")
    }

    @MainActor
    func testBackupIsSkippedForFileInTemp() {
        // Create a temporary file on disk and ensure BackupManager does not
        // create a backups directory for files inside `temp`.
        let fm = FileManager.default
        let tmpBase = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("typstedit-tests-temp")
        try? fm.removeItem(at: tmpBase)
        try! fm.createDirectory(at: tmpBase.appendingPathComponent("temp"), withIntermediateDirectories: true)
        let fileURL = tmpBase.appendingPathComponent("temp/test.typ")
        try! "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        BackupManager.shared.backupExistingFile(at: fileURL, projectRoot: nil)

        let backupsDir = fileURL.deletingLastPathComponent().appendingPathComponent("backups")
        XCTAssertFalse(fm.fileExists(atPath: backupsDir.path))

        try? fm.removeItem(at: tmpBase)
    }

    @MainActor
    func testRAGIsDisabledForProjectsInsideProtectedDirectories() {
        XCTAssertFalse(RAGManager.shouldUseRAG(for: URL(fileURLWithPath: "/tmp/project/backups")))
        XCTAssertFalse(RAGManager.shouldUseRAG(for: URL(fileURLWithPath: "/tmp/project/temp")))
        XCTAssertFalse(RAGManager.shouldUseRAG(for: URL(fileURLWithPath: "/tmp/project/vectorcaches")))
    }
}
