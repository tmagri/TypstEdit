import Foundation
import AppKit

/// Installs Agent Skills from the wild into the user's skills folder —
/// the global one, or the active project's `.typstedit/skills/`.
///
/// A skill is a folder with a `SKILL.md`; everything else in the folder is an
/// attachment the model reads on demand. The tricky part is that skills come
/// wrapped differently in practice, so this finds the skill rather than
/// assuming a layout:
///
///   * a GitHub repo whose skill lives in `skills/<name>/` (SimpleEnglish),
///   * a repo that keeps its skills in a *hidden* folder, which is what
///     `npx rea-agents setup` and the plugin marketplaces do
///     (`.agents/skills/<name>/`, `.cursor-plugin/skills/<name>/`),
///   * a repo that *declares* its skills in a plugin manifest
///     (`.claude-plugin/plugin.json`, `.cursor-plugin/plugin.json`, …),
///   * a repo with `SKILL.md` at the root,
///   * a repo with several skills inside `skills/` (installs all of them),
///   * a `.zip` of any of the above,
///   * a folder picked from disk,
///   * an npm package or package-runner command line
///     (`npx rea-agents setup`, `npm i -g rea-agents`), resolved to the
///     GitHub repository the package publishes from.
///
/// Nothing here runs code from the download or from the pasted command:
/// archives are opened with `ditto`, package runners are only *read* as
/// words, and only text files are copied.
///
/// Ported from Clippy's `SkillInstaller` (git-trees fast path, npm package
/// resolution, manifest-driven discovery), merged with TypstEdit's scope
/// model (global/project destinations).
@MainActor
enum SkillInstaller {

