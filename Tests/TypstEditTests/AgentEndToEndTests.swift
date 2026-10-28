import XCTest
@testable import TypstEdit

/// Live end-to-end run of the AI Chat agent: the real `AIChatManager`, the
/// real model from the app's saved AI settings, the real tools, on a copy
/// of a project. Skipped unless `TYPSTEDIT_E2E_PROJECT` is set, so normal
/// test runs never call a model.
///
/// Environment:
/// - `TYPSTEDIT_E2E_PROJECT`      project folder to work in (use a copy — files get edited)
/// - `TYPSTEDIT_E2E_PROMPT_FILE`  one chat message to send
/// - `TYPSTEDIT_E2E_PROMPTS_DIR`  or a folder of `1.txt`, `2.txt`, … sent in
///                                order as one continuing conversation
/// - `TYPSTEDIT_E2E_OUTPUT`       folder for `result.json` (default: the project folder)
/// - `TYPSTEDIT_E2E_MINUTES`      wall-clock cap; the run is stopped after it (default 30)
/// - `TYPSTEDIT_E2E_SETTINGS_DOMAIN` defaults domain to read AI settings from
///                                (default `com.tmagri.TypstEdit`)
/// - `TYPSTEDIT_E2E_MAX_TOKENS`   optional override for the AI Chat reply token cap
/// - `TYPSTEDIT_E2E_MAX_TURNS`    optional override for turns per message
/// - `TYPSTEDIT_E2E_REASONING_EFFORT` optional low/medium/high, applied to the
///                                saved model profile and the default effort
/// - `TYPSTEDIT_E2E_OPEN_FILE`    optional project-relative file to treat as open in the editor
/// - `TYPSTEDIT_AGENT_TRACE`      optional JSONL trace of every request (see `AgentTrace`)
///
/// The app's settings are loaded into the in-memory registration domain only,
/// so API keys are never written to this test process's own preferences.
/// For safety the run turns the Python sandbox on and Git fetch/pull/push off.
@MainActor
final class AgentEndToEndTests: XCTestCase {

    func testLiveAgentRun() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let projectPath = env["TYPSTEDIT_E2E_PROJECT"], !projectPath.isEmpty else {
            throw XCTSkip("Set TYPSTEDIT_E2E_PROJECT (and a prompt file or folder) to run the live agent test.")
        }
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
        let outputURL = URL(fileURLWithPath: env["TYPSTEDIT_E2E_OUTPUT"] ?? projectPath, isDirectory: true)
        let minutes = Double(env["TYPSTEDIT_E2E_MINUTES"] ?? "") ?? 30
        let prompts = try Self.promptTexts(env: env)
        XCTAssertFalse(prompts.isEmpty, "No prompts given.")

        try loadAppSettings(domain: env["TYPSTEDIT_E2E_SETTINGS_DOMAIN"] ?? "com.tmagri.TypstEdit", env: env)

        let chat = AIChatManager.shared
        let openFile = env["TYPSTEDIT_E2E_OPEN_FILE"].map { projectURL.appendingPathComponent($0) }
        chat.updateContext(projectRoot: projectURL, currentFileURL: openFile)
        chat.clearHistory()
        chat.yoloMode = true // every write is to the copy; push stays off

        let started = Date()
        var stoppedByWatchdog = false
        let watchdog = Task { @MainActor in
            try await Task.sleep(nanoseconds: UInt64(minutes * 60 * 1_000_000_000))
            stoppedByWatchdog = true
            chat.stop()
        }

