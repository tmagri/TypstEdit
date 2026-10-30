import Foundation
import AppKit

/// Headless command-line mode of the TypstEdit binary.
///
/// When the executable is started with a known subcommand (for example by the
/// `typstedit` shell command, or by an AI agent's MCP configuration) it runs
/// without any windows, prints its result and exits. Any other launch (Finder,
/// Dock, `open`) starts the normal app.
@MainActor
enum TypstEditCLI {
    nonisolated static let commands: Set<String> = ["compile", "check", "mcp", "info", "open", "install-cli", "help", "--help", "-h", "--version", "version"]

    static let bundleIdentifier = "com.tmagri.TypstEdit"

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The subcommand arguments when this launch is a CLI invocation, else nil.
    nonisolated static func invocation(from arguments: [String]) -> [String]? {
        guard arguments.count >= 2, commands.contains(arguments[1]) else { return nil }
        return Array(arguments.dropFirst())
    }

    /// Runs the CLI and exits the process; never returns.
    static func start(_ arguments: [String]) -> Never {
        let output = ProtocolOutput(fileDescriptor: reserveStdout())
        if arguments.first == "mcp" {
            TypstEditMCPServer(output: output).start()
        }
        Task { @MainActor in
            let code = await run(arguments, output: output)
            exit(code)
        }
        dispatchMain()
    }

    /// Duplicates the real stdout for our own output and points fd 1 at stderr,
    /// so diagnostic `print()` calls inside shared app code stay out of the
    /// machine-readable output (JSON, MCP messages).
    private static func reserveStdout() -> Int32 {
        let saved = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        setvbuf(stdout, nil, _IOLBF, 0)
        return saved >= 0 ? saved : STDERR_FILENO
    }

    // MARK: - Commands

    private static func run(_ arguments: [String], output: ProtocolOutput) async -> Int32 {
        var args = Array(arguments.dropFirst())
        switch arguments.first ?? "help" {
        case "compile":
            return await compile(&args, checkOnly: false, output: output)
        case "check":
            return await compile(&args, checkOnly: true, output: output)
        case "info":
            let info = await infoDictionary()
            if args.contains("--json") {
                output.writeLine(json(info))
            } else {
                output.writeLine(describe(info: info))
            }
            return 0
        case "open":
            let urls = args.filter { !$0.hasPrefix("-") }.map {
                AgentCompileService.resolve($0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            }
            let (ok, message) = openInApp(urls)
            output.writeLine(message)
            return ok ? 0 : 1
        case "install-cli":
            var directory: URL? = nil
            if let index = args.firstIndex(of: "--dir"), index + 1 < args.count {
                directory = URL(fileURLWithPath: (args[index + 1] as NSString).expandingTildeInPath)
            }
            do {
                let url = try AgentIntegrationManager.installCommandLineTool(into: directory)
                output.writeLine("Installed \(url.path)")
                if !AgentIntegrationManager.isOnPath(url.deletingLastPathComponent()) {
                    output.writeLine("Note: \(url.deletingLastPathComponent().path) is not on your PATH. Add it to your shell profile.")
                }
                return 0
            } catch {
                output.writeLine("install-cli failed: \(error.localizedDescription)")
                return 1
            }
        case "--version", "version":
            output.writeLine("TypstEdit \(appVersion)")
            return 0
        default:
            output.writeLine(usage)
            return arguments.first.map { ["help", "--help", "-h"].contains($0) } == true ? 0 : 2
        }
    }

    private static func compile(_ args: inout [String], checkOnly: Bool, output: ProtocolOutput) async -> Int32 {
        var request = AgentCompileRequest()
        request.checkOnly = checkOnly
        var positional: [String] = []
        var asJSON = false
        var openAfter = false

        func value(_ flag: String, _ index: inout Int) -> String? {
            guard index + 1 < args.count else {
                output.writeLine("error: \(flag) needs a value")
                return nil
            }
            index += 1
            return args[index]
        }

        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--json": asJSON = true
            case "--open": openAfter = true
            case "--format", "-f":
                guard let raw = value(arg, &index) else { return 2 }
                guard let format = AgentOutputFormat(rawValue: raw.lowercased()) else {
                    output.writeLine("error: unknown format '\(raw)' (use pdf, png or svg)")
                    return 2
                }
                request.format = format
            case "--root": guard let v = value(arg, &index) else { return 2 }; request.root = v
            case "--pages": guard let v = value(arg, &index) else { return 2 }; request.pages = v
            case "--ppi":
                guard let v = value(arg, &index), let ppi = Int(v) else { output.writeLine("error: --ppi needs a number"); return 2 }
                request.ppi = ppi
            case "--input":
                guard let v = value(arg, &index), let eq = v.firstIndex(of: "=") else { output.writeLine("error: --input needs key=value"); return 2 }
                request.inputs[String(v[..<eq])] = String(v[v.index(after: eq)...])
            case "--font-path": guard let v = value(arg, &index) else { return 2 }; request.fontPaths.append(v)
            case "--kind": guard let v = value(arg, &index) else { return 2 }; request.sourceKind = v
            default:
                if arg.hasPrefix("-") && arg != "-" {
                    output.writeLine("error: unknown option '\(arg)'\n\n\(usage)")
                    return 2
                }
                positional.append(arg)
            }
            index += 1
        }