    enum InstallError: LocalizedError {
        case badURL
        case downloadFailed(String)
        case extractionFailed(String)
        case noSkillFound
        case skillNotFound(String)
        case tooLarge(Int)
        case cancelled
        case packageNotFound(String)
        case noPackageRepository(String)
        case isMCPCommand

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "That doesn't look like a skill source. Paste a GitHub repository, a `npx skills add owner/repo` command, an `npx <package> setup` command, an npm package name, a zip URL, or a local folder."
            case .downloadFailed(let message):
                return "Download failed: \(message)"
            case .extractionFailed(let message):
                return "Could not open the download: \(message)"
            case .noSkillFound:
                return "No SKILL.md was found. A skill folder must contain a SKILL.md file with name and description frontmatter."
            case .skillNotFound(let name):
                return "This repository has no skill named \"\(name)\". Drop --skill to install every skill it contains."
            case .tooLarge(let bytes):
                return "That archive is \(bytes / 1_048_576) MB — larger than the 50 MB limit for a skill."
            case .cancelled:
                return "Install cancelled."
            case .packageNotFound(let name):
                return "The npm registry has no package named \"\(name)\"."
            case .noPackageRepository(let name):
                return "The npm package \"\(name)\" does not publish from a GitHub repository, so there is nothing to install from."
            case .isMCPCommand:
                return "That's an MCP server command, not a skill. Paste it in Settings ▸ MCP ▸ Paste Command… to add the server."
            }
        }
    }

    /// Where an install should come from, after parsing whatever the user
    /// pasted. The `npx …` forms, a bare `owner/repo`, a GitHub URL (with an
    /// optional `tree/<ref>/<path>`), a zip URL, a local path, and an npm
    /// package all end up here.
    struct SourceSpec: Equatable {
        /// `owner/repo` on GitHub.
        var slug: String?
        /// Explicit ref from a `tree/<ref>/…` URL.
        var branch: String?
        /// Folder inside the repository that holds the skill(s).
        var subpath: String?
        /// `--skill <name>`: install only the skill with this name or folder.
        var skillName: String?
        /// A direct archive URL (already a .zip).
        var archiveURL: URL?
        /// A path on disk (folder or zip).
        var localPath: String?
        /// An npm package name with any version tag stripped. Resolved to a
        /// GitHub repository before downloading; `npx rea-agents setup`
        /// parses to this.
        var npmPackage: String?
    }

    /// One skill discovered inside a download.
    struct Candidate: Identifiable {
        /// The folder containing SKILL.md.
        let folderURL: URL
        /// `name:` from the frontmatter, falling back to the folder name.
        let name: String
        let description: String
        /// Non-SKILL.md files that will come along as attachments.
        let attachmentCount: Int

        /// Identity for SwiftUI lists: the folder the skill was found in.
        var id: URL { folderURL }
    }

    /// An MCP server a repository declares in its own `mcp.json`, offered
    /// alongside the skill because a skill that says "call the rea tool" is
    /// useless without the server that provides it. Nothing is registered
    /// until the caller asks (see `registerMCPServers`).
    struct DetectedServer {
        let name: String
        let config: MCPServerConfig
        /// Where in the repository it was declared.
        let origin: String
    }

    /// Everything an install found: the skills that landed, plus the MCP
    /// servers the same source offered.
    struct Outcome {
        var installed: [Candidate] = []
        var detectedServers: [DetectedServer] = []
        /// The `owner/repo` an npm package resolved to, when it did.
        var resolvedRepository: String?
    }

    /// Hard cap on a downloaded archive, so a stray link can't fill the disk.
    static let maxArchiveBytes = 50 * 1_048_576
    /// Cap on files pulled from one remote skill folder.
    static let maxSkillFiles = 400
    /// Cap on the total bytes of one remote skill.
    static let maxSkillBytes = 20 * 1_048_576

    // MARK: - Entry points

    /// Installs into the given scope. The destination is the global skills
    /// folder, or the project's `.typstedit/skills/` when `scope` is
    /// `.project` (which needs `projectRoot`).
    static func install(
        from rawSource: String,
        scope: ConfigScope,
        projectRoot: URL?,
        manager: SkillsManager,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> [Candidate] {
        guard scope.isUserManageable else { throw InstallError.badURL }
        let destination: URL
        switch scope {
        case .global:
            destination = SkillsManager.globalSkillsDirectory
        case .project:
            guard let projectRoot else { throw InstallError.badURL }
            destination = ProjectSettingsManager.skillsDirectory(for: projectRoot)
        case .builtin:
            throw InstallError.badURL
        }
        let installed = try await installDetailed(from: rawSource, progress: progress, destination: destination).installed
        manager.skillsDidChange()
        return installed
    }

    /// Installs from `source`, which may be a GitHub URL, a bare `owner/repo`,
    /// an `npx`/`npm` command line, an npm package name, a zip URL, or a
    /// local folder. Returns what was installed.
    static func install(
        from source: String,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> [Candidate] {
        try await installDetailed(from: source, progress: progress).installed
    }

    /// The full result: installed skills *and* the MCP servers the source
    /// declares. The Settings sheet shows the servers and registers them only
    /// when the user leaves that box ticked.
    static func installDetailed(
        from source: String,
        progress: @escaping @MainActor (String) -> Void,
        destination: URL = SkillsManager.globalSkillsDirectory
    ) async throws -> Outcome {
        let spec = try parseSource(source)

        if let localPath = spec.localPath {
            let url = URL(fileURLWithPath: (localPath as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw InstallError.badURL
            }
            var outcome: Outcome
            if isDirectory.boolValue {
                outcome = Outcome(installed: try installFromFolder(url, spec: spec, progress: progress, destination: destination))
            } else {
                outcome = Outcome(installed: try installFromArchive(url, spec: spec, progress: progress, destination: destination))
            }
            outcome.detectedServers = detectServers(in: url)
            return outcome
        }

        if let archiveURL = spec.archiveURL {
            var outcome = Outcome(
                installed: try await installFromRemoteArchive(archiveURL, spec: spec, progress: progress, destination: destination)
            )
            outcome.detectedServers = await detectServers(inRemoteArchive: archiveURL)
            return outcome
        }

        var slug = spec.slug
        if slug == nil, let package = spec.npmPackage {
            progress("Looking up \(package) on npm…")
            slug = try await repositorySlug(forNpmPackage: package)
        }
        guard let slug else { throw InstallError.badURL }

        progress("Downloading \(slug)…")
        let resolved = try await installFromRepository(slug: slug, spec: spec, progress: progress, destination: destination)
        var outcome = Outcome(installed: resolved.installed)
        outcome.detectedServers = resolved.servers
        if spec.npmPackage != nil { outcome.resolvedRepository = slug }
        return outcome
    }

    // MARK: - Source parsing

    /// Turns whatever the user pasted into a `SourceSpec`.
    ///
    /// Recognized shapes:
    ///
    ///     https://github.com/owner/repo
    ///     https://github.com/owner/repo/tree/main/skills/name
    ///     owner/repo
    ///     npx skills add owner/repo --skill name
    ///     npx -y skills add owner/repo
    ///     npx rea-agents setup
    ///     npx -y rea-agents@latest setup
    ///     npm install --global rea-agents
    ///     rea-agents
    ///     https://example.com/skill.zip
    ///     ~/Downloads/skill.zip  (and absolute paths)
    ///
    /// An `mcp add` line is refused here with a pointer to the MCP tab, since
    /// it describes a server rather than a skill. The text is still only read.
    static func parseSource(_ source: String) throws -> SourceSpec {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw InstallError.badURL }

        if (try? MCPAddCommand.parse(text)) != nil {
            throw InstallError.isMCPCommand
        }

        // A package-runner command line. Nothing is executed — the words are
        // only read, so the app keeps its "no downloaded code runs" rule.
        if let invocation = runnerInvocation(in: text) {
            let arguments = invocation.arguments
            let skill = flagValue("--skill", in: arguments)

            // `npx skills add owner/repo`: a skill *target* follows `add`.
            if isSkillsCli(invocation.package) {
                guard let addIndex = arguments.firstIndex(of: "add"),
                      arguments.count > addIndex + 1,
                      let target = arguments[(addIndex + 1)...].first(where: { !$0.hasPrefix("-") })
                else { throw InstallError.badURL }
                var spec = try parseSource(target)
                if spec.skillName == nil { spec.skillName = skill }
                return spec
            }

            // Anything else is an npm package: `npx rea-agents setup`,
            // `npm i -g rea-agents`. The subcommand (`setup`) is not ours to
            // run, so it only identifies the package.
            guard let package = npmPackageName(in: invocation.package) else {
                throw InstallError.badURL
            }
            var spec = SourceSpec()
            spec.npmPackage = package
            spec.skillName = skill
            return spec
        }

        // A local folder or zip.
        if text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix("./") {
            var spec = SourceSpec()
            spec.localPath = text
            return spec
        }

        // A bare `owner/repo` (no scheme, exactly one slash, no spaces).
        if !text.contains("://"),
           text.split(separator: "/").count == 2,
           !text.contains(" "),
           text.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil {
            var spec = SourceSpec()
            spec.slug = text.replacingOccurrences(of: ".git", with: "")
            return spec
        }

        // A bare npm package name: `rea-agents`, `@scope/thing`.
        if !text.contains("://"), !text.contains(" "), !text.contains("/"),
           let package = npmPackageName(in: text) {
            var spec = SourceSpec()
            spec.npmPackage = package
            return spec
        }

        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw InstallError.badURL
        }

        var spec = SourceSpec()
        if url.pathExtension.lowercased() == "zip" {
            spec.archiveURL = url
            return spec
        }
        guard let slug = repositorySlug(from: url) else { throw InstallError.badURL }
        spec.slug = slug
        spec.branch = repositoryRef(from: url)
        spec.subpath = repositorySubpath(from: url)
        return spec
    }

    /// A package runner invocation, split into the package it would run and
    /// the arguments that follow it verbatim (flags included, because a
    /// skill target can carry `--skill`).
    private struct RunnerInvocation {
        let package: String
        let arguments: [String]
    }

    /// Names of package runners this understands. `npm`, `pnpm`, `yarn` and
    /// `bun` only count with an install/exec verb after them, so a sentence
    /// that happens to start with "npm" is not mistaken for a skill source.
    private static let runnerNames: Set<String> = [
        "npx", "bunx", "pnpx", "npm", "pnpm", "yarn", "bun", "deno"
    ]
    private static let runnerVerbs: Set<String> = [
        "exec", "dlx", "x", "i", "install", "add", "global"
    ]
    /// Runner flags that take a value, so the value is not read as the package.
    private static let runnerFlagsWithValues: Set<String> = [
        "-p", "--package", "--registry", "--cache", "--call", "-c",
        "--userconfig", "--prefix", "--reporter", "--target"
    ]

    private static func runnerInvocation(in text: String) -> RunnerInvocation? {
        let words = text
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        guard let runnerIndex = words.firstIndex(where: { runnerNames.contains($0.lowercased()) })
        else { return nil }

        var rest = Array(words[(runnerIndex + 1)...])
        let runner = words[runnerIndex].lowercased()
        // `npx`, `bunx` and `pnpx` take the package directly; the package
        // managers need their verb first (`npm i -g <pkg>`).
        let needsVerb: Set<String> = ["npm", "pnpm", "yarn", "bun", "deno"]
        if needsVerb.contains(runner) {
            guard let verbIndex = rest.firstIndex(where: { !$0.hasPrefix("-") }),
                  runnerVerbs.contains(rest[verbIndex].lowercased())
            else { return nil }
            rest = Array(rest[(verbIndex + 1)...])
        }

        var package: String?
        var packageIndex: Int?
        var i = 0
        while i < rest.count {
            let word = rest[i]
            if word.hasPrefix("-") {
                if runnerFlagsWithValues.contains(word) {
                    // `-p <pkg>` names the package being run.
                    if (word == "-p" || word == "--package"), i + 1 < rest.count, package == nil {
                        package = rest[i + 1]
                        packageIndex = i + 1
                    }
                    i += 2
                } else {
                    i += 1
                }
                continue
            }
            if package == nil {
                package = word
                packageIndex = i
            }
            i += 1
        }
        guard let package, let packageIndex else { return nil }
        // Everything after the package is its own argument list, kept
        // verbatim so `--skill <name>` survives.
        let arguments = Array(rest[(packageIndex + 1)...])
        return RunnerInvocation(package: package, arguments: arguments)
    }

    /// `skills`, `@x/skills`, `skills-cli`… anything that is the skills.sh
    /// runner rather than a skill package.
    private static func isSkillsCli(_ package: String) -> Bool {
        let name = package.lowercased()
        return name == "skills" || name.hasSuffix("/skills")
    }

    /// Strips a version or dist-tag from an npm package spec and validates the
    /// name, so `rea-agents@latest` and `@scope/thing@1.2.3` both normalize.
    static func npmPackageName(in raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("@") {
            guard let slash = text.firstIndex(of: "/") else { return nil }
            let afterSlash = text.index(after: slash)
            let remainder = String(text[afterSlash...])
            let name = remainder.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
            guard !name.isEmpty,
                  name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
            else { return nil }
            return String(text[text.startIndex...slash]) + name
        }

        let name = text.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        guard !name.isEmpty,
              name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
        else { return nil }
        return name
    }

    private static func flagValue(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
        return arguments[index + 1]
    }

    // MARK: - npm packages

    /// Cache so a retried install does not re-ask the registry.
    private static var packageRepositoryCache: [String: String] = [:]

    /// The `owner/repo` a package publishes from, read from the registry
    /// metadata. `npx rea-agents setup` → `morluto/rea`.
    static func repositorySlug(forNpmPackage name: String) async throws -> String {
        if let cached = packageRepositoryCache[name] { return cached }

        let encoded = name.replacingOccurrences(of: "/", with: "%2f")
        guard let url = URL(string: "https://registry.npmjs.org/\(encoded)/latest") else {
            throw InstallError.packageNotFound(name)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("TypstEdit-Skill-Installer", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw InstallError.downloadFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw InstallError.packageNotFound(name) }
            guard (200..<300).contains(http.statusCode) else {
                throw InstallError.downloadFailed("HTTP \(http.statusCode)")
            }
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.packageNotFound(name)
        }
        // `repository` is either a URL string or `{ type, url }`.
        var candidates: [String] = []
        if let repository = object["repository"] as? [String: Any],
           let repoURL = repository["url"] as? String {
            candidates.append(repoURL)
        } else if let repository = object["repository"] as? String {
            candidates.append(repository)
        }
        if let homepage = object["homepage"] as? String { candidates.append(homepage) }
        if let bugs = object["bugs"] as? [String: Any], let bugsURL = bugs["url"] as? String {
            candidates.append(bugsURL)
        }

        for candidate in candidates {
            if let slug = githubSlug(fromGitURL: candidate) {
                packageRepositoryCache[name] = slug
                return slug
            }
        }
        throw InstallError.noPackageRepository(name)
    }

    /// `git+https://github.com/o/r.git`, `git@github.com:o/r.git`,
    /// `github:o/r`, `https://github.com/o/r#readme` → `o/r`.
    static func githubSlug(fromGitURL raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("git+") { text.removeFirst(4) }
        if text.hasPrefix("github:") {
            let rest = text.dropFirst("github:".count)
            let parts = rest.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            return "\(parts[0])/\(parts[1].replacingOccurrences(of: ".git", with: ""))"
        }
        // `git@github.com:owner/repo.git`
        if let colon = text.range(of: "github.com:") {
            let rest = text[colon.upperBound...]
            let parts = rest.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            return "\(parts[0])/\(parts[1].replacingOccurrences(of: ".git", with: ""))"
        }
        guard let url = URL(string: text), url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1].replacingOccurrences(of: ".git", with: ""))"
    }

    // MARK: - Repository

    /// Fetches a GitHub repo's file list and installs the skills it contains.
    ///
    /// The file list comes from the git trees API, so only the skill files
    /// themselves are downloaded — a repo like `morluto/rea` is 32 MB as a zip
    /// and under 200 KB as a skill. When that is unavailable (rate limit, a
    /// truncated tree, a host that is not GitHub) this falls back to the zip
    /// archive.
    private static func installFromRepository(
        slug: String,
        spec: SourceSpec,
        progress: @escaping @MainActor (String) -> Void,
        destination: URL
    ) async throws -> (installed: [Candidate], servers: [DetectedServer]) {
        do {
            let remote = try await installFromTree(slug: slug, spec: spec, progress: progress, destination: destination)
            return (remote.installed, remote.servers)
        } catch let error as InstallError {
            switch error {
            // A repository that genuinely has no skill should say so, rather
            // than trigger a 32 MB download that would find the same nothing.
            case .noSkillFound, .skillNotFound, .tooLarge, .cancelled:
                throw error
            default:
                // Anything else is a transport problem: try the archive.
                break
            }
        }

        let archive = try await installFromZipArchive(slug: slug, spec: spec, progress: progress, destination: destination)
        return (archive.installed, archive.servers)
    }

    /// Branch candidates: an explicit `tree/<ref>` first, then `main`, `master`.
    private static func candidateBranches(_ explicit: String?) -> [String] {
        var branches: [String] = []
        if let explicit { branches.append(explicit) }
        for branch in ["main", "master"] where !branches.contains(branch) {
            branches.append(branch)
        }
        return branches
    }

    private static func installFromZipArchive(
        slug: String,
        spec: SourceSpec,
        progress: @escaping @MainActor (String) -> Void,
        destination: URL
    ) async throws -> (installed: [Candidate], servers: [DetectedServer]) {
        progress("Downloading \(slug)…")
        var lastError: Error = InstallError.downloadFailed("unknown")
        for branch in candidateBranches(spec.branch) {
            guard let zipURL = URL(string: "https://codeload.github.com/\(slug)/zip/refs/heads/\(branch)") else { continue }
            do {
                let data = try await download(zipURL)
                // A `tree/<ref>/<path>` link narrows the archive to that
                // folder before discovery runs.
                let installed = try installArchiveData(
                    data,
                    sourceName: slug,
                    subpath: spec.subpath,
                    skillName: spec.skillName,
                    progress: progress,
                    destination: destination
                )
                return (installed, try detectServers(inArchiveData: data))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Why the git-trees fast path could not be used. Caught by
    /// `installFromRepository`, which then falls back to the zip archive.
    private enum TreeUnavailable: LocalizedError {
        case reason

        var errorDescription: String? {
            "This repository's file list could not be read; falling back to a full archive."
        }
    }

    private static func installFromTree(
        slug: String,
        spec: SourceSpec,
        progress: @escaping @MainActor (String) -> Void,
        destination: URL
    ) async throws -> (installed: [Candidate], servers: [DetectedServer]) {
        var lastError: Error = InstallError.downloadFailed("unknown")
        for branch in candidateBranches(spec.branch) {
            do {
                let (files, _) = try await fetchTree(slug: slug, branch: branch)
                progress("Reading skill…")
                let choices = try await chooseFolders(
                    files: files,
                    spec: spec,
                    rootName: slug.split(separator: "/").last.map(String.init) ?? "skill",
                    fetchText: { path in try? await fetchRawText(slug: slug, branch: branch, path: path) }
                )
                let installed = try await materialize(
                    choices,
                    slug: slug,
                    branch: branch,
                    progress: progress,
                    destination: destination
                )
                let servers = (try? await detectServersInTree(slug: slug, branch: branch, files: files)) ?? []
                return (installed, servers)
            } catch let error as InstallError {
                // `main` may exist without the skill while `master` has it.
                switch error {
                case .noSkillFound, .skillNotFound:
                    lastError = error
                    continue
                default:
                    throw error
                }
            } catch {
                // A transport problem reaches `installFromRepository`, which
                // falls back to the archive.
                throw error
            }
        }
        throw lastError
    }

    /// Every blob path in the repo, with its size, via the git trees API.
    private static func fetchTree(slug: String, branch: String) async throws -> (files: [String: Int], branch: String) {
        guard let url = URL(string: "https://api.github.com/repos/\(slug)/git/trees/\(branch)?recursive=1") else {
            throw InstallError.downloadFailed("bad tree URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("TypstEdit-Skill-Installer", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw InstallError.downloadFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.downloadFailed("HTTP \(http.statusCode)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TreeUnavailable.reason
        }
        // A truncated listing cannot be trusted to be complete.
        if object["truncated"] as? Bool == true { throw TreeUnavailable.reason }
        guard let entries = object["tree"] as? [[String: Any]] else { throw TreeUnavailable.reason }

        var files: [String: Int] = [:]
        for entry in entries where (entry["type"] as? String) == "blob" {
            guard let path = entry["path"] as? String else { continue }
            files[path] = (entry["size"] as? NSNumber)?.intValue ?? 0
        }
        return (files, branch)
    }

    /// `https://raw.githubusercontent.com/<slug>/<branch>/<path>`, with each
    /// path component escaped. Dots and slashes stay readable.
    private static func rawURL(slug: String, branch: String, path: String) -> URL? {
        let escapedPath = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let escapedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        return URL(string: "https://raw.githubusercontent.com/\(slug)/\(escapedBranch)/\(escapedPath)")
    }

    private static func fetchRawText(slug: String, branch: String, path: String) async throws -> String {
        guard let url = rawURL(slug: slug, branch: branch, path: path) else {
            throw InstallError.downloadFailed("bad raw URL for \(path)")
        }
        let data = try await download(url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Downloads the chosen folders into a temp directory, then runs the same
    /// local install path a folder pick uses.
    private static func materialize(
        _ choices: [FolderChoice],
        slug: String,
        branch: String,
        progress: @escaping @MainActor (String) -> Void,
        destination: URL
    ) async throws -> [Candidate] {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("typstedit-skill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var totalBytes = 0
        var totalFiles = 0
        var candidates: [Candidate] = []

        for choice in choices {
            progress("Installing \(choice.displayName)…")
            let safeName = choice.displayName.replacingOccurrences(of: "/", with: "-")
            let folder = work.appendingPathComponent(safeName, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            var attachments = 0
            for file in choice.files {
                let relative = relativePath(file, inside: choice.folder)
                guard !relative.isEmpty, !shouldSkip(path: relative) else { continue }
                guard totalFiles < maxSkillFiles, totalBytes < maxSkillBytes else { break }
                guard let fileURL = rawURL(slug: slug, branch: branch, path: file),
                      let data = try? await download(fileURL)
                else { continue }
                totalBytes += data.count
                totalFiles += 1
                let target = folder.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: target)
                if relative != "SKILL.md" { attachments += 1 }
            }

            let skillFile = folder.appendingPathComponent("SKILL.md")
            guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
            let meta = parseFrontmatter(content)
            candidates.append(Candidate(
                folderURL: folder,
                name: choice.name.isEmpty
                    ? (meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? choice.displayName)
                    : choice.name,
                description: meta["description"] ?? "",
                attachmentCount: attachments
            ))
        }

        guard !candidates.isEmpty else { throw InstallError.noSkillFound }
        return try installCandidates(candidates, progress: progress, into: destination)
    }

    /// `https://github.com/AminBlg/SimpleEnglish[/tree/main/skills/x]` →
    /// `AminBlg/SimpleEnglish`. A `tree/<ref>/<subpath>` suffix narrows the
    /// search to that subpath, which is how a multi-skill repo pins one.
    static func repositorySlug(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// The ref a `tree/<ref>/…` GitHub URL points at, when there is one.
    static func repositoryRef(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let treeIndex = parts.firstIndex(of: "tree"), parts.count > treeIndex + 1 else { return nil }
        return parts[treeIndex + 1]
    }

    /// The subpath a `tree/…` GitHub URL points at, when there is one.
    static func repositorySubpath(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let treeIndex = parts.firstIndex(of: "tree"), parts.count > treeIndex + 2 else { return nil }
        return parts[(treeIndex + 2)...].joined(separator: "/")
    }

    // MARK: - Archives

    private static func installFromRemoteArchive(
        _ url: URL,
        spec: SourceSpec,
        progress: @escaping @MainActor (String) -> Void,
        destination: URL
    ) async throws -> [Candidate] {
        progress("Downloading \(url.lastPathComponent)…")
        let data = try await download(url)
        return try installArchiveData(
            data,
            sourceName: url.deletingPathExtension().lastPathComponent,
            subpath: spec.subpath,
            skillName: spec.skillName,
            progress: progress,
            destination: destination
        )
    }

    private static func installFromArchive(
        _ url: URL,
        spec: SourceSpec,
        progress: @escaping @MainActor (String) -> Void,
        destination: URL
    ) throws -> [Candidate] {
        let data = try Data(contentsOf: url)
        return try installArchiveData(
            data,
            sourceName: url.deletingPathExtension().lastPathComponent,
            subpath: spec.subpath,
            skillName: spec.skillName,
            progress: progress,
            destination: destination
        )
    }

    private static func installArchiveData(
        _ data: Data,
        sourceName: String,
        subpath: String? = nil,
        skillName: String? = nil,
        progress: @escaping @MainActor (String) -> Void,
        destination: URL
    ) throws -> [Candidate] {
        guard data.count <= maxArchiveBytes else {
            throw InstallError.tooLarge(data.count)
        }
        let unpacked = try unpack(data)
        defer { try? FileManager.default.removeItem(at: unpacked.deletingLastPathComponent()) }

        progress("Reading skill…")
        let candidates = try discoverSkills(in: unpacked, subpath: subpath, skillName: skillName)
        return try installCandidates(candidates, progress: progress, into: destination)
    }

    /// Writes `data` to a temp zip and opens it with `ditto`, which handles
    /// the zip formats skill authors actually ship (GitHub archives,
    /// `zip -r`, Finder's "Compress"). The returned folder's parent is the
    /// scratch directory to remove.
    private static func unpack(_ data: Data) throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("typstedit-skill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let zipURL = work.appendingPathComponent("download.zip")
        try data.write(to: zipURL)

        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        let result = runProcess("/usr/bin/ditto", ["-x", "-k", zipURL.path, unpacked.path])
        guard result == 0 else {
            try? FileManager.default.removeItem(at: work)
            throw InstallError.extractionFailed("ditto exited \(result)")
        }
        return unpacked
    }

    // MARK: - Folders

    private static func installFromFolder(
        _ folder: URL,
        spec: SourceSpec,
        progress: @escaping @MainActor (String) -> Void,
        destination: URL
    ) throws -> [Candidate] {
        let candidates = try discoverSkills(in: folder, subpath: spec.subpath, skillName: spec.skillName)
        return try installCandidates(candidates, progress: progress, into: destination)
    }

    // MARK: - Discovery

    /// Directory names never worth descending into: version control, package
    /// caches, Python bytecode. Everything else — hidden folders included —
    /// is fair game, because that is where modern agents keep their skills.
    private static let deniedDirectoryNames: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", "__pycache__", ".build", ".swiftpm",
    ]
    /// Files that are never skill material, whatever folder they sit in.
    private static let deniedFileNames: Set<String> = [".DS_Store"]

    /// Folders that hold skills by convention, preferred when a repo has no
    /// manifest to say otherwise.
    private static let conventionalSkillRoots: [String] = [
        "skills",
        ".agents/skills",
        ".claude/skills",
        ".cursor/skills",
        ".opencode/skills",
        "agent-skills",
        "agents/skills",
    ]

    /// Finds every skill in `root`: each directory containing a `SKILL.md`.
    /// GitHub archives wrap everything in one `<repo>-<branch>/` folder, so a
    /// single top-level wrapper is descended through first. When `subpath`
    /// is given (a `tree/<ref>/<path>` link), only that folder is searched,
    /// and `skillName` narrows the result to one skill.
    static func discoverSkills(
        in root: URL,
        subpath: String? = nil,
        skillName: String? = nil
    ) throws -> [Candidate] {
        let index = localIndex(in: root)
        let choices = selectFolders(
            files: index.files,
            readText: index.readText,
            subpath: subpath,
            skillName: skillName
        )
        var found: [Candidate] = []
        for choice in choices {
            guard let candidate = makeCandidate(folder: index.base.appendingPathComponent(choice.folder),
                                                fallbackName: choice.displayName)
            else { continue }
            found.append(candidate)
        }
        return try finish(found, skillName: skillName)
    }

    /// A local tree read as relative paths, so discovery runs on the same
    /// input as the remote file list.
    private struct LocalIndex {
        /// The folder the relative paths are rooted at, after unwrapping a
        /// lone GitHub-style `repo-main/` wrapper.
        let base: URL
        let files: [String]
        let readText: (String) -> String?
    }

    private static func localIndex(in root: URL) -> LocalIndex {
        let fm = FileManager.default
        var searchRoot = root

        // Unwrap a lone GitHub-style wrapper folder (`repo-main/`,
        // `thing-1.2.3/`). The name carries a dash, which is what separates an
        // archive's wrapper from a repo that simply keeps everything in one
        // folder like `skills/` or `.agents/`.
        if let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]),
           entries.count == 1,
           (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let name = entries[0].lastPathComponent
            let isConventionalRoot = conventionalSkillRoots.contains(name)
                || conventionalSkillRoots.contains { $0.split(separator: "/").last.map(String.init) == name }
            if !name.hasPrefix("."), !isConventionalRoot, name.contains("-") {
                searchRoot = entries[0]
            }
        }

        var files: [String] = []
        let enumerator = fm.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )
        while let entry = enumerator?.nextObject() as? URL {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let relative = relativePath(entry.path, under: searchRoot.path)
            guard !relative.isEmpty else { continue }
            let components = relative.split(separator: "/").map(String.init)
            if isDirectory {
                if deniedDirectoryNames.contains(entry.lastPathComponent) {
                    enumerator?.skipDescendants()
                }
                continue
            }
            if deniedFileNames.contains(entry.lastPathComponent) { continue }
            if components.contains(where: { deniedDirectoryNames.contains($0) }) { continue }
            // Depth-limited so a stray symlink farm can't run away.
            guard components.count <= 12 else { continue }
            files.append(relative)
        }

        let base = searchRoot
        return LocalIndex(base: base, files: files, readText: { relative in
            try? String(contentsOf: base.appendingPathComponent(relative), encoding: .utf8)
        })
    }

    /// `path` relative to `base`, with no leading slash. Empty when equal.
    ///
    /// Paths are compared in their symlink-resolved form because
    /// `FileManager.enumerator` reports `/private/var/…` for a
    /// `/var/…` root on macOS.
    private static func relativePath(_ path: String, under base: String) -> String {
        let resolvedPath = resolvePath(path)
        let resolvedBase = resolvePath(base)
        let normalizedBase = resolvedBase.hasSuffix("/") ? resolvedBase : resolvedBase + "/"
        if resolvedPath == resolvedBase { return "" }
        guard resolvedPath.hasPrefix(normalizedBase) else { return path }
        return String(resolvedPath.dropFirst(normalizedBase.count))
    }

    /// Handles the `/private` prefix macOS adds to symlink-resolved temp paths.
    private static func resolvePath(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved
    }

    /// A skill folder chosen from a file list.
    private struct FolderChoice {
        /// Repo-relative folder (`""` when the skill is the repo root).
        let folder: String
        /// `name:` from frontmatter, when known.
        let name: String
        /// Repo-relative paths belonging to this skill, SKILL.md included.
        let files: [String]

        var displayName: String {
            if !name.isEmpty { return name }
            return folder.split(separator: "/").last.map(String.init) ?? "skill"
        }
    }

    /// Picks the skill folders out of a file list.
    ///
    /// Order of trust:
    ///
    ///  1. A manifest that *declares* its skills (`.claude-plugin/plugin.json`,
    ///     `.codex-plugin/plugin.json`, `.cursor-plugin/plugin.json`). The
    ///     publisher is saying "these are my user-facing skills", which is
    ///     exactly what stops a repo's own contributor skills from being
    ///     installed by accident.
    ///  2. A conventional skills folder (`skills/`, `.agents/skills/`, …).
    ///  3. Anywhere a `SKILL.md` appears.
    ///
    /// Only one tier is used (the first that yields anything), and copies of
    /// the same skill reachable from two places are collapsed by folder name.
    private static func selectFolders(
        files: [String],
        readText: (String) -> String?,
        subpath: String?,
        skillName: String? = nil,
        rootName: String = ""
    ) -> [FolderChoice] {
        let all = files.filter { !shouldSkip(path: $0) }

        // A `tree/<ref>/<path>` link narrows everything to that folder.
        var scoped = all
        if let subpath, !subpath.isEmpty {
            let prefix = subpath.hasSuffix("/") ? subpath : subpath + "/"
            let narrowed = all.filter { $0.hasPrefix(prefix) }
            if !narrowed.isEmpty { scoped = narrowed }
        }

        let skillFolders = scoped
            .filter { $0 == "SKILL.md" || $0.hasSuffix("/SKILL.md") }
            .map { $0 == "SKILL.md" ? "" : String($0.dropLast("SKILL.md".count)) }
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }

        guard !skillFolders.isEmpty else { return [] }

        var chosen = skillFolders

        // An explicit `--skill <name>` is the user's choice, so tiering by
        // manifest or convention would only hide the skill they asked for.
        if let skillName, !skillName.isEmpty {
            let wanted = skillName.lowercased()
            chosen = chosen.filter { folder in
                let basename = folder.isEmpty ? rootName
                    : (folder.split(separator: "/").last.map(String.init) ?? folder)
                if basename.lowercased() == wanted { return true }
                let skillPath = folder.isEmpty ? "SKILL.md" : folder + "/SKILL.md"
                return readText(skillPath)
                    .flatMap { parseFrontmatter($0)["name"] }
                    .map { $0.lowercased() == wanted } ?? false
            }
        } else {
            let declared = declaredSkillRoots(in: all, readText: readText)
            if !declared.isEmpty {
                let inside = chosen.filter { folder in
                    declared.contains { root in
                        root.isEmpty || folder == root || folder.hasPrefix(root + "/")
                    }
                }
                if !inside.isEmpty { chosen = inside }
            } else {
                let conventional = chosen.filter { folder in
                    conventionalSkillRoots.contains { root in
                        folder == root || folder.hasPrefix(root + "/")
                    }
                }
                if !conventional.isEmpty { chosen = conventional }
            }
        }

        // Shallowest first, then alphabetical, so the canonical copy of a
        // duplicated skill wins. One skill per folder name.
        let ordered = chosen.sorted { lhs, rhs in
            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        var seenNames = Set<String>()
        var result: [FolderChoice] = []
        for folder in ordered {
            let basename = folder.isEmpty ? rootName : (folder.split(separator: "/").last.map(String.init) ?? folder)
            let key = basename.lowercased()
            guard seenNames.insert(key).inserted else { continue }
            let contents = scoped.filter { path in
                // A skill at the repo root owns the root's own files, not
                // every subfolder (which would copy vendored source trees).
                guard !folder.isEmpty else { return !path.contains("/") }
                return path == folder || path.hasPrefix(folder + "/")
            }
            let name = (contents.first { $0 == (folder.isEmpty ? "SKILL.md" : folder + "/SKILL.md") })
                .flatMap { readText($0) }
                .flatMap { parseFrontmatter($0)["name"] }
                .flatMap { $0.isEmpty ? nil : $0 } ?? ""
            result.append(FolderChoice(folder: folder, name: name, files: contents))
        }
        return result
    }

    /// Skill roots a plugin manifest declares, relative to the repo root.
    private static func declaredSkillRoots(
        in files: [String],
        readText: (String) -> String?
    ) -> [String] {
        let manifestNames: Set<String> = [
            ".claude-plugin/plugin.json",
            ".codex-plugin/plugin.json",
            ".cursor-plugin/plugin.json",
            ".claude-plugin/marketplace.json",
            "plugin.json",
            ".plugin/plugin.json",
        ]
        var roots: [String] = []
        for manifest in files where manifestNames.contains(manifest) {
            guard let content = readText(manifest),
                  let object = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
                  let declared = object["skills"]
            else { continue }
            // The plugin root is the folder that *contains* a dotted plugin
            // folder (`.cursor-plugin/`), and the manifest itself otherwise.
            let manifestFolder = (manifest as NSString).deletingLastPathComponent
            let parentFolder = (manifestFolder as NSString).deletingLastPathComponent
            let pluginRoot = (manifestFolder as NSString).lastPathComponent.hasPrefix(".")
                ? parentFolder : manifestFolder

            for raw in declaredPathList(declared) {
                var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                while path.hasPrefix("./") { path.removeFirst(2) }
                guard !path.isEmpty, path != "." else { continue }
                let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
                let candidates = [
                    join(trimmed, onto: pluginRoot),
                    join(trimmed, onto: manifestFolder),
                ]
                for candidate in candidates {
                    let normalized = candidate.hasPrefix("./") ? String(candidate.dropFirst(2)) : candidate
                    let exists = files.contains { $0.hasPrefix(normalized + "/") }
                    if exists {
                        roots.append(normalized)
                        break
                    }
                }
            }
        }
        return roots
    }

    private static func declaredPathList(_ value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let list = value as? [String] { return list }
        if let list = value as? [[String: Any]] {
            return list.compactMap { $0["path"] as? String ?? $0["src"] as? String }
        }
        return []
    }

    private static func join(_ path: String, onto root: String) -> String {
        root.isEmpty || root == "." ? path : root + "/" + path
    }

    /// Paths that are never copied into a skill: VCS data, dependency
    /// caches, editor droppings.
    private static func shouldSkip(path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        if components.contains(where: { deniedDirectoryNames.contains($0) }) { return true }
        if let last = components.last, deniedFileNames.contains(last) { return true }
        return false
    }

    private static func makeCandidate(folder: URL, fallbackName: String? = nil) -> Candidate? {
        let skillFile = folder.appendingPathComponent("SKILL.md")
        guard let data = try? Data(contentsOf: skillFile),
              let content = String(data: data, encoding: .utf8) else { return nil }
        let meta = parseFrontmatter(content)
        let name = meta["name"].flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackName.flatMap { $0.isEmpty ? nil : $0 }
            ?? folder.lastPathComponent
        let attachments = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0 != "SKILL.md" && !$0.hasPrefix(".") } ?? []
        return Candidate(
            folderURL: folder,
            name: name,
            description: meta["description"] ?? "",
            attachmentCount: attachments.count
        )
    }

    /// Applies `--skill` and the stable ordering. `--skill name` selects one,
    /// by frontmatter name or folder name.
    private static func finish(_ found: [Candidate], skillName: String?) throws -> [Candidate] {
        if let skillName, !skillName.isEmpty {
            let wanted = skillName.lowercased()
            let match = found.filter {
                $0.name.lowercased() == wanted
                    || $0.folderURL.lastPathComponent.lowercased() == wanted
            }
            guard !match.isEmpty else { throw InstallError.skillNotFound(skillName) }
            return match
        }
        guard !found.isEmpty else { throw InstallError.noSkillFound }
        // Stable order so "installed 2 skills" reads predictably.
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The remote flavour of `discoverSkills`: same selection rules, fed from
    /// a tree listing.
    private static func chooseFolders(
        files: [String: Int],
        spec: SourceSpec,
        rootName: String,
        fetchText: @escaping (String) async -> String?
    ) async throws -> [FolderChoice] {
        // Only the manifests and SKILL.md files are read, so selection stays
        // a handful of requests.
        var texts: [String: String] = [:]
        let interesting = files.keys.filter {
            $0 == "SKILL.md" || $0.hasSuffix("/SKILL.md") || $0.hasSuffix("plugin.json")
                || $0.hasSuffix("marketplace.json")
        }
        for path in interesting {
            if let text = await fetchText(path) { texts[path] = text }
        }
        let readText: (String) -> String? = { texts[$0] }

        let choices = selectFolders(files: Array(files.keys), readText: readText,
                                    subpath: spec.subpath, skillName: spec.skillName,
                                    rootName: rootName)
        guard !choices.isEmpty else {
            if let skillName = spec.skillName, !skillName.isEmpty {
                throw InstallError.skillNotFound(skillName)
            }
            throw InstallError.noSkillFound
        }

        // Drop files that are too big to be reference text, and keep the
        // Skill.md first so a partially fetched folder still parses.
        return choices.map { choice in
            let kept = choice.files.filter { path in
                guard let size = files[path] else { return false }
                return size <= 2 * 1_048_576
            }
            return FolderChoice(folder: choice.folder, name: choice.name,
                                files: kept.sorted { lhs, rhs in
                                    let lhsIsSkill = lhs.hasSuffix("SKILL.md")
                                    let rhsIsSkill = rhs.hasSuffix("SKILL.md")
                                    if lhsIsSkill != rhsIsSkill { return lhsIsSkill }
                                    return lhs < rhs
                                })
        }
    }

    /// `path` without `folder/` in front.
    private static func relativePath(_ path: String, inside folder: String) -> String {
        guard !folder.isEmpty else { return path }
        guard path == folder || path.hasPrefix(folder + "/") else { return "" }
        if path == folder { return "" }
        return String(path.dropFirst(folder.count + 1))
    }

    /// Reads `name`/`description` from `SKILL.md` frontmatter, including the
    /// `|`/`>` block style real skills use for long descriptions.
    static func parseFrontmatter(_ content: String) -> [String: String] {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---") else { return [:] }
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---", let closing = lines.dropFirst().firstIndex(of: "---") else { return [:] }

        var result: [String: String] = [:]
        var i = 1
        while i < closing {
            let line = lines[i]
            guard let colon = line.firstIndex(of: ":") else { i += 1; continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            if value == "|" || value == ">" || value == "|-" || value == ">-" {
                let folded = value.hasPrefix(">")
                var block: [String] = []
                i += 1
                while i < closing {
                    let raw = lines[i]
                    guard raw.isEmpty || raw.hasPrefix(" ") || raw.hasPrefix("\t") else { break }
                    block.append(raw.trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                let joined = folded
                    ? block.filter { !$0.isEmpty }.joined(separator: " ")
                    : block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { result[key] = joined }
                continue
            }

            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
            i += 1
        }
        return result
    }

    // MARK: - MCP servers declared by the source

    /// Reads the `mcpServers` a repository publishes at its root, so a skill
    /// that tells the model to call a tool comes with the server that offers
    /// it. Only stdio commands and http(s) URLs are accepted; anything else
    /// is skipped rather than offered.
    private static func detectServers(in folder: URL) -> [DetectedServer] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return [] }
        var root = folder
        if isDirectory.boolValue {
            // A picked folder may be a repo checkout or a single skill folder;
            // unwrap one top-level folder so `repo-main/mcp.json` is found.
            if let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]),
               entries.count == 1,
               (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                root = entries[0]
            }
            var found: [DetectedServer] = []
            for name in ["mcp.json", ".mcp.json"] {
                let url = root.appendingPathComponent(name)
                if let data = try? Data(contentsOf: url) {
                    found.append(contentsOf: parseServers(data, origin: name, prefix: ""))
                }
            }
            return found
        }
        guard let data = try? Data(contentsOf: folder) else { return [] }
        return (try? detectServers(inArchiveData: data)) ?? []
    }

    private static func detectServers(inRemoteArchive url: URL) async -> [DetectedServer] {
        guard let data = try? await download(url) else { return [] }
        return (try? detectServers(inArchiveData: data)) ?? []
    }

    private static func detectServers(inArchiveData data: Data) throws -> [DetectedServer] {
        guard data.count <= maxArchiveBytes else { return [] }
        let unpacked = try unpack(data)
        defer { try? FileManager.default.removeItem(at: unpacked.deletingLastPathComponent()) }

        var root = unpacked
        if let entries = try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: [.isDirectoryKey]),
           entries.count == 1,
           (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            root = entries[0]
        }
        var found: [DetectedServer] = []
        for name in ["mcp.json", ".mcp.json"] {
            let url = root.appendingPathComponent(name)
            if let contents = try? Data(contentsOf: url) {
                found.append(contentsOf: parseServers(contents, origin: name, prefix: ""))
            }
        }
        return found
    }

    private static func detectServersInTree(
        slug: String,
        branch: String,
        files: [String: Int]
    ) async throws -> [DetectedServer] {
        var found: [DetectedServer] = []
        for name in ["mcp.json", ".mcp.json"] where files[name] != nil {
            guard let text = try? await fetchRawText(slug: slug, branch: branch, path: name) else { continue }
            found.append(contentsOf: parseServers(Data(text.utf8), origin: name, prefix: ""))
        }
        return found
    }

    /// Decodes the `mcpServers` map TypstEdit itself writes, which is also
    /// what Claude Desktop, Cursor and opencode read.
    static func parseServers(_ data: Data, origin: String, prefix: String) -> [DetectedServer] {
        guard let file = try? JSONDecoder().decode(MCPConfigFile.self, from: data) else { return [] }
        return file.mcpServers.values.compactMap { server in
            var config = server
            config.name = prefix + server.name
            guard config.isConfigured else { return nil }
            if config.transport.isRemote {
                config.command = nil
                config.args = []
            } else {
                config.url = nil
                config.headers = [:]
            }
            return DetectedServer(name: config.name, config: config, origin: origin)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Writes the detected servers into the global `mcp.json`. An existing
    /// entry with the same name is left alone — the user's own configuration
    /// always wins — and the names actually added are returned.
    @discardableResult
    static func registerMCPServers(_ servers: [DetectedServer]) -> [String] {
        guard !servers.isEmpty else { return [] }
        var file = MCPConfigStore.load()
        var added: [String] = []
        for server in servers where file.mcpServers[server.name] == nil {
            file.mcpServers[server.name] = server.config
            added.append(server.name)
        }
        guard !added.isEmpty else { return [] }
        MCPConfigStore.save(file)
        // Every window's manager reloads its configs when this fires (each
        // `SkillsManager` and `MCPManager` observes it).
        NotificationCenter.default.post(name: .globalAIConfigurationDidChange, object: nil)
        return added
    }

    // MARK: - Copying in

    /// Copies each candidate into `base` under a unique slug.
    private static func installCandidates(
        _ candidates: [Candidate],
        progress: @escaping @MainActor (String) -> Void,
        into base: URL
    ) throws -> [Candidate] {
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        var installed: [Candidate] = []
        for candidate in candidates {
            progress("Installing \(candidate.name)…")
            let preferred = candidate.folderURL.lastPathComponent.isEmpty
                ? candidate.name : candidate.folderURL.lastPathComponent
            let slug = uniqueSlug(for: preferred, in: base)
            let destination = base.appendingPathComponent(slug, isDirectory: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try copyTree(from: candidate.folderURL, to: destination, depth: 0)
            installed.append(candidate)
        }
        return installed
    }

    /// Copies a skill folder, skipping hidden files, VCS data, and anything
    /// that is not plausibly reference material. Depth-limited so a stray
    /// symlink farm can't run away.
    private static func copyTree(from source: URL, to destination: URL, depth: Int) throws {
        guard depth <= 8 else { return }
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let name = entry.lastPathComponent
            guard !deniedDirectoryNames.contains(name), !deniedFileNames.contains(name),
                  !name.hasPrefix(".") else { continue }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let target = destination.appendingPathComponent(name)
            if isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try copyTree(from: entry, to: target, depth: depth + 1)
            } else {
                // Skip bulky binaries (screenshots, PDFs); text is what the
                // skill prompt can actually put in front of the model.
                let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size <= 2 * 1_048_576 else { continue }
                try? fm.removeItem(at: target)
                try fm.copyItem(at: entry, to: target)
            }
        }
    }

    private static func uniqueSlug(for preferred: String, in base: URL) -> String {
        var slug = preferred
        var suffix = 2
        while FileManager.default.fileExists(atPath: base.appendingPathComponent(slug).path) {
            slug = "\(preferred)-\(suffix)"
            suffix += 1
        }
        return slug
    }

    // MARK: - Helpers

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("TypstEdit-Skill-Installer", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.downloadFailed("HTTP \(http.statusCode)")
        }
        guard data.count <= maxArchiveBytes else { throw InstallError.tooLarge(data.count) }
        return data
    }

    /// True when a quick request to GitHub succeeds. Used by the live test to
    /// skip instead of failing offline.
    static var canReachNetworkForTesting: Bool {
        get async {
            guard let url = URL(string: "https://api.github.com/zen") else { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            return (try? await URLSession.shared.data(for: request)) != nil
        }
    }

    private static func runProcess(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
