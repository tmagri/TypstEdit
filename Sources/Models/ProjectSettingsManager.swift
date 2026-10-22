import Foundation
import Combine

/// Per-project configuration, persisted at `<project>/.typstedit/config.json`.
///
/// This folder is deliberately visible (not dot-hidden-and-forgotten) and
/// git-shareable: it mirrors the `.vscode/`, `.cursor/` convention so a team
/// can commit AI skills and MCP server definitions alongside the project.
/// Values here are `nil` by default, meaning "inherit the global default from
/// Settings" — only an explicit project override takes precedence.
struct ProjectConfig: Codable, Equatable {
    /// Overrides the global default for where the Typst compiler's scratch
    /// files live. `nil` = inherit `AISettingsManager.storeTempInProjectDefault`.
    var storeTempInProject: Bool?

    /// Overrides the global default for where the RAG embedding index lives.
    /// `nil` = inherit `AISettingsManager.storeVectorCacheInProjectDefault`.
    var storeVectorCacheInProject: Bool?

    /// Skill ids (global or project-scoped) enabled by default for this
    /// project's AI Prompt requests. Users can still toggle per-request.
    var enabledSkillIDs: [String]?

    /// MCP server ids (global or project-scoped) enabled by default for this
    /// project's AI Prompt requests.
    var enabledMCPServerIDs: [String]?

    static let empty = ProjectConfig()
}

@MainActor
final class ProjectSettingsManager: ObservableObject {
    @Published private(set) var config: ProjectConfig
    let projectRoot: URL

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
        self.config = Self.load(from: projectRoot)
    }

    // MARK: - Paths

    static let dotFolderName = ".typstedit"

    static func dotFolderURL(for projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(dotFolderName, isDirectory: true)
    }

    static func configFileURL(for projectRoot: URL) -> URL {
        dotFolderURL(for: projectRoot).appendingPathComponent("config.json")
    }

    static func skillsDirectory(for projectRoot: URL) -> URL {
        dotFolderURL(for: projectRoot).appendingPathComponent("skills", isDirectory: true)
    }

    static func mcpConfigURL(for projectRoot: URL) -> URL {
        dotFolderURL(for: projectRoot).appendingPathComponent("mcp.json")
    }

    // MARK: - Load / Save

    static func load(from projectRoot: URL) -> ProjectConfig {
        let url = configFileURL(for: projectRoot)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ProjectConfig.self, from: data) else {
            return .empty
        }
        return decoded
    }

    func reload() {
        config = Self.load(from: projectRoot)
    }

    func save() {
        let folder = Self.dotFolderURL(for: projectRoot)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: Self.configFileURL(for: projectRoot), options: .atomic)
    }

    func update(_ mutate: (inout ProjectConfig) -> Void) {
        mutate(&config)
        save()
    }

    // MARK: - Effective Resolution
    //
    // Static (file-based, instance-free) resolution so call sites that only
    // have a project root URL on hand — like `SafeDirectoryManager`, which
    // may run before any `ProjectSettingsManager` is instantiated for the
    // active window — don't need to thread an observable object through.
    // Reads are cheap: `config.json` is a few dozen bytes at most.

    static func effectiveStoreTempInProject(for projectRoot: URL) -> Bool {
        load(from: projectRoot).storeTempInProject ?? AISettingsManager.shared.storeTempInProjectDefault
    }

    static func effectiveStoreVectorCacheInProject(for projectRoot: URL) -> Bool {
        load(from: projectRoot).storeVectorCacheInProject ?? AISettingsManager.shared.storeVectorCacheInProjectDefault
    }
}
