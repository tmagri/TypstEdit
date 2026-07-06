import Foundation
import Combine

struct NotebookPage: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
}

struct Notebook: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    var pages: [NotebookPage]
}

@MainActor
class NotebookManager: ObservableObject {
    static let shared = NotebookManager()
    
    @Published var notebooks: [Notebook] = []
    
    var rootDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("TypstEdit Notes")
        
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
    
    init() {
        loadNotebooks()
    }
    
    func loadNotebooks() {
        var loaded: [Notebook] = []
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            
            for folder in contents {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                
                var pages: [NotebookPage] = []
                if let pageFiles = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for file in pageFiles where file.pathExtension.lowercased() == "note" {
                        pages.append(NotebookPage(url: file, name: file.deletingPathExtension().lastPathComponent))
                    }
                }
                
                loaded.append(Notebook(url: folder, name: folder.lastPathComponent, pages: pages.sorted { $0.name < $1.name }))
            }
        } catch {
            print("Error loading notebooks: \(error)")
        }
        self.notebooks = loaded.sorted { $0.name < $1.name }
    }
    
    func createNotebook(name: String) {
        let url = rootDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            loadNotebooks()
        } catch {
            print("Error creating notebook: \(error)")
        }
    }
    
    func deleteNotebook(url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            loadNotebooks()
        } catch {
            print("Error deleting notebook: \(error)")
        }
    }
    
    func createPage(in notebook: Notebook, name: String) -> URL? {
        let fileURL = notebook.url.appendingPathComponent(name).appendingPathExtension("note")
        do {
            let initialContent = "= \(name)\n\n"
            try initialContent.write(to: fileURL, atomically: true, encoding: .utf8)
            loadNotebooks()
            return fileURL
        } catch {
            print("Error creating note page: \(error)")
            return nil
        }
    }
    
    func deletePage(url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            loadNotebooks()
        } catch {
            print("Error deleting page: \(error)")
        }
    }
    
    func exportNotebook(_ notebook: Notebook, to destination: URL) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = notebook.url
        process.arguments = ["-r", "-q", destination.path, "."]
        
        return await withCheckedContinuation { continuation in
            do {
                try process.run()
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus == 0)
                }
            } catch {
                print("Zip export error: \(error)")
                continuation.resume(returning: false)
            }
        }
    }
    
    func restoreNotebook(from zipURL: URL, name: String) async -> Bool {
        let destFolder = rootDirectory.appendingPathComponent(name)
        do {
            if !FileManager.default.fileExists(atPath: destFolder.path) {
                try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
            }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.currentDirectoryURL = destFolder
            process.arguments = ["-q", zipURL.path]
            
            return await withCheckedContinuation { continuation in
                do {
                    try process.run()
                    process.terminationHandler = { process in
                        Task { @MainActor in
                            self.loadNotebooks()
                        }
                        continuation.resume(returning: process.terminationStatus == 0)
                    }
                } catch {
                    print("Unzip error: \(error)")
                    continuation.resume(returning: false)
                }
            }
            
        } catch {
            print("Restore directory error: \(error)")
            return false
        }
    }
}
