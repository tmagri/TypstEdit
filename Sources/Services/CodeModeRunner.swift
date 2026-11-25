import Foundation
import JavaScriptCore

/// A sandboxed JavaScript interpreter behind the `code__execute` tool.
///
/// Why it exists: a model that needs six reads to answer one question
/// otherwise spends six rounds doing it, and every raw file it reads stays in
/// the context for the rest of the chat. In here the model writes one small
/// program that calls the tools it already has, filters and joins their
/// results in code, and returns only the answer — one round, one small result.
///
/// What it is *not*: a general-purpose runtime. The interpreter is a bare
/// `JSContext`: no `fetch`, no file access, no timers, no imports. The only way
/// out is `tools.<namespace>.<tool>(…)`, and every one of those goes through
/// the agent's own `executeTool`, so the approval card, the saved permission
/// rules, the safety monitor, Plan mode and the transcript
/// rows all still apply. Code mode adds a way to *compose* calls; it adds no
/// authority. A script cannot do anything the model could not do in six
/// separate turns.
///
/// Three limits keep a bad script from taking the app with it:
///
/// - **Compute time.** JavaScriptCore's own watchdog terminates a script that
///   spins. The context survives, so the next turn still works.
/// - **Wall clock.** Even a script that only waits — on an approval card
///   nobody answers — gives up eventually.
/// - **Fan-out.** A loop that calls a tool once per line of a file would be a
///   denial of service on the user's attention, so nested calls are capped.
///
/// It is `@MainActor` because the caller needs it to be: nested calls raise
/// approval cards and write transcript rows. Waits hand the main actor back
/// with `Task.sleep`, so the chat window keeps drawing while a script is
/// parked on a card.
@MainActor
final class CodeModeRunner {

    // MARK: - Limits

    /// JavaScript compute time one script may use, in seconds. Not wall
    /// clock: time spent waiting for a tool (or for the user to approve one)
    /// is not the script's fault.
    nonisolated static let defaultComputeBudget: TimeInterval = 20

    /// Wall-clock cap for a script that has not touched a tool, in seconds.
    ///
    /// The flat 300-second limit this replaces killed a script that was
    /// legitimately *waiting*: one `file__search` over a big tree, a
    /// `shell__run` build, or a slow MCP call can each take minutes, and a
    /// script that awaits three of them in sequence died with "split the work
    /// into smaller scripts" — advice that could not help, because the work was
    /// already split and the tool was simply slow.
    ///
    /// The cap is now the tool's own bound plus this baseline (see
    /// `wallClockLimit(forCalls:)`), so the tool's timeout is what ends a slow
    /// call, not the script's patience.
    nonisolated static let wallClockBaseLimit: TimeInterval = 300

    /// Extra wall-clock time granted per nested call the script has made.
    ///
    /// A tool call's own timeout is the outer bound on how long it may run;
    /// this is the allowance for it to *be* slow. Nested calls already have
    /// their own deadlines (shell's 5-3600 s, the file walk's 60 s), so this is
    /// deliberately generous: it exists to keep a parked script from being
    /// killed for waiting, not to police the tools.
    nonisolated static let wallClockPerCallAllowance: TimeInterval = 120

    /// Hard wall-clock cap, every wait included, for a script that has made
    /// `calls` nested tool calls.
    ///
    /// Still finite, and still reached by a script parked on a card that can
    /// never be answered — an approval the user walked away from.
    nonisolated static func wallClockLimit(forCalls calls: Int) -> TimeInterval {
        wallClockBaseLimit + Double(max(0, calls)) * wallClockPerCallAllowance
    }

    /// The cap a caller that does not know the call count yet should assume.
    /// Kept for the existing call sites that reason about the limit up front.
    nonisolated static var wallClockLimit: TimeInterval { wallClockBaseLimit }

