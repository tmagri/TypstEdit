import Foundation

/// How a configured MCP server is reached. Stdio servers are spawned as local
/// subprocesses (the common case — most MCP servers today ship as an `npx`/
/// `uvx`/binary command); SSE and streamable-HTTP are remote servers reached
/// over a URL.
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

    /// Remote servers are reached over the network and can carry an OAuth
    /// token; a local command cannot.
    var isRemote: Bool { self != .stdio }
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
    /// Extra HTTP headers for a remote server. Values may use the
    /// `${env:VAR}` / `${keychain:name}` placeholders, so a shareable
    /// `mcp.json` never has to contain the token itself.
    var headers: [String: String] = [:]
    var enabled: Bool = true

    /// Tool names explicitly disabled by the user even though the server is
    /// enabled — e.g. allow a filesystem server's `read_file` but block
    /// `delete_file`. Empty means "every tool the server advertises".
    var disabledTools: [String] = []

    var id: String { name }

    var isConfigured: Bool {
        switch transport {
        case .stdio: return !(command ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        case .sse, .http: return MCPServerConfig.remoteURL(url) != nil
        }
    }

    /// The remote endpoint, when `url` is a usable absolute http(s) URL.
    static func remoteURL(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    private enum CodingKeys: String, CodingKey {
        case name, transport, command, args, env, url, headers, enabled, disabledTools
    }

    /// Decoded by hand so an older `mcp.json` (no `headers`, no `transport`)
    /// still reads, and an unknown transport name falls back to stdio rather
    /// than making the whole file undecodable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        let rawTransport = try container.decodeIfPresent(String.self, forKey: .transport) ?? "stdio"
        transport = MCPTransportType(rawValue: rawTransport) ?? .stdio
        command = try container.decodeIfPresent(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        url = try container.decodeIfPresent(String.self, forKey: .url)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        disabledTools = try container.decodeIfPresent([String].self, forKey: .disabledTools) ?? []
    }

    init(
        name: String,
        transport: MCPTransportType = .stdio,
        command: String? = nil,
        args: [String] = [],
        env: [String: String] = [:],
        url: String? = nil,
        headers: [String: String] = [:],
        enabled: Bool = true,
        disabledTools: [String] = []
    ) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.enabled = enabled
        self.disabledTools = disabledTools
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
