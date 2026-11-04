import Foundation
import Darwin

/// Makes sure no process TypstEdit started (preview compilers, MCP servers,
/// the CAS helper, Python runs…) keeps running after the app is gone, however
/// it ends.
///
/// - Normal quit: `terminateDescendants()` stops them before the app exits.
/// - Force Quit, a crash or `kill -9`: the app cannot run code then, so a
///   small watchdog shell started at launch remembers the app's descendants
///   and stops them once the app's process is gone.
/// - Anything left from older versions: `sweepOrphanedPreviewCompilers()` at
///   launch stops TypstEdit preview compilers whose parent has gone.
///
/// Foundation's `Process` puts each child in its own process group, so
/// killing the app's group would not reach them: descendants are found by
/// parent PID instead.
enum ChildProcessGuard {

    // MARK: - Normal Quit

    /// Sends SIGTERM to every descendant of this process, waits up to `grace`
    /// seconds, then sends SIGKILL to whatever is still running.
    static func terminateDescendants(grace: TimeInterval = 0.5) {
        let pids = descendants(of: getpid())
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }

        let deadline = Date().addingTimeInterval(grace)
        var running = pids
        while !running.isEmpty, Date() < deadline {
            usleep(20_000)
            running = running.filter(isAlive)
        }
        for pid in running { kill(pid, SIGKILL) }
    }

    /// Children, grandchildren and so on, parents before their children.
    static func descendants(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [root]
        while let parent = queue.popLast() {
            for child in children(of: parent) where !result.contains(child) {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    private static func children(of parent: pid_t) -> [pid_t] {
        let count = proc_listchildpids(parent, nil, 0)
        guard count > 0 else { return [] }
        // Room for children started between the two calls.
        var buffer = [pid_t](repeating: 0, count: Int(count) + 16)
        let filled = buffer.withUnsafeMutableBytes { raw in
            proc_listchildpids(parent, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return [] }
        return Array(buffer.prefix(Int(filled))).filter { $0 > 0 }
    }

    /// Running, and not a zombie waiting to be reaped.
    private static func isAlive(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }

    // MARK: - Force Quit and Crashes

    /// The watchdog snapshots the app's descendants every second while the
    /// app runs. When the app's PID is gone, it stops the last snapshot.
    /// It skips itself (and its own helper processes) when it looks.
    static let watchdogScript = #"""
    app="$1"
    me=$$
    tree() {
      for c in $(pgrep -P "$1"); do
        [ "$c" = "$me" ] && continue
        echo "$c"
        tree "$c"
      done
    }
    snap=""
    while kill -0 "$app" 2>/dev/null; do
      snap=$(tree "$app")
      sleep 1
    done
    [ -n "$snap" ] || exit 0
    kill -TERM $snap 2>/dev/null
    sleep 1
    kill -KILL $snap 2>/dev/null
    exit 0
    """#

    @MainActor private static var watchdog: Process?

    /// Starts the watchdog once per launch. GUI app only: headless CLI and
    /// MCP runs end with their own process.
    @MainActor static func startWatchdog() {
        guard watchdog == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", watchdogScript, "typstedit-watchdog", String(getpid())]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            watchdog = process
        } catch {
            print("[ChildProcessGuard] Could not start the watchdog: \(error)")
        }
    }

    // MARK: - Leftovers From Earlier Runs

    /// Stops `typst watch` preview compilers that an earlier TypstEdit run
    /// left behind. Only orphans (parent PID 1) that run a TypstEdit-managed
    /// typst binary on a TypstEdit preview file (`*.preview.typ`) match, so a
    /// `typst watch` the user started is never touched.
    static func sweepOrphanedPreviewCompilers(managedBinaryPrefixes: [String]) {
        let prefixes = managedBinaryPrefixes.filter { !$0.isEmpty }
        guard !prefixes.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let pids = orphanedPreviewCompilers(in: processTable(), managedBinaryPrefixes: prefixes)
            guard !pids.isEmpty else { return }
            print("[ChildProcessGuard] Stopping \(pids.count) leftover preview compiler(s)")
            for pid in pids { kill(pid, SIGTERM) }
            sleep(1)
            for pid in pids where isAlive(pid) { kill(pid, SIGKILL) }
        }
    }

    struct ProcessEntry: Equatable {
        var pid: pid_t
        var parent: pid_t
        var command: String
    }

    /// The matching rule, separate from `ps` so it can be unit tested.
    static func orphanedPreviewCompilers(in table: [ProcessEntry], managedBinaryPrefixes: [String]) -> [pid_t] {
        table.compactMap { entry in
            guard entry.parent == 1,
                  let watch = entry.command.range(of: " watch ") else { return nil }
            let binary = String(entry.command[..<watch.lowerBound])
            guard URL(fileURLWithPath: binary).lastPathComponent == "typst",
                  prefixes(managedBinaryPrefixes, contain: binary),
                  entry.command.contains(".preview.typ") else { return nil }
            return entry.pid
        }
    }

    private static func prefixes(_ prefixes: [String], contain path: String) -> Bool {
        prefixes.contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// `ps -axo pid=,ppid=,args=`, parsed.
    private static func processTable() -> [ProcessEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,ppid=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { return nil }
            return ProcessEntry(pid: pid, parent: parent, command: String(fields[2]))
        }
    }
}
