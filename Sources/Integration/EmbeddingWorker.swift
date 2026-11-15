import Foundation

/// The `typstedit embed-worker` side of the out-of-process embeddings.
///
/// Reads one JSON request per line from stdin — `{"seq": n, "texts": […],
/// "spec": {…}}` — embeds the texts with the model the app selected in
/// Settings (carried in `spec`; the worker itself reads no settings), and
/// writes one JSON reply per line to the reserved stdout —
/// `{"seq": n, "vectors": [[…], …]}` or `{"seq": n, "error": "…"}`.
///
/// EOF on stdin ends the process (the app closed or cancelled the pass).
/// The process is a plain CLI child: no SwiftUI app starts, so it never
/// appears in the Dock, ⌘-Tab or Mission Control.
enum EmbeddingWorker {
    static func main(output: ProtocolOutput) -> Never {
        // Read fd 0 directly with raw `read()` syscalls rather than through
        // `FileHandle.standardInput`: the process is spawned with its stdin
        // as a pipe whose data may already be sitting in the buffer when the
        // reader starts (the parent writes the first request right after
        // spawn). Foundation's standard-input handle carries dispatch
        // machinery that can consume buffered bytes independently of
        // `read(upToCount:)`, so the worker's first line was silently lost
        // when the request raced the loop startup. A plain `read(2)` on the
        // file descriptor sees those bytes every time — this is exactly how
        // C tools read their stdin.
        let inputFD: Int32 = 0

        Task { @MainActor in
            while let line = readLineFromFD(inputFD) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let reply = await handle(trimmed)
                output.write(reply)
            }
            exit(0)
        }
        dispatchMain()
    }

    /// Handles one request line and returns the reply line. Synchronous per
    /// request: the app keeps one request in flight at a time, and a busy
    /// local model queues requests server-side anyway.
    private static func handle(_ line: String) async -> String {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sequence = json["seq"] as? Int,
              let texts = json["texts"] as? [String] else {
            return reply(sequence: -1, error: "the request could not be parsed")
        }

        let spec = (json["spec"] as? [String: Any]).flatMap(EmbeddingWorkerSpec.from)
        guard let provider = spec?.makeProvider() else {
            return reply(sequence: sequence, error: "the request did not carry a usable embedding model")
        }
        do {
            var vectors: [[Float]?] = []
            vectors.reserveCapacity(texts.count)
            // One batched request where the provider supports it (the
            // same batching rule `EmbeddingBatcher` applies in-process),
            // with the array-batch fallback handled by the provider's own
            // default implementation when a server rejects arrays.
            let embedded = try await provider.getEmbeddings(for: texts)
            guard embedded.count == texts.count else {
                throw EmbeddingError.generationFailed
            }
            vectors = embedded
            return reply(sequence: sequence, vectors: vectors)
        } catch {
            return reply(sequence: sequence, error: error.localizedDescription)
        }
    }

    private static func reply(sequence: Int, vectors: [[Float]?]) -> String {
        // JSONSerialization writes null for nil, which parses back as
        // NSNull on the client; encode failed vectors as empty arrays
        // instead, which the client maps back to nil.
        let payload: [[Float]] = vectors.map { $0 ?? [] }
        let object: [String: Any] = ["seq": sequence, "vectors": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else {
            return reply(sequence: sequence, error: "the reply could not be encoded")
        }
        line += "\n"
        return line
    }

    private static func reply(sequence: Int, error: String) -> String {
        let object: [String: Any] = ["seq": sequence, "error": error]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else { return "\n" }
        line += "\n"
        return line
    }

    /// Reads one newline-terminated line from file descriptor `fd`, or nil
    /// at EOF. Raw `read(2)` calls, no Foundation pipe machinery: see
    /// `main(output:)` for why that matters when the request already sits
    /// in the pipe buffer when the loop starts. Reads at most 8 MB per
    /// line: a batch of passages is far under that, and a corrupted stream
    /// then cannot grow the buffer without bound.
    private static func readLineFromFD(_ fd: Int32) -> String? {
        var buffer = [UInt8]()
        buffer.reserveCapacity(4096)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while buffer.count < 8 * 1024 * 1024 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            if let newline = buffer.firstIndex(of: 0x0A) {
                return String(bytes: buffer[0..<newline], encoding: .utf8)
            }
        }
        return nil
    }
}
