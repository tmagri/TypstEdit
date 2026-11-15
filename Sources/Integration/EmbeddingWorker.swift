import Foundation

/// The `typstedit embed-worker` side of the out-of-process embeddings.
///
/// Reads one JSON request per line from stdin — `{"seq": n, "texts": […]}` —
/// embeds the texts with the model selected in Settings (rebuilt here from
/// `UserDefaults`, the same domain the app uses), and writes one JSON reply
/// per line to stdout — `{"seq": n, "vectors": [[…], …]}` or
/// `{"seq": n, "error": "…"}`.
///
/// The provider is rebuilt on *every* request, not once at start: the app
/// may have Settings open and the user may switch the embedding model
/// mid-indexing, and `AISettingsManager` reads live values. That also means
/// no state that can go stale; each request is self-contained.
///
/// EOF on stdin ends the process (the app closed or cancelled the pass).
enum EmbeddingWorker {
    static func main(output: ProtocolOutput) -> Never {
        let input = FileHandle.standardInput

        // The CLI's startup path (TypstEditCLI.start) parks the main thread
        // in dispatchMain(); a task here drains the request loop.
        Task { @MainActor in
            while let line = readLine(from: input) {
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

    /// Reads one newline-terminated chunk from `handle`, or nil at EOF.
    /// Reads at most 8 MB per line: a batch of passages is far under that,
    /// and a corrupted stream then cannot grow the buffer without bound.
    private static func readLine(from handle: FileHandle) -> String? {
        var buffer = Data()
        while buffer.count < 8 * 1024 * 1024 {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            } catch {
                return nil
            }
            guard !chunk.isEmpty else { return nil }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[buffer.startIndex..<newline])
                return String(data: lineData, encoding: .utf8)
            }
        }
        return nil
    }

}
