import Foundation
import CryptoKit

// MARK: - SessionLedger

/// Learns environment facts from agentic sessions and injects them into future
/// system prompts so the agent stops making the same mistakes.
///
/// **Lifecycle**
///
/// 1. After each session ends, call
///    ``recordSession(messages:referenceFolderPath:)`` with the full
///    ``ChatMessage`` array and the active reference-folder path (may be nil).
/// 2. When building the system prompt, call
///    ``workspaceFacts(for:)`` to get the `WORKSPACE FACTS` block (or `nil`
///    when nothing is confirmed yet).
///
/// **Storage layout**
///
/// ```
/// ~/.typstedit/ledger/
///   <sha256-first-8-of-folder-path>/
///     facts.json      ← [FactCandidate]
///     confirmed.json  ← [ConfirmedFact]
/// ```
///
/// All disk I/O is done on a background serial queue; the public API is safe
/// to call from any thread or `@MainActor` context.
final class SessionLedger: @unchecked Sendable {

    // MARK: Shared instance

    /// The process-wide singleton.
    static let shared = SessionLedger()

    // MARK: Private state

    /// Serial queue that owns all file reads and writes.
    private let ioQueue = DispatchQueue(label: "com.typstedit.sessionledger", qos: .utility)

    /// Root directory: `~/.typstedit/ledger/`.
    private let ledgerRoot: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        ledgerRoot = home
            .appendingPathComponent(".typstedit", isDirectory: true)
            .appendingPathComponent("ledger", isDirectory: true)
    }

    // MARK: - Public API

    /// Analyses the finished session transcript, updates candidate and
    /// confirmed-fact stores, and prunes stale facts — all in the background.
    ///
    /// - Parameters:
    ///   - messages: The complete ``ChatMessage`` array for the session that
    ///     just ended.
    ///   - referenceFolderPath: The active reference-folder path, used to
    ///     scope facts. Pass `nil` when no folder is configured.
    func recordSession(messages: [ChatMessage], referenceFolderPath: String?) async {
        // Hop off the calling actor so disk work never blocks the main thread.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                self.processSession(messages: messages, folderPath: referenceFolderPath)
                continuation.resume()
            }
        }
    }

    /// Returns a formatted `WORKSPACE FACTS` block for the given folder path,
    /// or `nil` when no confirmed facts exist.
    ///
    /// This call is **synchronous** and may block briefly on first access;
    /// call it from a background context or accept the negligible latency on
    /// the main thread (the file is tiny).
    ///
    /// - Parameter folderPath: The active reference-folder path. Pass `nil`
    ///   when no folder is configured; this method returns `nil` immediately.
    func workspaceFacts(for folderPath: String?) -> String? {
        guard let folderPath, !folderPath.isEmpty else { return nil }
        var result: String? = nil
        ioQueue.sync {
            let hash = Self.folderHash(folderPath)
            let confirmed = self.loadConfirmed(hash: hash)
            guard !confirmed.isEmpty else { return }
            var block = "WORKSPACE FACTS (learned from past sessions in this folder):"
            for fact in confirmed {
                block += "\n- \(fact.body)"
            }
            result = block
        }
        return result
    }

    // MARK: - Core pipeline (runs on ioQueue)

    private func processSession(messages: [ChatMessage], folderPath: String?) {
        guard let folderPath, !folderPath.isEmpty else { return }

        let hash = Self.folderHash(folderPath)

        // 1. Extract candidates from this session.
        let newBodies = extractFacts(from: messages)
        guard !newBodies.isEmpty else {
            // Even with no new facts we still check staleness.
            pruneStale(messages: messages, hash: hash)
            return
        }

        // 2. Load existing candidates, merge, persist.
        var candidates = loadCandidates(hash: hash)
        let now = Date()
        for body in newBodies {
            let lc = body.lowercased()
            if let idx = candidates.firstIndex(where: { $0.body.lowercased() == lc }) {
                candidates[idx].sessionCount += 1
                candidates[idx].lastSeen = now
            } else {
                candidates.append(FactCandidate(body: body, sessionCount: 1, lastSeen: now))
            }
        }
        saveCandidates(candidates, hash: hash)

        // 3. Promote qualifying candidates to confirmed facts.
        promoteIfReady(candidates: &candidates, hash: hash, now: now)
        saveCandidates(candidates, hash: hash)

        // 4. Remove stale confirmed facts.
        pruneStale(messages: messages, hash: hash)
    }

    // MARK: - Extraction

    /// Extracts environment-correction facts from a session transcript.
    ///
    /// Two heuristics are applied:
    ///
    /// 1. **Failed-then-corrected tool calls** — a `.toolCall` message whose
    ///    status is `.failed` and whose `toolName` contains `run_script`,
    ///    `bash`, or `shell`, immediately followed by an `.assistant` message
    ///    whose *next* `.toolCall` calls the same tool with *different*
    ///    arguments.
    ///
    /// 2. **Linguistic self-correction** — an `.assistant` message whose text
    ///    matches patterns like "Actually, the correct command is…" or
    ///    "I need to use `X` instead of `Y`".
    private func extractFacts(from messages: [ChatMessage]) -> [String] {
        var bodies: [String] = []

        let scriptToolNames = ["run_script", "bash", "shell"]
        func isScriptTool(_ name: String?) -> Bool {
            guard let name else { return false }
            return scriptToolNames.contains(where: { name.lowercased().contains($0) })
        }

        // --- Heuristic 1: failed-tool → corrected-tool pairs ---
        //
        // `dropLast()` is empty for an empty or one-message transcript.
        // Writing this as `0 ..< messages.count - 1` traps on such a
        // transcript: an empty session made the upper bound -1 and crashed
        // with "Range requires lowerBound <= upperBound" (the `+` button
        // clears the chat while a turn's `defer` still records it).
        for i in messages.indices.dropLast() {
            let msg = messages[i]
            guard msg.role == .toolCall,
                  msg.toolStatus == .failed,
                  isScriptTool(msg.toolName) else { continue }

            // Look for the next toolCall with the same tool name but different args.
            let failedArgs = msg.toolArgumentsJSON ?? ""
            let failedTool = msg.toolName ?? ""

            // Walk forward past assistant text to find the next tool call.
            for j in (i + 1) ..< messages.count {
                let next = messages[j]
                if next.role == .toolCall {
                    guard next.toolName == failedTool,
                          (next.toolArgumentsJSON ?? "") != failedArgs,
                          next.toolStatus != .failed else { break }
                    // Build a compact fact from the corrected arguments.
                    if let correctedArgs = next.toolArgumentsJSON,
                       !correctedArgs.isEmpty {
                        let fact = "In this workspace, \(next.toolLabel) requires arguments: \(correctedArgs.prefix(200))"
                        bodies.append(String(fact))
                    }
                    break
                }
                // Keep scanning past assistant text.
                if next.role == .user { break }
            }
        }

        // --- Heuristic 2: linguistic self-correction patterns ---
        let patterns: [String] = [
            "actually, the correct command is",
            "i need to use",
            "instead of",
            "the correct way is",
            "you should use",
            "use `",
            "must be run as",
        ]

        for msg in messages where msg.role == .assistant {
            let lower = msg.text.lowercased()
            guard patterns.contains(where: { lower.contains($0) }) else { continue }

            // Extract sentences that contain corrections (up to 300 chars each).
            let sentences = msg.text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            for sentence in sentences {
                let sl = sentence.lowercased()
                if patterns.contains(where: { sl.contains($0) }) {
                    let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count >= 15 && trimmed.count <= 300 {
                        bodies.append(trimmed)
                    }
                }
            }
        }

        // Deduplicate by lowercased equality.
        var seen = Set<String>()
        return bodies.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: - Promotion

    /// Promotes ``FactCandidate`` items whose `sessionCount` has reached 3
    /// into the confirmed-facts store, then removes them from candidates.
    private func promoteIfReady(candidates: inout [FactCandidate], hash: String, now: Date) {
        var confirmed = loadConfirmed(hash: hash)
        var promoted = false
        candidates = candidates.filter { candidate in
            guard candidate.sessionCount >= 3 else { return true }
            let lc = candidate.body.lowercased()
            guard !confirmed.contains(where: { $0.body.lowercased() == lc }) else { return false }
            confirmed.append(ConfirmedFact(body: candidate.body, confidence: 5, addedAt: now))
            promoted = true
            return false  // remove from candidates
        }
        if promoted {
            saveConfirmed(confirmed, hash: hash)
        }
    }

    // MARK: - Stale-fact pruning

    /// Decrements confidence for confirmed facts whose command appears in a
    /// *failed* tool call, and removes facts whose confidence reaches 0.
    private func pruneStale(messages: [ChatMessage], hash: String) {
        var confirmed = loadConfirmed(hash: hash)
        guard !confirmed.isEmpty else { return }

        // Collect the text of every failed script-tool call.
        let failedOutputs: [String] = messages.compactMap { msg -> String? in
            guard msg.role == .toolCall,
                  msg.toolStatus == .failed else { return nil }
            return [(msg.toolArgumentsJSON ?? ""), (msg.toolOutput ?? "")].joined(separator: " ")
        }

        guard !failedOutputs.isEmpty else { return }

        var changed = false
        confirmed = confirmed.compactMap { fact in
            var f = fact
            // Check if any keyword from the fact body appears in a failed call.
            let keywords = extractKeywords(from: fact.body)
            for output in failedOutputs {
                let lower = output.lowercased()
                if keywords.contains(where: { lower.contains($0) }) {
                    f.confidence -= 1
                    changed = true
                    break
                }
            }
            return f.confidence > 0 ? f : nil
        }

        if changed {
            saveConfirmed(confirmed, hash: hash)
        }
    }

    /// Splits a fact body into lowercase keyword tokens (backtick-quoted words
    /// and significant words ≥ 4 chars).
    private func extractKeywords(from body: String) -> [String] {
        var keywords: [String] = []
        // Pull backtick-quoted tokens first.
        var remaining = body
        while let start = remaining.range(of: "`"),
              let end = remaining.range(of: "`", range: start.upperBound ..< remaining.endIndex) {
            let token = String(remaining[start.upperBound ..< end.lowerBound]).lowercased()
            if !token.isEmpty { keywords.append(token) }
            remaining = String(remaining[end.upperBound...])
        }
        if !keywords.isEmpty { return keywords }
        // Fall back to significant words.
        return body.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 4 }
    }

    // MARK: - Persistence helpers

    /// Returns the per-folder ledger directory, creating it if needed.
    private func ledgerDir(hash: String) -> URL? {
        let dir = ledgerRoot.appendingPathComponent(hash, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    private func loadCandidates(hash: String) -> [FactCandidate] {
        guard let dir = ledgerDir(hash: hash) else { return [] }
        let url = dir.appendingPathComponent("facts.json")
        return decodeJSON([FactCandidate].self, from: url) ?? []
    }

    private func saveCandidates(_ candidates: [FactCandidate], hash: String) {
        guard let dir = ledgerDir(hash: hash) else { return }
        atomicWrite(candidates, to: dir.appendingPathComponent("facts.json"))
    }

    private func loadConfirmed(hash: String) -> [ConfirmedFact] {
        guard let dir = ledgerDir(hash: hash) else { return [] }
        let url = dir.appendingPathComponent("confirmed.json")
        return decodeJSON([ConfirmedFact].self, from: url) ?? []
    }

    private func saveConfirmed(_ confirmed: [ConfirmedFact], hash: String) {
        guard let dir = ledgerDir(hash: hash) else { return }
        atomicWrite(confirmed, to: dir.appendingPathComponent("confirmed.json"))
    }

    // MARK: - Atomic JSON I/O

    /// Writes `value` to `url` atomically: encodes to a `.tmp` file then
    /// renames over the destination so a crash never leaves a partial file.
    private func atomicWrite<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    // MARK: - Hashing

    /// Returns the first 8 hex characters of the SHA-256 hash of `path`,
    /// used as a stable, filesystem-safe directory name.
    static func folderHash(_ path: String) -> String {
        let data = Data(path.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8).lowercased()
    }
}