    /// Most nested tool calls one script may make.
    nonisolated static let maxNestedCalls = 64
    /// Most characters returned to the model. A script that returns a whole
    /// file would defeat the point of running one.
    nonisolated static let maxOutputChars = 24_000
    /// How often the pump wakes to deliver finished tool results.
    ///
    /// This is a `@MainActor` loop, so each tick is a main-thread wakeup for
    /// the whole life of a script. At the original 3 ms that was ~330 wakeups a
    /// second — work proportional to the run, on the actor that draws the
    /// window, for a value nobody can perceive: a tool result delivered 20 ms
    /// after it finished is indistinguishable from one delivered in 3 ms.
    nonisolated static let pollNanoseconds: UInt64 = 20_000_000

    // MARK: - Shapes

    /// One nested call a script made.
    struct CallRecord: Equatable {
        var tool: String
        var argumentsJSON: String
        /// "running", then the first line of the result.
        var outcome: String
    }

    struct Outcome: Equatable {
        var output: String
        var calls: [CallRecord]
    }

    /// The tool surface a script may reach.
    struct ExposedTool: Equatable {
        var namespace: String
        var name: String
        var qualifiedName: String
    }

    // MARK: - State

    private let context: JSContext
    private let bridge: Bridge
    private let watchdog = Watchdog()

    init() {
        let ctx = JSContext()!
        ctx.name = "typstedit-code-mode"
        // An exception thrown by a nested call would otherwise surface here
        // with no way to read it; keeping the last one lets the failure be
        // reported as the script's error rather than a silent empty result.
        self.context = ctx
        self.bridge = Bridge()
    }

