import Foundation

// MARK: - Worker spec

/// The embedding model configuration handed to the helper process with
/// every request. The helper may be running as a re-exec'd bundle helper
/// whose `Bundle.main` is not the app bundle, so it cannot read the app's
/// settings itself; the app sends everything the request needs. Never
/// persisted, never logged.
struct EmbeddingWorkerSpec: Sendable {
    enum Kind: String, Sendable {
        /// Apple's built-in NLEmbedding sentence model.
        case apple
        /// An OpenAI-compatible `/embeddings` endpoint (cloud or local).
        case api
    }

    var kind: Kind
    var endpoint: String?
    var apiKey: String?
    var model: String?
    var dimensions: Int?

    init(kind: Kind, endpoint: String? = nil, apiKey: String? = nil, model: String? = nil, dimensions: Int? = nil) {
        self.kind = kind
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.dimensions = dimensions
    }

    /// Captures the provider the app would use for the embedding task, or
    /// nil when the provider is not one of the two the worker can rebuild
    /// (in that case embedding stays in-process).
    init?(provider: EmbeddingProvider) {
        if provider is LocalEmbeddingProvider {
            kind = .apple
            return
        }
        guard let api = provider as? GenericAPIEmbeddingProvider else { return nil }
        kind = .api
        endpoint = api.endpointURL?.absoluteString
        apiKey = api.apiKey
        model = api.modelName
        dimensions = api.dimensions
    }

    var json: [String: Any] {
        var object: [String: Any] = ["kind": kind.rawValue]
        if let endpoint { object["endpoint"] = endpoint }
        if let apiKey { object["api_key"] = apiKey }
        if let model { object["model"] = model }
        if let dimensions { object["dimensions"] = dimensions }
        return object
    }

    static func from(_ json: [String: Any]) -> EmbeddingWorkerSpec? {
        guard let kindRaw = json["kind"] as? String, let kind = Kind(rawValue: kindRaw) else { return nil }
        return EmbeddingWorkerSpec(
            kind: kind,
            endpoint: json["endpoint"] as? String,
            apiKey: json["api_key"] as? String,
            model: json["model"] as? String,
            dimensions: json["dimensions"] as? Int
        )
    }

    /// Rebuilds the provider this spec describes.
    func makeProvider() -> EmbeddingProvider? {
        switch kind {
        case .apple:
            return LocalEmbeddingProvider()
        case .api:
            guard let endpoint, let model else { return nil }
            return GenericAPIEmbeddingProvider(
                dimensions: dimensions ?? 768,
                endpointURL: URL(string: endpoint),
                apiKey: apiKey ?? "",
                modelName: model
            )
        }
    }
}

// MARK: - Cancellation

/// A cross-task cancellation flag for one indexing pass. The pass reads
/// it between files; cancelling (project switched, user pressed Stop)
/// ends the pass at the next boundary instead of running to completion.
final class IndexRunCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

// MARK: - Reply payload

/// One reply from the helper: the vectors in input order, or the error the
/// helper reported. A plain struct rather than `Result`, so the payload can
/// travel through continuations without wrapping `String` in an error type.
struct EmbeddingWorkerReply: Sendable {
    var vectors: [[Float]?]
    var errorMessage: String?
}

enum EmbeddingWorkerError: LocalizedError {
    case died(String)

    var errorDescription: String? {
        switch self {
        case .died(let message): return "The embedding helper stopped: \(message)"
        }
    }
}

// MARK: - Client

