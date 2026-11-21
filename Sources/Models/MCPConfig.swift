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

    /// Reads the transport names other tools write, so a pasted config keeps
    /// its meaning: Claude Desktop and VS Code write `"type": "http"` or
    /// `"sse"`, Cursor `"streamable-http"`, opencode `"local"` / `"remote"`.
    /// Unknown values return nil so the caller can fall back on the shape of
    /// the entry (a `url` means remote, a `command` local).
    static func lenient(_ raw: String) -> MCPTransportType? {
        switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "stdio", "local", "command": return .stdio
        case "http", "streamable-http", "streamablehttp", "remote": return .http
        case "sse": return .sse
        default: return nil
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
    /// Extra HTTP headers for a remote server. Values may use the
    /// `${env:VAR}` / `${keychain:name}` placeholders, so a shareable
    /// `mcp.json` never has to contain the token itself.
    var headers: [String: String] = [:]
    var enabled: Bool = true

    /// Tool names explicitly disabled by the user even though the server is
    /// enabled — e.g. allow a filesystem server's `read_file` but block
    /// `delete_file`. Empty means "every tool the server advertises".
    var disabledTools: [String] = []

    /// Lets this server be reached without transport security: plain `http://` to any host
    /// (not only this machine or the LAN), and an `https://` certificate that is self-signed,
    /// expired or issued for another name. Meant for internal services that have no
    /// certificate. Off by default. With it off, a remote server over plain http is refused
    /// unless it is local. Settings shows an orange warning on every server that has it on.
    /// Ignored for stdio servers.
    var allowInsecure: Bool = false

    var id: String { name }

    var isConfigured: Bool {
        switch transport {
        case .stdio: return !(command ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        case .sse, .http: return MCPServerConfig.remoteURL(url) != nil
        }
    }

    /// The remote endpoint, when `url` is a usable absolute http(s) URL.
    static func remoteURL(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
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
        disabledTools: [String] = [],
        allowInsecure: Bool = false
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
        self.allowInsecure = allowInsecure
    }
}

extension MCPServerConfig {
    /// Every key the decoder understands, including the spellings other
    /// tools use. Kept apart from the synthesized `CodingKeys`, so encoding
    /// still writes TypstEdit's own field names and nothing else.
    private enum LenientKeys: String, CodingKey {
        case name, transport, type, command, args, env, environment, url, headers
        case enabled, disabled, disabledTools
        case allowInsecure, insecure, allowInsecureConnections
    }

    /// Decodes TypstEdit's own entries and the shapes other MCP clients write.
    ///
    /// The hand decoder required `name` inside every entry, so a Claude
    /// Desktop entry (`{"command": "npx", "args": […]}`) failed to decode —
    /// and because `MCPConfigStore.load` swallows decode errors, the *whole
    /// file* read as empty. `type: "http"` (Claude Desktop/VS Code),
    /// `streamable-http` (Cursor) and opencode's command-as-array also
    /// mis-decoded as stdio. Missing fields now take their defaults instead.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LenientKeys.self)
        // The map key is the canonical name (see `MCPConfigFile`); an entry
        // without its own `name` gets it there.
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""

        // opencode writes the command as one array: executable + arguments.
        var command: String?
        var args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        if let single = try? container.decodeIfPresent(String.self, forKey: .command) {
            command = single
        } else if let parts = try? container.decodeIfPresent([String].self, forKey: .command), let first = parts.first {
            command = first
            args = Array(parts.dropFirst()) + args
        }
        self.command = command
        self.args = args

        env = try container.decodeIfPresent([String: String].self, forKey: .env)
            ?? container.decodeIfPresent([String: String].self, forKey: .environment)
            ?? [:]
        url = try container.decodeIfPresent(String.self, forKey: .url)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]

        let rawTransport = try container.decodeIfPresent(String.self, forKey: .transport)
            ?? container.decodeIfPresent(String.self, forKey: .type)
        if let rawTransport, let known = MCPTransportType.lenient(rawTransport) {
            transport = known
        } else {
            // No usable transport name: a URL without a command is remote.
            transport = (command == nil && url != nil) ? .http : .stdio
        }

        if let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) {
            self.enabled = enabled
        } else if let disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) {
            self.enabled = !disabled
        } else {
            self.enabled = true
        }
        disabledTools = try container.decodeIfPresent([String].self, forKey: .disabledTools) ?? []
        // Absent means off. `insecure` / `allowInsecureConnections` are accepted spellings for a
        // hand-written mcp.json; TypstEdit itself writes `allowInsecure`.
        allowInsecure = (try? container.decodeIfPresent(Bool.self, forKey: .allowInsecure))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .insecure))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .allowInsecureConnections))
            ?? false
    }

    /// Why this server may not be connected to as configured, or nil when it may. A remote
    /// server over plain http on a host that is not this machine or the LAN needs
    /// `allowInsecure`: the token and every tool result would cross the network unencrypted.
    static func insecureRefusal(for url: URL, allowInsecure: Bool) -> MCPError? {
        guard !allowInsecure, url.scheme?.lowercased() == "http",
              !MCPOAuthDiscovery.isLocalHost(url.host) else { return nil }
        return .insecureConnectionNotAllowed(host: url.host ?? url.absoluteString)
    }
}

/// Root shape of `mcp.json`, both globally and per-project.
struct MCPConfigFile: Codable {
    var mcpServers: [String: MCPServerConfig] = [:]

    init(mcpServers: [String: MCPServerConfig] = [:]) {
        self.mcpServers = mcpServers
    }

    private enum CodingKeys: String, CodingKey {
        case mcpServers
    }

    /// The map key is the server's name — that is how every other client
    /// identifies an entry, and the entries they write carry no `name` field.
    /// One malformed entry is skipped rather than failing the whole file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([String: FailableServer].self, forKey: .mcpServers) ?? [:]
        var servers: [String: MCPServerConfig] = [:]
        for (key, entry) in raw {
            guard var server = entry.value else { continue }
            server.name = key
            servers[key] = server
        }
        mcpServers = servers
    }

    /// Decodes one entry without letting its failure escape.
    private struct FailableServer: Decodable {
        let value: MCPServerConfig?
        init(from decoder: Decoder) throws {
            value = try? MCPServerConfig(from: decoder)
        }
    }
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