    /// Runs `code` and returns what it produced.
    ///
    /// - Parameters:
    ///   - code: the program body. It runs inside an `async` function, so
    ///     top-level `await` and `return` both work.
    ///   - tools: what the script may call.
    ///   - budget: JavaScript compute seconds. Injectable so a test can prove
    ///     the watchdog fires without waiting twenty seconds.
    ///   - call: dispatches one nested call, on the main actor. The agent's
    ///     `executeTool` is the real implementation.
    func run(
        code: String,
        tools: [ExposedTool],
        budget: TimeInterval = CodeModeRunner.defaultComputeBudget,
        call: @escaping @MainActor (String, String) async -> String
    ) async -> Outcome {
        bridge.attach(context: context, tools: tools)
        context.evaluateScript(Self.prologue)

        let started = Date()
        var remaining = max(1, budget)
        var records: [CallRecord] = []
        var inFlight: [Int: Task<Void, Never>] = [:]

        // The first evaluate needs the watchdog too. An `async` function body
        // runs synchronously until its first `await`, so `while (true) {}` at
        // the top of a script would otherwise block this very call — the app
        // included — before the loop below ever got a chance to interrupt it.
        let openStart = Date()
        if watchdog.evaluate(Self.wrapped(code), in: context, seconds: remaining) {
            return Outcome(
                output: "Error: the script was stopped after \(Int(budget)) seconds of compute time — it looks like an endless loop, and no tool calls ran.",
                calls: []
            )
        }
        remaining -= max(0, Date().timeIntervalSince(openStart))

        while true {
            if Task.isCancelled { return stop(records, inFlight) }

            // The cap grows with the calls the script has actually made, so a
            // slow tool ends by its own timeout rather than by this one. A
            // script that never calls a tool keeps the baseline.
            let callLimit = Self.wallClockLimit(forCalls: records.count)
            if Date().timeIntervalSince(started) > callLimit {
                return Outcome(
                    output: "Error: the script ran longer than its \(Int(callLimit))-second wall-clock limit with \(records.count) tool call\(records.count == 1 ? "" : "s") made — it is waiting on something that never finished. No further calls were run.\(Self.callSummary(records))",
                    calls: records
                )
            }

            // Start whatever the script asked for since the last tick.
            for request in bridge.takePending() {
                guard records.count + inFlight.count < Self.maxNestedCalls else {
                    bridge.reject(
                        id: request.id,
                        message: "This script has made \(Self.maxNestedCalls) tool calls, which is the limit, so this one was not run. Do the rest in another script."
                    )
                    continue
                }
                let index = records.count
                records.append(CallRecord(tool: request.tool, argumentsJSON: request.argumentsJSON, outcome: "running"))
                inFlight[request.id] = Task { @MainActor [weak self] in
                    let output = await call(request.tool, request.argumentsJSON)
                    guard let self else { return }
                    self.bridge.complete(id: request.id, output: output)
                    if index < records.count {
                        records[index].outcome = Self.oneLine(output)
                    }
                }
            }

            // A finished task must leave the map, or the call cap would count
            // it forever. `takeCompleted` below is what tells the script it
            // finished; here it is only bookkeeping for the cap and the drain
            // at the end.
            for id in inFlight.keys where bridge.isSettled(id: id) {
                inFlight.removeValue(forKey: id)
            }

            if remaining <= 0.05 {
                return Outcome(
                    output: "Error: the script used its \(Int(budget)) seconds of compute time without finishing — that usually means an endless loop. Split the work into smaller scripts.",
                    calls: records
                )
            }

            // One pump slice, all of it under the watchdog.
            //
            // Resolving a promise is not a passive act: JavaScriptCore runs
            // the continuation inline, which means the code after an `await`
            // executes *here*, inside `bridge.resolve`. An unguarded resolve
            // would therefore let `const x = await tool(…); while (true) {}`
            // hang the main thread with no way to interrupt it. So the
            // watchdog wraps both steps.
            let sliceStart = Date()
            watchdog.begin(seconds: remaining, in: context)
            for (id, output) in bridge.takeCompleted() {
                // The harness reports a failed call as text starting with
                // "Error: " — that is how `executeTool` signals a declined
                // approval, a permission rule, or a tool that threw. Passing
                // it through as a resolved value would make the script look
                // successful and a `try/catch` around the call never fire, so
                // it is turned back into a rejection here.
                if output.hasPrefix("Error: ") {
                    bridge.reject(id: id, message: String(output.dropFirst("Error: ".count)))
                } else {
                    bridge.resolve(id: id, with: output)
                }
            }
            context.evaluateScript("0")
            let fired = watchdog.end(in: context)
            remaining -= max(0, Date().timeIntervalSince(sliceStart))

            if fired {
                return Outcome(
                    output: "Error: the script was stopped after \(Int(budget)) seconds of compute time — it looks like an endless loop. \(Self.callSummary(records))",
                    calls: records
                )
            }
            if isDone() { break }

            // Nothing outstanding and nothing running: every promise the
            // script awaited has been settled, so it cannot make progress
            // without another tool call. That means it is finished with fewer
            // calls than it started with — report what it produced.
            if inFlight.isEmpty, bridge.outstanding == 0 { break }

            try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
        }

        // Let any call still running finish, so no task outlives the run and
        // the summary lists what really happened.
        for task in inFlight.values { _ = await task.value }
        watchdog.begin(seconds: 2, in: context)
        for (id, output) in bridge.takeCompleted() {
            if output.hasPrefix("Error: ") {
                bridge.reject(id: id, message: String(output.dropFirst("Error: ".count)))
            } else {
                bridge.resolve(id: id, with: output)
            }
        }
        context.evaluateScript("0")
        _ = watchdog.end(in: context)

        if let error = errorText() {
            let summary = Self.callSummary(records)
            return Outcome(
                output: "Error in the script: \(Self.trimmed(error, to: Self.maxOutputChars))"
                    + (summary.isEmpty ? "" : "\n\n\(summary)"),
                calls: records
            )
        }

        let rendered = Self.render(resultValue(), in: context)
        let summary = Self.callSummary(records)
        var output = rendered.isEmpty
            ? "The script finished without returning a value. Return what you want to see, for example `return matches`."
            : rendered
        if !summary.isEmpty { output += "\n\n\(summary)" }
        return Outcome(output: output, calls: records)
    }

    // MARK: - Loop helpers

    /// Stops the run without waiting on in-flight calls. They are already
    /// begun — the same position a stopped sequential turn leaves them in —
    /// and their transcript rows update when they finish.
    private func stop(_ records: [CallRecord], _ inFlight: [Int: Task<Void, Never>]) -> Outcome {
        inFlight.values.forEach { $0.cancel() }
        return Outcome(output: "Stopped: the run was interrupted before the script finished. Any tool calls listed below had already begun.", calls: records)
    }

