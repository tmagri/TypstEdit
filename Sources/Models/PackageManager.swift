import Foundation
import Combine

struct TypstPackageInfo: Codable, Identifiable {
    let name: String
    let version: String
    let description: String
    let repository: String?
    
    var id: String { "\(name)-\(version)" }
}

@MainActor
class PackageManager: ObservableObject {
    static let shared = PackageManager()
    
    @Published var packages: [TypstPackageInfo] = []
    @Published var isLoading: Bool = false
    @Published var isInstalling: Bool = false
    @Published var statusMessage: String?
    
    private let registryURL = URL(string: "https://packages.typst.org/preview/index.json")!
    
    private var typstPackagesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("typst/packages/preview", isDirectory: true)
    }
    
    func fetchPackages() async {
        isLoading = true
        statusMessage = "Fetching package list..."
        
        do {
            let (data, _) = try await URLSession.shared.data(from: registryURL)
            let decoded = try JSONDecoder().decode([TypstPackageInfo].self, from: data)
            
            // Filter to only show the latest version of each package
            var latestPackages: [String: TypstPackageInfo] = [:]
            for pkg in decoded {
                if let existing = latestPackages[pkg.name] {
                    if pkg.version.compare(existing.version, options: .numeric) == .orderedDescending {
                        latestPackages[pkg.name] = pkg
                    }
                } else {
                    latestPackages[pkg.name] = pkg
                }
            }
            
            self.packages = Array(latestPackages.values).sorted { $0.name < $1.name }
            self.statusMessage = nil
        } catch {
            self.statusMessage = "Failed to load packages: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    func installPackage(_ package: TypstPackageInfo) async {
        isInstalling = true
        statusMessage = "Installing \(package.name) v\(package.version)..."
        
        let downloadURL = URL(string: "https://packages.typst.org/preview/\(package.name)-\(package.version).tar.gz")!
        let destDir = typstPackagesDirectory.appendingPathComponent("\(package.name)/\(package.version)", isDirectory: true)
        
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
            
            // Create target directory
            try? FileManager.default.removeItem(at: destDir)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            
            // Extract using native tar
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", tempURL.path, "-C", destDir.path]
            
            try await runProcess(process)
            statusMessage = "Successfully installed \(package.name)!"
        } catch {
            statusMessage = "Failed to install \(package.name): \(error.localizedDescription)"
        }
        
        isInstalling = false
        
        // Clear success message after a few seconds
        if statusMessage?.contains("Successfully") == true {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !isInstalling { statusMessage = nil }
        }
    }
    
    func isInstalled(_ package: TypstPackageInfo) -> Bool {
        let destDir = typstPackagesDirectory.appendingPathComponent("\(package.name)/\(package.version)", isDirectory: true)
        return FileManager.default.fileExists(atPath: destDir.path)
    }
    
    private func runProcess(_ process: Process) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(domain: "PackageManager", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Extraction failed"]))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}