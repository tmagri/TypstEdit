import Foundation

/// Prevents nested creation of backup, temp, and vectorcaches directories.
/// This utility ensures that if a file is already located in one of these special directories,
/// we never create a nested subfolder of the same type within it.
enum SafeDirectoryManager {
    private static let specialDirs = ["backups", "temp", "vectorcaches", ".typstedit"]
    
    /// Checks if a given URL path contains any of the special directory names.
    /// - Parameter url: The URL to check
    /// - Returns: The name of the special directory found, or nil if none found
    static func containsSpecialDirectory(_ url: URL) -> String? {
        let pathComponents = url.pathComponents
        for component in pathComponents {
            if specialDirs.contains(component) {
                return component
            }
        }
        return nil
    }
    
    /// Safely resolves a backup directory, preventing nested backups.
    /// If the file is already in a backups directory, returns the existing backups directory.
    /// Otherwise, returns the parent directory with "backups" appended.
    /// - Parameters:
    ///   - fileURL: The original file URL
    ///   - projectRoot: Optional project root URL
    /// - Returns: Safe backup directory URL
    static func safeBackupDirectory(for fileURL: URL, projectRoot: URL?) -> URL {
        if let specialDir = containsSpecialDirectory(fileURL) {
            if specialDir == "backups" {
                // File is already in a backups directory, return it as-is
                return fileURL.deletingLastPathComponent()
            }
            // File is inside a protected directory (temp or vectorcaches).
            // Per new policy we must NOT create backups for files located in
            // protected directories and must not route them to external backups.
            // Return the file's parent (no "backups" subfolder) so callers can
            // decide to skip creating backups entirely.
            return fileURL.deletingLastPathComponent()
        }

        // Normal case: create backups directory in parent
        return fileURL.deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
    }

    /// Returns an external backup directory inside Application Support used when the
    /// original file is located in a protected directory (temp/vectorcaches).
    static func safeExternalBackupDirectory(for fileURL: URL) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSupport.appendingPathComponent("TypstEdit/ExternalBackups", isDirectory: true)
        return base
    }
    
    /// Safely resolves a temp directory, preventing nested temp directories.
    /// If the project is already in a temp directory, returns that directory.
    /// Otherwise, returns either `<project>/temp` or, when the project (or the
    /// global default) opts out of in-project storage, a per-project mirror
    /// under the OS temp directory — see `AppTempDirectoryManager`.
    /// - Parameter projectRoot: The project root URL
    /// - Returns: Safe temp directory URL
    @MainActor
    static func safeTempDirectory(in projectRoot: URL) -> URL {
        if let specialDir = containsSpecialDirectory(projectRoot), specialDir == "temp" {
            // Project is already in a temp directory, return it as-is
            return projectRoot
        }
        if ProjectSettingsManager.effectiveStoreTempInProject(for: projectRoot) {
            return projectRoot.appendingPathComponent("temp")
        }
        return AppTempDirectoryManager.ensureDirectory(for: projectRoot, kind: .compilerScratch)
    }
    
    /// Safely resolves a vectorcaches directory, preventing nested vectorcaches directories.
    /// If the project is already in a vectorcaches directory, returns that directory.
    /// Otherwise, returns either `<project>/vectorcaches` or, when the project (or the
    /// global default) opts out of in-project storage, a per-project mirror
    /// under the OS temp directory — see `AppTempDirectoryManager`.
    /// - Parameter projectRoot: The project root URL
    /// - Returns: Safe vectorcaches directory URL
    @MainActor
    static func safeVectorcachesDirectory(in projectRoot: URL) -> URL? {
        guard projectRoot.pathComponents.count > 0 else { return nil }
        
        if let specialDir = containsSpecialDirectory(projectRoot), specialDir == "vectorcaches" {
            // Project is already in a vectorcaches directory, return it as-is
            return projectRoot
        }
        if ProjectSettingsManager.effectiveStoreVectorCacheInProject(for: projectRoot) {
            return projectRoot.appendingPathComponent("vectorcaches", isDirectory: true)
        }
        return AppTempDirectoryManager.ensureDirectory(for: projectRoot, kind: .vectorCache)
    }
    
    /// Creates a directory safely, ensuring no nested special directories are created.
    /// - Parameters:
    ///   - url: The directory URL to create
    ///   - createIntermediates: Whether to create intermediate directories
    /// - Throws: FileManager errors
    static func createDirectorySafely(at url: URL, withIntermediateDirectories createIntermediates: Bool = true) throws {
        // Check if we're trying to create a nested special directory
        let pathComponents = url.pathComponents
        
        // Count occurrences of each special directory in the path
        for specialDir in specialDirs {
            let occurrences = pathComponents.filter { $0 == specialDir }.count
            if occurrences > 1 {
                // Attempting to create nested special directories - log warning but don't create
                print("[SafeDirectoryManager] Warning: Prevented creation of nested '\(specialDir)' directories at \(url.path)")
                return
            }
        }
        
        // Safe to create
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: nil
        )
    }
}
