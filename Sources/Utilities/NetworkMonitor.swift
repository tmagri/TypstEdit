import Foundation
import Network

/// Reports whether this Mac currently has a usable network path, and lets a
/// request wait for the path to come back — the wait-for-network recovery
/// from TypstEdit's chat: a request that failed because Wi-Fi dropped is
/// parked and re-sent the moment macOS reports a connection again, without
/// burning a retry attempt.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    /// Whether the system currently reports a satisfied path.
    @Published private(set) var isSatisfied: Bool = true

    private let monitor = NWPathMonitor()
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    private init() {
        // `pathUpdateHandler` runs on the monitor's own queue, never on the
        // main actor — so this must hop, not assert. It used to call
        // `MainActor.assumeIsolated`, which traps the moment macOS delivers
        // the first path update and took the whole app down with it.
        // Explicitly @Sendable: without it Swift 6 infers this closure as
        // main-actor isolated (it is written inside a @MainActor init) and
        // inserts a runtime isolation check — the same trap again.
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.isSatisfied = satisfied
                if satisfied {
                    self.resumeWaiters()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "TypstEdit.NetworkMonitor"))
    }

    /// Suspends until the network path is satisfied (or the task is
    /// cancelled). Returns immediately when already satisfied.
    func waitForPath() async {
        if isSatisfied || Task.isCancelled { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuations[UUID()] = continuation
        }
    }

    private func resumeWaiters() {
        let waiters = continuations
        continuations.removeAll()
        for (_, continuation) in waiters {
            continuation.resume()
        }
    }
}
