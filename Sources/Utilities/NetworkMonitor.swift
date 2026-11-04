import Foundation
import Network

/// Tracks whether macOS currently reports a usable network path, so a chat
/// request that failed because the network dropped can wait for the link to
/// come back instead of surfacing an error.
///
/// `NWPathMonitor` is the source of truth. Its "satisfied" status means an
/// interface is up — Wi-Fi associated, cable in, VPN tunnel established — not
/// that the internet beyond it answers, so callers combine `isConnected`
/// with the `URLError` they actually saw rather than trusting either alone.
/// All state is lock-protected: the monitor reports on a private queue while
/// chat requests poll from the main actor.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    /// False until the monitor delivers its first path update, which lands on
    /// its queue shortly after the singleton is first touched.
    private var pathIsSatisfied = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.pathIsSatisfied = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "app.typstedit.networkmonitor"))
    }

    deinit {
        monitor.cancel()
    }

    /// Whether an interface currently has a usable path.
    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pathIsSatisfied
    }
}
