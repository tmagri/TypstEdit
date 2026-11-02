import Foundation

/// Counts the model requests in flight to each server (host and port), so a
/// feature that is about to call a model can tell whether that server is
/// already busy.
///
/// Local servers (LM Studio, Ollama, llama.cpp) often process one request at
/// a time and queue the rest silently: a second caller just waits, with no
/// sign of why. Every request path registers here — chat turns, one-shot
/// completions, embeddings, PDF-import transcriptions — so "busy" is known
/// exactly, without relying on server-specific status endpoints.
final class ModelServerActivity: @unchecked Sendable {
    static let shared = ModelServerActivity()

    struct Ticket: Sendable, Hashable {
        fileprivate let id: UUID
        fileprivate let server: String
    }

    private let lock = NSLock()
    private var inFlight: [String: Set<UUID>] = [:]

    /// "host:port" for a request URL; the port defaults by scheme.
    static func serverKey(for url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        // localhost and 127.0.0.1 are the same server.
        let normalized = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) ? "localhost" : host
        return "\(normalized):\(port)"
    }

    /// Registers a request. Pair every call with `end`, typically via `defer`.
    func begin(_ url: URL) -> Ticket {
        let ticket = Ticket(id: UUID(), server: Self.serverKey(for: url))
        lock.lock()
        inFlight[ticket.server, default: []].insert(ticket.id)
        lock.unlock()
        return ticket
    }

    func end(_ ticket: Ticket) {
        lock.lock()
        inFlight[ticket.server]?.remove(ticket.id)
        if inFlight[ticket.server]?.isEmpty == true { inFlight[ticket.server] = nil }
        lock.unlock()
    }

    /// Requests in flight to the server behind `url`.
    func activeRequests(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight[Self.serverKey(for: url)]?.count ?? 0
    }

    func isBusy(_ url: URL) -> Bool { activeRequests(for: url) > 0 }

    /// Waits until the server has no requests in flight, checking every
    /// quarter second, for at most `timeout` seconds. Returns `false` when it
    /// is still busy at the deadline (or the task is cancelled).
    func waitUntilIdle(_ url: URL, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isBusy(url) {
            guard Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return true
    }
}
