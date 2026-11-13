import Foundation

@MainActor
enum SkillInstaller {
    enum InstallError: LocalizedError {
        case invalidSource
        case downloadFailed(String)
        case extractionFailed
        case noSkillsFound
        case requestedSkillNotFound(String)
        case archiveTooLarge
        case fileTooLarge(String)
        case unsafeArchive

        var errorDescription: String? {
            switch self {
            case .invalidSource:
                return "Enter a GitHub repository, a .zip URL, a local folder, or an `npx skills add` command."
            case .downloadFailed(let message):
                return "Could not download the Skill source: \(message)"
            case .extractionFailed:
                return "Could not open the ZIP archive."
            case .noSkillsFound:
                return "No SKILL.md files were found in that source."
            case .requestedSkillNotFound(let name):
                return "No Skill named “\(name)” was found in that source."
            case .archiveTooLarge:
                return "The ZIP archive exceeds the 50 MB limit."
            case .fileTooLarge(let name):
                return "The Skill file “\(name)” exceeds the 2 MB per-file limit."
            case .unsafeArchive:
                return "The ZIP archive contains an unsafe path and was not opened."
            }
        }
    }

    struct Candidate: Identifiable {
        let id: URL
        let folderURL: URL
        let name: String
        let description: String
        let attachmentCount: Int
    }

    struct Source {
        var repository: String?
        var branch: String?
        var subpath: String?
        var archiveURL: URL?
        var localPath: String?
        var skillName: String?

        init(
            repository: String? = nil,
            branch: String? = nil,
            subpath: String? = nil,
            archiveURL: URL? = nil,
            localPath: String? = nil,
            skillName: String? = nil
        ) {
            self.repository = repository
            self.branch = branch
            self.subpath = subpath
            self.archiveURL = archiveURL
            self.localPath = localPath
            self.skillName = skillName
        }
    }

    static let maxArchiveBytes = 50 * 1_048_576
    private static let maxAttachmentBytes = 2 * 1_048_576
    private static let excludedDirectories: Set<String> = [
        ".git", ".github", "node_modules", "__pycache__", ".DS_Store"
    ]

    static func parseSource(_ rawSource: String) throws -> Source {
        var text = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw InstallError.invalidSource }

        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if let addIndex = words.firstIndex(of: "add"),
           words.prefix(addIndex).contains(where: { $0 == "npx" || $0 == "skills" || $0.hasSuffix("skills") }) {
            let arguments = Array(words.dropFirst(addIndex + 1))
            guard let target = arguments.first(where: { !$0.hasPrefix("-") }) else {
                throw InstallError.invalidSource
            }
            var source = try parseSource(target)
            if let flagIndex = arguments.firstIndex(of: "--skill"), arguments.indices.contains(flagIndex + 1) {
                source.skillName = arguments[flagIndex + 1]
            }
            return source
        }

