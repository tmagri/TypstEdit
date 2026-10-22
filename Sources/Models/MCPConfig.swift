import Foundation

/// How a configured MCP server is reached. Stdio servers are spawned as local
/// subprocesses (the common case — most MCP servers today ship as an `npx`/
/// `uvx`/binary command); SSE and streamable-HTTP are remote servers reached
/// over a URL. Only stdio is wired up to an actual transport right now —
/// remote transports are defined so configs round-trip but `MCPClient`
/// currently only implements `.stdio`.
enum MCPTransportType: String, Codable, CaseIterable, Identifiable {
    case stdio
    case sse
    case http

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stdio: return "Local Command (stdio)"
        case .sse: return "Remote (SSE)"
        case .http: return "Remote (HTTP)"
        }
    }
}

/// One configured MCP server, matching the `mcpServers` map convention shared
/// by Claude Desktop, Cursor, VS Code, and OpenCode's own `mcp.json`, so a
/// config written for one of those tools can be pasted in here with minimal
/// changes.
struct MCPServerConfig: Codable, Identifiable, Equatable {
    var name: String
    var transport: MCPTransportType = .stdio
    var command: String?
    var args: [String] = []
    var env: [String: String] = [:]
    var url: String?
    var enabled: Bool = true

    /// Tool names explicitly disabled by the user even though the server is
    /// enabled — e.g. allow a filesystem server's `read_file` but block
    /// `delete_file`. Empty means "every tool the server advertises".
    var disabledTools: [String] = []

    var id: String { name }

    var isConfigured: Bool {
        switch transport {
        case .stdio: return !(command ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        case .sse, .http: return !(url ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

/// Root shape of `mcp.json`, both globally and per-project.
struct MCPConfigFile: Codable {
    var mcpServers: [String: MCPServerConfig] = [:]
}

/// Identifies a server across its scope, since a global and a project config
/// may both define a server with the same name.
struct ScopedMCPServer: Identifiable, Equatable {
    var config: MCPServerConfig
    var scope: ConfigScope

    var id: String { "\(scope.rawValue):\(config.name)" }
}

/// Loads/saves `mcp.json` for a given scope. Kept separate from `MCPManager`
/// (which owns running processes) so Settings UI can read/write configs
/// without needing a live client.
enum MCPConfigStore {
    static func globalConfigURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TypstEdit/mcp.json")
    }

    static func load(from url: URL) -> MCPConfigFile {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MCPConfigFile.self, from: data) else {
            return MCPConfigFile()
        }
        return decoded
    }

    static func save(_ config: MCPConfigFile, to url: URL) {
        let folder = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
