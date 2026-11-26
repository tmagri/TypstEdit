import Foundation

/// Turns an `mcp add` command line — the kind server READMEs tell you to run
/// in Codex, Claude Code, Gemini CLI or opencode — into an `MCPServerConfig`.
///
/// Nothing is executed. The words are only read, the same as the skill
/// installer treats `npx skills add`, so pasting a line from a README can
/// never run the thing it names; it only describes it.
///
/// Accepted shapes, all of which appear in real setup instructions:
///
///     codex mcp add affinity -- uvx mcp-proxy --transport sse http://localhost:6767/sse
///     claude mcp add --transport http notion https://mcp.notion.com/mcp
///     claude mcp add --transport sse asana https://mcp.asana.com/sse
///     claude mcp add --env KEY=value airtable -- npx -y airtable-mcp-server
///     claude mcp add --header "Authorization: Bearer t" secure https://api.example.com/mcp
///     codex mcp add docs --url https://mcp.example.com/mcp
///     codex mcp add docs --url https://x/mcp --bearer-token-env-var DOCS_TOKEN
///     claude mcp add-json example '{"command":"npx","args":["-y","@example/mcp-server"]}'
///     { "mcpServers": { "demo": { "command": "npx", "args": ["-y", "demo"] } } }
enum MCPAddCommand {

    enum ParseError: LocalizedError {
        case unrecognized
        case missingName
        case missingTarget(String)
        case badPair(String)
        case badJSON(String)
        case noServers

        var errorDescription: String? {
            switch self {
            case .unrecognized:
                return "That doesn't look like an MCP command. Paste an `mcp add` line such as `codex mcp add affinity -- uvx mcp-proxy --transport sse http://localhost:6767/sse`, an `mcp add-json` line, or an `mcpServers` JSON block."
            case .missingName:
                return "The command has no server name. Put it after `mcp add`, before `--` or the URL."
            case .missingTarget(let name):
                return "\"\(name)\" has no launch command and no URL. Add `-- <command> …` for a local server, or give an http(s) URL."
            case .badPair(let text):
                return "Expected KEY=value (for --env) or `Name: value` (for --header), got \"\(text)\"."
            case .badJSON(let message):
                return "That JSON is not an MCP server definition: \(message)"
            case .noServers:
                return "No MCP server was found in that JSON."
            }
        }
    }

    // MARK: - Entry point

