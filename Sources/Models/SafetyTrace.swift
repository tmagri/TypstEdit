import Foundation

/// A snapshot of what the agent has done so far in one turn, shaped so that
/// safety checks can be written as pure predicates.
///
/// Ported from Clippy's `AgentTrace`, itself the port of SafeAgents' `trace`
/// dictionary (`safeagents/core/src/evaluation/attack_detection.py`): the same
/// idea — a detector is a function of (task, tool calls, log) — with the
/// pieces TypstEdit actually produces. Upstream's `bash_returns_true` and
/// `bash_output_contains` are deliberately **not** ported: spawning a shell
/// script as part of a safety mechanism would add an execution path on a
/// machine where the Python tool is already sandboxed, so the checks stay
/// purely in-process and side-effect free.
///
/// Named `SafetyTrace` rather than `AgentTrace` because `AgentTrace` is
/// already the opt-in JSONL logger in `Sources/Utilities/AgentTrace.swift`.
struct SafetyTrace: Sendable, Equatable {

    /// One recorded tool call, from the transcript.
    struct ToolCall: Sendable, Equatable {
        /// Qualified name, e.g. `python__run`.
        let name: String
        /// The arguments exactly as the model sent them.
        let argumentsJSON: String
        /// How the call ended; `nil` while it is still running.
        let status: ChatMessage.ToolStatus?
        /// What the tool returned or the error it raised.
        let output: String

        /// Whether the call ran to completion.
        var succeeded: Bool { status == .succeeded }
        /// Whether the call failed or the user refused it.
        var failed: Bool { status == .failed || status == .denied }
        /// Whether the call actually happened (as opposed to being skipped
        /// by a guard or still in flight).
        var ran: Bool { status == .succeeded || status == .failed }

        /// The arguments parsed into a dictionary, when they are JSON.
        var arguments: [String: Any] {
            guard let data = argumentsJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return object
        }

        /// A single string argument, or `nil`.
        func stringArgument(_ key: String) -> String? {
            arguments[key] as? String
        }
    }

    /// What the user asked for, as written. Empty when unknown.
    var task: String = ""

    /// Every tool call recorded for this turn, oldest first.
    var toolCalls: [ToolCall] = []

    /// Builds a trace from the tail of a transcript. Compaction summaries and
    /// plan updates are not actions, so they never enter the trace.
    ///
    /// - Parameters:
    ///   - messages: The conversation, oldest first.
    ///   - task: The request the turn is answering.
    static func from(messages: [ChatMessage], task: String = "") -> SafetyTrace {
        let planTool = "\(AgentHarnessTools.namespace)__update_plan"
        let calls = messages.compactMap { message -> ToolCall? in
            guard message.role == .toolCall,
                  let name = message.toolName,
                  name != planTool
            else { return nil }
            return ToolCall(
                name: name,
                argumentsJSON: message.toolArgumentsJSON ?? "",
                status: message.toolStatus,
                output: message.toolOutput ?? ""
            )
        }
        return SafetyTrace(task: task, toolCalls: calls)
    }

    /// The messages belonging to the turn in progress: the newest user message
    /// and everything after it. Rules must see only this, or a `.env` read in
    /// one turn would keep vetoing YOLO for the rest of the conversation.
    /// With no user message at all, the whole transcript is the turn.
    static func currentTurn(from messages: [ChatMessage]) -> [ChatMessage] {
        guard let index = messages.lastIndex(where: { $0.role == .user }) else {
            return messages
        }
        return Array(messages[index...])
    }

    /// A trace of the turn in progress. This is what the safety monitor
    /// evaluates — never the whole conversation.
    static func currentTurnTrace(from messages: [ChatMessage], task: String = "") -> SafetyTrace {
        SafetyTrace.from(messages: currentTurn(from: messages), task: task)
    }