        guard let input = positional.first else {
            output.writeLine("error: missing input file\n\n\(usage)")
            return 2
        }
        if input == "-" {
            // Source on stdin: handy for agents piping generated Typst.
            let data = FileHandle.standardInput.readDataToEndOfFile()
            request.source = String(data: data, encoding: .utf8) ?? ""
        } else {
            request.inputPath = input
        }
        if positional.count > 1, !checkOnly { request.outputPath = positional[1] }

        let result = await AgentCompileService.shared.compile(request)
        output.writeLine(asJSON ? result.jsonString() : result.summary)

        if openAfter, result.success, let first = result.outputs.first {
            _ = runOpen(["/usr/bin/open", first])
        }
        return result.success ? 0 : 1
    }

    // MARK: - Shared helpers (CLI + MCP)

    static func infoDictionary() async -> [String: Any] {
        let service = AgentCompileService.shared
        var info: [String: Any] = [
            "app": "TypstEdit",
            "version": appVersion,
            "bundleIdentifier": bundleIdentifier,
            "executable": Bundle.main.executablePath ?? CommandLine.arguments[0],
            "formats": AgentOutputFormat.allCases.map(\.rawValue),
            "inputTypes": ["typ", "md", "note"],
            "mcpCommand": [AgentIntegrationManager.preferredCommandPath, "mcp"]
        ]
        if Bundle.main.bundleURL.pathExtension == "app" { info["appBundle"] = Bundle.main.bundlePath }
        if let path = service.typstPath { info["typstPath"] = path }
        if let version = await service.typstVersion() { info["typstVersion"] = version }
        if let shim = AgentIntegrationManager.installedCommandLineTool() { info["cliTool"] = shim.path }
        return info
    }

    static func describe(info: [String: Any]) -> String {
        var lines = ["TypstEdit \(info["version"] ?? "")"]
        if let bundle = info["appBundle"] { lines.append("  app:        \(bundle)") }
        lines.append("  typst:      \(info["typstPath"] ?? "not found") \(info["typstVersion"].map { "(\($0))" } ?? "")")
        lines.append("  cli tool:   \(info["cliTool"] ?? "not installed (Settings > Integrations)")")
        lines.append("  formats:    pdf, png, svg   inputs: .typ, .md, .note")
        if let command = info["mcpCommand"] as? [String] {
            lines.append("  MCP server: \(command.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }

    /// Opens files in the TypstEdit app (the GUI), launching it if needed.
    static func openInApp(_ urls: [URL]) -> (Bool, String) {
        guard !urls.isEmpty else { return (false, "Nothing to open.") }
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        if !missing.isEmpty { return (false, "File not found: \(missing.map(\.path).joined(separator: ", "))") }
        // Hand the files to a TypstEdit that is already running, so they open
        // as windows of that one instance instead of starting a second copy.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { !$0.isTerminated && $0.activationPolicy == .regular && $0.bundleURL != nil }
        let target: [String]
        if let runningPath = running?.bundleURL?.path {
            target = ["-a", runningPath]
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            target = ["-a", Bundle.main.bundlePath]
        } else {
            target = ["-b", bundleIdentifier]
        }
        let ok = runOpen(["/usr/bin/open"] + target + urls.map(\.path))
        return ok
            ? (true, "Opened \(urls.map(\.lastPathComponent).joined(separator: ", ")) in TypstEdit.")
            : (false, "Could not open the file in TypstEdit. Is the app installed?")
    }

    @discardableResult
    private static func runOpen(_ command: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static let usage = """
    TypstEdit command-line interface

    USAGE
      typstedit compile <file|-> [output] [options]   Compile to PDF/PNG/SVG
      typstedit check   <file|-> [options]            Report errors/warnings only
      typstedit open    <file>...                     Open files in the TypstEdit app
      typstedit info    [--json]                      Show versions and paths
      typstedit mcp                                   Run the MCP server (stdio) for AI agents
      typstedit install-cli [--dir DIR]               Install the `typstedit` command

    INPUTS
      .typ, .md and .note files. Markdown and Notes are converted exactly like
      in the editor. Use `-` to read Typst source from stdin.

    OPTIONS
      -f, --format pdf|png|svg   Output format (default: from output name, else pdf)
      --root DIR                 Project root (default: the file's folder)
      --pages P                  Pages to export, e.g. 1 or 2,4-6
      --ppi N                    PNG resolution (default 144)
      --input key=value          Set sys.inputs (repeatable)
      --font-path DIR            Extra font folder (repeatable)
      --kind typ|md|note         Syntax of stdin source (default typ)
      --json                     Machine-readable result
      --open                     Open the output after compiling

    EXIT STATUS
      0 success, 1 compile errors, 2 usage error

    AI AGENTS
      Add an MCP server with command `typstedit` and argument `mcp`
      (tools: typst_check, typst_compile, typst_render_preview, typstedit_open,
      typstedit_info). See TypstEdit > Settings > Integrations.
    """
}

/// Process entry point: a CLI subcommand runs headless, anything else starts the app.
@main
@MainActor
enum TypstEditMain {
    static func main() {
        if let arguments = TypstEditCLI.invocation(from: CommandLine.arguments) {
            TypstEditCLI.start(arguments)
        }
        TypstEditApp.main()
    }
}
