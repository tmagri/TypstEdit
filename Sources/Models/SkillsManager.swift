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

    /// Supplementary files living alongside `SKILL.md` in the skill's own
    /// folder — reference docs, templates, examples — the Agent Skills
    /// convention of shipping material a skill's body can point at without
    /// it being loaded into every prompt. Read on demand by the AI via the
    /// `read_skill_file` tool (see `LocalToolExecutor`), not preloaded here.
    var attachments: [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url -> String? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDir else { return nil }
            let name = url.lastPathComponent
            return name == "SKILL.md" ? nil : name
        }.sorted()
    }
}

@MainActor
final class SkillsManager: ObservableObject {
    static let shared = SkillsManager()

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

    private init() {
        refreshBuiltin()
        refreshGlobal()
    }

    var allSkills: [AISkill] { builtinSkills + globalSkills + projectSkills }

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

    static var globalSkillsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TypstEdit/Skills", isDirectory: true)
    }

    /// The bundled skills folder inside the SwiftPM resource bundle
    /// (`Sources/Resources/Skills/`, declared as `.copy` in Package.swift so
    /// the `typst-reference/…` folder layout survives verbatim). Several
    /// candidate roots are probed because the resource bundle's location
    /// differs per environment: inside the installed app, next to the
    /// `swift run` executable, and beside the `swift test` runner bundle.
    static var builtinSkillsDirectory: URL? {
        let resourceBundleName = "TypstEdit_TypstEdit.bundle"
        var bundles: [Bundle] = [ModuleResources.main, .main, Bundle(for: SkillsManager.self)]
        for bundle in bundles {
            var bases = [bundle.resourceURL, bundle.bundleURL].compactMap({ $0 })
            // The resource bundle usually sits NEXT to the executable or test
            // runner bundle (`.build/<config>/TypstEdit_TypstEdit.bundle`).
            if let siblingRoot = bundle.bundleURL.deletingLastPathComponent() as URL? {
                bases.append(siblingRoot)
            }
            for base in bases {
                // Direct …/Skills layout.
                let dir = base.appendingPathComponent("Skills", isDirectory: true)
                if FileManager.default.fileExists(atPath: dir.path) {
                    return dir
                }
                // …/TypstEdit_TypstEdit.bundle(/Contents/Resources)/Skills.
                let nested = base.appendingPathComponent(resourceBundleName, isDirectory: true)
                for nestedRoot in [nested.appendingPathComponent("Skills", isDirectory: true),
                                   nested.appendingPathComponent("Contents/Resources/Skills", isDirectory: true)] {
                    if FileManager.default.fileExists(atPath: nestedRoot.path) {
                        return nestedRoot
                    }
                }
            }
            if let url = bundle.url(forResource: "Skills", withExtension: nil, subdirectory: "Skills") {
                return url.deletingLastPathComponent()
            }
        }
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

    /// Parses the simple `---\nkey: value\n---` frontmatter block used by
    /// `SKILL.md`. Deliberately not a general YAML parser — skill frontmatter
    /// only ever needs flat scalar keys, and pulling in a YAML dependency for
    /// two fields isn't worth it.
    private static func splitFrontmatter(_ content: String) -> ([String: String], String) {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---") else { return ([:], normalized) }

        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---" else { return ([:], normalized) }

        var frontmatter: [String: String] = [:]
        var i = 1
        while i < lines.count, lines[i] != "---" {
            let line = lines[i]
            if let colonIdx = line.firstIndex(of: ":") {
                let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                if !key.isEmpty {
                    frontmatter[key] = value
                }
            }
            i += 1
        }

        let body: String
        if i + 1 < lines.count {
            body = lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = ""
        }
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

    private static func slug(from name: String) -> String {
        let lowered = name.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        var slug = String(mapped)
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
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

        refreshAll()
        return allSkills.first { $0.folderName == folderName && $0.scope == scope }
    }

    func updateSkill(_ skill: AISkill, name: String, description: String, body: String) {
        guard skill.scope.isUserManageable else { return }
        let content = Self.render(name: name, description: description, body: body)
        try? content.write(to: skill.folderURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        refreshAll()
    }

    func deleteSkill(_ skill: AISkill) {
        guard skill.scope.isUserManageable else { return }
        try? FileManager.default.removeItem(at: skill.folderURL)
        refreshAll()
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
        refreshAll()
        return true
    }

    func removeAttachment(_ fileName: String, from skill: AISkill) {
        guard skill.scope.isUserManageable else { return }
        try? FileManager.default.removeItem(at: skill.folderURL.appendingPathComponent(fileName))
        refreshAll()
    }
}
