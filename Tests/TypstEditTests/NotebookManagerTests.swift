import XCTest
@testable import TypstEdit

final class NotebookManagerTests: XCTestCase {
    
    @MainActor
    func testHiddenFoldersExcludedFromNotebooks() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        
        let manager = NotebookManager.shared
        let originalPath = manager.customRootPath
        manager.setRootDirectory(tempRoot)
        
        defer {
            if originalPath.isEmpty {
                manager.resetRootDirectory()
            } else {
                manager.setRootDirectory(URL(fileURLWithPath: originalPath))
            }
        }
        
        // Create normal notebook directories
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("Math"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("Physics"), withIntermediateDirectories: true)
        
        // Create special / cache directories that RAG / Typst / Backups create
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("vectorcaches"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("temp"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("backups"), withIntermediateDirectories: true)
        
        manager.loadNotebooks()
        
        let notebookNames = manager.notebooks.map(\.name)
        XCTAssertTrue(notebookNames.contains("Math"), "Should include Math notebook")
        XCTAssertTrue(notebookNames.contains("Physics"), "Should include Physics notebook")
        XCTAssertFalse(notebookNames.contains("vectorcaches"), "Should hide vectorcaches from notebooks")
        XCTAssertFalse(notebookNames.contains("temp"), "Should hide temp from notebooks")
        XCTAssertFalse(notebookNames.contains("backups"), "Should hide backups from notebooks")
    }
    
    @MainActor
    func testCannotCreateHiddenFolderNotebook() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        
        let manager = NotebookManager.shared
        let originalPath = manager.customRootPath
        manager.setRootDirectory(tempRoot)
        
        defer {
            if originalPath.isEmpty {
                manager.resetRootDirectory()
            } else {
                manager.setRootDirectory(URL(fileURLWithPath: originalPath))
            }
        }
        
        manager.createNotebook(name: "vectorcaches")
        manager.createNotebook(name: "temp")
        manager.createNotebook(name: "backups")
        
        let notebookNames = manager.notebooks.map(\.name)
        XCTAssertFalse(notebookNames.contains("vectorcaches"))
        XCTAssertFalse(notebookNames.contains("temp"))
        XCTAssertFalse(notebookNames.contains("backups"))
    }
}