    /// Every server the text describes. A JSON block can define several; a
    /// command line defines one.
    static func parse(_ text: String) throws -> [MCPServerConfig] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.unrecognized }

        // A pasted JSON block, with or without the `mcpServers` wrapper.
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return try parseJSON(trimmed)
        }

        let tokens = tokenize(trimmed)
        guard let verbIndex = mcpVerbIndex(in: tokens) else { throw ParseError.unrecognized }
        let verb = tokens[verbIndex].lowercased()
        let arguments = Array(tokens[(verbIndex + 1)...])

        if verb == "add-json" { return try parseAddJSON(arguments) }
        return [try parseAdd(arguments)]
    }

    /// The index of `add`/`add-json` in `<client> mcp add …`. Only the first
    /// few words are checked, so a sentence that merely contains "mcp" is not
    /// mistaken for a command.
    private static func mcpVerbIndex(in tokens: [String]) -> Int? {
        let verbs: Set<String> = ["add", "add-json"]
        guard tokens.count >= 2 else { return nil }
        let limit = min(3, tokens.count - 1)
        for index in 0...limit where tokens[index].lowercased() == "mcp" {
            let next = index + 1
            guard next < tokens.count else { continue }
            if verbs.contains(tokens[next].lowercased()) { return next }
        }
        return nil
    }

    // MARK: - `mcp add`

    private static func parseAdd(_ arguments: [String]) throws -> MCPServerConfig {
        var name: String?
        var explicitTransport: MCPTransportType?
        var url: String?
        var env: [String: String] = [:]
        var headers: [String: String] = [:]
        var bearerTokenEnvVar: String?
        var command: [String] = []
        var positionals: [String] = []

        var index = 0
        while index < arguments.count {
            let word = arguments[index]

            // Everything after `--` belongs to the server process, untouched.
            if word == "--" {
                command = Array(arguments[(index + 1)...])
                break
            }

            if word.hasPrefix("-") {
                let value: String? = index + 1 < arguments.count ? arguments[index + 1] : nil
                switch word {
                case "--transport", "-t":
                    explicitTransport = value.flatMap(MCPTransportType.lenient)
                    index += 2
                case "--env", "-e":
                    guard let value else { throw ParseError.badPair(word) }
                    let (key, pair) = try splitPair(value, separator: "=", flag: word)
                    env[key] = pair
                    index += 2
                case "--header", "-H":
                    guard let value else { throw ParseError.badPair(word) }
                    let (key, pair) = try splitPair(value, separator: ":", flag: word)
                    headers[key] = pair
                    index += 2
                case "--url":
                    url = value
                    index += 2
                case "--bearer-token-env-var":
                    bearerTokenEnvVar = value
                    index += 2
                case "--scope", "-s":
                    // TypstEdit's scope (global/project) is chosen in the
                    // paste sheet, not in the command; the flag is read and
                    // dropped.
                    index += 2
                default:
                    // A flag this parser does not model. Skip the flag itself
                    // so its value, if any, is still read as a positional.
                    index += 1
                }
                continue
            }

            positionals.append(word)
            index += 1
        }

        if let first = positionals.first, !first.isEmpty {
            name = first
            positionals.removeFirst()
        }
        guard var serverName = name else { throw ParseError.missingName }
        serverName = sanitizedName(serverName)
        guard !serverName.isEmpty else { throw ParseError.missingName }

        // A URL positional means a remote server; anything else is the
        // command, which is how `gemini mcp add <name> <command> [args]`
        // works without a `--`.
        if command.isEmpty, let first = positionals.first {
            if MCPServerConfig.remoteURL(first) != nil {
                url = first
                positionals.removeFirst()
            } else {
                command = positionals
                positionals = []
            }
        }
        if url == nil, let trailing = positionals.first, MCPServerConfig.remoteURL(trailing) != nil {
            url = trailing
        }

        // A bearer token in the environment becomes an Authorization header,
        // so the token stays in the environment or Keychain instead of in the
        // config file.
        if let bearerTokenEnvVar, !bearerTokenEnvVar.isEmpty,
           headers.keys.first(where: { $0.lowercased() == "authorization" }) == nil {
            headers["Authorization"] = "Bearer ${env:\(bearerTokenEnvVar)}"
        }

        var config = MCPServerConfig(name: serverName)
        config.env = env
        config.headers = headers

        if let first = command.first, !first.isEmpty {
            config.transport = .stdio
            config.command = first
            config.args = Array(command.dropFirst())
            config.url = nil
            config.headers = [:]
            return config
        }

        if let url, MCPServerConfig.remoteURL(url) != nil {
            config.transport = explicitTransport ?? inferredTransport(for: url)
            config.url = url
            config.command = nil
            config.args = []
            config.env = [:]
            return config
        }

        throw ParseError.missingTarget(serverName)
    }

    /// A server name becomes the tool prefix (`name__tool`), so it is kept to
    /// characters every client accepts for that.
    static func sanitizedName(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = raw.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        var name = String(mapped)
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// `https://mcp.asana.com/sse` is an SSE endpoint; anything else is taken
    /// as Streamable HTTP, which is what most published endpoints serve.
    static func inferredTransport(for url: String) -> MCPTransportType {
        let path = URL(string: url)?.path.lowercased() ?? ""
        return path.hasSuffix("/sse") ? .sse : .http
    }

    private static func splitPair(
        _ text: String, separator: Character, flag: String
    ) throws -> (String, String) {
        guard let index = text.firstIndex(of: separator) else {
            throw ParseError.badPair("\(flag) \(text)")
        }
        let key = String(text[..<index]).trimmingCharacters(in: .whitespaces)
        let value = String(text[text.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw ParseError.badPair("\(flag) \(text)") }
        return (key, value)
    }

    // MARK: - `mcp add-json` and JSON blocks

    private static func parseAddJSON(_ arguments: [String]) throws -> [MCPServerConfig] {
        // `<name> <json>`; the name may be omitted when the JSON carries one.
        guard !arguments.isEmpty else { throw ParseError.unrecognized }
        if arguments.count == 1 {
            // Only a JSON blob: it must name the server itself.
            return try parseJSON(arguments[0], fallbackName: nil)
        }
        let json = arguments.dropFirst().joined(separator: " ")
        return try parseJSON(json, fallbackName: sanitizedName(arguments[0]))
    }

    /// An `mcpServers` wrapper, a single entry, or an array of entries.
    ///
    /// `fallbackName` is the name from `add-json <name> <json>`, which a bare
    /// entry has nowhere else to carry.
    static func parseJSON(_ text: String, fallbackName: String? = nil) throws -> [MCPServerConfig] {
        guard let data = text.data(using: .utf8) else {
            throw ParseError.badJSON("not valid text")
        }

        // The wrapper every client writes.
        if let file = try? JSONDecoder().decode(MCPConfigFile.self, from: data),
           !file.mcpServers.isEmpty {
            return file.mcpServers.values
                .compactMap { validated($0) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        // One entry, or several.
        if let list = try? JSONDecoder().decode([MCPServerConfig].self, from: data), !list.isEmpty {
            return try finish(list, fallbackName: fallbackName)
        }
        if let single = try? JSONDecoder().decode(MCPServerConfig.self, from: data) {
            return try finish([single], fallbackName: fallbackName)
        }

        // Surface the decoder's own reason when the shape is close but wrong.
        do {
            _ = try JSONDecoder().decode(MCPConfigFile.self, from: data)
        } catch {
            throw ParseError.badJSON(error.localizedDescription)
        }
        throw ParseError.noServers
    }

    private static func finish(
        _ servers: [MCPServerConfig], fallbackName: String?
    ) throws -> [MCPServerConfig] {
        let valid = servers.compactMap { server -> MCPServerConfig? in
            var config = server
            if config.name.trimmingCharacters(in: .whitespaces).isEmpty, let fallbackName {
                config.name = fallbackName
            }
            return validated(config)
        }
        guard !valid.isEmpty else { throw ParseError.noServers }
        return valid
    }

    /// A JSON entry may omit the name (a bare entry in a block gets it from
    /// the map key) and may be missing everything a server needs.
    private static func validated(_ server: MCPServerConfig) -> MCPServerConfig? {
        var config = server
        let name = sanitizedName(config.name)
        guard !name.isEmpty, config.isConfigured else { return nil }
        config.name = name
        // Keep only the fields the chosen transport reads, so a mixed entry
        // does not carry a stale command or header set into the editor.
        if config.transport.isRemote {
            config.command = nil
            config.args = []
        } else {
            config.url = nil
            config.headers = [:]
        }
        return config
    }

    // MARK: - Tokenizing

    /// Splits a command line into words the way a shell would for the parts
    /// that matter here: quoted runs stay together, `\`-newline continues the
    /// line, and a bare `--` survives as its own token.
    static func tokenize(_ raw: String) -> [String] {
        var text = raw
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")

        // A copy-pasted prompt marker is not part of the command.
        for marker in ["$ ", "> "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count))
        }

        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]

            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" || text[next] == "\\" {
                        current.append(text[next])
                        index = text.index(after: next)
                        hasCurrent = true
                        continue
                    }
                    current.append(character)
                    hasCurrent = true
                } else {
                    current.append(character)
                    hasCurrent = true
                }
            } else if character == "\"" || character == "'" {
                quote = character
                hasCurrent = true
            } else if character.isWhitespace {
                if hasCurrent {
                    tokens.append(current)
                    current = ""
                    hasCurrent = false
                }
            } else {
                current.append(character)
                hasCurrent = true
            }
            index = text.index(after: index)
        }
        if hasCurrent { tokens.append(current) }
        return tokens
    }
}