    /// The trace folded into the flat text an LLM judge reads. One line per
    /// call, because ARIA cares about *which* actions were taken, not their
    /// full output (a wall of file contents would bury the signal).
    func logForJudge(outputLimit: Int = 400) -> String {
        var lines: [String] = []
        if !task.isEmpty {
            lines.append("TASK: \(task)")
        }
        guard !toolCalls.isEmpty else {
            lines.append("(no tool calls)")
            return lines.joined(separator: "\n")
        }
        for (index, call) in toolCalls.enumerated() {
            let status = call.status?.rawValue ?? "running"
            lines.append("\(index + 1). \(call.name) [\(status)] \(call.argumentsJSON)")
            let output = Self.oneLine(call.output, max: outputLimit)
            if !output.isEmpty {
                lines.append("   result: \(output)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func oneLine(_ text: String, max: Int) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }
}

// MARK: - Detectors

/// A named predicate over a `SafetyTrace`. Mirrors SafeAgents'
/// `AttackDetector` type alias, plus a label so a hit can say *which* check
/// fired instead of just "attack detected".
struct AttackDetector: Sendable {
    let label: String
    let test: @Sendable (SafetyTrace) -> Bool

    init(_ label: String, _ test: @escaping @Sendable (SafetyTrace) -> Bool) {
        self.label = label
        self.test = test
    }

    func callAsFunction(_ trace: SafetyTrace) -> Bool { test(trace) }
}

/// A value that a tool argument is checked against. Upstream accepts a Python
/// callable here; the Codable-friendly equivalent is a small set of matchers,
/// which is also what the user-defined rules in Settings can express.
enum ArgumentMatcher: Equatable, Sendable, Codable {
    /// The argument equals this string exactly.
    case equals(String)
    /// The argument contains this substring (case-insensitive).
    case contains(String)
    /// The argument matches this regular expression (case-insensitive).
    case matches(String)

    /// Decoded from `{kind, value}`, so a future matcher kind this build does
    /// not know reads as a harmless `contains("")` instead of making the
    /// whole rule set undecodable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        switch kind {
        case "equals": self = .equals(value)
        case "matches": self = .matches(value)
        default: self = .contains(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .equals(let value):
            try container.encode("equals", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .contains(let value):
            try container.encode("contains", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .matches(let value):
            try container.encode("matches", forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    func matches(_ value: String) -> Bool {
        switch self {
        case .equals(let expected):
            return value == expected
        case .contains(let needle):
            return value.range(of: needle, options: .caseInsensitive) != nil
        case .matches(let pattern):
            return value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

extension AttackDetector {

    /// True when any of `toolNames` was called and actually ran.
    static func toolsCalled(_ toolNames: [String]) -> AttackDetector {
        AttackDetector("tools_called(\(toolNames.joined(separator: ", ")))") { trace in
            trace.toolCalls.contains { $0.ran && toolNames.contains($0.name) }
        }
    }

    /// True when `toolName` ran with arguments matching every check.
    static func toolCalledWithArgs(
        _ toolName: String,
        _ argChecks: [String: ArgumentMatcher]
    ) -> AttackDetector {
        let described = argChecks.keys.sorted().joined(separator: ", ")
        return AttackDetector("tool_called_with_args(\(toolName): \(described))") { trace in
            trace.toolCalls.contains { call in
                guard call.ran, call.name == toolName else { return false }
                let arguments = call.arguments
                return argChecks.allSatisfy { key, matcher in
                    guard let value = arguments[key] as? String else { return false }
                    return matcher.matches(value)
                }
            }
        }
    }

    /// True when `toolName` was called strictly more than `threshold` times.
    static func countToolCalls(_ toolName: String, threshold: Int) -> AttackDetector {
        AttackDetector("count_tool_calls(\(toolName) > \(threshold))") { trace in
            trace.toolCalls.filter { $0.ran && $0.name == toolName }.count > threshold
        }
    }

    /// True when any tool output matches `pattern`.
    static func logContains(_ pattern: String, caseSensitive: Bool = true) -> AttackDetector {
        AttackDetector("log_contains(\(pattern))") { trace in
            let options: String.CompareOptions = caseSensitive
                ? .regularExpression
                : [.regularExpression, .caseInsensitive]
            return trace.toolCalls.contains { call in
                call.output.range(of: pattern, options: options) != nil
            }
        }
    }

    /// OR-combines detectors: a hit from any one is a hit.
    static func anyOf(_ detectors: AttackDetector...) -> AttackDetector {
        AttackDetector("any_of(\(detectors.map(\.label).joined(separator: " | ")))") { trace in
            detectors.contains { $0(trace) }
        }
    }

    /// AND-combines detectors: every one must hit.
    static func allOf(_ detectors: AttackDetector...) -> AttackDetector {
        AttackDetector("all_of(\(detectors.map(\.label).joined(separator: " & ")))") { trace in
            detectors.allSatisfy { $0(trace) }
        }
    }

    /// NOR-combines detectors: a hit only when none of them hit.
    static func noneOf(_ detectors: AttackDetector...) -> AttackDetector {
        AttackDetector("none_of(\(detectors.map(\.label).joined(separator: " | ")))") { trace in
            !detectors.contains { $0(trace) }
        }
    }
}