    private func isDone() -> Bool {
        context.objectForKeyedSubscript("__typstedit_done")?.toBool() ?? false
    }

    private func resultValue() -> JSValue? {
        context.objectForKeyedSubscript("__typstedit_result")
    }

    private func errorText() -> String? {
        guard let value = context.objectForKeyedSubscript("__typstedit_error"),
              !value.isNull, !value.isUndefined else { return nil }
        let text = value.toString() ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: - Source

    /// Guards that explain themselves, so a model that reaches for `fetch` or
    /// `require` learns why it cannot rather than getting "undefined is not a
    /// function".
    nonisolated static let prologue = """
    (function () {
      "use strict";
      const deny = (name) => function () {
        throw new Error(name + " is not available in code mode. Only tools.<namespace>.<tool>(…) is: this is a restricted interpreter, not a general runtime.");
      };
      ["fetch", "XMLHttpRequest", "require", "importScripts", "setTimeout", "setInterval", "process"].forEach((name) => {
        try { Object.defineProperty(globalThis, name, { value: deny(name), writable: false, configurable: false }); } catch (error) {}
      });
    })();
    """

    /// The model's code, wrapped so top-level `await` and `return` work and
    /// so a rejection is recorded instead of vanishing into a lost promise.
    nonisolated static func wrapped(_ code: String) -> String {
        """
        globalThis.__typstedit_done = false;
        globalThis.__typstedit_result = undefined;
        globalThis.__typstedit_error = null;
        (async () => {
        \(code)
        })()
          .then((value) => {
            globalThis.__typstedit_result = value;
            globalThis.__typstedit_done = true;
          })
          .catch((error) => {
            const text = (error && error.message) ? String(error.message) : String(error);
            globalThis.__typstedit_error = text === "[object Object]" ? JSON.stringify(error) : text;
            globalThis.__typstedit_done = true;
          });
        """
    }

    // MARK: - Rendering

    /// What the model sees for the script's `return` value.
    ///
    /// A string comes back as itself: every tool returns text, and wrapping
    /// that in JSON quotes is noise. Anything else is JSON, which is what a
    /// script that returned `{ files, count }` expected to see.
    nonisolated static func render(_ value: JSValue?, in context: JSContext) -> String {
        guard let value, !value.isUndefined else { return "" }
        if value.isNull { return "null" }
        if value.isString { return trimmed(value.toString() ?? "", to: maxOutputChars) }
        let stringify = context.objectForKeyedSubscript("JSON")?.objectForKeyedSubscript("stringify")
        // `null` and `2` are the replacer and the indent: JSON, pretty
        // printed, which is what a model reads best.
        let arguments: [Any] = [value, JSValue(nullIn: context)!, JSValue(int32: 2, in: context)!]
        if let json = stringify?.call(withArguments: arguments),
           let text = json.toString(), !json.isUndefined {
            return trimmed(text, to: maxOutputChars)
        }
        return trimmed(value.toString() ?? "", to: maxOutputChars)
    }

    nonisolated static func trimmed(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… [truncated: \(text.count - limit) more characters]"
    }

    nonisolated static func oneLine(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 120 ? String(flat.prefix(120)) + "…" : flat
    }

    /// A short "what this script did" footer. The model needs to know which
    /// calls actually ran: a script that swallowed an error in `try/catch`
    /// otherwise looks like it succeeded.
    nonisolated static func callSummary(_ records: [CallRecord]) -> String {
        guard !records.isEmpty else { return "" }
        let lines = records.map { "- \($0.tool) → \($0.outcome)" }
        return "Tool calls made by the script (oldest first):\n" + lines.joined(separator: "\n")
    }
}

// MARK: - Watchdog

/// JavaScriptCore's execution-time limit is private SPI, so it is loaded by
/// symbol rather than declared in a header. The fallback is deliberate: if the
/// symbol ever disappears the tool still works, it just loses the endless-loop
/// guard. The wall-clock limit still ends the run.
final class Watchdog: @unchecked Sendable {
    private typealias SetLimit = @convention(c) (
        OpaquePointer?,
        Double,
        (@convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Bool)?,
        UnsafeMutableRawPointer?
    ) -> Void
    private typealias ClearLimit = @convention(c) (OpaquePointer?) -> Void

