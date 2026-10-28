import Foundation

/// Opt-in JSON Lines trace of the tool-calling loop: one record per model
/// request, tool call, retry and steering note. Off unless the process
/// is started with `TYPSTEDIT_AGENT_TRACE=/path/to/trace.jsonl`, so it costs
/// nothing in normal use. Records hold sizes, names and short previews —
/// never API keys or headers.
enum AgentTrace {
    static let environmentKey = "TYPSTEDIT_AGENT_TRACE"

    private static let path: String? = {
        let value = ProcessInfo.processInfo.environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }()

    private static let lock = NSLock()

    static var isEnabled: Bool { path != nil }

    /// Appends one record. `fields` must be JSON-serializable; anything
    /// that isn't is dropped rather than failing the request.
    static func log(_ event: String, _ fields: [String: Any] = [:]) {
        guard let path else { return }
        var record = fields
        record["event"] = event
        record["time"] = Date().timeIntervalSince1970
        guard JSONSerialization.isValidJSONObject(record),
              var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// First `max` characters, for previews in a record.
    static func preview(_ text: String, max: Int = 300) -> String {
        text.count > max ? String(text.prefix(max)) + "…" : text
    }
}
