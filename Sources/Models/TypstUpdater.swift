import Foundation
import Combine
import SwiftUI

@MainActor
class TypstUpdater: ObservableObject {
    @Published var isUpdating: Bool = false
    @Published var status: String = "Ready"
    @Published var progress: Double = 0
    @Published var lastError: String? = nil
    
    private var currentProcess: Process?
    
    private let repoURL = "https://github.com/typst/typst.git"
    private let releasesAPI = "https://api.github.com/repos/typst/typst/releases/latest"
    
    private var storageDirectory: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("TypstEdit", isDirectory: true)
        let sourceDir = appSupport.appendingPathComponent("typst_source", isDirectory: true)
        
        // Ensure directories exist
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        
        return sourceDir
    }
    
    func update() {
        guard !isUpdating else { return }
        
        isUpdating = true
        status = "Initializing..."
        progress = 0.05
        lastError = nil
        
        let mode = GeneralSettingsManager.shared.updateMode
        
        Task {
            if mode == .bleedingEdgeSource {
                await updateFromSource()
            } else {
                await updateFromBinary()
            }
        }
    }
    
    private func updateFromSource() async {
        status = "Checking environment..."
        progress = 0.1
        
        // Check for git and cargo
        guard await checkCommand("git"), await checkCommand("cargo") else {
            setError("Missing dependencies: 'git' and 'cargo' (Rust) are required for source builds.")
            return
        }
        
        do {
            try await syncRepository()
            try await buildTypst()
            
            let binaryPath = storageDirectory.appendingPathComponent("target/release/typst")
            if FileManager.default.fileExists(atPath: binaryPath.path) {
                setFinished(path: binaryPath.path)
            } else {
                setError("Build finished but binary not found at \(binaryPath.path)")
            }
        } catch {
            setError("Source update failed: \(error.localizedDescription)")
        }
    }
    
    private func updateFromBinary() async {
        status = "Fetching latest release info..."
        progress = 0.1
        
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: releasesAPI)!)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            
            let architecture = getArchitecture()
            let assetName = architecture == "arm64" ? "typst-aarch64-apple-darwin.tar.xz" : "typst-x86_64-apple-darwin.tar.xz"
            
            guard let asset = release.assets.first(where: { $0.name == assetName }) else {
                setError("Could not find suitable binary for \(architecture) in release \(release.tag_name)")
                return
            }
            
            status = "Downloading \(release.tag_name)..."
            progress = 0.3
            
            let downloadURL = URL(string: asset.browser_download_url)!
            let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
            
            status = "Extracting binary..."
            progress = 0.8
            
            let destinationDir = storageDirectory.appendingPathComponent("binary_install", isDirectory: true)
            try? FileManager.default.removeItem(at: destinationDir)
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            
            let tarProcess = Process()
            tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tarProcess.arguments = ["-xf", tempURL.path, "-C", destinationDir.path, "--strip-components=1"]
            
            try await runProcess(tarProcess)
            
            let binaryPath = destinationDir.appendingPathComponent("typst")
            if FileManager.default.fileExists(atPath: binaryPath.path) {
                setFinished(path: binaryPath.path)
            } else {
                setError("Extraction failed: binary not found in archive")
            }
        } catch {
            setError("Binary update failed: \(error.localizedDescription)")
        }
    }
    
    private func getArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }
    
    private func checkCommand(_ command: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }
            
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
    
    private func syncRepository() async throws {
        setStatus("Syncing repository...", progress: 0.3)
        
        let gitDir = storageDirectory.appendingPathComponent(".git")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        
        if FileManager.default.fileExists(atPath: gitDir.path) {
            process.arguments = ["pull"]
            process.currentDirectoryURL = storageDirectory
        } else {
            process.arguments = ["clone", repoURL, "."]
            process.currentDirectoryURL = storageDirectory
        }
        
        try await runProcess(process)
    }
    
    private func buildTypst() async throws {
        setStatus("Compiling Typst (this may take several minutes)...", progress: 0.5)
        
        let process = Process()
        let cargoPath = await runWhich("cargo") ?? "/usr/local/bin/cargo"
        process.executableURL = URL(fileURLWithPath: cargoPath)
        process.arguments = ["build", "--release"]
        process.currentDirectoryURL = storageDirectory
        
        try await runProcess(process)
    }
    
    private func runWhich(_ command: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        let pipe = Pipe()
        process.standardOutput = pipe
        
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                        continuation.resume(returning: path)
                        return
                    }
                }
                continuation.resume(returning: nil)
            }
            
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
    
    private func runProcess(_ process: Process) async throws {
        self.currentProcess = process
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? "Unknown process error"
                    continuation.resume(throwing: NSError(domain: "TypstUpdater", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output]))
                }
            }
            
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    private func setStatus(_ msg: String, progress: Double) {
        self.status = msg
        self.progress = progress
    }
    
    private func setError(_ msg: String) {
        self.status = "Failed"
        self.lastError = msg
        self.isUpdating = false
    }
    
    private func setFinished(path: String) {
        self.status = "Update successful!"
        self.progress = 1.0
        self.isUpdating = false
        GeneralSettingsManager.shared.customTypstPath = path
        GeneralSettingsManager.shared.useCustomTypst = true
    }
}

// GitHub API Models
struct GitHubRelease: Codable {
    let tag_name: String
    let assets: [GitHubAsset]
}

struct GitHubAsset: Codable {
    let name: String
    let browser_download_url: String
}