        if text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix("./") {
            return Source(localPath: (text as NSString).expandingTildeInPath)
        }
        if !text.contains("://"),
           text.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$"#, options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: ".git", with: "")
            return Source(repository: text)
        }

        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw InstallError.invalidSource
        }
        if url.host?.lowercased() == "codeload.github.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 4, parts[2] == "zip" else { throw InstallError.invalidSource }
            return Source(archiveURL: url)
        }
        if url.pathExtension.lowercased() == "zip",
           url.host?.lowercased() == "github.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count >= 4, parts[2] == "archive" {
                let refPath = parts.dropFirst(3).joined(separator: "/")
                let archiveRef = refPath.hasSuffix(".zip") ? String(refPath.dropLast(4)) : refPath
                let repository = "\(parts[0])/\(parts[1])"
                guard repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
                    throw InstallError.invalidSource
                }
                return Source(archiveURL: URL(string: "https://codeload.github.com/\(repository)/zip/\(archiveRef)")!)
            }
        }
        if url.pathExtension.lowercased() == "zip" {
            return Source(archiveURL: url)
        }
        guard url.host?.lowercased() == "github.com" else {
            throw InstallError.invalidSource
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { throw InstallError.invalidSource }
        let repositoryName = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let repository = "\(parts[0])/\(repositoryName)"
        guard repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
            throw InstallError.invalidSource
        }
        guard let treeIndex = parts.firstIndex(of: "tree"), parts.count > treeIndex + 1 else {
            return Source(repository: repository)
        }
        let branch = parts[treeIndex + 1]
        let subpath = parts.count > treeIndex + 2 ? parts[(treeIndex + 2)...].joined(separator: "/") : nil
        return Source(repository: repository, branch: branch, subpath: subpath)
    }

    static func discoverSkills(in root: URL, subpath: String? = nil, skillName: String? = nil) throws -> [Candidate] {
        let fileManager = FileManager.default
        var searchRoot = root
        if let children = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ), children.count == 1,
           (try? children[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            searchRoot = children[0]
        }
        if let subpath, !subpath.isEmpty {
            let components = subpath.split(separator: "/")
            guard !components.contains(".."), !subpath.hasPrefix("/") else { throw InstallError.unsafeArchive }
            for base in [root, searchRoot] {
                let narrowed = components.reduce(base) { $0.appendingPathComponent(String($1), isDirectory: true) }
                if fileManager.fileExists(atPath: narrowed.path) {
                    searchRoot = narrowed
                    break
                }
            }
        }

        var candidates: [Candidate] = []
        if let enumerator = fileManager.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                if values?.isDirectory == true, excludedDirectories.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard fileURL.lastPathComponent == "SKILL.md",
                      let candidate = makeCandidate(in: fileURL.deletingLastPathComponent()) else { continue }
                candidates.append(candidate)
            }
        }

        if let skillName, !skillName.isEmpty {
            let match = candidates.filter {
                $0.name.localizedCaseInsensitiveCompare(skillName) == .orderedSame
                    || $0.folderURL.lastPathComponent.localizedCaseInsensitiveCompare(skillName) == .orderedSame
            }
            guard !match.isEmpty else { throw InstallError.requestedSkillNotFound(skillName) }
            return match
        }
        guard !candidates.isEmpty else { throw InstallError.noSkillsFound }
        return candidates.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func install(
        from rawSource: String,
        scope: ConfigScope,
        projectRoot: URL?,
        manager: SkillsManager,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> [Candidate] {
        guard scope.isUserManageable else { throw InstallError.invalidSource }
        if scope == .project, projectRoot == nil { throw InstallError.invalidSource }
        let source = try parseSource(rawSource)

        let candidates: [Candidate]
        if let localPath = source.localPath {
            let url = URL(fileURLWithPath: localPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw InstallError.invalidSource
            }
            if isDirectory.boolValue {
                candidates = try discoverSkills(in: url, subpath: source.subpath, skillName: source.skillName)
            } else {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) <= maxArchiveBytes else { throw InstallError.archiveTooLarge }
                candidates = try await discoverSkills(inArchive: Data(contentsOf: url), source: source)
            }
        } else {
            if let archiveURL = source.archiveURL {
                let archiveData = try await download(archiveURL)
                candidates = try await discoverSkills(inArchive: archiveData, source: source)
            } else if let repository = source.repository {
                var branches = source.branch.map { [$0] } ?? ["main", "master"]
                var lastError: Error?
                var foundCandidates: [Candidate]?
                while let branch = branches.first {
                    branches.removeFirst()
                    do {
                        let archiveData = try await download(repositoryArchiveURL(repository, branch: branch))
                        foundCandidates = try await discoverSkills(inArchive: archiveData, source: source)
                        break
                    } catch {
                        lastError = error
                    }
                }
                guard let foundCandidates else {
                    throw lastError ?? InstallError.downloadFailed("No repository archive could be read.")
                }
                candidates = foundCandidates
            } else {
                throw InstallError.invalidSource
            }
        }

        let destination: URL
        switch scope {
        case .global:
            destination = SkillsManager.globalSkillsDirectory
        case .project:
            guard let projectRoot else { throw InstallError.invalidSource }
            destination = ProjectSettingsManager.skillsDirectory(for: projectRoot)
        case .builtin:
            throw InstallError.invalidSource
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var installedFolders: [URL] = []
        do {
            for candidate in candidates {
                progress("Installing \(candidate.name)…")
                let baseName = slug(candidate.folderURL.lastPathComponent)
                var folderName = baseName
                var suffix = 2
                while FileManager.default.fileExists(atPath: destination.appendingPathComponent(folderName).path) {
                    folderName = "\(baseName)-\(suffix)"
                    suffix += 1
                }
                let target = destination.appendingPathComponent(folderName, isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                installedFolders.append(target)
                try copySkillFiles(from: candidate.folderURL, to: target, depth: 0)
            }
        } catch {
            for folder in installedFolders {
                try? FileManager.default.removeItem(at: folder)
            }
            throw error
        }
        manager.skillsDidChange()
        return candidates
    }

    private static func repositoryArchiveURL(_ repository: String, branch: String?) -> URL {
        let ref = branch ?? "main"
        let escapedRef = ref.replacingOccurrences(of: "/", with: "%2F")
        return URL(string: "https://codeload.github.com/\(repository)/zip/refs/heads/\(escapedRef)")!
    }

    private static func download(_ url: URL) async throws -> Data {
        let fetched: SafeURLFetcher.FetchedPage
        do {
            fetched = try await SafeURLFetcher.fetch(url, timeout: 60, maxBytes: maxArchiveBytes)
        } catch {
            throw InstallError.downloadFailed(error.localizedDescription)
        }
        guard (200..<300).contains(fetched.status) else {
            throw InstallError.downloadFailed("HTTP \(fetched.status)")
        }
        guard fetched.data.count <= maxArchiveBytes else { throw InstallError.archiveTooLarge }
        return fetched.data
    }

    private static func discoverSkills(inArchive data: Data, source: Source) async throws -> [Candidate] {
        guard data.count <= maxArchiveBytes else { throw InstallError.archiveTooLarge }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("typstedit-skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let archive = workspace.appendingPathComponent("source.zip")
        try data.write(to: archive, options: .atomic)
        guard await archiveEntriesAreSafe(archive) else { throw InstallError.unsafeArchive }
        let extracted = workspace.appendingPathComponent("extracted", isDirectory: true)
        let status = await runProcess("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        guard status == 0 else { throw InstallError.extractionFailed }
        return try discoverSkills(in: extracted, subpath: source.subpath, skillName: source.skillName)
    }

    private static func archiveEntriesAreSafe(_ archive: URL) async -> Bool {
        let output = await runProcessOutput("/usr/bin/unzip", ["-Z1", archive.path])
        guard output.status == 0 else { return false }
        return output.stdout.split(whereSeparator: \.isNewline).allSatisfy { entry in
            let path = String(entry)
            return !path.hasPrefix("/")
                && !path.contains("\\")
                && !path.split(separator: "/").contains("..")
                && !path.split(separator: "/").contains(".")
        }
    }

    private static func makeCandidate(in folder: URL) -> Candidate? {
        let skillFile = folder.appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else { return nil }
        let metadata = parseFrontmatter(content)
        let name = metadata["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
        let attachments = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0 != "SKILL.md" && !$0.hasPrefix(".") }.count ?? 0
        return Candidate(
            id: folder,
            folderURL: folder,
            name: name,
            description: metadata["description"] ?? "",
            attachmentCount: attachments
        )
    }

    private static func parseFrontmatter(_ content: String) -> [String: String] {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var values: [String: String] = [:]
        var index = 1
        while index < end {
            let line = lines[index]
            guard let colon = line.firstIndex(of: ":") else {
                index += 1
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if ["|", ">", "|-", ">-"].contains(value) {
                let folded = value.hasPrefix(">")
                var block: [String] = []
                index += 1
                while index < end {
                    let raw = lines[index]
                    guard raw.isEmpty || raw.hasPrefix(" ") || raw.hasPrefix("\t") else { break }
                    block.append(raw.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = folded
                    ? block.filter { !$0.isEmpty }.joined(separator: " ")
                    : block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { values[key] = value }
                continue
            }
            if value.count >= 2, value.first == "'", value.last == "'" {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            } else if value.count >= 2, value.first == "\"", value.last == "\"" {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { values[key] = value }
            index += 1
        }
        return values
    }

    private static func copySkillFiles(from source: URL, to destination: URL, depth: Int) throws {
        guard depth <= 8 else { return }
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let name = entry.lastPathComponent
            guard !excludedDirectories.contains(name), !name.hasPrefix(".") else { continue }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { continue }
            let target = destination.appendingPathComponent(name)
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                try copySkillFiles(from: entry, to: target, depth: depth + 1)
            } else if name == "SKILL.md" && (values.fileSize ?? 0) > maxAttachmentBytes {
                throw InstallError.fileTooLarge(name)
            } else if (values.fileSize ?? 0) <= maxAttachmentBytes {
                try fileManager.copyItem(at: entry, to: target)
            }
        }
    }

    private static func slug(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        var text = String(name.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        while text.contains("--") { text = text.replacingOccurrences(of: "--", with: "-") }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if text.isEmpty { text = UUID().uuidString.lowercased() }
        return text
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) async -> Int32 {
        await runProcessOutput(executable, arguments).status
    }

    private static func runProcessOutput(_ executable: String, _ arguments: [String]) async -> (status: Int32, stdout: String) {
        await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: data, as: UTF8.self))
            } catch {
                return (-1, "")
            }
        }.value
    }
}
