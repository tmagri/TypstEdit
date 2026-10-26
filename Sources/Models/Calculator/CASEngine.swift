import Foundation

/// Drives the `typstedit-cas` helper: a subprocess embedding Giac that
/// evaluates one entry line at a time and answers with JSON (see
/// `Tools/cas/typstedit-cas.cpp` for the protocol).
///
/// One instance per app; the subprocess stays alive so stored variables
/// (`5→a`) survive between entries, like the TI-89's home screen.
actor CASEngine {
    static let shared = CASEngine()

    /// AI math calls use a fresh, restricted engine, never the panel's
    /// persistent context. Refuse to run if the OS sandbox is unavailable.
    private let sandboxed: Bool

    init(sandboxed: Bool = false) {
        self.sandboxed = sandboxed
    }

    nonisolated static var sandboxAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")
    }

    /// AI math needs system libraries and frameworks, so this is
    /// default-allow with targeted denials: no network, no writes, no child
    /// processes, and no reads of user data (projects, home, temporary
    /// folders, configuration). A deny-all read policy prevents dyld from
    /// starting the helper.
    nonisolated static func sandboxProfile(helperPath: String) -> String {
        let escaped = helperPath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write*)
        (allow file-write* (literal "/dev/null") (literal "/dev/stdout") (literal "/dev/stderr"))
        (deny file-read*
            (subpath "/Users") (subpath "/Volumes")
            (subpath "/tmp") (subpath "/private/tmp")
            (subpath "/etc") (subpath "/private/etc")
            (subpath "/private/var/folders")
            (subpath "/opt") (subpath "/usr/local"))
        (deny process-exec)
        (allow process-exec (literal "\(escaped)"))
        (deny process-fork)
        """
    }

    /// Read-side of the helper's stdout, pulled from a detached reader task.
    /// Only touched from that one task, hence `@unchecked Sendable`.
    private final class LineReader: @unchecked Sendable {
        private let handle: FileHandle
        private var buffer = Data()

        init(handle: FileHandle) {
            self.handle = handle
        }

        /// Blocks until a full line arrives. Returns nil at end of stream.
        func nextLine() -> String? {
            while true {
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return String(data: lineData, encoding: .utf8)
                }
                let chunk = handle.availableData
                if chunk.isEmpty { // EOF — the helper exited
                    if buffer.isEmpty { return nil }
                    let rest = buffer
                    buffer.removeAll()
                    return String(data: rest, encoding: .utf8)
                }
                buffer.append(chunk)
            }
        }
    }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<CASEvalResult, Never>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private(set) var lastLaunchError: String?
    private(set) var launchCount = 0

    // MARK: - Binary lookup

    /// Where the helper binary is expected. Mirrors how TypstEdit finds its
    /// bundled `typst`: app bundle first, then the developer workspace.
    nonisolated static func locateHelperBinary() -> String? {
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = "\(resourcePath)/bin/typstedit-cas"
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }
        var candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/cas/typstedit-cas").path,
            NSString(string: "~/Desktop/TypstEdit/build/cas/typstedit-cas").expandingTildeInPath,
            "/usr/local/bin/typstedit-cas",
            "/opt/homebrew/bin/typstedit-cas",
        ]
        // Xcode/SwiftPM run from different working directories; walk up from
        // the executable so `swift run` in a subdirectory still finds it.
        if let execURL = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(execURL.appendingPathComponent("build/cas/typstedit-cas").path)
        }
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    nonisolated static var isAvailable: Bool {
        locateHelperBinary() != nil
    }

    // MARK: - Launch / shutdown

    private func ensureRunning() throws {
        if let process, process.isRunning { return }
        guard let path = Self.locateHelperBinary() else {
            throw CASEngineError.helperMissing
        }
        let process2 = Process()
        if sandboxed {
            guard Self.sandboxAvailable else { throw CASEngineError.sandboxUnavailable }
            let helperPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            process2.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process2.arguments = ["-p", Self.sandboxProfile(helperPath: helperPath), helperPath]
            process2.currentDirectoryURL = URL(fileURLWithPath: "/")
            // Do not inherit project paths, credentials or dynamic-loader
            // overrides from the editor's environment.
            process2.environment = ["PATH": "/usr/bin:/bin", "HOME": "/", "LANG": "en_US.UTF-8"]
        } else {
            process2.executableURL = URL(fileURLWithPath: path)
        }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process2.standardInput = stdinPipe
        process2.standardOutput = stdoutPipe
        process2.standardError = FileHandle.nullDevice
        do {
            try process2.run()
        } catch {
            lastLaunchError = error.localizedDescription
            throw CASEngineError.launchFailed(error.localizedDescription)
        }
        process = process2
        stdinHandle = stdinPipe.fileHandleForWriting
        launchCount += 1
        pending.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()

        let reader = LineReader(handle: stdoutPipe.fileHandleForReading)
        let engine = self
        readerTask?.cancel()
        readerTask = Task.detached(priority: .userInitiated) {
            while let line = reader.nextLine() {
                await engine.handleResponse(line)
            }
            await engine.helperDied()
        }
    }

    /// Called when the reader hits EOF: fail anything in flight so callers
    /// don't hang; the next eval relaunches the helper.
    func helperDied() {
        let failures = pending
        pending.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        stdinHandle = nil
        for (id, continuation) in failures {
            continuation.resume(returning: CASEvalResult(
                inputTree: nil, resultTree: nil, resultText: "",
                resultTypst: "", inputTypst: "",
                errorMessage: "The CAS helper exited unexpectedly.", ok: false))
        }
    }

    func shutdown() {
        if stdinHandle != nil {
            send(line: "{\"v\":1,\"op\":\"shutdown\"}")
        }
        process?.terminate()
        process = nil
        stdinHandle = nil
        readerTask?.cancel()
        readerTask = nil
    }

    deinit {
        process?.terminate()
    }

    // MARK: - Evaluation

    /// Evaluates one entry line. Never throws — failures come back as
    /// `ok == false` results with a user-facing message.
    func eval(input: String,
              approx: Bool,
              angle: CASAngleMode,
              digits: Int,
              timeout: TimeInterval = 10) async -> CASEvalResult {
        do {
            try ensureRunning()
        } catch {
            return failed(error.localizedDescription, kind: "launch")
        }

        let id = nextID
        nextID += 1

        let request: [String: Any] = [
            "v": 1,
            "id": id,
            "op": "eval",
            "input": input,
            "approx": approx,
            "angle": angle == .degrees ? "deg" : "rad",
            "digits": digits,
        ]
        guard let line = Self.jsonLine(request) else {
            return failed("Could not encode the request.", kind: "protocol")
        }
        send(line: line)

        // The helper answers exactly one reply per request.
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            timeoutTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.timedOut(id: id)
            }
        }
    }

    /// SIGINTs the helper. If it is mid-computation, giac aborts and answers
    /// with an "Interrupted" reply; if it hangs outright we kill after a
    /// grace period so the UI never stays busy forever.
    func interrupt() {
        process?.interrupt()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.forceKillIfStillPending()
        }
    }

    private func timedOut(id: Int) {
        guard pending[id] != nil else { return }
        interrupt()
    }

    private func forceKillIfStillPending() {
        guard !pending.isEmpty else { return }
        process?.terminate()
    }

    /// Drops all stored variables by restarting the helper's context.
    func reset() async {
        if let process, process.isRunning, stdinHandle != nil {
            send(line: "{\"v\":1,\"op\":\"reset\"}")
        }
    }

    // MARK: - Replies

    func handleResponse(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let idNumber = dict["id"] as? NSNumber else { return }
        let id = idNumber.intValue
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)?.cancel()

        let ok = (dict["ok"] as? NSNumber)?.boolValue ?? false
        if ok {
            var inputTree: CASExpression?
            var resultTree: CASExpression?
            if let raw = dict["inputTree"] as? [String: Any] {
                inputTree = try? CASExpressionDecoder.decode(raw)
            }
            if let raw = dict["resultTree"] as? [String: Any] {
                resultTree = try? CASExpressionDecoder.decode(raw)
            }
            let resultText = dict["resultText"] as? String ?? ""
            // A string result (e.g. a function-definition echo) is not math:
            // leave resultTypst empty so the history shows plain monospace
            // text instead of a quoted Typst string.
            var resultTypst = ""
            if let tree = resultTree, case .string = tree {
                resultTypst = ""
            } else {
                resultTypst = resultTree.map { CASTypstRenderer.typst($0) } ?? ""
            }
            continuation.resume(returning: CASEvalResult(
                inputTree: inputTree,
                resultTree: resultTree,
                resultText: resultText,
                resultTypst: resultTypst,
                inputTypst: inputTree.map { CASTypstRenderer.typst($0) } ?? "",
                errorMessage: "",
                ok: true))
        } else {
            let message = dict["error"] as? String ?? "The CAS returned an error."
            continuation.resume(returning: CASEvalResult(
                inputTree: nil, resultTree: nil, resultText: "",
                resultTypst: "", inputTypst: "",
                errorMessage: message, ok: false))
        }
    }

    // MARK: - Plumbing

    private nonisolated static func jsonLine(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func send(line: String) {
        guard let stdinHandle, let data = (line + "\n").data(using: .utf8) else { return }
        try? stdinHandle.write(contentsOf: data)
    }

    private func failed(_ message: String, kind: String) -> CASEvalResult {
        _ = kind
        return CASEvalResult(
            inputTree: nil, resultTree: nil, resultText: "",
            resultTypst: "", inputTypst: "",
            errorMessage: message, ok: false)
    }
}

enum CASEngineError: LocalizedError {
    case helperMissing
    case sandboxUnavailable
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "The CAS helper (typstedit-cas) isn't installed. Build it with Tools/cas/build_cas.sh — see Docs/calculator.md."
        case .sandboxUnavailable:
            return "The OS sandbox is unavailable. AI math evaluation cannot run without it."
        case let .launchFailed(detail):
            return "Could not start the CAS helper: \(detail)"
        }
    }
}