    private let setLimit: SetLimit?
    private let clearLimit: ClearLimit?
    /// Every flag ever handed to the watchdog. JavaScriptCore keeps the
    /// pointer after `evaluateScript` returns, and its timer thread can call
    /// back once more; freeing the flag with the call would leave that
    /// callback writing into freed memory. They are tiny, and one per pump
    /// slice of one script, so keeping them is cheaper than the crash.
    private var flags: [TerminationFlag] = []
    /// The flag for the slice in progress, so `end` can report it.
    private var current: TerminationFlag?

    init() {
        let handle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW)
        setLimit = handle.flatMap { dlsym($0, "JSContextGroupSetExecutionTimeLimit") }
            .map { unsafeBitCast($0, to: SetLimit.self) }
        clearLimit = handle.flatMap { dlsym($0, "JSContextGroupClearExecutionTimeLimit") }
            .map { unsafeBitCast($0, to: ClearLimit.self) }
    }

    var isAvailable: Bool { setLimit != nil && clearLimit != nil }

    /// Runs one slice of the interpreter's work, terminating it if it computes
    /// for longer than `seconds`. Returns whether the watchdog fired.
    ///
    /// `begin` / `end` rather than a single `evaluate` because a slice is not
    /// one call: resolving a promise runs the script's continuation inline, so
    /// the guard has to span the resolve *and* the pump that follows it.
    func begin(seconds: TimeInterval, in context: JSContext) {
        guard let setLimit, let group = JSContextGetGroup(context.jsGlobalContextRef) else { return }
        let flag = TerminationFlag()
        // Retained until the runner is gone: JavaScriptCore's watchdog thread
        // can fire just after `evaluateScript` returns, and a flag that died
        // with the call would be a use-after-free in that callback.
        flags.append(flag)
        current = flag
        setLimit(group, max(0.05, seconds), { _, info in
            guard let info else { return true }
            Unmanaged<TerminationFlag>.fromOpaque(info).takeUnretainedValue().value = true
            return true
        }, Unmanaged.passUnretained(flag).toOpaque())
    }

    /// Closes the slice and reports whether the watchdog stopped it.
    func end(in context: JSContext) -> Bool {
        if let clearLimit, let group = JSContextGetGroup(context.jsGlobalContextRef) {
            clearLimit(group)
        }
        let fired = current?.value ?? false
        current = nil
        return fired
    }

    /// Runs `script` as one complete slice, guarded if the SPI is available.
    func evaluate(_ script: String, in context: JSContext, seconds: TimeInterval) -> Bool {
        begin(seconds: seconds, in: context)
        context.evaluateScript(script)
        return end(in: context)
    }
}

/// The flag a C callback can hold by pointer: a captured `var` cannot cross
/// that boundary, and the callback runs on the interpreter's thread while the
/// runner reads it on the main one.
final class TerminationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }
        set {
            lock.lock()
            fired = newValue
            lock.unlock()
        }
    }
}

// MARK: - Bridge

