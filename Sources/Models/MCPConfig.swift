import Foundation

/// How a configured MCP server is reached. Stdio servers are spawned as local
/// subprocesses (the common case — most MCP servers today ship as an `npx`/
/// `uvx`/binary command). Remote servers are reached over a URL: `http` is
/// the current Streamable HTTP transport (MCP 2025-03-26 and later), `sse` the
/// older HTTP+SSE transport (MCP 2024-11-05) that some servers still serve.
/// Ported from Clippy's `MCPConfig.swift`.
enum MCPTransportType: String, Codable, CaseIterable, Identifiable {
    case stdio
    case sse
    case http

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stdio: return "Local Command (stdio)"
        case .sse: return "Remote (legacy SSE)"
        case .http: return "Remote (Streamable HTTP)"
        }
    }

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
    /// HTTP headers sent with every request to a remote server — typically
    /// `Authorization: Bearer ${keychain:name}`. Values resolve the same
    /// `${env:…}` / `${keychain:…}` placeholders as `env`, so the token never
    /// has to sit in `mcp.json` itself. Ignored for stdio servers.
    var headers: [String: String] = [:]
    var enabled: Bool = true

    /// Tool names explicitly disabled by the user even though the server is
    /// enabled — e.g. allow a filesystem server's `read_file` but block
    /// `delete_file`. Empty means "every tool the server advertises".
    var disabledTools: [String] = []

    /// Whether this server's read-only tools may be called concurrently with
    /// one another.
    ///
    /// Opt-in per server, because whether overlap is safe is the server's
    /// property, not the client's: a server holding one connection, a global
    /// lock, or shared mutable state answers a parallel call slowly or
    /// wrongly, and nothing in the protocol lets a client detect that. The
    /// `readOnlyHint` annotations this also requires are hints only.
    ///
    /// Off by default. A server whose tools are annotated read-only and whose
    /// operator knows it supports concurrent requests is the case this exists
    /// for — typically a remote server, where the round trip is what costs.
    var allowConcurrentCalls: Bool = false

    /// A client registered by hand with the server's sign-in service, for
    /// services that don't let apps register themselves (e.g. a shared Auth0
    /// tenant with dynamic client registration turned off). Nil means
    /// "register automatically", the normal case. Ignored for stdio servers.
    var oauth: MCPOAuthClientConfig?

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
        case .sse, .http: return Self.remoteURL(url) != nil
        }
    }

    /// The configured URL when it is an absolute http(s) URL with a host —
    /// the only kind a remote transport can connect to.
    static func remoteURL(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

extension MCPServerConfig {
    /// Every key the decoder understands, including the spellings other
    /// tools use. Kept apart from the synthesized `CodingKeys`, so encoding
    /// still writes TypstEdit's own field names and nothing else.
    private enum LenientKeys: String, CodingKey {
        case name, transport, type, command, args, env, environment, url, headers
        case enabled, disabled, disabledTools
        case allowConcurrentCalls
        case oauth
        case allowInsecure, insecure, allowInsecureConnections
    }

    /// Decodes TypstEdit's own entries and the shapes other MCP clients write.
    ///
    /// The synthesized decoder required every field, so a Claude Desktop
    /// entry (`{"command": "npx", "args": […]}`) failed to decode — and
    /// because `MCPConfigStore.load` swallows decode errors, the *whole file*
    /// read as empty. Adding `headers` would have done the same to every
    /// existing `mcp.json`. Missing fields now take their defaults instead.
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
        // Absent means off: a config written before this option existed must
        // not start overlapping calls on an upgrade.
        allowConcurrentCalls = try container.decodeIfPresent(Bool.self, forKey: .allowConcurrentCalls) ?? false
        // A malformed block reads as absent rather than dropping the whole file.
        oauth = (try? container.decodeIfPresent(MCPOAuthClientConfig.self, forKey: .oauth)) ?? nil
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

/// A pre-registered OAuth client for one server (see `MCPServerConfig.oauth`).
///
/// Example for a shared Auth0 tenant:
/// ```json
/// "oauth": {
///   "clientId": "AbC123…",
///   "callbackPort": 33418,
///   "audience": "https://api.cimpress.io/",
///   "scopes": ["openid", "email", "offline_access"]
/// }
/// ```
struct MCPOAuthClientConfig: Codable, Equatable {
    var clientId: String
    /// Only for a confidential client. Use a `${keychain:name}` placeholder:
    /// a literal secret in `mcp.json` would be readable by anything that can
    /// read the file.
    var clientSecret: String?
    /// The sign-in service matches callback URLs exactly, so a hand-registered
    /// client needs a fixed port: register
    /// `http://127.0.0.1:<callbackPort>/callback` as its callback URL.
    var callbackPort: Int?
    /// Sent as `audience` on the authorization request. Auth0 reads this
    /// instead of the standard `resource` parameter unless the tenant opts in
    /// to resource indicators; without it Auth0 issues a token the server
    /// can't use.
    var audience: String?
    /// Replaces the scopes the server advertises. Include `offline_access`
    /// to get a refresh token, so expiry renews silently.
    var scopes: [String]?

    /// The client id with surrounding whitespace removed; nil when blank, so
    /// an emptied form field turns pre-registration off again.
    var normalizedClientID: String? {
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A usable loopback port, or nil for "pick any free port".
    var normalizedCallbackPort: UInt16? {
        guard let callbackPort, (1024...65535).contains(callbackPort) else { return nil }
        return UInt16(callbackPort)
    }
}

/// Root shape of `mcp.json`.
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

/// Loads/saves `mcp.json` for a given scope. Kept separate from
/// `MCPManager` (which owns running processes) so Settings can read/write
/// configs without needing a live client. The global config lives under
/// Application Support; a project's lives in its `.typstedit/` folder (see
/// `ProjectSettingsManager.mcpConfigURL`).
enum MCPConfigStore {
    /// Test override so a suite can exercise the write path without touching
    /// the user's real server list. Only a test sets this, before it reads.
    nonisolated(unsafe) static var configURLOverride: URL?

    /// True inside an XCTest run. XCTest loads `XCTestCase` into any process
    /// it hosts, so this holds under `swift test` and Xcode alike.
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// `~/Library/Application Support/TypstEdit/mcp.json` — the global scope.
    static func globalConfigURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TypstEdit/mcp.json")
    }

    /// The default (global) config location, with the test guards: an
    /// override wins, and inside an XCTest run a throwaway path is returned so
    /// a test that sets no override must never see the user's servers. A
    /// fresh agent selects every enabled server, and fetching its tools starts
    /// them — Keychain and sign-in popups, and a hang on any that never
    /// answers. A path that does not exist reads as "no servers".
    static func configURL() -> URL {
        if let configURLOverride { return configURLOverride }
        if isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("TypstEditTests-no-mcp-\(ProcessInfo.processInfo.processIdentifier)")
                .appendingPathComponent("mcp.json")
        }
        return globalConfigURL()
    }

    static func load() -> MCPConfigFile {
        load(from: configURL())
    }

    static func load(from url: URL) -> MCPConfigFile {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MCPConfigFile.self, from: data) else {
            return MCPConfigFile()
        }
        return decoded
    }

    static func save(_ config: MCPConfigFile) {
        save(config, to: configURL())
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