        var turns: [[String: Any]] = []
        for prompt in prompts where !stoppedByWatchdog {
            let turnStart = Date()
            await chat.sendMessage(prompt)
            let rows = chat.messages.filter { $0.role == .toolCall }
            var statusCounts: [String: Int] = [:]
            for row in rows {
                statusCounts[row.toolStatus?.rawValue ?? "none", default: 0] += 1
            }
            let answer = chat.messages.last(where: { $0.role == .assistant })?.text ?? ""
            turns.append([
                "prompt": prompt,
                "seconds": Date().timeIntervalSince(turnStart),
                "error": chat.errorMessage ?? "",
                "toolCalls": rows.count,
                "toolStatus": statusCounts,
                "plan": chat.plan.map { "[\($0.status.rawValue)] \($0.content)" },
                "answer": answer
            ])
            // Written after every message, so a later turn (or the watchdog)
            // can't lose what earlier ones did.
            try Self.write(["turns": turns, "stoppedByWatchdog": stoppedByWatchdog],
                           to: outputURL.appendingPathComponent("result.json"))
        }
        watchdog.cancel()

        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Self.write([
            "seconds": Date().timeIntervalSince(started),
            "stoppedByWatchdog": stoppedByWatchdog,
            "turns": turns
        ], to: outputURL.appendingPathComponent("result.json"))

        // The run itself is the measurement; only a hard failure fails the test.
        let lastAnswer = (turns.last?["answer"] as? String) ?? ""
        XCTAssertFalse(lastAnswer.isEmpty && chat.errorMessage == nil && !stoppedByWatchdog,
                       "The run ended with neither an answer nor an error.")
    }

    /// One prompt file, or every `*.txt` in a prompts folder (by file name).
    static func promptTexts(env: [String: String]) throws -> [String] {
        if let dir = env["TYPSTEDIT_E2E_PROMPTS_DIR"], !dir.isEmpty {
            let files = try FileManager.default.contentsOfDirectory(atPath: dir)
                .filter { $0.hasSuffix(".txt") }
                .sorted()
            return try files.map { try String(contentsOfFile: URL(fileURLWithPath: dir).appendingPathComponent($0).path, encoding: .utf8) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        guard let path = env["TYPSTEDIT_E2E_PROMPT_FILE"] else { return [] }
        return [try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    private static func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    /// Copies the app's AI settings (keys starting with `ai` or `portkey`)
    /// into the registration domain, removing any value this test process
    /// saved earlier for the same keys so the app's value wins.
    private func loadAppSettings(domain: String, env: [String: String]) throws {
        guard let app = UserDefaults(suiteName: domain)?.persistentDomain(forName: domain), !app.isEmpty else {
            throw XCTSkip("No saved settings found in the '\(domain)' defaults domain.")
        }
        var values = app.filter { $0.key.hasPrefix("ai") || $0.key.hasPrefix("portkey") }
        // Safety for an unattended run.
        values["aiChatPythonSandboxEnabled"] = true
        values["aiChatGitFetchEnabled"] = false
        values["aiChatGitPullEnabled"] = false
        values["aiChatGitPushEnabled"] = false
        if let maxTokens = env["TYPSTEDIT_E2E_MAX_TOKENS"].flatMap(Int.init) {
            values["aiChatMaxTokens"] = maxTokens
        }
        if let maxTurns = env["TYPSTEDIT_E2E_MAX_TURNS"].flatMap(Int.init) {
            values["aiChatMaxTurns"] = maxTurns
        }
        if let effort = env["TYPSTEDIT_E2E_REASONING_EFFORT"], !effort.isEmpty {
            values["aiReasoningEffort.generation"] = effort
            // Every saved model profile too — a chosen profile overrides the
            // global effort, so rewriting only the global key would not reach
            // the model the chat actually uses.
            if let raw = values["aiModelProfiles"] as? String,
               let data = raw.data(using: .utf8),
               var profiles = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for index in profiles.indices {
                    profiles[index]["reasoningEffort"] = effort
                }
                if let encoded = try? JSONSerialization.data(withJSONObject: profiles),
                   let string = String(data: encoded, encoding: .utf8) {
                    values["aiModelProfiles"] = string
                }
            }
        }

        let standard = UserDefaults.standard
        let loopKeys = ["aiChatRepeatCallLimit", "aiChatNoProgressRounds", "aiChatTurnLimitWarningReplies",
                        "aiChatMaxTokens", "aiChatTokenLimitRetry"]
        for key in Array(values.keys) + loopKeys {
            standard.removeObject(forKey: key)
        }
        standard.register(defaults: values)
    }
}
