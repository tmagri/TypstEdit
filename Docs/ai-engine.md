# Notes for agents working on the AI engine

Read this before changing anything under `Sources/Models/AIChatManager.swift`,
`Sources/Utilities/AICompletionService.swift`, `Sources/Services/`, or the tool
executors. The engine was replaced wholesale; this records the seams that are
load-bearing so they are not re-litigated on every change.

## Shape of the engine

Three layers, deliberately separated:

1. **`AICompletionService`** (`Sources/Utilities/`) — the provider boundary and
   the tool-calling loop. Knows nothing about TypstEdit's UI or tools. Speaks
   OpenAI-compatible, Anthropic, and Gemini (one-shot) wire formats. Every
   request goes through it.
2. **`AIChatManager`** (`Sources/Models/`) — one instance per conversation. Owns
   the transcript, decides which tools are offered, routes tool calls, runs
   approvals, compaction, delegation, case file, auto-proceed.
3. **Tool executors** — `LocalToolExecutor` (project/notebook, Python, screen,
   web), `GitTools`, `MachineToolExecutor` (`file__*`, `shell__run`), plus the
   in-agent `agent__*`, `code__execute`, `skill__*` and `mcp__*` tools.

`AIChatSessionStore` (`ChatSessions.swift`) owns the conversations and one
manager each; `ChatHistoryStore` (`ChatHistory.swift`) is the on-disk index +
per-conversation files.

## The tool namespace router

`MCPTool.qualifiedName` is `<server>__<tool>`. The agent routes by the prefix:

| Prefix | Goes to |
| --- | --- |
| `project__`, `python__`, `screen__` | `LocalToolExecutor.execute(toolName: <unqualified>, …)` |
| `git__` | `GitTools.execute(toolName: <unqualified>, scope: localTools.scope, …)` |
| `calculator__` | `LocalToolExecutor.execute` (it dispatches to `CalculatorTool`) |
| `file__`, `shell__` | `MachineToolExecutor.execute(qualifiedName: …)` |
| `agent__`, `code__`, `skill__`, `mcp__` | in-agent handlers |
| anything else | a live MCP server (`mcp.callTool`) |

`MCPManager` is **per window**, not a singleton, and is injected into the agent
(`mcp: MCPManager?`). A `nil` manager means "no MCP": never fall back to a global.

## Rules that are easy to break

1. **`session.didSet` → `persist()` re-enters itself.** `persist()` stamps
   `updatedAt` on `session`, which fires the observer again. The `isPersisting`
   guard is what keeps that from becoming unbounded recursion (a stack overflow,
   not a slow save). Do not remove it.
2. **Plan mode withholds Python outright**, not case by case — a script decides
   what it does. `isPlanModeBlockedTool` must return `true` for `python__run`.
   Subagents are read-only, enforced **twice**: descriptor filtering and
   `validateToolAccess` at dispatch. Keep the double defense.
3. **`ToolCallRepeatGuard` is a silent fallback if it clears too eagerly.** Only
   a call that could change what a read returns resets it; `neutralToolNames`
   (plan updates, scratchpad, calculator, delegation) must not. It keys on the
   *qualified* name — a base name collides across namespaces.
4. **`ParallelToolCalls.safeToolNames` ⊆ names `readOnlyPlan` can parse.** A
   "safe" name whose parse returns `nil` silently runs sequentially instead of
   batching; that is how batching once got turned off without anyone noticing.
   The project tools' plans are `projectReadFile`/`projectOutline`/
   `projectGrep`/`projectSkillFile` and run through `LocalToolExecutor.
   runProjectReadOnly` (which keeps the read-before-edit ledger).
5. **Compaction cuts by cost, over rows.** The newest row is always kept. Keep
   the cut row-based: a turn-based cut makes a marathon turn (one instruction,
   hundreds of tool rows) uncompactable.
6. **A tool output too large to inline is filed, not dropped.** `ToolOutputStore`
   writes the whole text under `~/Library/Logs/TypstEdit/Outputs` and puts the
   path in the marker. A failed write must say the data is gone rather than name
   a path that 404s.
7. **Background jobs are detached.** `delegate_background` runs in
   `Task.detached`, not `Task`: inheriting the turn's cancellation would kill a
   job the moment the parent's next request began. A finished report is delivered
   once; a failed job says FAILED, not empty.
8. **`LLMLingua2Engine` feeds the model a fixed-shape input.** The exported Core
   ML model declares a fixed 512-token window; building a variable-length array
   makes `prediction(from:)` fail and compression silently degrades. Every call
   is padded to the declared shape and masked. A failed prediction falls back to
   the heuristic filter, never to "keep the first N words".
9. **Approvals: deny rules are checked first, before YOLO or a card.** A saved
   deny refuses without a card, even under YOLO. `denyPending` drains the whole
   round's queue (one decision, not four clicks), and it does so by resuming
   approvals one at a time — clearing the queue first would orphan continuations.
10. **Scheduled / unattended runs do not wait for a human.** `canShowApprovalCard`
    is false there and an approval refuses instead of hanging. Withhold
    `delegate_background` from a background run, a subagent and code mode.

## Settings

TypstEdit persists settings in `UserDefaults` through `AISettingsManager`. The
ported engine reads its own member names (`shellToolEnabled`,
`chatParallelReadsEnabled`, `effectiveMaxTurns(for:)`, the learned-budget API, …);
those are **adapters** in `AISettingsEngineCompat.swift` over TypstEdit's existing
keys, or new `aiChat*` keys. Add new engine settings there, not by renaming the
engine's reads — that keeps re-checking a ported file honest.

## Testing

`swift test` (set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
The engine suites are pure or fixture-based; they construct agents with injected
`localTools`/`machineTools`/`mcp`/`skills`/`settings`/`service`/`historyStore`.
`MCPConfigStore` returns a throwaway config path under XCTest, so no test can
read the real `mcp.json` — never point one at it. Live tests (embedding endpoint,
LLMLingua model, real MCP servers) `XCTSkip` when their precondition is absent;
never assert that the machine has the data.

`ToolOutputStore.directoryOverride` and `MCPConfigStore.configURLOverride` are
test seams: a test runner must never write into the user's Console archives or
the real MCP config.