/// The seam between the interpreter and Swift.
///
/// The tool functions a script calls are `@convention(block)` closures that
/// JavaScriptCore invokes synchronously, while their results arrive later from
/// `async` Swift. This class is the smallest thing that carries that across: a
/// block records a request and returns a promise; the runner drains requests,
/// runs them, and resolves the promises it kept.
///
/// Every method is called from the main thread; the lock is there because the
/// build closures are typed for JavaScriptCore, not for Swift's actor model.
final class Bridge: @unchecked Sendable {
    struct Request {
        var id: Int
        var tool: String
        var argumentsJSON: String
    }

    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Request] = []
    private var completed: [(Int, String)] = []
    private var resolvers: [Int: JSValue] = [:]
    private var rejecters: [Int: JSValue] = [:]
    /// Requests not yet delivered, plus results not yet handed over. Zero
    /// means the script is only waiting on its own computation.
    private var outstandingCount = 0

    var outstanding: Int { locked { outstandingCount } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Builds `tools` for the script: one object per namespace, one function
    /// per tool.
    func attach(context: JSContext, tools: [CodeModeRunner.ExposedTool]) {
        locked {
            nextID = 0
            pending = []
            completed = []
            resolvers = [:]
            rejecters = [:]
            outstandingCount = 0
        }
        let root = JSValue(newObjectIn: context)!
        var namespaces: [String: JSValue] = [:]
        for tool in tools {
            let namespace: JSValue
            if let existing = namespaces[tool.namespace] {
                namespace = existing
            } else {
                namespace = JSValue(newObjectIn: context)!
                namespaces[tool.namespace] = namespace
                root.setObject(namespace, forKeyedSubscript: tool.namespace as NSString)
            }
            let function: @convention(block) (JSValue) -> JSValue = { [weak self] arguments in
                guard let self else { return JSValue(undefinedIn: context)! }
                return self.makePromise(for: tool.qualifiedName, arguments: arguments, in: context)
            }
            namespace.setObject(function, forKeyedSubscript: tool.name as NSString)
        }
        context.setObject(root, forKeyedSubscript: "tools" as NSString)
    }

    /// Records one call and hands the script a promise for its result.
    private func makePromise(for tool: String, arguments: JSValue, in context: JSContext) -> JSValue {
        // Serialize with the interpreter's own `JSON.stringify`, so nested
        // objects, arrays and non-ASCII text arrive exactly as written.
        let argumentsJSON = Self.jsonString(for: arguments, in: context)
        let id = locked { () -> Int in
            let id = nextID
            nextID += 1
            outstandingCount += 1
            pending.append(Request(id: id, tool: tool, argumentsJSON: argumentsJSON))
            return id
        }
        return JSValue(newPromiseIn: context) { [weak self] resolve, reject in
            guard let self, let resolve, let reject else { return }
            self.locked {
                self.resolvers[id] = resolve
                self.rejecters[id] = reject
            }
        }!
    }

    static func jsonString(for arguments: JSValue, in context: JSContext) -> String {
        let stringify = context.objectForKeyedSubscript("JSON")?.objectForKeyedSubscript("stringify")
        // `undefined` is a common typo for a tool that takes no arguments;
        // treat it as `{}` so the call fails on the tool's own terms.
        let value = arguments.isUndefined ? JSValue(object: [String: Any](), in: context)! : arguments
        guard let result = stringify?.call(withArguments: [value]),
              let text = result.toString(), !result.isUndefined else {
            return "{}"
        }
        return text
    }

    func takePending() -> [Request] {
        locked {
            let requests = pending
            pending = []
            return requests
        }
    }

    /// Records a finished call. The count drops when the promise is actually
    /// settled (`resolve`/`reject`), not here: a result sitting in the queue
    /// has not reached the script yet, and treating it as done would let the
    /// loop conclude early.
    func complete(id: Int, output: String) {
        locked { completed.append((id, output)) }
    }

    func takeCompleted() -> [(Int, String)] {
        locked {
            let results = completed
            completed = []
            return results
        }
    }

    func resolve(id: Int, with output: String) {
        let resolve = locked { () -> JSValue? in
            let value = resolvers.removeValue(forKey: id)
            rejecters.removeValue(forKey: id)
            if value != nil { outstandingCount -= 1 }
            return value
        }
        resolve?.call(withArguments: [output])
    }

    /// Whether a call's promise has already been handed its result, so the
    /// runner can drop its task.
    func isSettled(id: Int) -> Bool {
        locked { resolvers[id] == nil && rejecters[id] == nil }
    }

    func reject(id: Int, message: String) {
        let reject = locked { () -> JSValue? in
            let value = rejecters.removeValue(forKey: id)
            resolvers.removeValue(forKey: id)
            if value != nil { outstandingCount -= 1 }
            return value
        }
        reject?.call(withArguments: [message])
    }
}