/// Embeddings produced by the app's own executable in a separate helper
/// process (`typstedit embed-worker`, see `EmbeddingWorker`).
///
/// When embedding runs in-process, a pass over a large project competes
/// with the app for the very things the UI needs: memory (whole-project
/// scans peak in the hundreds of MB), CPU, and — for some model runtimes —
/// the main thread. Moving it into a child process keeps the app
/// responsive no matter how heavy the model is, and lets the OS (not the
/// app) arbitrate CPU. The process is disposable: a crash or a hang costs
/// one pass, the next indexing run starts a fresh one, and every fallible
/// step falls back to in-process embedding (the previous behavior) instead
/// of failing the pass.
///
/// Requests are newline-delimited JSON over stdin/stdout pipes. One
/// request is in flight at a time: the helper embeds sequentially anyway,
/// so a second concurrent request would only queue behind it.
///
/// Thread-safety: all mutable state lives behind `NSLock`, taken only in
/// synchronous methods. The reader tasks hop to the locked methods and
/// never hold the lock across an await.
final class EmbeddingWorkerClient: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var running = false
    private var requestSequence = 0
    private var earlyReplies: [Int: EmbeddingWorkerReply] = [:]
    private var waiters: [Int: CheckedContinuation<EmbeddingWorkerReply, Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var diagnostics = ""

    /// Replaces the spawned process for tests: given the texts, returns
    /// the vectors.
    var protocolOverride: (@Sendable ([String]) async -> [[Float]?])?

    init() {}

    deinit {
        readerTask?.cancel()
        stderrTask?.cancel()
        process?.terminate()
    }

    // MARK: - Locked state (synchronous only)

    private var diagnosticsText: String {
        lock.lock()
        defer { lock.unlock() }
        return diagnostics
    }

    /// Tail of the helper's stderr, for diagnostics.
    var lastDiagnostics: String { diagnosticsText }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Whether this process can host the helper: the packaged app, or the
    /// `TypstEdit` binary built by `swift build`. A test runner or any other
    /// host must not be spawned with a subcommand argument — `xctest` would
    /// run the whole suite again — so those embed in-process.
    private static var canSpawnHelper: Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            let name = URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent
            return name == "TypstEdit" || name == "typstedit"
        }
        return true
    }

    /// Spawns the helper lazily, on first use. False when it could not be
    /// started; the caller then embeds in-process rather than failing.
    @discardableResult
    func startIfNeeded() -> Bool {
        if let protocolOverride { return true }

        lock.lock()
        if running {
            lock.unlock()
            return true
        }
        lock.unlock()

        guard let executable = Bundle.main.executablePath ?? CommandLine.arguments.first,
              Self.canSpawnHelper else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [executable, "embed-worker"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            recordDiagnostics("Could not launch the embedding helper: \(error.localizedDescription)")
            return false
        }

        lock.lock()
        // A concurrent starter may have won the race; give ours up.
        if running {
            lock.unlock()
            process.terminate()
            return true
        }
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.running = true
        lock.unlock()

        startReader(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
        return true
    }

    /// Embeds `texts`, one result per text in order (`nil` per failure).
    /// Returns nil when the helper is not usable at all, so the caller can
    /// fall back to in-process embedding.
    func embed(texts: [String], spec: EmbeddingWorkerSpec) async -> [[Float]?]? {
        guard !texts.isEmpty else { return [] }

        if let fake = protocolOverride {
            return await fake(texts)
        }

        guard startIfNeeded() else { return nil }
        guard isRunning else { return nil }

        let sequence: Int = nextSequence()

        var request: [String: Any] = ["seq": sequence, "texts": texts, "spec": spec.json]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              var line = String(data: data, encoding: .utf8) else { return nil }
        line += "\n"

        let handle = takeStdinHandle()
        guard let handle else { return nil }
        do {
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            recordDiagnostics("Could not write to the embedding helper: \(error.localizedDescription)")
            return nil
        }

        let reply: EmbeddingWorkerReply
        do {
            reply = try await awaitReply(sequence: sequence)
        } catch {
            // The helper exited before replying.
            return nil
        }

        if let message = reply.errorMessage {
            recordDiagnostics(message)
            return nil
        }
        return reply.vectors
    }

    /// Kills the helper, if any. Safe any time; the next request starts a
    /// fresh one.
    func stop() {
        lock.lock()
        let process = self.process
        running = false
        let pending = waiters
        waiters.removeAll()
        earlyReplies.removeAll()
        self.process = nil
        stdinHandle = nil
        lock.unlock()

        readerTask?.cancel()
        readerTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        process?.terminate()
        for (_, continuation) in pending {
            continuation.resume(throwing: EmbeddingWorkerError.died("the helper was stopped"))
        }
    }

    private func nextSequence() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let sequence = requestSequence
        requestSequence += 1
        return sequence
    }

    /// Registers a waiter for the reply with `sequence`, or hands back a
    /// reply that already arrived. The locked section is synchronous;
    /// `await` only suspends on the continuation.
    private func awaitReply(sequence: Int) async throws -> EmbeddingWorkerReply {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EmbeddingWorkerReply, Error>) in
            registerWaiter(continuation, for: sequence)
        }
    }

    private func registerWaiter(
        _ continuation: CheckedContinuation<EmbeddingWorkerReply, Error>, for sequence: Int
    ) {
        lock.lock()
        if let early = earlyReplies.removeValue(forKey: sequence) {
            lock.unlock()
            continuation.resume(returning: early)
        } else {
            waiters[sequence] = continuation
            lock.unlock()
        }
    }

    private func takeStdinHandle() -> FileHandle? {
        lock.lock()
        defer { lock.unlock() }
        return stdinHandle
    }

    // MARK: - Reading the helper's output

    /// Spawns the stdout/stderr readers. Each stdout line is one reply; EOF
    /// means the helper exited, and anything still waiting fails rather
    /// than hangs.
    private func startReader(stdoutPipe: Pipe, stderrPipe: Pipe) {
        let stdout = stdoutPipe.fileHandleForReading
        let stderr = stderrPipe.fileHandleForReading
        readerTask = Task.detached(priority: .utility) { [weak self] in
            var buffer = Data()
            while !Task.isCancelled {
                let chunk: Data
                do {
                    chunk = try stdout.read(upToCount: 64 * 1024) ?? Data()
                } catch {
                    break
                }
                guard !chunk.isEmpty else { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let line = String(data: lineData, encoding: .utf8) {
                        self?.handleReplyLine(line)
                    }
                }
            }
            self?.helperExited()
        }
        stderrTask = Task.detached(priority: .utility) { [weak self] in
            var buffer = Data()
            while !Task.isCancelled {
                let chunk: Data
                do {
                    chunk = try stderr.read(upToCount: 64 * 1024) ?? Data()
                } catch {
                    break
                }
                guard !chunk.isEmpty else { break }
                buffer.append(chunk)
                if buffer.count > 16 * 1024 {
                    buffer.removeFirst(buffer.count - 16 * 1024)
                }
                if let text = String(data: buffer, encoding: .utf8) {
                    self?.recordDiagnostics(text)
                }
            }
        }
    }

    /// Parses one reply line and hands it to the waiter for its sequence.
    /// Runs on the reader thread; takes the lock only to swap state, and
    /// resumes the continuation outside it.
    private func handleReplyLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sequence = json["seq"] as? Int else { return }

        let reply: EmbeddingWorkerReply
        if let error = json["error"] as? String {
            reply = EmbeddingWorkerReply(vectors: [], errorMessage: error)
        } else if let vectors = json["vectors"] as? [[Any]] {
            // An empty vector marks a text whose embedding failed: the wire
            // format carries nils as empty arrays.
            reply = EmbeddingWorkerReply(
                vectors: vectors.map { vector in
                    let values = vector.compactMap { ($0 as? NSNumber)?.floatValue }
                    return values.isEmpty ? nil : values
                },
                errorMessage: nil
            )
        } else {
            reply = EmbeddingWorkerReply(vectors: [], errorMessage: "the reply could not be parsed")
        }

        var waiter: CheckedContinuation<EmbeddingWorkerReply, Error>?
        lock.lock()
        if let taken = waiters.removeValue(forKey: sequence) {
            waiter = taken
        } else {
            earlyReplies[sequence] = reply
        }
        lock.unlock()
        waiter?.resume(returning: reply)
    }

    /// The helper exited: nothing more will arrive, so pending waiters fail.
    private func helperExited() {
        var pending: [CheckedContinuation<EmbeddingWorkerReply, Error>] = []
        lock.lock()
        running = false
        pending = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume(throwing: EmbeddingWorkerError.died("the helper exited"))
        }
    }

    private func recordDiagnostics(_ text: String) {
        lock.lock()
        diagnostics = text
        lock.unlock()
    }
}
