import Foundation
import Combine

/// Where a skill (or MCP server) definition lives. Built-in ones ship inside
/// the app bundle and are read-only; global ones are managed in Settings and
/// apply to every project; project ones live in the project's `.typstedit/`
/// folder and are shareable via git.
enum ConfigScope: String, Codable, CaseIterable, Identifiable {
    case builtin
    case global
    case project

    var id: String { rawValue }
    var label: String {
        switch self {
        case .builtin: "Built-in"
        case .global: "Global"
        case .project: "Project"
        }
    }
    /// Built-in skills ship with the app and cannot be created, edited or
    /// deleted; only global/project scopes are user-manageable.
    var isUserManageable: Bool { self != .builtin }
}

/// An AI Skill: a folder containing `SKILL.md` with YAML-style frontmatter
/// (`name`, `description`) and a markdown body of instructions. This mirrors
/// the Agent Skills format used by Claude Code / OpenCode, so skills authored
/// for one tool are plain-text portable to the other: only the cheap
/// `description` is kept around for picking a skill, and the full `body` is
/// only pulled into a prompt once the user actually enables it.
struct AISkill: Identifiable, Equatable {
    let folderName: String
    var name: String
    var description: String
    var body: String
    let scope: ConfigScope
    let folderURL: URL

    /// Composite so a global and project skill that happen to share a folder
    /// name never collide in a SwiftUI `ForEach`.
    var id: String { "\(scope.rawValue):\(folderName)" }

    /// Supplementary files inside the skill's own folder — reference docs,
    /// templates, examples — read on demand by the AI via the
    /// `read_skill_file` tool (see `LocalToolExecutor`), not preloaded here.
    ///
    /// Subfolders are listed too (as `references/rule-catalog.md`), because
    /// real skills group reference material that way: a skill keeps its rule
    /// catalogue in `references/`.
    var attachments: [String] {
        var results: [String] = []
        let fm = FileManager.default
        func walk(_ directory: URL, prefix: String, depth: Int) {
            guard depth <= 4,
                  let entries = try? fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                  ) else { return }
            for entry in entries {
                let name = entry.lastPathComponent
                guard name != "SKILL.md", !name.hasPrefix(".") else { continue }
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
                if isDirectory {
                    walk(entry, prefix: relative, depth: depth + 1)
                } else {
                    results.append(relative)
                }
            }
        }
        walk(folderURL, prefix: "", depth: 0)
        return results.sorted()
    }
}

@MainActor
final class SkillsManager: ObservableObject {

    /// Skills shipped inside the app bundle (`Sources/Resources/Skills/…`).
    /// Read-only: they can be enabled per chat like any other skill, but the
    /// user cannot edit or delete them, and app updates refresh them.
    @Published private(set) var builtinSkills: [AISkill] = []
    @Published private(set) var globalSkills: [AISkill] = []
    @Published private(set) var projectSkills: [AISkill] = []
    /// The active project's root, so the Settings window (which has no
    /// direct reference to `EditorController`) can still show/manage
    /// project-scoped skills and know when none is open.
    @Published private(set) var projectRoot: URL?

    private var peerObserver: NSObjectProtocol?

