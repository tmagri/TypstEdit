import Foundation

/// One row of the chat's visible task list — the same "keep the model (and
/// you) honest about multi-step work" idea as Claude Code's todo list. Kept
/// intentionally small: an imperative description and a status.
struct AgentPlanItem: Equatable, Identifiable, Codable {
    enum Status: String, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    var id = UUID()
    var content: String
    var status: Status
}

/// Tools that belong to the agent loop itself rather than to the filesystem,
/// so they live in `AIChatManager` (which can start a nested completion and
/// own transcript state) instead of `LocalToolExecutor`.
enum AgentHarnessTools {
    static let namespace = "agent"

    static var updatePlanTool: MCPTool { MCPTool(
        serverName: namespace,
        name: "update_plan",
        description: "Create or update the task list shown to the user during a multi-step job. Use it when a request needs 3+ distinct actions, and update it as you go: exactly one item in_progress at a time, mark items completed immediately when done. Skip it for single-step or conversational requests.",
        inputSchema: [
            "type": "object",
            "properties": [
                "items": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "content": ["type": "string", "description": "Imperative description, e.g. \"Rewrite the Status section\""],
                            "status": ["type": "string", "enum": ["pending", "in_progress", "completed"]]
                        ],
                        "required": ["content", "status"]
                    ],
                    "description": "The complete list, in order. Omit finished-and-no-longer-relevant items entirely."
                ]
            ],
            "required": ["items"]
        ]
    ) }

    nonisolated static let updateCaseQualifiedName = "\(namespace)__update_case"
    nonisolated static let reviewCaseQualifiedName = "\(namespace)__review_case"

    /// `agent__update_case`: the only write path to the case file (see
    /// `CaseFile`). Every field is optional so a call carries only what
    /// changed. The charter, dropping a criterion and overruling a ruling
    /// stop on a card for the user; the rest applies at once.
    static func updateCaseTool(methods: [CaseMethod]) -> MCPTool {
        let stringList: [String: Any] = ["type": "array", "items": ["type": "string"]]
        let methodList = methods.map { "\($0.id) — \($0.summary)" }.joined(separator: " ")
        return MCPTool(
            serverName: namespace,
            name: "update_case",
            description: "Open or update the case file for goal-directed work — a job whose point is to produce an artifact or establish a conclusion, not a quick question. The case holds the user-ratified charter (objective, definitions, constraints, out of scope, budget), the method, the standard (done-when criteria), settled rulings, open issues, claims, design options, risks and the phase. Phases are the same five roles in every method (discovery → hypothesis → build → verify → verdict); the method names them and sets the gates. It is in your context every turn and outranks the summary. Proposing or changing the charter or the method, removing a criterion, overruling a ruling, replacing a chosen option, or accepting a high risk unmitigated shows the user an approval card; everything else applies at once. Mark a criterion met only with evidence. Methods: \(methodList)",
            inputSchema: [
                "type": "object",
                "properties": [
                    "method": ["type": "string", "enum": methods.map(\.id), "description": "How the case is worked. Propose it with the charter; changing it later needs the user's approval."],
                    "charter": [
                        "type": "object",
                        "description": "The question presented. Needs the user's approval.",
                        "properties": [
                            "objective": ["type": "string", "description": "The goal, in the user's terms."],
                            "definitions": ["type": "array", "items": ["type": "string"], "description": "What the key terms mean, e.g. \"fast = p99 under 50 ms\"."],
                            "constraints": stringList,
                            "out_of_scope": stringList,
                            "turn_budget": ["type": "integer", "description": "Optional: finished turns the user grants for this case."],
                            "iteration_budget": ["type": "integer", "description": "Optional: build → verify rounds the user grants."]
                        ],
                        "required": ["objective"]
                    ],
                    "add_criteria": ["type": "array", "items": ["type": "string"], "description": "Done-when criteria to add, each testable."],
                    "remove_criteria": ["type": "array", "items": ["type": "string"], "description": "Criterion ids to drop (needs the user's approval)."],
                    "mark_criteria": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "met": ["type": "boolean"],
                                "evidence": ["type": "string", "description": "Required when met: a path and lines, a test result, a tool output."]
                            ],
                            "required": ["id", "met"]
                        ]
                    ],
                    "settle": [
                        "type": "array",
                        "description": "Decisions that bind later turns.",
                        "items": [
                            "type": "object",
                            "properties": ["text": ["type": "string"], "reason": ["type": "string"]],
                            "required": ["text", "reason"]
                        ]
                    ],
                    "overrule": [
                        "type": "array",
                        "description": "Settled rulings to reverse (needs the user's approval).",
                        "items": [
                            "type": "object",
                            "properties": ["id": ["type": "string"], "reason": ["type": "string"]],
                            "required": ["id", "reason"]
                        ]
                    ],
                    "add_issues": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "text": ["type": "string"],
                                "blocking": ["type": "boolean", "description": "Blocks the verdict until resolved. Default true."],
                                "needs_user": ["type": "boolean", "description": "Only the user can answer it. Default false."]
                            ],
                            "required": ["text"]
                        ]
                    ],
                    "resolve_issues": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": ["id": ["type": "string"], "resolution": ["type": "string", "description": "How it was answered or fixed."]],
                            "required": ["id", "resolution"]
                        ]
                    ],
                    "claims": [
                        "type": "array",
                        "description": "Add a claim (omit id) or update one (give its id).",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "claim": ["type": "string"],
                                "grounds": ["type": "string", "description": "The evidence for it."],
                                "warrant": ["type": "string", "description": "Why the grounds support the claim."],
                                "qualifier": ["type": "string", "description": "How strongly it holds, e.g. \"for inputs under 1 MB\"."],
                                "rebuttal": ["type": "string", "description": "What would show it false. Required for a new claim."],
                                "status": ["type": "string", "enum": ["proposed", "supported", "refuted", "withdrawn"]]
                            ]
                        ]
                    ],
                    "options": [
                        "type": "array",
                        "description": "Design alternatives for a trade study: add one (omit id) or update one (give its id).",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "title": ["type": "string"],
                                "summary": ["type": "string"],
                                "pros": stringList,
                                "cons": stringList,
                                "scores": ["type": "object", "description": "Criterion id → 0–5, e.g. {\"S1\": 4, \"S2\": 2}.", "additionalProperties": ["type": "integer"]],
                                "status": ["type": "string", "enum": ["candidate", "rejected"]]
                            ]
                        ]
                    ],
                    "choose_option": [
                        "type": "object",
                        "description": "Commit to one evaluated option. Recorded as a settled ruling; replacing it later needs the user.",
                        "properties": ["id": ["type": "string"], "reason": ["type": "string", "description": "Why it beats the others."]],
                        "required": ["id", "reason"]
                    ],
                    "risks": [
                        "type": "array",
                        "description": "The risk register: add one (omit id) or update one (give its id).",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "text": ["type": "string"],
                                "likelihood": ["type": "string", "enum": ["low", "medium", "high"]],
                                "impact": ["type": "string", "enum": ["low", "medium", "high"]],
                                "mitigation": ["type": "string"],
                                "status": ["type": "string", "enum": ["open", "mitigated", "accepted"]]
                            ]
                        ]
                    ],
                    "failed_verification": ["type": "string", "description": "In verify: what failed. The case goes back to the method's rework stage and a new iteration starts."],
                    "phase": ["type": "string", "enum": CaseFile.Phase.allCases.map(\.rawValue)]
                ]
            ]
        )
    }

    /// `agent__review_case`: opposing counsel. A read-only subagent gets the
    /// case and the artifact and argues against the result; each objection
    /// becomes a blocking issue.
    ///
    /// The round is **incremental**: the reviewer is given only the items
    /// whose evidence changed since their last verdict, plus a one-line
    /// ledger of what already passed. Re-running it after fixing one thing
    /// therefore re-checks one thing, not the whole case — which is what made
    /// the old whole-case review the slowest step of a long engineering chat.
    ///
    /// It is also **batched**: one call judges a few items at a time and saves
    /// each batch as it lands, so a long round can be interrupted and resumed.
    /// The tool forwards that, because a model that assumes the call is
    /// all-or-nothing will not know a failed round left work behind.
    static var reviewCaseTool: MCPTool { MCPTool(
        serverName: namespace,
        name: "review_case",
        description: "Ask a read-only reviewer to argue against the result, as opposing counsel. It gets the charter, then judges each item of the case — every criterion, claim, risk and settled ruling — and returns a pass or fail per item plus objections. Each failed item becomes a blocking issue you must resolve before a verdict. Run it in the verify phase, after you have marked the criteria you believe are met. Running it again only re-checks the items whose evidence changed since their last verdict, so a fix costs one check rather than a full review; pass full: true to make it re-read everything anyway. A round is judged in small batches and each batch is saved as it is judged: if the call stops part way (a timeout, an error), the verdicts it already reached are kept, and running it again picks up the remaining items instead of starting over. When the result says items were not checked yet, run it again to finish them.",
        inputSchema: [
            "type": "object",
            "properties": [
                "artifact": ["type": "string", "description": "What to review: the files or output produced and where they are, written for a reader who cannot see this chat."],
                "files": ["type": "array", "items": ["type": "string"], "description": "Relative paths the reviewer should read first."],
                "full": ["type": "boolean", "description": "Re-read every item instead of only those whose evidence changed. Default false, except on the first review of a case."]
            ],
            "required": ["artifact"]
        ]
    ) }

    static var delegateTaskTool: MCPTool { MCPTool(
        serverName: namespace,
        name: "delegate_task",
        description: "Hand a self-contained research or reading job to a subagent. It runs in its own context, can read/search files but cannot write, edit, run code, or delegate further, and returns only its written findings. Use it when exploring a large document or several files would otherwise flood this conversation with raw text — ask for the specific facts, quotes, and file locations you need back.",
        inputSchema: [
            "type": "object",
            "properties": [
                "task": ["type": "string", "description": "What to find out or verify, written as a complete brief — the subagent can't see this conversation."],
                "files": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Optional starting points: relative paths it should look at first."
                ]
            ],
            "required": ["task"]
        ]
    ) }

    /// `agent__delegate_background`: start a read-only subagent and carry on.
    ///
    /// Separate from `delegate_task` because the two make different promises.
    /// `delegate_task` blocks the turn until the findings arrive, which is right
    /// when the next step depends on them. This one returns immediately with a
    /// job number, and the model checks it with `job_status` — right when the
    /// answer is needed eventually but not before the next thing can be done.
    ///
    /// Offered only when delegation is on at all, so a chat with subagents
    /// disabled is never shown a tool whose answer is "no".
    static var delegateBackgroundTool: MCPTool { MCPTool(
        serverName: namespace,
        name: "delegate_background",
        description: "Start a read-only subagent and keep working. It runs in its own context, can read and search files but cannot write, edit, run code, or delegate, and writes its findings down. This call returns at once with a job number, so use it when the answer will be needed soon but the next step does not depend on it — checking many files for the same thing, gathering background for a later reply. Check on it with agent__job_status, which hands you the findings once they exist. Use agent__delegate_task instead when you need the answer before you can do anything else, because that one waits and this one does not.",
        inputSchema: [
            "type": "object",
            "properties": [
                "task": ["type": "string", "description": "What to find out or verify, written as a complete brief — the subagent can't see this conversation."],
                "files": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Optional starting points: relative paths it should look at first."
                ]
            ],
            "required": ["task"]
        ]
    ) }

    /// `agent__job_status`: check a background subagent.
    ///
    /// Reading a finished job hands back its report exactly once; asking again
    /// says it was already delivered rather than repeating a long answer.
    static var jobStatusTool: MCPTool { MCPTool(
        serverName: namespace,
        name: "job_status",
        description: "Check the background subagents started with agent__delegate_background. With no job number it lists them all and their state. A finished job's findings are handed to you on the first check after it finishes, once — checking again will not repeat them, so keep what you need. A job that is still running says so: do not wait on it, do other work and check again at the end of the turn.",
        inputSchema: [
            "type": "object",
            "properties": [
                "job": ["type": "integer", "description": "Which job to check, by its number. Omit to list every job in this chat."]
            ],
            "required": []
        ]
    ) }

    /// `agent__delegate_parallel`: several read-only briefs at once.
    ///
    /// A separate tool from `delegate_task` because the two say different
    /// things. `delegate_task` is one job and is always run alone;
    /// `delegate_parallel` is a list, and the list is the model's own claim
    /// that the jobs do not depend on each other. A harness cannot infer that,
    /// and batching `delegate_task` calls instead would silently overlap jobs
    /// the model meant to run in order.
    ///
    /// Only offered when the resolved worker count is greater than one, so a
    /// chat on a one-slot server is never shown a tool whose answer is "no".
    /// The count in the description is the real one for this model.
    static func delegateParallelTool(workers: Int) -> MCPTool { MCPTool(
        serverName: namespace,
        name: "delegate_parallel",
        description: "Hand SEVERAL independent research or reading jobs to subagents that run at the same time (\(workers) at once on this model). Each subagent works in its own context, can read and search files but cannot write, edit, run code, or delegate, and returns only its findings. Use it when you have jobs that do not depend on each other — a question per file, one check per claim — because that is the whole gain: \(workers) jobs finish in about the time of the slowest one. Do NOT use it for jobs where one's answer decides what the next one should look for; do those one at a time with delegate_task. Write every brief as if the subagent has never seen this conversation.",
        inputSchema: [
            "type": "object",
            "properties": [
                "briefs": [
                    "type": "array",
                    "minItems": 2,
                    "items": [
                        "type": "object",
                        "properties": [
                            "task": ["type": "string", "description": "One complete stand-alone job: what to find out or verify, and what to report back."],
                            "files": [
                                "type": "array",
                                "items": ["type": "string"],
                                "description": "Optional starting points for this brief only: relative paths it should look at first."
                            ]
                        ],
                        "required": ["task"]
                    ],
                    "description": "The jobs to run together. Each is independent; the order of the reports matches this order."
                ]
            ],
            "required": ["briefs"]
        ]
    ) }

    /// Searches the parts of the conversation that left the context, plus the
    /// scratch notes the model wrote earlier. Offered when there is something
    /// to find in either.
    static var recallTool: MCPTool { MCPTool(
        serverName: namespace,
        name: "recall",
        description: "Search what is no longer in your context: earlier turns that were folded into the summary, what earlier tool calls returned (file reads, searches, web pages, script output, subagent reports), and the notes you wrote with the think tool. Use it when you need the exact words behind something the summary or work log mentions — what the user asked for, a decision and its reason, a value a tool returned — instead of guessing or re-running a call whose result may differ. For the current content of a file, use read_file instead; for a note you want in full, scratch_read.",
        inputSchema: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "What you are trying to find, in plain words, e.g. \"the citation style the user asked for\"."]
            ],
            "required": ["query"]
        ]
    ) }

    /// `agent__think`: the scratchpad. A place to write a thought down so it
    /// survives compaction, instead of it living only inside the context
    /// window where a summary is free to drop it.
    ///
    /// This is the harness-side half of "externalised thinking". The other
    /// half — the model's hidden reasoning — cannot be captured: providers
    /// return a summary of it at best, and the block carrying the real
    /// reasoning must be echoed back unmodified or the request is rejected.
    /// What a harness *can* do is exactly this: give the model somewhere to
    /// write, and read it back when the window no longer holds it.
    static var thinkTool: MCPTool { MCPTool(
        serverName: namespace,
        name: "think",
        description: "Write a thought down so it survives the context window. Use it for the things you would otherwise have to remember later: a decision and why you made it, an approach you ruled out and what ruled it out, a fact you verified and where you found it, or what you were in the middle of when the work got long. Do not narrate every step — write what would be expensive to work out a second time. Notes are searchable later with scratch__search and readable with scratch__read; a summary of your notes is always in your context.",
        inputSchema: [
            "type": "object",
            "properties": [
                "thought": ["type": "string", "description": "The note itself, written to be useful to you later: state the conclusion, then the reason or the evidence."],
                "topic": ["type": "string", "description": "Optional short heading grouping related notes, e.g. \"citation style\" or \"why the build fails\". Reuse the same topic for notes on the same subject."]
            ],
            "required": ["thought"]
        ]
    ) }

    /// `scratch__read`: paged read of one scratch file.
    static var scratchReadTool: MCPTool { MCPTool(
        serverName: namespace,
        name: "scratch_read",
        description: "Read a file you wrote earlier in this chat, by name and line window. Files are listed in the SCRATCH NOTES block of your context; a scratch__search hit also names the file and line. Use it to get back the exact wording of a note the summary only mentions, or to page through a long notes file instead of pulling all of it into the conversation.",
        inputSchema: [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "The file name from the scratch list, e.g. \"notes.md\"."],
                "start_line": ["type": "integer", "description": "First line, 1-based. Default 1."],
                "end_line": ["type": "integer", "description": "Last line. Defaults to start_line + 2000."]
            ],
            "required": ["name"]
        ]
    ) }

    /// `scratch__search`: literal text search across this chat's scratch files.
    /// The think tool's description and the SCRATCH NOTES manifest have both
    /// advertised it since the scratchpad shipped; making it real closes a
    /// loop where the model was told to use a tool that did not exist.
    static var scratchSearchTool: MCPTool { MCPTool(
        serverName: namespace,
        name: "scratch_search",
        description: "Search the text of every scratch file this chat wrote (case-insensitive, literal). Returns file:line: text matches. Use it to find which note holds a decision or a fact when the summary in your context only mentions it — cheaper than reading a long notes file in pages.",
        inputSchema: [
            "type": "object",
            "properties": [
                "pattern": ["type": "string", "description": "The text to search for."]
            ],
            "required": ["pattern"]
        ]
    ) }

    /// Asks the user a structured question and waits for the answer in place,
    /// instead of ending the turn and hoping the reply covers it. Only offered
    /// while Settings → AI Chat → Ask Questions is on, since a question blocks
    /// the run until someone answers — the wrong default for an unattended
    /// job, but a good one while planning.
    static var askQuestionTool: MCPTool { MCPTool(
        serverName: namespace,
        name: "ask_question",
        description: "Ask the user one or more questions and wait for the answers before continuing. Use it when a decision would otherwise be a guess: which of several structures they want, what a vague requirement means, or which of two conflicting instructions wins. Prefer it over asking in your reply, because the run resumes with the answer attached instead of ending. Keep it to what blocks you — a question costs the user's attention. The user can always type an answer that isn't in your options, and can dismiss the whole card, in which case you should proceed on a stated assumption. Do not use it to confirm something you were already asked to do.",
        inputSchema: [
            "type": "object",
            "properties": [
                "questions": [
                    "type": "array",
                    "description": "One or more questions to ask at once. Asking them together is cheaper than several rounds.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "question": ["type": "string", "description": "The question itself, in one sentence."],
                            "header": ["type": "string", "description": "Two or three words naming the topic, shown as the card's title."],
                            "options": [
                                "type": "array",
                                "description": "Suggested answers. If you recommend one, put it first and end its label with \" (Recommended)\".",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "label": ["type": "string", "description": "The answer, as short text."],
                                        "detail": ["type": "string", "description": "Optional one line on what choosing this means."]
                                    ],
                                    "required": ["label"]
                                ]
                            ],
                            "multiple": ["type": "boolean", "description": "Allow more than one option to be chosen. Default false."]
                        ],
                        "required": ["question"]
                    ]
                ]
            ],
            "required": ["questions"]
        ]
    ) }

    nonisolated static let showUIQualifiedName = "\(namespace)__show_ui"

    /// `agent__show_ui`: a card the model draws instead of asking for text.
    /// The payload is real A2UI v0.9 (Google's Agent-to-User Interface
    /// protocol), not a bespoke shape, so the messages it writes are the ones
    /// the specification describes and could be handed to any other renderer.
    ///
    /// The description carries the parts of the spec a model actually needs to
    /// get right — the message order, the component list, and the data model's
    /// two-way binding — because the model is writing JSON from prose. It is
    /// deliberately a compact reminder with one worked example rather than the
    /// full schema: the full schema is 46 KB, and the model already knows the
    /// protocol's name.
    static var showUITool: MCPTool { MCPTool(
        serverName: namespace,
        name: "show_ui",
        description: """
        Draw a form, a set of buttons, or a small piece of interface in the chat, and wait for the user to interact with it. Use it instead of asking in prose when the answer is a choice, a few fields, or a confirmation — the run resumes with the exact values the user entered, so nothing is lost to a free-text reply.

        The payload is A2UI v0.9 (Google's agent-to-user-interface protocol): a JSON array of messages, in this order.
        1. {"version":"v0.9","createSurface":{"surfaceId":"<id>","catalogId":"https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"}}
        2. {"version":"v0.9","updateComponents":{"surfaceId":"<id>","components":[ ... ]}} — a flat list; one component must have id "root".
        3. {"version":"v0.9","updateDataModel":{"surfaceId":"<id>","path":"/form","value":{"email":"","subscribe":false}}} — initial values for bound fields.

        Components (properties are literal values, or {"path":"/form/email"} to bind the data model): Text(text, variant: h1…h5|caption|body), Row(children), Column(children), List(children, listStyle), Card(child), Divider, Button(child, variant: default|primary|borderless, action), TextField(label, value, variant: shortText|longText|number|obscured), CheckBox(label, value), ChoicePicker(label, options:[{label,value}], value:[…], variant: mutuallyExclusive|multipleSelection), Slider(label, value, min, max), DateTimeInput(label, value, enableDate, enableTime).

        A Button's action is {"event":{"name":"submit","context":{"email":{"path":"/form/email"}}}}. Its context is resolved against the data model when pressed, and the whole data model is returned with it, so name only what you need. Input components write to their bound path as the user types; a literal value is just a default and never comes back.
        checks: [{"condition":{"call":"required","args":{"value":{"path":"/form/email"}}},"message":"Email is required"}] disables the button while it fails.
        functions: required, regex, length, numeric, email, formatString, formatNumber, formatCurrency, formatDate, pluralize, and, or, not.

        Three or four components is a good card; a chat panel is 320–700pt wide, so prefer a Column of short rows over a wide grid. Every card needs at least one Button with an action, or the user has no way to answer and must dismiss it. Do not use it for a form whose answers you could get from the tools, and do not use it to confirm something the user already asked for.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "messages": [
                    "type": "array",
                    "description": "The A2UI v0.9 messages, in order: createSurface, then updateComponents, then optionally updateDataModel.",
                    "items": ["type": "object"]
                ],
                "title": ["type": "string", "description": "Optional one-line caption above the card, e.g. \"Two things to confirm\"."]
            ],
            "required": ["messages"]
        ]
    ) }

    /// The JavaScript escape hatch (`code__execute`). It lives here rather than
    /// in `MachineToolExecutor` because it is harness infrastructure: it does
    /// not touch files itself, it calls the tools that do, through the agent.    ///
    /// The catalog in the description is what makes it usable. A model that
    /// cannot see the exact call signatures guesses at them and wastes the
    /// round, so every offered tool is listed with its arguments.
    static func executeTool(catalog: [MCPTool], computeSeconds: Int) -> MCPTool {
        MCPTool(
            serverName: "code",
            name: "execute",
            description: """
            Run a short JavaScript program that calls your other tools, and return only what you need from the results.

            Use it when one answer needs several reads or a filter over what they return. Example: read six files with Promise.all, then return only the headings that matched — one round instead of six, and the raw text never enters the conversation. For a single simple call, call that tool directly instead.

            The available tools, as `tools.<namespace>.<name>(arguments)`:

            \(catalogListing(catalog))

            Rules:
            - `await` and `return` work at the top level. Run independent calls together with `await Promise.all([...])`; a call that needs another's result must wait for it.
            - A tool that fails rejects the promise, so wrap calls in `try`/`catch` when a failure is possible (a declined approval, a missing file). Every call is still shown to the user for approval exactly as it would be on its own.
            - Return the smallest thing that answers the question — a count, a filtered array, a few lines. Returning a whole file defeats the purpose.
            - No imports, network, filesystem, timers or fetch: only `tools`. JavaScript runs in a restricted interpreter with \(computeSeconds) seconds of compute; waiting on a tool does not count against that.
            - The reply lists the tool calls the script made, so you do not need to report them yourself.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "code": [
                        "type": "string",
                        "description": "The JavaScript to run. Use `return` for the result you want back."
                    ]
                ],
                "required": ["code"]
            ]
        )
    }

    /// One line per tool, `namespace.name(arguments) → what it returns`, for
    /// the `execute` description. Only the argument names and the first
    /// sentence of the description fit; the direct tool definition has the
    /// rest, and this is a reminder of what exists rather than a manual.
    ///
    /// Capped at `catalogBudget` characters: a session with several MCP
    /// servers can offer dozens of tools, and the listing duplicates names
    /// the declared tool schemas already carry. Past the budget the catalog
    /// degrades to one summary line per namespace — every tool is still
    /// declared to the model with its full signature, and
    /// `tools.<namespace>.<name>(...)` calls it all the same, so nothing is
    /// unreachable, only unnamed here.
    nonisolated static let catalogBudget = 2_400

    static func catalogListing(_ tools: [MCPTool], budget: Int = catalogBudget) -> String {
        guard !tools.isEmpty else { return "(none right now)" }
        var byNamespace: [String: [String]] = [:]
        for tool in tools {
            let signature = "\(tool.name)(\(argumentSummary(tool.inputSchema)))"
            byNamespace[tool.serverName, default: []].append(signature)
        }
        let namespaces = byNamespace.keys.sorted()
        let full = namespaces.map { namespace in
            "  tools.\(namespace): " + (byNamespace[namespace] ?? []).joined(separator: ", ")
        }.joined(separator: "\n")
        guard full.count > budget else { return full }
        let summaries = namespaces.map { namespace -> String in
            let count = byNamespace[namespace]?.count ?? 0
            return "  tools.\(namespace): \(count) tool\(count == 1 ? "" : "s")"
        }.joined(separator: "\n")
        return summaries
            + "\n  (catalog shortened to fit the prompt budget — every tool of these namespaces is also declared to you with its full signature, and `tools.<namespace>.<name>(...)` calls it the same way)"
    }

    /// `path, start_line?, end_line?` from a JSON Schema's `properties` and
    /// `required`.
    static func argumentSummary(_ schema: [String: Any]) -> String {
        guard let properties = schema["properties"] as? [String: Any], !properties.isEmpty else {
            return ""
        }
        let required = Set(schema["required"] as? [String] ?? [])
        return properties.keys.sorted().map { key in
            required.contains(key) ? key : key + "?"
        }.joined(separator: ", ")
    }

    /// Tools a `code__execute` script may call: everything offered, minus the
    /// two that make no sense inside a script. `code__execute` itself would
    /// nest interpreters, and `agent__ask_question` blocks the run waiting on
    /// a card — a script waiting on a question, inside a call that is already
    /// waiting, is a deadlock the user would have to untangle by hand.
    /// `agent__update_case` is out for the same reason as the question: a
    /// charter change stops on the user's approval card.
    nonisolated static func codeModeCanCall(_ qualifiedName: String) -> Bool {
        qualifiedName != "code__execute"
            && qualifiedName != "agent__ask_question"
            && qualifiedName != showUIQualifiedName
            && qualifiedName != toolSearchQualifiedName
            && qualifiedName != updateCaseQualifiedName
            // A script that started a background job could only wait for it,
            // and waiting inside a call that is already waiting is a deadlock
            // by construction. The model can start one outside the script.
            && qualifiedName != delegateBackgroundQualifiedName
            && qualifiedName != jobStatusQualifiedName
    }

    /// `agent__delegate_parallel`, named once so the dispatch, the tests and
    /// the subagent allowlist check cannot drift apart.
    nonisolated static let delegateParallelQualifiedName = "\(namespace)__delegate_parallel"

    /// `agent__delegate_background`.
    nonisolated static let delegateBackgroundQualifiedName = "\(namespace)__delegate_background"

    /// `agent__job_status`.
    nonisolated static let jobStatusQualifiedName = "\(namespace)__job_status"

    // MARK: - Lazy MCP tools (tool_search)

    /// `agent__tool_search`, the qualified name of the lazy-MCP discovery
    /// tool. The model calls it with a plain-words query; the matching
    /// undeclared MCP tools become callable directly from the next request.
    nonisolated static let toolSearchQualifiedName = "\(namespace)__tool_search"

    /// The declaration for `agent__tool_search`. Only offered when undeclared
    /// MCP tools exist, so the count in the description is always real.
    static func toolSearchTool(deferredCount: Int) -> MCPTool {
        MCPTool(
            serverName: namespace,
            name: "tool_search",
            description: """
            Search the tools that are not declared in this conversation (\(deferredCount) of them right now — MCP server tools, declared lazily to keep the prompt small) and make the matches callable. Use it when the job needs a server tool you have not been given: name the kind of thing you need in plain words ("search jira issues", "create a github pull request"), and the matching tools load with their signatures shown so you can call them directly. Loaded tools stay available for the rest of the conversation. Search again with different words if nothing matched.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The kind of tool you need, in plain words. Name the service or the action: \"search jira issues\", \"read a notion page\"."]
                ],
                "required": ["query"]
            ]
        )
    }

    /// Ranks the deferred pool against a plain-words query and returns the
    /// tools worth declaring. Scoring is deliberately dumb — term matches in
    /// the name count triple, matches in the description once — because the
    /// queries are short and the pool is tens of tools, not thousands. Pure,
    /// so the ranking rules are testable without a running server.
    static func toolSearchMatches(query: String, pool: [MCPTool], limit: Int = 6) -> [MCPTool] {
        let terms = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty, limit > 0 else { return [] }
        let ranked = pool.map { tool -> (tool: MCPTool, score: Int) in
            let name = tool.qualifiedName.lowercased()
            let description = tool.description.lowercased()
            var score = 0
            for term in terms {
                if name.contains(term) { score += 3 }
                if description.contains(term) { score += 1 }
            }
            return (tool, score)
        }
        return ranked
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.tool.qualifiedName < rhs.tool.qualifiedName
            }
            .prefix(limit)
            .map(\.tool)
    }

    /// The result text for one `tool_search` call: what loaded, and how to
    /// call it. The signatures mirror the catalog listing's shape, so a model
    /// that has written one script can read the other.
    static func toolSearchResult(_ loaded: [MCPTool]) -> String {
        guard !loaded.isEmpty else {
            return "No tools matched. Try different words, or do the work with the tools you already have."
        }
        var lines = ["Loaded \(loaded.count) tool\(loaded.count == 1 ? "" : "s") — they are callable directly now, and stay available for the rest of the conversation:"]
        for tool in loaded {
            let firstSentence = tool.description
                .components(separatedBy: ". ")
                .first.map { $0.isEmpty ? "" : $0 + "." } ?? ""
            lines.append("- \(tool.qualifiedName)(\(argumentSummary(tool.inputSchema))) — \(firstSentence)")
        }
        return lines.joined(separator: "\n")
    }

    static func plan(from messages: [ChatMessage]) -> [AgentPlanItem] {
        guard let last = messages.last(where: { $0.role == .toolCall && $0.toolName == "\(namespace)__update_plan" }),
              let json = last.toolArgumentsJSON,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let content = item["content"] as? String,
                  let rawStatus = item["status"] as? String,
                  let status = AgentPlanItem.Status(rawValue: rawStatus) else { return nil }
            return AgentPlanItem(content: content, status: status)
        }
    }

    // MARK: - Working Memory

    /// The plan as a system-prompt block, so the checklist steers the model
    /// on every new turn instead of only being drawn in the panel. `nil` when
    /// there is no plan.
    static func planPromptBlock(_ plan: [AgentPlanItem]) -> String? {
        guard !plan.isEmpty else { return nil }
        let lines = plan.map { item -> String in
            switch item.status {
            case .completed: return "[x] \(item.content)"
            case .inProgress: return "[>] \(item.content) (in progress)"
            case .pending: return "[ ] \(item.content)"
            }
        }
        return """
        CURRENT PLAN (from your last update_plan call). Continue from the in-progress item, and call update_plan as soon as an item is done or the plan changes:
        \(lines.joined(separator: "\n"))
        """
    }

    /// Default number of tool calls `workLog` lists.
    static let workLogLimit = 20

    /// One line per tool call from earlier turns: what was called, on what,
    /// and how it went. Earlier turns' raw tool output never reaches the
    /// model again (`buildPrompt` sends only the prose), so without this a
    /// follow-up turn starts blind and re-lists, re-greps and re-reads to
    /// find out what it already knew. Subagent internals, plan updates and
    /// case updates are left out — the delegate_task row and the plan and
    /// case blocks cover those.
    static func workLog(from messages: [ChatMessage], limit: Int = workLogLimit) -> String? {
        let planToolName = "\(namespace)__update_plan"
        let rows = messages.filter {
            $0.role == .toolCall && !$0.isSubagent
                && $0.toolName != planToolName
                && $0.toolName != updateCaseQualifiedName
                && $0.toolStatus != .running
                && $0.toolStatus != .skipped
        }
        guard !rows.isEmpty, limit > 0 else { return nil }
        let recent = rows.suffix(limit)
        var lines = recent.map(workLogLine)
        if rows.count > recent.count {
            let omitted = rows.count - recent.count
            lines.insert("- (\(omitted) earlier call\(omitted == 1 ? "" : "s") not shown)", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    /// The work log as a system-prompt block. `nil` when there's nothing to log.
    static func workLogPromptBlock(from messages: [ChatMessage], limit: Int = workLogLimit) -> String? {
        guard let log = workLog(from: messages, limit: limit) else { return nil }
        return """
        WORK LOG — tool calls from earlier turns of this chat, oldest first. Their raw output is no longer in context, and files may have changed since. Use this to go straight to the right file and line range instead of re-listing, re-searching and re-reading everything. You still have to read a file in this turn before editing it.
        \(log)
        """
    }

    /// Arguments worth showing in a work-log line, in display order. Bulky
    /// ones (old_string, new_string, content, code, items) are left out.
    private static let workLogArgumentKeys = [
        "path", "outline", "skim", "symbol", "pattern", "glob", "query", "url", "offset", "limit",
        "start_line", "end_line", "before_line", "name",
        "source", "output", "format", "destination", "files", "sources", "task", "message"
    ]

    static func workLogLine(_ row: ChatMessage) -> String {
        "- \(workLogCall(row)) → \(workLogOutcome(status: row.toolStatus, output: row.toolOutput ?? ""))"
    }

    /// The call half of a work-log line, `name(key: value, …)`, without the
    /// outcome — for callers that only label the call and would otherwise
    /// scan its whole output for nothing.
    static func workLogCall(_ row: ChatMessage) -> String {
        let qualified = row.toolName ?? "tool"
        let name = qualified.range(of: "__").map { String(qualified[$0.upperBound...]) } ?? qualified

        var arguments: [String: Any] = [:]
        if let json = row.toolArgumentsJSON, let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = object
        }
        let argumentText = workLogArgumentKeys.compactMap { key -> String? in
            guard let value = arguments[key] else { return nil }
            let rendered: String
            if let list = value as? [Any] {
                let strings = list.map { "\($0)" }
                rendered = strings.prefix(3).joined(separator: ", ") + (strings.count > 3 ? ", +\(strings.count - 3) more" : "")
            } else if let string = value as? String {
                rendered = "\"\(oneLine(string, max: 60))\""
            } else if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                // JSON booleans arrive as NSNumber; don't print `true` as 1.
                rendered = number.boolValue ? "true" : "false"
            } else {
                rendered = "\(value)"
            }
            return "\(key): \(rendered)"
        }.joined(separator: ", ")

        return argumentText.isEmpty ? name : "\(name)(\(argumentText))"
    }

    /// Short outcome for a work-log line: the read window, the compile
    /// verdict, or the first line of the result.
    static func workLogOutcome(status: ChatMessage.ToolStatus?, output: String) -> String {
        switch status {
        case .failed: return "failed: \(oneLine(output, max: 120))"
        case .denied: return "declined by the user"
        case .cancelled: return "stopped before it finished"
        case .running: return "still running"
        case .skipped: return "not run"
        case .succeeded, .none: break
        }
        // Lazily: only the first few lines are read, and splitting a
        // multi-megabyte output whole to look at them dominated every caller.
        // read_file / read_skill_file / web_fetch window header.
        if let window = firstLine(in: output, within: 3, where: { $0.hasPrefix("[lines ") && $0.hasSuffix("]") }) {
            return "ok, " + String(window.dropFirst().dropLast())
        }
        let firstLine = firstLine(in: output, where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .map(String.init) ?? ""
        var outcome = oneLine(firstLine, max: 120)
        if output.contains("✓ Typst check: compiles cleanly") {
            outcome += " (compiles cleanly)"
        } else if output.contains("⚠️ Typst check") {
            outcome += " (Typst check reported problems)"
        }
        return outcome.isEmpty ? "ok" : outcome
    }

    /// The first of the first `limit` lines of `text` that matches, reading
    /// no further into the text than that line.
    private static func firstLine(
        in text: String,
        within limit: Int = .max,
        where matches: (Substring) -> Bool
    ) -> Substring? {
        var start = text.startIndex
        var seen = 0
        while seen < limit {
            // Bytes, not Characters: `\r\n` is one Character and would hide
            // the break, where the old Foundation split found it.
            let end = text.utf8[start...].firstIndex(of: UInt8(ascii: "\n")) ?? text.endIndex
            let line = text[start..<end]
            if matches(line) { return line }
            seen += 1
            guard end < text.endIndex else { return nil }
            start = text.index(after: end)
        }
        return nil
    }

    private static func oneLine(_ text: String, max: Int) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }
}
