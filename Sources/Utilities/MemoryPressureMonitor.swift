import Foundation

/// App-wide "the system is short on memory" broadcast.
///
/// Everything TypstEdit keeps only to make a later action faster is a cache,
/// and every cache can be rebuilt. Holding one through a memory warning only
/// pushes the app toward swapping (or being killed) for something nobody is
/// looking at. macOS reports pressure through a `DispatchSourceMemoryPressure`;
/// this reposts it as a `Notification` on the main queue so ordinary
/// `NotificationCenter` observers can drop their caches without touching GCD.
///
/// The `willFreeMemory` name is deliberate: an observer's only job is to let
/// go of reproducible state, never to change what is on screen.
final class MemoryPressureMonitor: @unchecked Sendable {
    static let shared = MemoryPressureMonitor()

    /// Posted on the main queue when the system asks for memory back.
    static let willFreeMemory = Notification.Name("TypstEdit.willFreeMemory")

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.typstedit.memorypressure", qos: .utility)
    private lazy var source = DispatchSource.makeMemoryPressureSource(
        eventMask: [.warning, .critical],
        queue: queue
    )
    private var started = false

    private init() {}

    /// Starts listening. Idempotent, so callers may invoke it from wherever
    /// the first cache happens to be created.
    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        source.setEventHandler {
            // The event handler fires on `queue`; observers live on the main
            // actor, so hop here once rather than making each of them do it.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.willFreeMemory, object: nil)
            }
        }
        source.resume()
    }
}
