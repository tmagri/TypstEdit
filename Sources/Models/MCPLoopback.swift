import Foundation
import Network

/// A value written on one queue and read on another, with a lock — for the
/// small hand-offs between Network.framework's queue and whoever is waiting.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}

/// Receives the one redirect an OAuth sign-in sends back, on
/// `http://127.0.0.1:<port>/callback`.
///
/// A loopback redirect is the correct channel for a desktop app (RFC 8252):
/// no custom URL scheme for another app to claim, and no way for a page on
/// the internet to read the code. The port is chosen by the system, which
/// RFC 8252 requires authorization servers to accept for loopback
/// redirects; a server that pins the port is a known incompatibility.
///
/// The listener answers exactly one request — the redirect — with a small
/// page telling the user to go back to TypstEdit, and closes. Everything else
/// (favicon requests, a scanner on the port) is answered with 404 and does
/// not end the wait.
final class MCPLoopbackListener: @unchecked Sendable {
    /// How many bytes of the request line to read before giving up on it.
    private static let maxRequestBytes = 16 * 1024

    private let listener: NWListener
    private let queue = DispatchQueue(label: "typstedit.mcp.oauth.loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var settled = false
    private(set) var port: UInt16 = 0

    /// `http://127.0.0.1:<port>/callback`.
    var redirectURI: String {
        "http://127.0.0.1:\(port)/callback"
    }

    /// Starts listening on an ephemeral loopback port.
    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
        // Loopback only: never reachable from the network.
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        let started = DispatchSemaphore(value: 0)
        let startError = LockedBox<Error?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                started.signal()
            case .failed(let error):
                startError.set(error)
                started.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        guard started.wait(timeout: .now() + 10) == .success else {
            listener.cancel()
            throw MCPOAuthError.discoveryFailed("the local sign-in receiver did not start")
        }
        if let startError = startError.get() {
            listener.cancel()
            throw MCPOAuthError.discoveryFailed("the local sign-in receiver could not listen: \(startError.localizedDescription)")
        }
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw MCPOAuthError.discoveryFailed("the local sign-in receiver got no port")
        }
        self.port = port
    }

    deinit {
        listener.cancel()
    }

    /// Waits for the redirect. Only one waiter exists at a time: one sign-in.
    /// Cancellable: a sign-in the caller abandoned (a timeout, a closed
    /// window) must not leave this suspended forever.
    func waitForRedirect() async throws -> URL {
        let box = LockedBox<CheckedContinuation<URL, Error>?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if settled {
                    lock.unlock()
                    continuation.resume(throwing: MCPOAuthError.cancelled)
                    return
                }
                self.continuation = continuation
                box.set(continuation)
                lock.unlock()
            }
        } onCancel: {
            if let waiter = box.get() { waiter.resume(throwing: MCPOAuthError.cancelled) }
            self.settle(.failure(MCPOAuthError.cancelled))
        }
    }

    func stop() {
        settle(.failure(MCPOAuthError.cancelled))
        listener.cancel()
    }

    /// Resumes the waiter once; later calls are no-ops.
    private func settle(_ result: Result<URL, Error>) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        let waiter = continuation
        continuation = nil
        lock.unlock()
        switch result {
        case .success(let url): waiter?.resume(returning: url)
        case .failure(let error): waiter?.resume(throwing: error)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var data = buffer
            if let chunk { data.append(chunk) }
            if let error {
                connection.cancel()
                // A dropped connection before a redirect is not a sign-in
                // failure: the browser may retry, and a scanner often does
                // this. Keep waiting.
                _ = error
                return
            }
            if let request = Self.parseRequest(data) {
                self.respond(to: connection, request: request)
                return
            }
            if isComplete || data.count >= Self.maxRequestBytes {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: data)
        }
    }

    private struct RequestLine {
        var method: String
        var target: String
    }

    /// The request line, once a full line of headers has arrived.
    private static func parseRequest(_ data: Data) -> RequestLine? {
        guard let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n"),
              let firstLine = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first else { return nil }
        _ = headerEnd
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return RequestLine(method: String(parts[0]).uppercased(), target: String(parts[1]))
    }

    private func respond(to connection: NWConnection, request: RequestLine) {
        guard request.method == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + request.target),
              components.path == "/callback" else {
            // Not the redirect: a favicon, a scanner, a second page. Answer
            // and keep waiting for the real one.
            send(status: "404 Not Found", body: "Not found.", on: connection)
            return
        }
        guard let url = components.url else {
            send(status: "400 Bad Request", body: "Bad request.", on: connection)
            settle(.failure(MCPOAuthError.authorizationDenied("the redirect was malformed")))
            return
        }
        send(status: "200 OK", body: Self.successPage, on: connection)
        settle(.success(url))
    }

    private func send(status: String, body: String, on connection: NWConnection) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(Data(body.utf8).count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Plain, small, and offline: the browser shows it once and the user
    /// closes the tab.
    static let successPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>TypstEdit — signed in</title>
    <style>body{font:15px -apple-system,Helvetica,sans-serif;margin:3em auto;max-width:30em;text-align:center;color:#222}
    code{background:#f0f0f0;padding:.15em .35em;border-radius:4px}</style></head>
    <body><h2>Signed in</h2><p>TypstEdit has the access it needs. You can close this tab and go back to
    <code>Settings → MCP</code> to finish.</p></body></html>
    """
}
