import Foundation

/// Makes TypstEdit discoverable by external tools and AI agents: installs the
/// `typstedit` shell command and produces MCP configuration for common agents.
@MainActor
enum AgentIntegrationManager {
    static let toolName = "typstedit"
    /// Marker line that identifies a shim written by TypstEdit (so we never overwrite a foreign file).
    static let shimMarker = "# typstedit-shim: installed by TypstEdit"

    enum InstallError: LocalizedError {
        case foreignFile(String)
        case notWritable(String)
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .foreignFile(let path): return "\(path) already exists and was not created by TypstEdit."
            case .notWritable(let path): return "\(path) is not writable."
            case .cancelled: return "Installation was cancelled."
            case .failed(let message): return message
            }
        }
    }

    // MARK: - Paths

    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    static var appBundlePath: String? {
        Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundlePath : nil
    }

    /// Folders checked (in order) for an installed shim.
    static var candidateDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent("bin")
        ]
    }

    /// The command agents should run: the installed shim, else the app binary itself.
    static var preferredCommandPath: String {
        installedCommandLineTool()?.path ?? executablePath
    }

    static func installedCommandLineTool() -> URL? {
        candidateDirectories
            .map { $0.appendingPathComponent(toolName) }
            .first { isOurShim($0) }
    }

    static func isOurShim(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(shimMarker)
    }

    /// Whether `directory` is on the PATH a login shell would typically see.
    /// (A GUI app's own PATH is minimal, so /etc/paths is consulted too.)
    static func isOnPath(_ directory: URL) -> Bool {
        var entries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if let system = try? String(contentsOfFile: "/etc/paths", encoding: .utf8) {
            entries += system.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let extra = try? FileManager.default.contentsOfDirectory(atPath: "/etc/paths.d") {
            for file in extra {
                if let text = try? String(contentsOfFile: "/etc/paths.d/\(file)", encoding: .utf8) {
                    entries += text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                }
            }
        }
        // Homebrew's shellenv adds this for virtually every Apple Silicon developer setup.
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") { entries.append("/opt/homebrew/bin") }
        let target = directory.standardizedFileURL.path
        return entries.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == target }
    }

    // MARK: - Shim

    /// A tiny launcher script. It prefers the app's current location, then
    /// /Applications, then Spotlight — so it keeps working if the app moves.
    static func shimScript() -> String {
        let current = appBundlePath.map { "\"\($0)\"" } ?? ""
        return """
        #!/bin/sh
        \(shimMarker)
        # Command-line access to TypstEdit: `typstedit --help`. Remove via TypstEdit > Settings > Integrations.
        for APP in \(current) "/Applications/TypstEdit.app" "$HOME/Applications/TypstEdit.app"; do
          if [ -x "$APP/Contents/MacOS/TypstEdit" ]; then exec "$APP/Contents/MacOS/TypstEdit" "$@"; fi
        done
        APP=$(mdfind 'kMDItemCFBundleIdentifier == "\(TypstEditCLI.bundleIdentifier)"' 2>/dev/null | head -n 1)
        if [ -n "$APP" ] && [ -x "$APP/Contents/MacOS/TypstEdit" ]; then exec "$APP/Contents/MacOS/TypstEdit" "$@"; fi
        echo "typstedit: TypstEdit.app was not found. Open TypstEdit and reinstall the command-line tool." >&2
        exit 127

        """
    }

    /// Installs the shim into `directory`, or the first writable folder on the PATH
    /// (falling back to ~/.local/bin). Does not prompt for a password.
    @discardableResult
    static func installCommandLineTool(into directory: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let target: URL
        if let directory {
            target = directory
        } else {
            target = candidateDirectories.first { dir in
                fm.isWritableFile(atPath: dir.path) && isOnPath(dir)
            } ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let url = target.appendingPathComponent(toolName)
        if fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            guard isOurShim(url) else { throw InstallError.foreignFile(url.path) }
            try fm.removeItem(at: url)
        }
        guard fm.isWritableFile(atPath: target.path) else { throw InstallError.notWritable(target.path) }
        try shimScript().write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Installs into /usr/local/bin (always on the default macOS PATH) with an admin prompt.
    @discardableResult
    static func installCommandLineToolWithAdministrator() throws -> URL {
        let destination = URL(fileURLWithPath: "/usr/local/bin/\(toolName)")
        if FileManager.default.fileExists(atPath: destination.path), !isOurShim(destination) {
            throw InstallError.foreignFile(destination.path)
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("typstedit-shim-\(UUID().uuidString)")
        try shimScript().write(to: staging, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: staging) }

        let shell = "/bin/mkdir -p /usr/local/bin && /bin/cp '\(staging.path)' '\(destination.path)' && /bin/chmod 755 '\(destination.path)'"
        let source = "do shell script \"\(shell.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 { throw InstallError.cancelled }
            throw InstallError.failed(errorInfo[NSAppleScript.errorMessage] as? String ?? "Installation failed.")
        }
        return destination
    }

    static func uninstallCommandLineTool() throws {
        while let url = installedCommandLineTool() {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Agent configuration

    enum AgentClient: String, CaseIterable, Identifiable {
        case generic = "Generic (mcpServers JSON)"
        case claudeCode = "Claude Code"
        case claudeDesktop = "Claude Desktop"
        case codex = "Codex CLI"
        case opencode = "opencode"
        case cursor = "Cursor / Windsurf / VS Code"

        var id: String { rawValue }

        var hint: String {
            switch self {
            case .generic: return "Paste into the agent's MCP configuration file."
            case .claudeCode: return "Run in Terminal."
            case .claudeDesktop: return "~/Library/Application Support/Claude/claude_desktop_config.json — or use “Add to Claude Desktop”."
            case .codex: return "Add to ~/.codex/config.toml."
            case .opencode: return "Add to opencode.json (project) or ~/.config/opencode/opencode.json."
            case .cursor: return "Add to .cursor/mcp.json, ~/.codeium/windsurf/mcp_config.json, or .vscode/mcp.json (use \"servers\" for VS Code)."
            }
        }
    }

    static func configSnippet(for client: AgentClient, command: String = preferredCommandPath) -> String {
        let quoted = jsonString(command)
        switch client {
        case .generic, .claudeDesktop, .cursor:
            return """
            {
              "mcpServers": {
                "typstedit": {
                  "command": \(quoted),
                  "args": ["mcp"]
                }
              }
            }
            """
        case .claudeCode:
            return "claude mcp add --scope user typstedit -- \(shellQuoted(command)) mcp"
        case .codex:
            return """
            [mcp_servers.typstedit]
            command = \(quoted)
            args = ["mcp"]
            """
        case .opencode:
            return """
            {
              "mcp": {
                "typstedit": {
                  "type": "local",
                  "command": [\(quoted), "mcp"],
                  "enabled": true
                }
              }
            }
            """
        }
    }

    static var claudeDesktopConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// Merges the TypstEdit server into Claude Desktop's config, preserving everything else.
    static func addToClaudeDesktop() throws {
        let url = claudeDesktopConfigURL
        var config: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: url.path), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.failed("Claude Desktop's config is not a JSON object; edit it by hand.")
            }
            config = parsed
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["typstedit"] = ["command": preferredCommandPath, "args": ["mcp"]]
        config["mcpServers"] = servers
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "\"\(value)\"" }
        return String(text.dropFirst().dropLast())
    }

    private static func shellQuoted(_ value: String) -> String {
        value.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) }
            ? value
            : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
