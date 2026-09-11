import Foundation
import Combine
import SwiftUI

@MainActor
class TypstUpdater: ObservableObject {
    static let shared = TypstUpdater()

    @Published var isUpdating: Bool = false
    @Published var status: String = "Ready"
    @Published var progress: Double = 0
    @Published var lastError: String? = nil
    
    // Update check properties
    @Published var isCheckingForUpdate: Bool = false
    @Published var currentVersion: String? = nil
    @Published var availableRelease: GitHubRelease? = nil
    @Published var showUpdatePrompt: Bool = false
    @Published var checkError: String? = nil

    private var hasCheckedOnLaunch: Bool = false
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

    /// Resolves the currently active Typst executable path.
    func resolveActiveTypstPath() -> String? {
        // Priority 0: Custom user-configured Typst
        if GeneralSettingsManager.shared.useCustomTypst,
           let customPath = GeneralSettingsManager.shared.resolvedCustomTypstPath {
            return customPath
        }

        // Priority 1: Bundled inside the app bundle
        if let bundlePath = Bundle.main.resourcePath {
            let bundledTypst = "\(bundlePath)/bin/typst"
            if FileManager.default.fileExists(atPath: bundledTypst) {
                return bundledTypst
            }
        }

        // Priority 2: Common system installation locations
        let paths = [
            "/opt/homebrew/bin/typst",
            "/usr/local/bin/typst",
            "/usr/bin/typst",
            NSString(string: "~/bin/typst").expandingTildeInPath,
            NSString(string: "~/.cargo/bin/typst").expandingTildeInPath,
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Detects the semantic version of the currently active Typst compiler.
    @discardableResult
    func detectCurrentVersion() async -> String? {
        guard let typstPath = resolveActiveTypstPath() else {
            self.currentVersion = nil
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let version: String? = await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                guard proc.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    continuation.resume(returning: nil)
                    return
                }
                // typst --version prints e.g. "typst 0.12.0 (737895d7)"
                if let regex = try? NSRegularExpression(pattern: #"\b\d+\.\d+(\.\d+)?\b"#),
                   let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                   let range = Range(match.range, in: output) {
                    continuation.resume(returning: String(output[range]))
                } else {
                    continuation.resume(returning: output)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }

        self.currentVersion = version
        return version
    }

    /// Compares two version strings (e.g. "0.12.0" and "0.15.1" or "v0.15.1").
    /// Returns true if v1 is strictly older than v2.
    static func isVersion(_ v1: String, strictlyOlderThan v2: String) -> Bool {
        let clean1 = v1.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n\r"))
        let clean2 = v2.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n\r"))

        let parts1 = clean1.split(separator: "-").first?.split(separator: ".").compactMap { Int($0) } ?? []
        let parts2 = clean2.split(separator: "-").first?.split(separator: ".").compactMap { Int($0) } ?? []

        let count = max(parts1.count, parts2.count)
        for i in 0..<count {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 < p2 { return true }
            if p1 > p2 { return false }
        }
        return false
    }

    /// Fetches the latest stable release metadata from GitHub.
    func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: URL(string: releasesAPI)!)
        request.setValue("TypstEdit-App", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw NSError(domain: "TypstUpdater", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "GitHub API error (status \(httpResponse.statusCode))"])
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// Checks if a new stable version of Typst is available.
    func checkForUpdates(userInitiated: Bool = false) async {
        guard !isCheckingForUpdate else { return }
        isCheckingForUpdate = true
        checkError = nil

        _ = await detectCurrentVersion()

        do {
            let release = try await fetchLatestRelease()
            self.availableRelease = release

            let latestTag = release.tag_name
            let isNewer: Bool
            if let current = self.currentVersion {
                isNewer = Self.isVersion(current, strictlyOlderThan: latestTag)
            } else {
                // If no existing version found, offer update
                isNewer = true
            }

            if isNewer {
                self.showUpdatePrompt = true
            } else if userInitiated {
                self.status = "Typst is up to date (\(self.currentVersion ?? latestTag))"
            }
        } catch {
            if userInitiated {
                self.checkError = "Failed to check for updates: \(error.localizedDescription)"
            }
            // If background launch check, fail silently without disrupting user
        }

        isCheckingForUpdate = false
    }

    /// Invoked on app load to check for updates if enabled in settings.
    func checkOnLaunchIfNeeded() {
        guard !hasCheckedOnLaunch else { return }
        hasCheckedOnLaunch = true

        guard GeneralSettingsManager.shared.checkForTypstUpdatesOnLaunch else { return }

        Task {
            // Short delay so the app UI and window render smoothly first
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await checkForUpdates(userInitiated: false)
        }
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
            let repoDir = storageDirectory.appendingPathComponent("git_repo", isDirectory: true)
            try await syncRepository(into: repoDir)
            try await buildTypst(in: repoDir)
            
            let binaryPath = repoDir.appendingPathComponent("target/release/typst")
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
            let release: GitHubRelease
            if let cached = availableRelease {
                release = cached
            } else {
                release = try await fetchLatestRelease()
                self.availableRelease = release
            }
            
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
            
            let destinationDir = storageDirectory.appendingPathComponent("stable_bin", isDirectory: true)
            try? FileManager.default.removeItem(at: destinationDir)
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            
            let tarProcess = Process()
            tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tarProcess.arguments = ["-xf", tempURL.path, "-C", destinationDir.path, "--strip-components=1"]
            
            try await runProcess(tarProcess)
            
            let binaryPath = destinationDir.appendingPathComponent("typst")
            if FileManager.default.fileExists(atPath: binaryPath.path) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath.path)
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
    
    private func resolveCommandPath(_ command: String) -> String? {
        let commonPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            NSString(string: "~/.cargo/bin").expandingTildeInPath,
            NSString(string: "~/bin").expandingTildeInPath
        ]
        
        for dir in commonPaths {
            let fullPath = (dir as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }

    private func checkCommand(_ command: String) async -> Bool {
        if resolveCommandPath(command) != nil {
            return true
        }
        
        // Fallback to 'which' just in case
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
    
    private func syncRepository(into repoDir: URL) async throws {
        setStatus("Syncing repository...", progress: 0.3)
        
        let gitDir = repoDir.appendingPathComponent(".git")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        
        try? FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        
        if FileManager.default.fileExists(atPath: gitDir.path) {
            process.arguments = ["pull"]
            process.currentDirectoryURL = repoDir
        } else {
            // Ensure directory is empty for clone if it already exists
            if FileManager.default.fileExists(atPath: repoDir.path) {
                let contents = try FileManager.default.contentsOfDirectory(atPath: repoDir.path)
                if !contents.isEmpty {
                    try FileManager.default.removeItem(at: repoDir)
                    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
                }
            }
            
            process.arguments = ["clone", repoURL, "."]
            process.currentDirectoryURL = repoDir
        }
        
        try await runProcess(process)
    }
    
    private func buildTypst(in repoDir: URL) async throws {
        setStatus("Compiling Typst (this may take several minutes)...", progress: 0.5)
        
        let process = Process()
        let cargoPath = await runWhich("cargo") ?? "/usr/local/bin/cargo"
        process.executableURL = URL(fileURLWithPath: cargoPath)
        process.arguments = ["build", "--release"]
        process.currentDirectoryURL = repoDir
        
        try await runProcess(process)
    }
    
    private func runWhich(_ command: String) async -> String? {
        if let resolved = resolveCommandPath(command) {
            return resolved
        }
        
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
        Task {
            _ = await detectCurrentVersion()
        }
    }
}

// GitHub API Models
struct GitHubRelease: Codable {
    let tag_name: String
    let name: String?
    let body: String?
    let assets: [GitHubAsset]
}

struct GitHubAsset: Codable {
    let name: String
    let browser_download_url: String
}
