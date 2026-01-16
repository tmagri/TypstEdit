import Foundation

@MainActor
class AutoRecoveryManager {
    static let shared = AutoRecoveryManager()
    
    // Directory where recovery files are stored
    private let recoveryDirectory: URL
    
    // Tasks to handle debouncing
    private var saveTasks: [URL: Task<Void, Never>] = [:]
    
    private init() {
        // ~/Library/Application Support/TypstEdit/AutoRecovery
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("TypstEdit")
        self.recoveryDirectory = appDirectory.appendingPathComponent("AutoRecovery")
        
        createDirectoryIfNeeded()
    }
    
    private func createDirectoryIfNeeded() {
        if !FileManager.default.fileExists(atPath: recoveryDirectory.path) {
            try? FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        }
    }
    
    /// Returns the file URL for the recovery copy of a given document URL
    nonisolated private func getRecoveryURL(for originalURL: URL) -> URL {
        // Reconstruct directory path to be safe in nonisolated context
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("TypstEdit")
        let dir = appDirectory.appendingPathComponent("AutoRecovery")
        
        // Hash the path to create a unique filename safe for the filesystem
        let docPath = originalURL.path
        let hash = UInt64(bitPattern: Int64(docPath.hash))
        
        // Use a readable prefix + hash + original extension
        let safeName = originalURL.lastPathComponent.replacingOccurrences(of: ".", with: "_")
        let fileName = "\(safeName)_\(hash).recovery"
        
        return dir.appendingPathComponent(fileName)
    }
    
    /// Schedules a recovery save. Replaces any pending save for this URL.
    func updateRecovery(content: String, for url: URL) {
        // Cancel existing pending task
        saveTasks[url]?.cancel()
        
        let task = Task {
            do {
                // Wait 5 seconds of inactivity before writing
                try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            } catch {
                return // Cancelled or error
            }
            
            if Task.isCancelled { return }
            
            // Perform save on background thread (detached)
            await Task.detached(priority: .utility) {
                self.performSave(content: content, for: url)
            }.value
            
            // Clean up the task entry if we finished successfully and weren't cancelled by a newer task
            if !Task.isCancelled {
                self.saveTasks.removeValue(forKey: url)
            }
        }
        
        saveTasks[url] = task
    }
    
    nonisolated private func performSave(content: String, for url: URL) {
        let recoveryURL = getRecoveryURL(for: url)
        do {
            // Create directory if needed
            let dir = recoveryURL.deletingLastPathComponent()
             if !FileManager.default.fileExists(atPath: dir.path) { 
                 try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) 
             }
             
            try content.write(to: recoveryURL, atomically: true, encoding: .utf8)
            print("[AutoRecovery] Saved recovery file for \(url.lastPathComponent)")
        } catch {
            print("[AutoRecovery] Failed to save recovery file: \(error)")
        }
    }
    
    /// Removes the recovery file for a specific document (e.g. after successful save)
    func clearRecovery(for url: URL) {
        // Cancel pending
        saveTasks[url]?.cancel()
        saveTasks.removeValue(forKey: url)
        
        Task.detached(priority: .utility) {
            let recoveryURL = self.getRecoveryURL(for: url)
            if FileManager.default.fileExists(atPath: recoveryURL.path) {
                try? FileManager.default.removeItem(at: recoveryURL)
                print("[AutoRecovery] Cleared recovery file for \(url.lastPathComponent)")
            }
        }
    }
    
    /// Checks for any valid recovery files that exist on disk
    nonisolated func checkRecoveryFiles() -> [URL] {
        // Reconstruct directory path
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("TypstEdit")
        let dir = appDirectory.appendingPathComponent("AutoRecovery")
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        
        return files.filter { $0.pathExtension == "recovery" }
    }
    
    nonisolated func hasRecovery(for url: URL) -> Bool {
        let rec = getRecoveryURL(for: url)
        return FileManager.default.fileExists(atPath: rec.path)
    }
    
    nonisolated func restoreContent(for url: URL) -> String? {
        let rec = getRecoveryURL(for: url)
        return try? String(contentsOf: rec, encoding: .utf8)
    }
}