    /// One instance per window (see `ProjectContext`), so project skills are
    /// only visible to the window whose project defines them.
    init() {
        refreshBuiltin()
        refreshGlobal()
        peerObserver = NotificationCenter.default.addObserver(
            forName: .globalAIConfigurationDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            let sender = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, sender != ObjectIdentifier(self) else { return }
                self.refreshAll()
            }
        }
    }

    /// Reloads after a change made here, and tells the other windows.
    private func didChangeSkills() {
        refreshAll()
        NotificationCenter.default.post(name: .globalAIConfigurationDidChange, object: self)
    }

    func skillsDidChange() {
        didChangeSkills()
    }

    /// One skill per folder, even if the same folder is reachable from two
    /// roots. Blind concatenation listed a folder present under two scopes
    /// twice — and because the ids are `scope:folder`, the two rows were also
    /// independently togglable, which is exactly the duplicate the Skills
    /// list showed.
    var allSkills: [AISkill] {
        var seenFolders = Set<String>()
        var result: [AISkill] = []
        // Builtin wins when a folder is in both scopes: it is the read-only
        // copy the app ships, and the user cannot edit it anyway.
        for skill in builtinSkills + globalSkills + projectSkills {
            let key = skill.folderURL.standardizedFileURL.path
            guard seenFolders.insert(key).inserted else { continue }
            result.append(skill)
        }
        return result
    }

    func skill(withID id: String) -> AISkill? {
        allSkills.first { $0.id == id }
    }

    /// Called whenever the active project changes (including becoming
    /// standalone, i.e. `nil`).
    func setProjectRoot(_ url: URL?) {
        guard projectRoot != url else { return }
        projectRoot = url
        refreshProject()
    }

    func refreshAll() {
        refreshGlobal()
        refreshProject()
    }

    private func refreshBuiltin() {
        builtinSkills = Self.builtinSkillsDirectory.map {
            Self.loadSkills(in: $0, scope: .builtin)
        } ?? []
        if builtinSkills.isEmpty {
            print("[SkillsManager] No built-in skills found in the app bundle.")
        }
    }

    private func refreshGlobal() {
        globalSkills = Self.loadSkills(in: Self.globalSkillsDirectory, scope: .global)
    }

    private func refreshProject() {
        guard let root = projectRoot else {
            projectSkills = []
            return
        }
        projectSkills = Self.loadSkills(in: ProjectSettingsManager.skillsDirectory(for: root), scope: .project)
    }

    // MARK: - Paths

    /// Test override for the global skills directory, so tests never touch or
    /// move real user skills.
    static var globalSkillsDirectoryOverride: URL?

    static var globalSkillsDirectory: URL {
        if let override = globalSkillsDirectoryOverride {
            let canonical = (try? override.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) }
            return canonical ?? override.resolvingSymlinksInPath()
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent("TypstEdit/Skills", isDirectory: true)
        let canonical = (try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) }
        return canonical ?? url.resolvingSymlinksInPath()
    }

    /// The bundled skills folder inside the SwiftPM resource bundle
    /// (`Sources/Resources/Skills/`, declared as `.copy` in Package.swift so
    /// the `typst-reference/…` folder layout survives verbatim). Several
    /// candidate roots are probed because the resource bundle's location
    /// differs per environment: inside the installed app, next to the
    /// `swift run` executable, and beside the `swift test` runner bundle.
    static var builtinSkillsDirectory: URL? {
        let resourceBundleName = "TypstEdit_TypstEdit.bundle"
        // A bundled-skills root must never be (or contain) the user's global
        // skills folder: that would load every installed skill twice, once
        // per scope, and the list would show duplicates.
        let globalPath = globalSkillsDirectory.standardizedFileURL.path

        var bundles: [Bundle] = [ModuleResources.main, .main, Bundle(for: SkillsManager.self)]
        for bundle in bundles {
            var bases = [bundle.resourceURL, bundle.bundleURL].compactMap({ $0 })
            // The resource bundle usually sits NEXT to the executable or test
            // runner bundle (`.build/<config>/TypstEdit_TypstEdit.bundle`).
            if let siblingRoot = bundle.bundleURL.deletingLastPathComponent() as URL? {
                bases.append(siblingRoot)
            }
            for base in bases {
                // Direct …/Skills layout, and
                // …/TypstEdit_TypstEdit.bundle(/Contents/Resources)/Skills.
                let candidates = [
                    base.appendingPathComponent("Skills", isDirectory: true),
                    base.appendingPathComponent(resourceBundleName, isDirectory: true)
                        .appendingPathComponent("Skills", isDirectory: true),
                    base.appendingPathComponent(resourceBundleName, isDirectory: true)
                        .appendingPathComponent("Contents/Resources/Skills", isDirectory: true),
                ]
                for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                    let resolved = candidate.standardizedFileURL.path
                    // Reject the global folder, and any root that merely
                    // contains it (it would be rescanned as builtin).
                    if resolved == globalPath { continue }
                    if globalPath.hasPrefix(resolved + "/") { continue }
                    return candidate
                }
            }
            if let url = bundle.url(forResource: "Skills", withExtension: nil, subdirectory: "Skills") {
                let resolved = url.deletingLastPathComponent().standardizedFileURL.path
                if resolved != globalPath, !globalPath.hasPrefix(resolved + "/") {
                    return url.deletingLastPathComponent()
                }
            }
        }
        #if DEBUG
        // Dev fallback: the source tree (Sources/Resources/Skills).
        let models = URL(fileURLWithPath: (#filePath as NSString).deletingLastPathComponent)
        let sourceSkills = models.deletingLastPathComponent()
            .appendingPathComponent("Resources/Skills", isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceSkills.path) { return sourceSkills }
        #endif
        return nil
    }

    // MARK: - Discovery

    private static func loadSkills(in directory: URL, scope: ConfigScope) -> [AISkill] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var skills: [AISkill] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard let data = try? Data(contentsOf: skillFile),
                  let content = String(data: data, encoding: .utf8) else { continue }

            let (frontmatter, body) = splitFrontmatter(content)
            let name = frontmatter["name"]?.isEmpty == false ? frontmatter["name"]! : entry.lastPathComponent
            let description = frontmatter["description"] ?? ""
            skills.append(AISkill(
                folderName: entry.lastPathComponent,
                name: name,
                description: description,
                body: body,
                scope: scope,
                folderURL: entry
            ))
        }
        return skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Parses the `---` frontmatter used by `SKILL.md`. Handles the block
    /// scalar style real skills use for long text:
    ///
    ///     description: |
    ///       first line
    ///       second line
    ///
    /// Deliberately not a general YAML parser — flat keys plus `|`/`>`
    /// blocks cover every published skill seen so far.
    private static func splitFrontmatter(_ content: String) -> ([String: String], String) {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---") else { return ([:], normalized) }
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---", let closing = lines.dropFirst().firstIndex(of: "---") else {
            return ([:], normalized)
        }

        var frontmatter: [String: String] = [:]
        var i = 1
        while i < closing {
            let line = lines[i]
            guard let colon = line.firstIndex(of: ":") else { i += 1; continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            // Block scalar: `|` keeps newlines, `>` folds them to spaces.
            if value == "|" || value == ">" || value == "|-" || value == ">-" {
                let folded = value.hasPrefix(">")
                var block: [String] = []
                i += 1
                while i < closing {
                    let raw = lines[i]
                    // The block ends at the first line that is not indented.
                    guard raw.isEmpty || raw.hasPrefix(" ") || raw.hasPrefix("\t") else { break }
                    block.append(raw.trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                let joined = folded
                    ? block.filter { !$0.isEmpty }.joined(separator: " ")
                    : block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { frontmatter[key] = joined }
                continue
            }

            // Plain scalar: strip matching quotes.
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { frontmatter[key] = value }
            i += 1
        }

        let body = lines[(closing + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (frontmatter, body)
    }

    private static func render(name: String, description: String, body: String) -> String {
        let escapedName = name.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedDescription = description.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        ---
        name: "\(escapedName)"
        description: "\(escapedDescription)"
        ---

        \(body)
        """
    }

    /// The SKILL.md content a `skill__update` would write, exposed so the
    /// approval card can show the model exactly what is about to land on
    /// disk before anything does.
    static func renderedSkillFile(name: String, description: String, body: String) -> String {
        render(name: name, description: description, body: body)
    }

    private static func slug(from name: String) -> String {
        let lowered = name.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        var slug = String(mapped)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? UUID().uuidString.lowercased() : slug
    }

    // MARK: - CRUD

    @discardableResult
    func createSkill(name: String, description: String, body: String, scope: ConfigScope, projectRoot: URL?) -> AISkill? {
        guard scope.isUserManageable else { return nil }
        let baseDir: URL
        switch scope {
        case .builtin:
            return nil
        case .global:
            baseDir = Self.globalSkillsDirectory
        case .project:
            guard let projectRoot else { return nil }
            baseDir = ProjectSettingsManager.skillsDirectory(for: projectRoot)
        }

        var folderName = Self.slug(from: name)
        var folder = baseDir.appendingPathComponent(folderName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folderName = "\(Self.slug(from: name))-\(suffix)"
            folder = baseDir.appendingPathComponent(folderName, isDirectory: true)
            suffix += 1
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let content = Self.render(name: name, description: description, body: body)
            try content.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        } catch {
            print("[SkillsManager] Failed to create skill '\(name)': \(error)")
            return nil
        }

        didChangeSkills()
        return allSkills.first { $0.folderName == folderName && $0.scope == scope }
    }

    func updateSkill(_ skill: AISkill, name: String, description: String, body: String) {
        guard skill.scope.isUserManageable else { return }
        let content = Self.render(name: name, description: description, body: body)
        try? content.write(to: skill.folderURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        didChangeSkills()
    }

    func deleteSkill(_ skill: AISkill) {
        guard skill.scope.isUserManageable else { return }
        try? FileManager.default.removeItem(at: skill.folderURL)
        didChangeSkills()
    }

    // MARK: - Attachments

    /// Copies `sourceURL` into the skill's folder so it sits alongside
    /// `SKILL.md`, overwriting any existing attachment with the same name.
    /// Returns false (without throwing) on any filesystem failure, since
    /// this is driven directly from a file picker and the caller only needs
    /// to know whether to refresh its list.
    @discardableResult
    func addAttachment(to skill: AISkill, from sourceURL: URL) -> Bool {
        guard skill.scope.isUserManageable else { return false }
        let destination = skill.folderURL.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            print("[SkillsManager] Failed to attach '\(sourceURL.lastPathComponent)' to skill '\(skill.name)': \(error)")
            return false
        }
        didChangeSkills()
        return true
    }

    func removeAttachment(_ fileName: String, from skill: AISkill) {
        guard skill.scope.isUserManageable else { return }
        try? FileManager.default.removeItem(at: skill.folderURL.appendingPathComponent(fileName))
        didChangeSkills()
    }

    // MARK: - Agent-authoring API
    //
    // The `skill__create` / `skill__update` / `skill__add_attachment` /
    // `skill__delete` tools route through these. They return the skill (or
    // an error message) instead of silently no-op'ing on builtin scopes, so
    // the model gets an answer it can act on — and the approval happens in
    // the agent before any of these run, so a decline never leaves debris.

    @discardableResult
    func createSkillForAgent(
        name: String, description: String, body: String, scope: ConfigScope = .global, projectRoot: URL? = nil
    ) -> Result<AISkill, Error> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return .failure(SkillAuthoringError.emptyName)
        }
        guard let created = createSkill(name: trimmedName, description: description, body: body, scope: scope, projectRoot: projectRoot) else {
            return .failure(SkillAuthoringError.writeFailed)
        }
        return .success(created)
    }

    func updateSkillForAgent(
        skill: AISkill, name: String, description: String, body: String
    ) -> Result<AISkill, Error> {
        guard skill.scope.isUserManageable else {
            return .failure(SkillAuthoringError.builtinReadOnly(skill.name))
        }
        updateSkill(skill, name: name, description: description, body: body)
        // `updateSkill` refreshes; re-look up so the returned value matches
        // what is on disk now.
        guard let updated = allSkills.first(where: { $0.id == skill.id }) else {
            return .failure(SkillAuthoringError.writeFailed)
        }
        return .success(updated)
    }

    /// Writes a text attachment into a skill's folder. `relativePath` may
    /// include subfolders (`references/rules.md`); intermediate directories
    /// are created. Binary content is not supported — the agent authors
    /// markdown and text, and images etc. come in through the Settings UI
    /// or the installer.
    func addAttachmentForAgent(
        skill: AISkill, relativePath: String, content: String
    ) -> Result<AISkill, Error> {
        guard skill.scope.isUserManageable else {
            return .failure(SkillAuthoringError.builtinReadOnly(skill.name))
        }
        let path = relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty else {
            return .failure(SkillAuthoringError.emptyPath)
        }
        // Containment: no escaping the skill folder, no overwriting the
        // skill file itself.
        guard !path.contains(".."), !path.hasPrefix("/"), path != "SKILL.md" else {
            return .failure(SkillAuthoringError.badPath)
        }
        let destination = skill.folderURL.appendingPathComponent(path)
        let rawBase = skill.folderURL.resolvingSymlinksInPath().standardizedFileURL.path
        let rawResolved = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let stripPrivate: (String) -> String = { p in
            p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p
        }
        let base = stripPrivate(rawBase)
        let resolved = stripPrivate(rawResolved)
        guard resolved.hasPrefix(base + "/") || resolved == base else {
            return .failure(SkillAuthoringError.badPath)
        }
        do {
            let parent = destination.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try content.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            return .failure(SkillAuthoringError.writeFailed)
        }
        didChangeSkills()
        guard let updated = allSkills.first(where: { $0.id == skill.id }) else {
            return .failure(SkillAuthoringError.writeFailed)
        }
        return .success(updated)
    }

    func deleteSkillForAgent(_ skill: AISkill) -> Result<String, Error> {
        guard skill.scope.isUserManageable else {
            return .failure(SkillAuthoringError.builtinReadOnly(skill.name))
        }
        try? FileManager.default.removeItem(at: skill.folderURL)
        didChangeSkills()
        return .success(skill.name)
    }
}

/// Why an agent-authoring call failed, in words the model can act on.
enum SkillAuthoringError: LocalizedError {
    case emptyName
    case emptyPath
    case badPath
    case builtinReadOnly(String)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "A skill needs a name."
        case .emptyPath:
            return "An attachment needs a file path."
        case .badPath:
            return "Attachment paths are relative paths inside the skill folder (no \"..\", no leading \"/\", and not SKILL.md itself)."
        case .builtinReadOnly(let skillName):
            return "\"\(skillName)\" is a built-in skill that ships with the app; it cannot be changed. Suggest a new skill instead."
        case .writeFailed:
            return "Writing to the skills folder failed."
        }
    }
}
