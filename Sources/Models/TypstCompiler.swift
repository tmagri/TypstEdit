import Foundation
import Combine

// MARK: - Precompiled Regexes

enum CompilerRegex {
    static let stroke = try! NSRegularExpression(pattern: "((?:bottom|top|left|right)\\s*:\\s*[0-9.]+\\s*pt)(?!\\s*\\+)", options: [.caseInsensitive])
    static let luma = try! NSRegularExpression(pattern: "luma\\(\\s*([0-9.]+)\\s*(%?)\\s*\\)", options: [.caseInsensitive])
    static let black = try! NSRegularExpression(pattern: "(:\\s*\\b)(black|rgb\\(\\s*0\\s*,\\s*0\\s*,\\s*0\\s*\\)|rgb\\(\"#000000\"\\))(\\b|\\))", options: [.caseInsensitive])
    static let markdownConverterFunc = try! NSRegularExpression(pattern: #"^#([A-Za-z][A-Za-z0-9_]*)[\[(]"#)
    // Inline/block math for the dangling-operator fixer. The trailing lookahead
    // keeps two register tokens (`$3DF8/$3E50`, `$DC10/$DC4F`) from being read as
    // one math block (which would inject `""` into the hex literal).
    static let mathBlock = try! NSRegularExpression(pattern: "\\$\\$?([^\\$]+)\\$\\$?(?![A-Za-z0-9])")
    static let trailSupSub = try! NSRegularExpression(pattern: "([\\^_])\\s*$")
    static let trailOp = try! NSRegularExpression(pattern: "([+\\-*\\/=<>]|\\\\times|\\\\cdot)\\s*$")
    static let loneCaret = try! NSRegularExpression(pattern: "(?<![\\\\\\$])\\^\\s*$")
    static let bareHash = try! NSRegularExpression(pattern: "(?<!\\\\)#\\s*$")
    static let codeSpan = try! NSRegularExpression(pattern: "(?s)(`+).*?(?<!`)\\1(?!`)")
    // The inline `$…$` branch requires the closing `$` to not be glued to an
    // alphanumeric. Otherwise two register-style `$` tokens separated by a
    // non-space punctuation (e.g. `$DC10–$DC4F`, `$3DF8/$3E50`, `$FE00–$FE9F`)
    // are mis-paired into a single math region, so neither `$` is escaped and
    // Typst tries to parse the hex token as a math expression (compile error).
    // A genuine inline math region (`$E = mc^2$`, `$B=p(1+i)^{t}$`) ends at a
    // whitespace/punctuation/EOF boundary, so the lookahead does not affect it.
    static let mathRegion = try! NSRegularExpression(pattern: "(?s)\\$\\$.+?\\$\\$|(?<!\\\\)\\$(?!\\s)[^\\$\\n]+?(?<!\\s)(?<!\\\\)\\$(?![A-Za-z0-9])|(?s)\\\\\\[.+?\\\\\\]|(?s)\\\\\\([^\\n]+?\\\\\\)")
    static let operatorRe = try! NSRegularExpression(pattern: "(?<!\\\\)[@#$<>]")
    // `image(...)` only needs its leading `#` when it starts a markup-mode
    // statement. Nested inside another call — `#figure(image("…"))`,
    // `#box(image("…"))`, `#grid(image("…"), image("…"))` — it's already in
    // code mode and is written bare, so matching on `\bimage\(` (like the
    // import/include regex below already does) catches both forms instead
    // of only the standalone `#image(...)` case.
    static let webImage = try! NSRegularExpression(pattern: #"\bimage\(\s*"([^"]*)""#)
    static let relativeImport = try! NSRegularExpression(pattern: #"(\b(?:import|include)\s+")([^/@.][^"]*)(")"#)
    static let relativeImage = try! NSRegularExpression(pattern: #"(\bimage\(\s*")(?!\.\./)(?![/~])(?!https?://)([^"]+)(")"#)
    static let fontArgument = try! NSRegularExpression(pattern: #"font\s*:\s*(?:"[^"]*"|\([^()]*\))"#)
    static let quotedString = try! NSRegularExpression(pattern: #""([^"]*)""#)
    // Raw-block OPENING fence line: optional indent, a run of 3+ backticks,
    // optional whitespace, then the language tag. Typst's tag is a single
    // token — `#`, `+`, `.` and `-` are part of it (hence `c#`, `c++`,
    // `objective-c`) — and anything after the tag is block CONTENT per
    // Typst's grammar, not part of the tag.
    static let rawFenceOpen = try! NSRegularExpression(pattern: #"^(\s*`{3,})(\s*)([A-Za-z0-9_#+.-]+)(.*)$"#)
}

struct TypstError: Identifiable, Equatable {
    enum Severity: Equatable {
        case error
        case warning
    }

    /// One call-site frame Typst prints under a diagnostic — "while calling
    /// `boom`" (0.13+) or "error occurred in this call of function `boom`"
    /// (older releases) — with the location it was called from.
    struct TraceEntry: Equatable {
        let message: String
        /// Line in the open document (already mapped), or nil when the frame
        /// is in another file.
        var line: Int?
        /// Path as Typst printed it, when the frame is in another file.
        var file: String?
        var fileLine: Int?
        /// The code Typst printed under the frame, e.g. `boom(2)`.
        var snippet: String? = nil
    }

    let id = UUID()
    /// 1-based line in the open document. `nil` when the diagnostic has no
    /// location in this document (a general compiler error, or an error that is
    /// entirely inside another file).
    let line: Int?
    let message: String
    var severity: Severity = .error
    /// 0-based character offset of the reported span within `snippet`.
    var column: Int? = nil
    /// Length, in characters, of the reported span (`^^^` under the code).
    var length: Int? = nil
    /// The source line as the compiler saw it.
    var snippet: String? = nil
    /// Set when the diagnostic is inside another file (e.g. an imported module).
    var file: String? = nil
    var fileLine: Int? = nil
    /// `= hint: …` lines from Typst.
    var hints: [String] = []
    /// `help: …` frames from Typst (where an error in another file was triggered).
    var trace: [TraceEntry] = []

    /// Convenience constructor that keeps existing call sites (line/message) working.
    init(line: Int?, message: String, severity: Severity = .error) {
        self.line = line
        self.message = message
        self.severity = severity
    }

    /// Short location label for the UI, e.g. "Line 53, col 76", "lib.typ:2", "General".
    var locationLabel: String {
        if let file {
            return fileLine.map { "\(file):\($0)" } ?? file
        }
        guard let line else { return "General" }
        if let column { return "Line \(line), col \(column + 1)" }
        return "Line \(line)"
    }

    /// Plain-text rendering of the full diagnostic, suitable for the clipboard
    /// (bug reports, pasting into a chat).
    func reportText(documentName: String? = nil) -> String {
        var out = "\(severity == .warning ? "warning" : "error"): \(message)\n"
        if let file {
            out += "  in \(file)\(fileLine.map { ", line \($0)" } ?? "")\n"
        } else if let line {
            let doc = documentName.map { "\($0), " } ?? ""
            out += "  at \(doc)line \(line)\(column.map { ", column \($0 + 1)" } ?? "")\n"
        }
        if let snippet {
            out += "    \(snippet)\n"
            if let column {
                out += "    " + String(repeating: " ", count: column) + String(repeating: "^", count: max(1, length ?? 1)) + "\n"
            }
        }
        for hint in hints { out += "  hint: \(hint)\n" }
        for frame in trace {
            let at = frame.file.map { "\($0)\(frame.fileLine.map { ":\($0)" } ?? "")" }
                ?? frame.line.map { "line \($0)" } ?? ""
            out += "  \(frame.message)\(at.isEmpty ? "" : " (\(at))")\n"
            if let code = frame.snippet { out += "    \(code)\n" }
        }
        if let explanation = TypstErrorExplainer.explanation(for: self) {
            out += "  how to fix: \(explanation)\n"
        }
        return out
    }
}

@MainActor
class TypstCompiler: ObservableObject {
    @Published var compilationStatus: String = "Ready"
    @Published var isCompiling: Bool = false
    @Published var errors: [TypstError] = []

    public var fileLoader: ((String) -> String?)? = nil

    // Backing stores that feed the published `errors` list.
    // `typstErrors`   – real compilation errors reported by the `typst` binary.
    // `typstWarnings` – `warning:` diagnostics reported by the `typst` binary
    //                   (non-blocking; the document still compiles).
    // `noteWarnings`  – advisory warnings produced by `delimitImproperOperators`
    //                   for hybrid `.note` files (one per source line that needed
    //                   auto-delimiting). Kept separate so they survive a
    //                   successful recompile but are cleared when content changes.
    private var typstErrors: [TypstError] = []
    private var typstWarnings: [TypstError] = []
    private var noteWarnings: [TypstError] = []
    /// Advisory warnings from the TypstEdit calculator pipeline: `#calc`
    /// resolution failures plus, for `.typ` files, the "not portable Typst"
    /// notice. Recomputed on each `updateContent`, cleared only when the
    /// features disappear — they survive a successful recompile, like
    /// `noteWarnings`.
    private var calcWarnings: [TypstError] = []

    /// True when the open document uses TypstEdit calculator features
    /// (`#calc`, `calc-param`, `plot`, `BesselJ`…) AND the file type expects
    /// portability (`.typ`). `.note` files never set this: notes are a
    /// TypstEdit-native format, so there is no portability expectation.
    @Published var usesNonPortableCalcFeatures: Bool = false
    /// Comma-separated feature list for the status-bar badge tooltip.
    @Published var calcFeatureSummaryText: String? = nil

    // Calculator resolution state, so debounced recompiles reuse previous
    // CAS results (the cache key covers the call text, the document
    // parameters and the modes) and parameter stores only replay on change.
    private var calcResolutionCache: [String: String] = [:]
    private var calcStoredParameters: [CalculatorStoredVariable] = []
    /// Cap on remembered `#calc` results. A document with a huge table of
    /// calls, recompiled after many edits, would otherwise accumulate one
    /// entry per version of each call for the life of the window.
    private static let maxCalcCacheEntries = 2_000

    /// Merges real errors + advisory warnings into the published `errors` list and
    /// notifies observers. Real compile errors are listed first (they block output);
    /// warnings follow. Compile diagnostics are cleared on a successful recompile;
    /// `.note` delimiting warnings persist until the source changes.
    ///
    /// The list is capped at `maxPublishedIssues` with a trailing "… N more"
    /// marker: every observer is O(list) per update, and a rough conversion can
    /// produce thousands of diagnostics that no UI should render at once.
    private func publishIssues() {
        var combined = typstErrors + typstWarnings + noteWarnings + calcWarnings
        if combined.count > Self.maxPublishedIssues {
            let hidden = combined.count - Self.maxPublishedIssues
            combined.removeLast(hidden)
            combined.append(
                TypstError(
                    line: nil,
                    message: "… \(hidden) more issue\(hidden == 1 ? "" : "s") not shown — the document has too many diagnostics to display.",
                    severity: .warning
                )
            )
        }
        self.errors = combined
        NotificationCenter.default.post(name: .typstErrorsUpdated, object: self, userInfo: ["errors": combined])
    }

    var isDarkMode: Bool = false
    /// Snapshot of the "Keep with Next" setting taken when the current shadow
    /// source was written. `preambleLineCount` must always describe the file
    /// that is actually on disk, so this is captured in `updateContent`
    /// instead of being read live (mirrors `isDarkMode`).
    private var keepWithNextActive: Bool = false
    /// Snapshot of "the calculator bridge was imported for this shadow source",
    /// captured in `updateContent` alongside `keepWithNextActive` for the same
    /// reason: diagnostics line mapping must describe the file on disk.
    private var calcBridgeActive: Bool = false
    private var preambleLineCount: Int {
        var count = 0
        if keepWithNextActive {
            count += Self.keepWithNextPreamble.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        }
        if isDarkMode {
            count += darkModePreamble.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        }
        if currentFileExtension == "note" {
            count += Self.notePreamble.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        }
        if calcBridgeActive {
            count += 1 /* the single #import line */
        }
        return count
    }
    
    private let darkModePreamble = """
// Base page and text colors
#set page(fill: rgb("#1a1a1a"))
#set text(fill: rgb("#d1d1d1"))

// Links
#show link: set text(fill: rgb("#58a6ff"))

// Geometric shape strokes (Safe to set globally)
#set line(stroke: rgb("#d1d1d1"))
#set rect(stroke: rgb("#d1d1d1"))
#set square(stroke: rgb("#d1d1d1"))
#set circle(stroke: rgb("#d1d1d1"))
#set ellipse(stroke: rgb("#d1d1d1"))
#set polygon(stroke: rgb("#d1d1d1"))

// Inline raw text (code)
#show raw: set text(fill: rgb("#d1d1d1"))

// Code blocks (adds distinct background and subtle border)
#show raw.where(block: true): set block(
  fill: rgb("#2a2a2a"),
  inset: 8pt,
  radius: 4pt,
  stroke: rgb("#444444")
)
""" + "\n"

    // Helpers every .note file can rely on. Defined first so any user
    // definition of the same name in the note body shadows ours.
    nonisolated static let notePreamble =
"""
#let title(body) = align(center)[#text(size: 24pt, weight: "bold")[#body]]
#let note-box(title, body) = block(
  width: 100%,
  fill: rgb("#eef2f7"),
  stroke: (left: 2.5pt + rgb("#3b82f6")),
  inset: (x: 12pt, y: 10pt),
)[
  #text(size: 11pt, weight: "bold")[#title]
  #v(4pt)
  #body
]
""" + "\n"

    /// "Keep with next": a heading must never be the last thing on a page.
    /// The rule glues every heading's block to whatever follows it
    /// (`block.sticky`, Typst 0.12+) and makes the heading itself
    /// unbreakable, so a heading that would be orphaned at the bottom of a
    /// page moves to the next page together with the start of the paragraph
    /// after it. Typst already makes headings sticky by default, but
    /// documents that install their own `#show heading` rule replace that
    /// default block — re-asserting the styles here covers those documents
    /// too (as long as their rule produces a block).
    nonisolated static let keepWithNextPreamble =
"""
// TypstEdit keep-with-next: keep headings together with what follows.
#show heading: set block(sticky: true, breakable: false)
""" + "\n"
    
    // Check if typst makes sense or we need full path
    private func resolveTypstPath() -> String? {
        // Priority 0: Check for custom user-built Typst
        if GeneralSettingsManager.shared.useCustomTypst, 
           let customPath = GeneralSettingsManager.shared.resolvedCustomTypstPath {
            return customPath
        }

        // Priority 1: Check if bundled with the app
        if let bundlePath = Bundle.enclosingAppBundle.resourcePath {
            let bundledTypst = "\(bundlePath)/bin/typst"
            if FileManager.default.fileExists(atPath: bundledTypst) {
                return bundledTypst
            }
        }
        
        // Priority 2: Common system paths and workspace bundled binary
        let localProjectPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("typst-aarch64-apple-darwin/typst").path
        let paths = [
            localProjectPath,
            NSString(string: "~/Desktop/TypstEdit/typst-aarch64-apple-darwin/typst").expandingTildeInPath,
            "/opt/homebrew/bin/typst",
            "/usr/local/bin/typst",
            "/usr/bin/typst",
            NSString(string: "~/bin/typst").expandingTildeInPath,
            NSString(string: "~/.cargo/bin/typst").expandingTildeInPath,
        ]
        
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    private var currentProcess: Process?
    private var processOutputPipe: Pipe?
    /// Owns the running `typst watch`. `Process` does not stop its child when
    /// it is released, so without this a compiler torn down with its window
    /// (no `cleanUp()` call) left the watch running until the app quit.
    private let watchOwner = WatchProcessOwner()

    /// True while this compiler's `typst watch` is running.
    var isWatching: Bool { currentProcess?.isRunning == true }

    // MARK: Idle stop
    //
    // `typst watch` keeps the whole compiled document in memory (parsed
    // sources, layout, fonts, decoded images) so the next edit recompiles
    // incrementally. That is what makes typing fast, but for a large document
    // it is hundreds of megabytes held while nobody types. After
    // `previewIdleStopSeconds` without a compile, the watch is stopped; the PDF
    // on disk and the issue list stay, and the next `updateContent` starts a
    // new watch (one full compile, then incremental again).

    /// True while the watch was stopped for being idle — the preview is still
    /// valid, nothing is compiling, and the next change restarts it.
    @Published private(set) var isIdleStopped = false
    private var idleStopTask: Task<Void, Never>?
    /// Overridable for tests; nil reads the user setting.
    var idleStopDelayOverride: TimeInterval?
    nonisolated(unsafe) private var memoryObserver: NSObjectProtocol?

    private var idleStopDelay: TimeInterval {
        idleStopDelayOverride ?? TimeInterval(GeneralSettingsManager.shared.previewIdleStopSeconds)
    }

    init() {
        MemoryPressureMonitor.shared.start()
        // Under memory pressure an idle watch is the cheapest thing to give
        // back: it costs one cold compile on the next edit, nothing else.
        memoryObserver = NotificationCenter.default.addObserver(
            forName: MemoryPressureMonitor.willFreeMemory, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopWatchIfIdle(reason: "memory pressure") }
        }
    }

    deinit {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }

    /// Restarts the countdown. Called when a compile cycle finishes.
    private func scheduleIdleStop() {
        idleStopTask?.cancel()
        idleStopTask = nil
        let delay = idleStopDelay
        guard delay > 0, isWatching else { return }
        idleStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.idleStopTask = nil
            self.stopWatchIfIdle(reason: "idle \(Int(delay))s")
        }
    }

    private func cancelIdleStop() {
        idleStopTask?.cancel()
        idleStopTask = nil
    }

    /// Stops the watch, keeping the preview and the issues, unless a compile
    /// (or a lenient-mode fix waiting for its recompile) is still in flight —
    /// then it tries again after another delay.
    private func stopWatchIfIdle(reason: String) {
        guard isWatching else { return }
        if isCompiling || pendingFallbackRewrite || !pendingFallbackRawLines.isEmpty {
            scheduleIdleStop()
            return
        }
        AppDelegate.debugLog("typst watch: stopping for \(reason)")
        cancelIdleStop()
        watchOwner.stop()
        currentProcess = nil
        processOutputPipe = nil
        isIdleStopped = true
        compilationStatus = "Idle"
    }
    
    // We keep track of the current shadow file being watched
    private var currentShadowSourceURL: URL?
    public private(set) var currentShadowPDFURL: URL?

    // Lenient-mode fallback tracking (used for .note / .md files)
    // `fallbackAttempts[line] = n` records how many escalating fixes we've applied
    // to that raw shadow-file line. Each escalation is more aggressive so that,
    // eventually, *something* always renders.
    //   0 → (untouched)   1 → escape special chars   2 → wrap whole line in #raw()
    private var currentFileExtension: String = ""
    private var fallbackAttempts: [Int: Int] = [:]
    private var pendingFallbackRawLines: [Int] = []   // shadow-file error lines awaiting a fallback fix
    private var pendingFallbackRewrite: Bool = false    // true while a fallback rewrite is in-flight and another compile cycle is expected

    // Flood protection for the diagnostic pipeline. A healthy document produces
    // a handful of diagnostics per cycle; a rough Markdown conversion can
    // produce thousands. Reacting per diagnostic block is then quadratic on the
    // main thread (O(n) rebuild + O(n) UI publish per block), and the lenient
    // fallback fixer rewrites the shadow file on every cycle, each rewrite
    // triggering a recompile whose fresh errors cascade — a self-sustaining
    // freeze. These gates keep per-block work for healthy documents and fold
    // flooded batches into a single debounced, capped pass instead.
    /// Diagnostics per compile cycle above which the cycle is treated as a
    /// flood: no per-block rebuilding/publishing, no line-by-line repair.
    private static let diagnosticFloodLimit = 100
    /// Consecutive fix→recompile cycles the fallback fixer may chase before it
    /// gives up on the current content. Reset when the source changes or a
    /// compile succeeds.
    private static let fallbackCycleLimit = 3
    private var batchDiagnosticCount = 0
    private var fallbackCycleCount = 0
    /// Debounces issue publication so a batch is published once, after its
    /// diagnostic stream pauses, instead of once per block.
    private var publishTask: Task<Void, Never>?
    private static let publishDebounceNanos: UInt64 = 250_000_000
    /// Hard cap on the issue list handed to the UI. Panel, highlights and
    /// context menus are O(displayed) per update; internally the full lists
    /// (typstErrors / typstWarnings) stay intact.
    private static let maxPublishedIssues = 250

    // Watch-output stream state. `typst watch` diagnostics can be split across
    // arbitrary pipe chunks, so output is buffered until a complete line arrives;
    // complete lines are assembled into diagnostics by `diagnosticParser`.
    private var pendingOutputBuffer: String = ""
    private var diagnosticParser = TypstDiagnosticParser()
    /// The file whose diagnostics belong to the open document: its name as
    /// Typst prints it, and whether it is the shadow copy (whose line numbers
    /// must be mapped back to the editor buffer).
    private var diagnosticDocument: (fileName: String, isShadow: Bool)? = nil

    /// Maps a converted-output line number (1-based, excluding the injected preamble)
    /// back to the user's source line, so compile errors are reported against the text
    /// in the editor rather than the intermediate shadow file. Rebuilt on each
    /// `updateContent`.
    private var shadowToSourceLine: [Int: Int] = [:]
    
    func cleanUp() {
        cancelIdleStop()
        isIdleStopped = false
        watchOwner.stop()
        currentProcess = nil
        processOutputPipe = nil
        currentShadowSourceURL = nil
        currentShadowPDFURL = nil
        // Drop any partially-buffered watch output so the next watch starts clean.
        pendingOutputBuffer = ""
        diagnosticParser.reset()
        publishTask?.cancel()
        publishTask = nil
        batchDiagnosticCount = 0
        pendingFallbackRewrite = false
        fallbackCycleCount = 0
        pendingFallbackRawLines = []
        // We do not clear fallback tracking here because updateContent() sets them
        // up just before cleanUp() is called to switch processes.
    }

    /// Set to the window's `ProjectContext.instanceID`. Two windows can
    /// preview files that share a temp folder (the same project, or a
    /// standalone copy of a project file); the namespace keeps their shadow
    /// files apart.
    var scratchNamespace: String?

    /// `main.typ.preview` or, with a namespace, `main.typ.1a2b3c4d.preview`.
    nonisolated static func shadowStem(for filename: String, namespace: String?) -> String {
        guard let namespace, !namespace.isEmpty else { return "\(filename).preview" }
        return "\(filename).\(namespace).preview"
    }

    /// Removes only the shadow files one window wrote into `tempDir`, for when
    /// another window still uses the folder.
    nonisolated static func cleanUpScratchFiles(in tempDir: URL, namespace: String) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: tempDir.path) else { return }
        let marker = ".\(namespace).preview."
        for name in names where name.contains(marker) {
            try? manager.removeItem(at: tempDir.appendingPathComponent(name))
        }
    }

    /// Call this when the project or app is about to close to remove the temp/ directory.
    func cleanUpProjectTemp(projectRoot: URL) {
        TypstCompiler.cleanUpTempDirectory(in: projectRoot)
    }

    /// Removes the resolved temp directory for the given project root,
    /// silently — whether that's `<project>/temp` or, when the project opts
    /// out of in-project storage, its OS-temp mirror (see
    /// `AppTempDirectoryManager`).
    static func cleanUpTempDirectory(in projectRoot: URL) {
        // Skip cleanup only when the project root itself IS a "temp" directory
        // (e.g. the user opened a literal temp/ folder as their project root)
        // — never delete the project's own folder outright.
        if SafeDirectoryManager.containsSpecialDirectory(projectRoot) == "temp" {
            print("[TypstCompiler] Skipping cleanup: project root is itself a temp directory: \(projectRoot.path)")
            return
        }
        let tempDir = SafeDirectoryManager.safeTempDirectory(in: projectRoot)
        cleanUpTempDirectory(tempDir)
    }
    
    private static func cleanUpTempDirectory(_ tempDir: URL) {
        guard FileManager.default.fileExists(atPath: tempDir.path) else { return }
        do {
            try FileManager.default.removeItem(at: tempDir)
            print("[TypstCompiler] Cleaned up temp directory: \(tempDir.path)")
        } catch {
            print("[TypstCompiler] Failed to remove temp directory \(tempDir.path): \(error)")
        }
    }

    // MARK: - Compile Root

    /// The `--root` to hand to `typst` for a shadow file, plus whether that root
    /// had to be widened past the project directory to contain it.
    struct CompileRoot {
        var url: URL
        /// True when the shadow source sits outside the project (the "Store Temp
        /// Files Inside Project" setting is off), so root-absolute references
        /// must be rewritten before compiling — see `rewriteRootAbsolutePaths`.
        var isWidened: Bool
    }

    /// Typst refuses to compile a source file that is not inside the project
    /// root ("source file must be contained in project root"). With in-project
    /// temp files the project directory already contains the shadow copy. With
    /// OS-temp temp files it does not, so the root is widened to the deepest
    /// directory that contains both — usually `/` on macOS.
    ///
    /// Widening moves the anchor for root-absolute paths (`/lib.typ`), so the
    /// shadow's own references are made relative first (see
    /// `rewriteRootAbsolutePaths`). Files imported from the project are compiled
    /// from their real location and are not rewritten: a `/…` reference *inside*
    /// an imported library still resolves against the widened root.
    nonisolated static func compileRoot(projectRoot: URL, shadowDirectory: URL) -> CompileRoot {
        let project = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let shadow = shadowDirectory.standardizedFileURL.resolvingSymlinksInPath()

        let projectPath = project.path
        let prefix = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        if shadow.path == projectPath || shadow.path.hasPrefix(prefix) {
            return CompileRoot(url: project, isWidened: false)
        }

        let projectComponents = project.pathComponents
        let shadowComponents = shadow.pathComponents
        var common = 0
        while common < min(projectComponents.count, shadowComponents.count),
              projectComponents[common] == shadowComponents[common] {
            common += 1
        }
        // The filesystem root has a single component and needs no joining.
        let commonComponents = Array(projectComponents.prefix(common))
        let root: URL = commonComponents.count <= 1
            ? URL(fileURLWithPath: "/")
            : URL(fileURLWithPath: NSString.path(withComponents: commonComponents))
        return CompileRoot(url: root, isWidened: true)
    }

    /// Rewrites root-absolute file references (`#import "/lib.typ"`,
    /// `#image("/logo.png")`) to paths relative to the shadow file.
    ///
    /// Typst resolves a leading `/` against `--root`. When that root was widened
    /// to contain an out-of-project shadow file, `/lib.typ` would no longer mean
    /// `<project>/lib.typ`. Only quoted literals that name a file which actually
    /// exists under the project directory are rewritten, so plain text that
    /// happens to start with a slash is left untouched.
    nonisolated static func rewriteRootAbsolutePaths(
        in content: String, projectRoot: URL, shadowDirectory: URL
    ) -> String {
        guard content.contains("\"/") else { return content }

        let project = projectRoot.standardizedFileURL
        let matches = CompilerRegex.quotedString.matches(
            in: content, options: [], range: NSRange(0..<content.utf16.count))
        guard !matches.isEmpty else { return content }

        // Replacing in reverse keeps the ranges of earlier matches valid.
        var processed = content
        for match in matches.reversed() {
            let literal = (processed as NSString).substring(with: match.range(at: 1))
            guard literal.count > 1, literal.hasPrefix("/"), !literal.hasPrefix("//") else { continue }

            let target = project.appendingPathComponent(String(literal.dropFirst()))
            guard FileManager.default.fileExists(atPath: target.path) else { continue }

            let relative = relativePath(from: shadowDirectory, to: target)
            guard !relative.isEmpty else { continue }
            processed = (processed as NSString)
                .replacingCharacters(in: match.range, with: "\"\(relative)\"")
        }
        return processed
    }

    /// Creates the temp directory inside the project folder if it doesn't exist, and returns its URL.
    /// Prevents nested temp directories if the project is already in a temp folder.
    private func ensureTempDirectory(in projectRoot: URL) -> URL {
        let tempDir = SafeDirectoryManager.safeTempDirectory(in: projectRoot)
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try? SafeDirectoryManager.createDirectorySafely(at: tempDir, withIntermediateDirectories: true)
        }
        return tempDir
    }
    
    // Writes content to the shadow file. If watch is not running, starts it.
    func updateContent(source: String, fileURL: URL) async {
        // New work: the watch is needed again (or still), so no idle stop.
        cancelIdleStop()
        await MainActor.run { self.isCompiling = true }
        
        let workingDirectory = fileURL.deletingLastPathComponent()
        let filename = fileURL.lastPathComponent
        
        // Scratch files live either in a 'temp/' subdirectory of the project or,
        // when the project opts out of in-project storage, in an OS-temp mirror
        // (see `SafeDirectoryManager.safeTempDirectory`). In the latter case the
        // shadow file is outside the project, so the compiler root is widened to
        // contain it — otherwise Typst refuses to compile ("source file must be
        // contained in project root").
        let projectTempDir = ensureTempDirectory(in: workingDirectory)
        let shadowStem = Self.shadowStem(for: filename, namespace: scratchNamespace)
        let shadowSourceURL = projectTempDir.appendingPathComponent("\(shadowStem).typ")
        let shadowPDFURL = projectTempDir.appendingPathComponent("\(shadowStem).pdf")
        
        let projectRoot = workingDirectory
        let compileRoot = Self.compileRoot(projectRoot: projectRoot, shadowDirectory: projectTempDir)
        
        // Write content to shadow file
        do {
            var finalSource = source
            
            // If the file is a Markdown (.md) or hybrid Note (.note) file,
            // convert Markdown syntax to Typst before compilation.
            // Native Typst syntax (= headings, #functions, etc.) passes through unchanged.
            let ext = fileURL.pathExtension.lowercased()

            // Track the file type for lenient-mode fallback, and reset escape history
            // and the watch-output stream state because the user typed new content —
            // start fresh.
            currentFileExtension = ext
            keepWithNextActive = GeneralSettingsManager.shared.keepWithNextHeadings
            fallbackAttempts = [:]
            pendingFallbackRawLines = []
            diagnosticParser.reset()
            pendingOutputBuffer = ""
            publishTask?.cancel()
            publishTask = nil
            batchDiagnosticCount = 0
            pendingFallbackRewrite = false
            fallbackCycleCount = 0

            // Operator-delimiting warnings for `.note` files (computed alongside
            // sanitization below, committed to `noteWarnings` once we publish).
            var pendingNoteWarnings: [TypstError] = []

            // The whole-document text passes below run off the main thread, so a compile that
            // starts while the user is typing does not stall the editor.
            if ext == "md" || ext == "note" {
                let textToProcess = finalSource
                let aiService = AICompletionService.shared
                let isHybrid = (ext == "note")
                // For hybrid `.note` files, first delimit any operator characters
                // (`@ # $ < >`) that aren't valid Typst so the parser doesn't have
                // to guess. This runs on the user's original text (accurate line
                // numbers for the warnings) and produces backslash escapes that the
                // sanitizer's hybrid rules already treat as idempotent.
                let (sanitized, warnings, lineMap) = await Task.detached {
                    let fixed = isHybrid ? Self.autoFixBrokenNoteSyntax(textToProcess) : textToProcess
                    let delimited = isHybrid ? Self.delimitImproperOperators(fixed) : (output: fixed, warnings: [TypstError]())
                    let cleaned = aiService.sanitizeMarkdownToTypst(delimited.output, isHybrid: isHybrid)
                    // Map converted-output lines back to the user's source so compile
                    // errors land on the line the user actually wrote.
                    let map = Self.buildLineMap(source: source, output: cleaned)
                    return (cleaned, delimited.warnings, map)
                }.value
                finalSource = sanitized
                shadowToSourceLine = lineMap
                pendingNoteWarnings = warnings
            } else {
                pendingNoteWarnings = []
                shadowToSourceLine = [:]
            }

            // Fonts that don't ship on macOS (e.g. Liberation Serif) would only
            // yield an "unknown font family" warning plus typst's default
            // fallback face. Substituting the metric-compatible font in the
            // shadow source renders the preview with the intended metrics.
            // Within-line rewrite, so line numbers still map back to the source.
            //
            // Then map raw-block language tags Typst can't highlight (csharp, ...)
            // to ones it can, and close up "``` json"-style gaps. Line-preserving.
            let sourceForFontPass = finalSource
            finalSource = await Task.detached {
                Self.normalizeRawLanguages(Self.substituteMissingFonts(sourceForFontPass))
            }.value

            // ---- TypstEdit calculator features -----------------------------
            // Scan for `#calc` / `calc-param` / `plot` / Bessel usage. The
            // scan result decides (a) whether `#calc` calls are resolved
            // through the CAS before compiling, (b) whether the calculator
            // bridge preamble (`BesselJ`, `plot`, `calc-param`…) is injected
            // into the shadow, and (c) whether the document is flagged as
            // non-portable Typst (`.typ` files only; `.note` files are
            // TypstEdit-native and exempt).
            // Static compilation (loops, #calc, bridge install) is shared with
            // every export path; the import line itself is added below with
            // the other preambles so line accounting stays in one place.
            let calcPipeline = await applyCalcPipeline(
                finalSource, fileExtension: ext, bridgeDirectory: projectTempDir, prependImport: false)
            let calcSummary = calcPipeline.summary
            var calcAdvisory = calcPipeline.diagnostics
            finalSource = calcPipeline.content
            if calcPipeline.lineCountChanged {
                // Loop specialisation repeats loop bodies: re-align so
                // diagnostics still land on the line the user wrote.
                shadowToSourceLine = Self.buildLineMap(source: source, output: finalSource)
            }
            if calcSummary.needsResolution {
                // Mirror the document's parameters onto the Calculator panel.
                NotificationCenter.default.post(
                    name: .calcDocumentParametersChanged,
                    object: self,
                    userInfo: ["parameters": calcPipeline.parameters])
            }

            // The bridge module and the WASM numeric core are loaded by
            // relative path, so both must sit next to the shadow file.
            // Without them the import would only produce "file not found".
            var bridgeReady = false
            if calcSummary.needsBridge {
                bridgeReady = CalcPlugin.install(into: projectTempDir)
                if !bridgeReady {
                    var issue = TypstError(
                        line: calcSummary.firstLine,
                        message: "The calculator’s WebAssembly core is not built — calculator functions in this document cannot run.",
                        severity: .warning)
                    issue.hints = [
                        "Build it with Tools/calc-plugin/build_calc_plugin.sh (needs brew install lld).",
                        "The bridge imports TypstEditCalc.wasm; both are copied next to the preview file.",
                    ]
                    calcAdvisory.append(issue)
                }
            }
            calcBridgeActive = calcSummary.needsBridge && bridgeReady

            if let portabilityWarning = CalcPortabilityPolicy.warning(summary: calcSummary, fileExtension: ext) {
                calcAdvisory.append(portabilityWarning)
            }
            self.calcWarnings = calcAdvisory
            let nonPortable = CalcPortabilityPolicy.shouldWarn(fileExtension: ext) && calcSummary.usesAny
            if self.usesNonPortableCalcFeatures != nonPortable {
                self.usesNonPortableCalcFeatures = nonPortable
            }
            self.calcFeatureSummaryText = calcSummary.usesAny ? calcSummary.featureNames.joined(separator: ", ") : nil

            var injectedPreamble = ""
            if calcBridgeActive {
                injectedPreamble += CalcPlugin.importStatement
            }
            if keepWithNextActive {
                injectedPreamble += Self.keepWithNextPreamble
            }
            if ext == "note" {
                injectedPreamble += Self.notePreamble
            }
            if isDarkMode {
                let sourceForDarkMode = finalSource
                finalSource = await Task.detached {
                    Self.applyDarkModeRewrites(sourceForDarkMode)
                }.value
                injectedPreamble += darkModePreamble
            }
            finalSource = injectedPreamble + finalSource
            
            finalSource = await self.rewriteRelativeImports(in: finalSource, sourceDirectory: workingDirectory, tempDirectory: projectTempDir)
            
            // With a widened root, `/…` no longer resolves to the project folder.
            if compileRoot.isWidened {
                finalSource = Self.rewriteRootAbsolutePaths(
                    in: finalSource, projectRoot: projectRoot, shadowDirectory: projectTempDir)
            }
            
            // Download web images and inject local paths before saving. Runs
            // after the rewriters so the injected filenames — relative to the
            // shadow file, which sits next to the downloads — are left alone.
            finalSource = await resolveWebImages(
                in: finalSource, projectRoot: projectRoot, shadowDirectory: projectTempDir)
            
            let finalSourceToWrite = finalSource
            try await Task.detached {
                try finalSourceToWrite.write(to: shadowSourceURL, atomically: true, encoding: .utf8)
            }.value
            
            // Reset the issue list for the new content: drop stale compile errors
            // and warnings, and install the freshly-computed operator-delimiting
            // warnings. We're on the main actor here, so this lands before
            // `startWatching` below.
            self.noteWarnings = pendingNoteWarnings
            self.typstErrors = []
            self.typstWarnings = []
            self.publishIssues()        } catch {
            self.compilationStatus = "Error writing shadow file: \(error)"
            return
        }
        
        // If we are already watching THIS file, we are done
        if let current = currentShadowSourceURL, current == shadowSourceURL, currentProcess?.isRunning == true {
             self.compilationStatus = "Compiling..." 
             return
        }
        
        // Otherwise, stop previous watch and start new one
        cleanUp()
        startWatching(sourceURL: shadowSourceURL, outputURL: shadowPDFURL, root: compileRoot.url)
    }
    
    private func startWatching(sourceURL: URL, outputURL: URL, root: URL) {
        guard let typstPath = resolveTypstPath() else {
            self.compilationStatus = "Error: 'typst' executable not found."
            return
        }
        
        currentShadowSourceURL = sourceURL
        currentShadowPDFURL = outputURL
        isIdleStopped = false
        // Clear compile diagnostics when (re)starting a watch; keep note warnings,
        // which describe the source and are recomputed on each `updateContent`.
        self.typstErrors = []
        self.typstWarnings = []
        self.diagnosticParser.reset()
        self.diagnosticDocument = (sourceURL.lastPathComponent, true)
        self.pendingOutputBuffer = ""
        self.publishTask?.cancel()
        self.publishTask = nil
        self.batchDiagnosticCount = 0
        self.pendingFallbackRewrite = false
        self.fallbackCycleCount = 0
        self.pendingFallbackRawLines = []
        self.publishIssues()
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        
        // Use --root to ensure relative imports from the temporary file work correctly
        process.arguments = ["watch", sourceURL.path, outputURL.path, "--root", root.path]
        
        let pipe = Pipe()
        process.standardError = pipe // typst often logs to stderr or stdout, check both? usually stderr for logs
        process.standardOutput = pipe
        
        self.processOutputPipe = pipe
        self.currentProcess = process
        
        process.terminationHandler = { [weak self] terminated in
            // SIGTERM is what we send to stop or replace a watch; it is not a
            // compiler failure and must not show as one.
            let stoppedByUs = terminated.terminationReason == .uncaughtSignal
                && terminated.terminationStatus == SIGTERM
            let exitCode = stoppedByUs ? 0 : terminated.terminationStatus
            let processID = ObjectIdentifier(terminated)
            Task { @MainActor [weak self] in
                // The pipe's last chunk can be delivered after termination;
                // give it a moment so the final diagnostic is not cut off.
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                // Only the active watch may touch compiler state. A process we
                // stopped (replaced, idle, window closed) must not: a new
                // watch may already be compiling, and "Idle" must stay "Idle".
                guard let current = self.currentProcess, ObjectIdentifier(current) == processID else {
                    return
                }
                self.isCompiling = false
                // `typst watch` exits on fatal errors (e.g. "source file must be
                // contained in project root"), sometimes without the blank line
                // that ends a diagnostic block — publish whatever it printed.
                self.finishCompilerOutput()
                // The final batch has no following `compiling …` marker to end
                // it: publish synchronously instead of waiting for the debounce.
                self.publishTask?.cancel()
                self.publishTask = nil
                self.rebuildIssuesFromParser()
                self.publishIssues()
                self.compilationStatus = exitCode == 0
                    ? "Watch process ended."
                    : "Error: the Typst compiler stopped (exit code \(exitCode))."
            }
        }
        
        do {
            try process.run()
            watchOwner.adopt(process, pipe: pipe, sourcePath: sourceURL.standardizedFileURL.path)
            self.isCompiling = true
            self.compilationStatus = "Watching..."
            
            // Start reading output in background
            monitorOutput(pipe: pipe, outputURL: outputURL)
        } catch {
            self.compilationStatus = "Failed to start watch: \(error)"
        }
    }
    
    private func monitorOutput(pipe: Pipe, outputURL: URL) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF: the watch exited. A handler left installed at EOF keeps
                // firing with empty reads, spinning a CPU and holding the pipe.
                handle.readabilityHandler = nil
                return
            }

            guard let chunk = String(data: data, encoding: .utf8) else { return }

            Task { @MainActor [weak self] in
                self?.handleCompilerOutput(chunk, outputURL: outputURL)
            }
        }
    }

    /// Processes one chunk of `typst watch` output. Chunks arrive at arbitrary
    /// boundaries — a diagnostic's `error:` line and its `┌─ file:line:col` location
    /// can land in different chunks, and even mid-line — so text is buffered and only
    /// complete lines are handed to `consumeCompilerOutputLine`.
    private func handleCompilerOutput(_ chunk: String, outputURL: URL) {
        pendingOutputBuffer += chunk
        var lines = pendingOutputBuffer.components(separatedBy: "\n")
        // The final element is an incomplete line unless the chunk ended with "\n";
        // keep it buffered until its remainder arrives. A partial line is a few
        // hundred bytes in practice; anything past this cap is a compiler
        // spewing without newlines, and holding all of it would grow for as
        // long as the watch runs.
        pendingOutputBuffer = String((lines.popLast() ?? "").suffix(Self.maxPendingOutputBytes))
        for line in lines {
            consumeCompilerOutputLine(line, outputURL: outputURL)
        }
    }

    /// Upper bound on one incomplete watch-output line kept across chunks.
    private static let maxPendingOutputBytes = 64 * 1024

    private func consumeCompilerOutputLine(_ line: String, outputURL: URL) {
        print("[TYPST-OUTPUT]: \(line)")

        if line.contains("compiling ...") {
            // This marker also ENDS the previous cycle's diagnostic batch:
            // typst prints its status marker before that batch's diagnostics,
            // and the batch has no other end delimiter. Finalize it, and cancel
            // any debounced publish this synchronous pass replaces.
            publishTask?.cancel()
            publishTask = nil
            finalizeDiagnosticBatch()
            cancelIdleStop()
            isCompiling = true
            compilationStatus = "Compiling..."
            pendingFallbackRewrite = false
            return
        }

        // `typst watch` prints its status marker BEFORE the diagnostics of that
        // cycle, so each marker starts a fresh batch; the batch is published as
        // its diagnostic blocks complete (see `consumeDiagnosticLine`).
        if line.contains("compiled successfully") || line.contains("compiled with warnings") {
            // Both mean a PDF was written; "with warnings" is followed by the
            // warning diagnostics.
            isCompiling = false
            compilationStatus = "Watching..."
            // Notify the view with a small delay to ensure the file is fully flushed.
            // The compiler is the sender, so only its own window reloads.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(name: .pdfDidUpdate, object: self, userInfo: ["url": outputURL])
            }
            // A successful compile clears stale compile diagnostics, but keeps the
            // `.note` operator-delimiting warnings, which stay valid until the
            // source changes.
            publishTask?.cancel()
            publishTask = nil
            typstErrors = []
            typstWarnings = []
            diagnosticParser.reset()
            batchDiagnosticCount = 0
            // The previous fixes (if any) compiled: the fallback fixer earned a
            // fresh chase budget for the next broken cycle.
            fallbackCycleCount = 0
            publishIssues()
            scheduleIdleStop()
            return
        }

        if line.contains("compiled with errors") {
            // NOTE: this contains the substring "compiled", so it must be checked
            // separately from the success case above. `typst watch` keeps running
            // after a failed compile and re-reports the full diagnostic set below
            // this marker, so start the batch from a clean slate. The previous
            // list stays on screen until the new blocks arrive (no flicker).
            isCompiling = false
            compilationStatus = "Compilation Error"
            publishTask?.cancel()
            publishTask = nil
            diagnosticParser.reset()
            batchDiagnosticCount = 0
            // A broken document is idle too; `stopWatchIfIdle` waits for any
            // lenient-mode fix this batch queues.
            scheduleIdleStop()
            return
        }

        if TypstDiagnosticParser.startsBlock(line)
            || diagnosticParser.isInsideBlock
            || line.trimmingCharacters(in: .whitespaces).isEmpty {
            consumeDiagnosticLine(line)
            return
        }
    }

    /// Feeds one line to `diagnosticParser` and reacts to what it completed:
    /// queues lenient-fallback rewrites for errors in the shadow file, and
    /// publishes the batch each time a diagnostic block ends. Diagnostics without
    /// a location (e.g. "source file must be contained in project root") are
    /// published too, with no line.
    ///
    /// When the cycle is a diagnostic flood (more than `diagnosticFloodLimit`
    /// diagnostics), per-block work is skipped entirely: rebuilding, publishing
    /// and repairing are all O(batch), and thousands of blocks would make the
    /// cycle quadratic on the main thread. A flooded batch is folded into one
    /// debounced pass instead (see `scheduleFloodPublish`).
    private func consumeDiagnosticLine(_ line: String) {
        switch diagnosticParser.consume(line) {
        case .located(let index):
            let diagnostic = diagnosticParser.diagnostics[index]
            batchDiagnosticCount += 1
            // Only errors in the shadow file itself queue a fallback rewrite.
            // Warnings don't block output, and rewriting their lines wrapped
            // valid content (e.g. a list item whose `__x__` triggers "no text
            // within underscores") in `#raw(...)`. Errors inside an imported
            // file carry *that* file's line numbers, which must never be used to
            // rewrite the shadow file. Queuing stops once the cycle floods —
            // the flush gate would refuse to repair it anyway, and this keeps
            // the duplicate check bounded.
            if batchDiagnosticCount <= Self.diagnosticFloodLimit,
               diagnostic.severity == .error,
               let location = diagnostic.location,
               isOpenDocumentPath(location.path, requireShadow: true),
               !pendingFallbackRawLines.contains(location.line) {
                pendingFallbackRawLines.append(location.line)
            }
        case .updated:
            // A call-site frame (`while calling …`) arrived after the primary
            // block closed. Typst prints those outside the block, so the
            // diagnostic itself was already published; fold the new frame in
            // without re-running the fallback repair.
            if batchDiagnosticCount > Self.diagnosticFloodLimit {
                scheduleFloodPublish()
            } else {
                rebuildIssuesFromParser()
                scheduleBatchPublish()
            }
        case .blockEnded:
            if batchDiagnosticCount > Self.diagnosticFloodLimit {
                // Flooded cycle: one debounced rebuild + capped publish for the
                // whole batch, no per-block repair.
                scheduleFloodPublish()
            } else {
                rebuildIssuesFromParser()
                // Repair anything the block flagged — as before, small documents
                // are fixed as fast as typst reports their errors.
                flushPendingFallbackFix()
                scheduleBatchPublish()
            }
        case .none:
            break
        }
    }

    /// Synchronously ends the current diagnostic batch: closes any open block,
    /// folds it into the displayed issue lists and applies one (and only one)
    /// lenient-fallback pass for the whole batch. Called when the batch ends —
    /// at the next cycle's `compiling …` marker and, via the termination
    /// handler, when the compiler stops — since the last batch of a session has
    /// no following marker to end it.
    private func finalizeDiagnosticBatch() {
        if diagnosticParser.isInsideBlock {
            consumeDiagnosticLine("")
        }
        guard batchDiagnosticCount > 0 || !pendingFallbackRawLines.isEmpty else { return }
        rebuildIssuesFromParser()
        flushPendingFallbackFix()
        if !pendingFallbackRewrite {
            publishIssues()
        }
    }

    /// Debounced issue publication for healthy (non-flooded) batches: the lists
    /// are already rebuilt, so this only coalesces the UI update. Skipped when a
    /// fallback rewrite just queued a recompile — the post-fix cycle publishes
    /// the real state, and showing the transient pre-fix errors would flash.
    private func scheduleBatchPublish() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.publishDebounceNanos)
            guard !Task.isCancelled, let self else { return }
            self.publishTask = nil
            guard !self.pendingFallbackRewrite else { return }
            self.publishIssues()
        }
    }

    /// Debounced pass for flooded batches: a single O(batch) rebuild plus one
    /// capped publish after the diagnostic stream pauses. No repair — flood
    /// gate in `flushPendingFallbackFix` would refuse it anyway.
    private func scheduleFloodPublish() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.publishDebounceNanos)
            guard !Task.isCancelled, let self else { return }
            self.publishTask = nil
            self.rebuildIssuesFromParser()
            guard !self.pendingFallbackRewrite else { return }
            self.publishIssues()
        }
    }

    /// Ends any diagnostic still open when the compiler's output stops (the
    /// process exited without a trailing blank line), so it is not lost.
    private func finishCompilerOutput() {
        if !pendingOutputBuffer.isEmpty {
            let rest = pendingOutputBuffer
            pendingOutputBuffer = ""
            if TypstDiagnosticParser.startsBlock(rest) || diagnosticParser.isInsideBlock {
                consumeDiagnosticLine(rest)
            }
        }
        if diagnosticParser.isInsideBlock {
            consumeDiagnosticLine("")
        }
    }

    /// Batch variant of the incremental diagnostic parser for one-shot compile runs
    /// (e.g. exports) where the full compiler output is already in memory.
    /// `sourceFileName` is the file that was compiled; its line numbers are used
    /// as-is (it is not a shadow copy).
    private func parseErrors(from output: String, sourceFileName: String) {
        let previousDocument = diagnosticDocument
        let previousParser = diagnosticParser
        let previousBatchCount = batchDiagnosticCount
        defer {
            diagnosticDocument = previousDocument
            diagnosticParser = previousParser
            batchDiagnosticCount = previousBatchCount
        }
        diagnosticDocument = (sourceFileName, false)
        diagnosticParser.reset()
        batchDiagnosticCount = 0
        for line in output.components(separatedBy: "\n") {
            _ = diagnosticParser.consume(line)
        }
        rebuildIssuesFromParser()
        publishIssues()
    }

    /// True when a path printed by Typst refers to the open document (the
    /// shadow copy during live preview, or the compiled file during export).
    private func isOpenDocumentPath(_ path: String, requireShadow: Bool = false) -> Bool {
        guard let document = diagnosticDocument else { return false }
        if requireShadow && !document.isShadow { return false }
        return (path as NSString).lastPathComponent == document.fileName
    }

    /// Maps a line number Typst reported for the open document to the editor buffer.
    private func editorLine(forDocumentLine line: Int) -> Int {
        (diagnosticDocument?.isShadow ?? true) ? sourceLine(forShadowLine: line) : line
    }

    /// Replaces `typstErrors` / `typstWarnings` with the parser's current batch.
    /// Deduplication is set-keyed: a `contains(where:)` scan per diagnostic made
    /// each rebuild O(n²), and with thousands of diagnostics per cycle that
    /// alone saturated the main thread.
    private func rebuildIssuesFromParser() {
        var errorKeys = Set<String>()
        var warningKeys = Set<String>()
        var errors: [TypstError] = []
        var warnings: [TypstError] = []
        errors.reserveCapacity(diagnosticParser.diagnostics.count)
        for raw in diagnosticParser.diagnostics {
            let issue = makeIssue(from: raw)
            let key = "\(issue.line ?? -1)|\(issue.file ?? "-")|\(issue.message)"
            if issue.severity == .warning {
                if warningKeys.insert(key).inserted { warnings.append(issue) }
            } else {
                if errorKeys.insert(key).inserted { errors.append(issue) }
            }
        }
        typstErrors = errors
        typstWarnings = warnings
    }

    /// Converts a raw compiler diagnostic into a `TypstError` for the editor:
    /// shadow-file lines are mapped to the user's source, and diagnostics inside
    /// another file keep that file's name and line. `warning:` diagnostics are
    /// kept separate from errors: they don't block output but are still surfaced
    /// and navigable.
    private func makeIssue(from raw: RawTypstDiagnostic) -> TypstError {
        var line: Int? = nil
        var file: String? = nil
        var fileLine: Int? = nil
        if let location = raw.location {
            if isOpenDocumentPath(location.path) {
                line = editorLine(forDocumentLine: location.line)
            } else {
                file = location.path
                fileLine = location.line
            }
        }

        let trace: [TypstError.TraceEntry] = raw.trace.map { frame in
            guard let location = frame.location else {
                return TypstError.TraceEntry(message: frame.message, snippet: frame.snippet)
            }
            if isOpenDocumentPath(location.path) {
                return TypstError.TraceEntry(
                    message: frame.message,
                    line: editorLine(forDocumentLine: location.line),
                    snippet: frame.snippet)
            }
            return TypstError.TraceEntry(
                message: frame.message,
                file: location.path,
                fileLine: location.line,
                snippet: frame.snippet)
        }

        // An error inside an imported file is still triggered from a line in this
        // document — the first trace frame here is where clicking should jump.
        if line == nil, let callSite = trace.first(where: { $0.line != nil })?.line {
            line = callSite
        }

        var issue = TypstError(line: line, message: raw.message, severity: raw.severity)
        issue.snippet = raw.snippet
        issue.column = raw.caretColumn
        issue.length = raw.caretLength
        issue.file = file
        issue.fileLine = fileLine
        issue.hints = raw.hints
        issue.trace = trace
        return issue
    }

    /// Runs the lenient fallback fixer for any diagnostics that completed since the
    /// last flush. For `.note` / `.md` files this rewrites the offending shadow-file
    /// lines so the document compiles and the preview is preserved.
    ///
    /// Sets `pendingFallbackRewrite` so the error panel defers display until the
    /// resulting recompile finishes.
    private func flushPendingFallbackFix() {
        let rawLines = pendingFallbackRawLines
        pendingFallbackRawLines = []
        guard !rawLines.isEmpty else { return }
        guard currentFileExtension == "note" || currentFileExtension == "md" else { return }
        // Flood gate 1: a cycle with this many diagnostics cannot be repaired
        // line-by-line — the rewrites cascade into fresh errors and the
        // fix→recompile loop never converges. Leave the document alone and
        // surface the errors instead.
        guard batchDiagnosticCount <= Self.diagnosticFloodLimit else {
            print("[FallbackFix] Diagnostic flood (\(batchDiagnosticCount) diagnostics this cycle) — skipping line-by-line repair.")
            return
        }
        // Flood gate 2: cap the fix→recompile chase so an oscillating cascade
        // cannot rewrite the shadow file cycle after cycle. Budget resets when
        // the source changes or a compile succeeds.
        guard fallbackCycleCount < Self.fallbackCycleLimit else {
            print("[FallbackFix] Fix chase budget exhausted (\(fallbackCycleCount) recompile cycles) — skipping repair until the source changes or compiles.")
            return
        }
        // If (and only if) the fallback actually rewrote the shadow file, typst
        // watch will recompile — mark that we're mid-fix so the error panel
        // doesn't flash transient errors. A skipped repair (protected
        // directives, live Typst regions, maxed-out lines) rewrites nothing, so
        // no recompile is coming: setting the flag anyway would gate every
        // later publish off forever — the Issues panel reads "No issues" while
        // the preview shows nothing, exactly the unfixable-error deadlock this
        // flag existed to avoid.
        if attemptFallbackFix(rawErrorLines: rawLines) {
            pendingFallbackRewrite = true
            fallbackCycleCount += 1
        }
    }

    /// Maps a shadow-file line number to the line in the user's editor buffer. The
    /// shadow file holds the converted text (Markdown→Typst for `.note` / `.md`)
    /// plus the injected preamble, so raw compiler positions don't address the
    /// source; `shadowToSourceLine` — built on each `updateContent` — bridges them,
    /// falling back to the preamble-only adjustment for unmatched lines.
    private func sourceLine(forShadowLine line: Int) -> Int {
        let outputLine = line - preambleLineCount
        if outputLine >= 1, let mapped = shadowToSourceLine[outputLine] {
            return mapped
        }
        return max(1, outputLine)
    }

    // MARK: - Shadow → Source Line Mapping

    /// Builds a map from converted-output line (1-based) to source line by
    /// matching normalized lines, then interpolating what falls between the
    /// matches.
    ///
    /// The conversion is mostly structure-preserving, but it also *expands*:
    /// an `.note` with 7,560 lines converts to a 9,257-line shadow, because
    /// lists and tables add lines. A pure "look ahead N source lines" walk
    /// cannot recover once the output has drifted more than N lines past the
    /// source cursor — every later line then maps to the same stale position.
    /// (In a real 7,500-line document that collapsed all 18 diagnostics onto a
    /// single, unrelated source line.) So matches are found by content in the
    /// whole remaining source, and gaps between two confident matches are
    /// spread proportionally, which absorbs local expansion.
    nonisolated static func buildLineMap(source: String, output: String) -> [Int: Int] {
        let srcLines = source.components(separatedBy: "\n")
        let outLines = output.components(separatedBy: "\n")
        guard !srcLines.isEmpty, !outLines.isEmpty else { return [:] }

        // Normalized source text → candidate line indices, in document order.
        // Only distinctive lines are indexed: a blank line or a lone `-` says
        // nothing about where it came from.
        var index: [String: [Int]] = [:]
        for (i, line) in srcLines.enumerated() {
            let normalized = normalizedForLineMap(line)
            guard normalized.count >= Self.lineMapMinimumAnchorLength else { continue }
            index[normalized, default: []].append(i)
        }

        // Pass 1: confident anchors, in order. Lines are matched to the first
        // equal source line at or after the cursor, so a repeated paragraph
        // cannot drag the mapping backwards.
        var anchors: [(output: Int, source: Int)] = []
        var cursor = 0
        for (i, line) in outLines.enumerated() {
            let normalized = normalizedForLineMap(line)
            guard normalized.count >= Self.lineMapMinimumAnchorLength,
                  let candidates = index[normalized] else { continue }
            // `candidates` is sorted ascending; find the first at/after cursor.
            var low = 0
            var high = candidates.count
            while low < high {
                let mid = (low + high) / 2
                if candidates[mid] < cursor { low = mid + 1 } else { high = mid }
            }
            guard low < candidates.count else { continue }
            let sourceIndex = candidates[low]
            anchors.append((i, sourceIndex))
            cursor = sourceIndex + 1
        }

        // Pass 2: fill the gaps between anchors.
        var map: [Int: Int] = [:]
        map.reserveCapacity(outLines.count)

        /// Maps `outputCount` output lines starting at `outputStart` onto
        /// `sourceCount` source lines starting at `sourceStart`, all 0-based.
        ///
        /// Equal counts map one-to-one, so an unchanged document keeps exact
        /// line numbers. Unequal counts are spread evenly — that is what absorbs
        /// a table or list that expands into more output lines than it had in
        /// the source. The ranges are exclusive of the anchors on both sides,
        /// so a filled line can never claim an anchor's own position.
        func fill(outputStart: Int, outputCount: Int, sourceStart: Int, sourceCount: Int) {
            guard outputCount > 0, !srcLines.isEmpty else { return }
            for k in 0..<outputCount {
                let offset: Int
                if sourceCount <= 0 {
                    offset = 0
                } else if sourceCount == outputCount {
                    offset = k
                } else {
                    // Floor, not round: a rounding-up last step would spill onto
                    // the next anchor's source line.
                    offset = Int(Double(k) * Double(sourceCount) / Double(outputCount))
                }
                let sourceIndex = min(sourceStart + offset, srcLines.count - 1)
                map[outputStart + k + 1] = max(1, sourceIndex + 1)
            }
        }

        guard let first = anchors.first else {
            // Nothing matched (fully rewritten document): a straight
            // proportional fallback still beats no mapping at all.
            fill(outputStart: 0, outputCount: outLines.count,
                 sourceStart: 0, sourceCount: srcLines.count)
            return map
        }

        fill(outputStart: 0, outputCount: first.output,
             sourceStart: 0, sourceCount: first.source)
        for (a, b) in zip(anchors, anchors.dropFirst()) {
            fill(outputStart: a.output + 1, outputCount: b.output - a.output - 1,
                 sourceStart: a.source + 1, sourceCount: b.source - a.source - 1)
        }
        if let last = anchors.last {
            fill(outputStart: last.output + 1, outputCount: outLines.count - last.output - 1,
                 sourceStart: last.source + 1, sourceCount: srcLines.count - last.source - 1)
        }
        // The anchors themselves are exact.
        for anchor in anchors { map[anchor.output + 1] = anchor.source + 1 }
        return map
    }

    /// Shorter normalized lines (a list bullet, a lone word) match too many
    /// places to be a trustworthy anchor, so they are interpolated instead.
    private nonisolated static let lineMapMinimumAnchorLength = 12

    private nonisolated static func normalizedForLineMap(_ line: String) -> String {
        String(line.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: - Lenient Fallback Fixer (.note / .md)

    /// For non-strict file types, when Typst reports an error on specific lines of the shadow
    /// file, this method rewrites those lines so the document always compiles and text is
    /// preserved. The content is rendered verbatim in the output instead of being silently
    /// dropped.
    ///
    /// Two escalating strategies are applied, per line, tracked via `fallbackAttempts`:
    ///
    ///   **Strategy 1 – Escape:** escape every Typst-special character on the line so it
    ///   becomes literal plain text. Cheapest fix, looks the nicest, but doesn't help for
    ///   multi-line constructs (e.g. an unbalanced `]` inside a generated `#table()` cell).
    ///
    ///   **Strategy 2 – Wrap in `#raw()`:** replace the entire line with
    ///   `#raw("escaped content", block: true)`. Raw blocks are *never* parsed by Typst,
    ///   so this is guaranteed to compile, no matter what the original line contained.
    ///
    /// `typst watch` detects the file change after each rewrite and recompiles, so a single
    /// problematic section may be fixed across two watch cycles (escape first, raw-wrap if
    /// that wasn't enough).
    ///
    /// **Exclusions:** Lines that start with native Typst top-level directives
    /// (`#import`, `#include`, `#let`, `#set`, `#show`, `#return`) are deliberately left
    /// untouched. These are intentional Typst code the user wrote — for example a package
    /// `#import` may briefly fail while the package downloads, and silently escaping it
    /// would break the rest of the document. The original error is surfaced to the user
    /// instead of being swallowed by the fallback.

    /// Line numbers of the errors Typst reported, for the lenient fallback fixer.
    ///
    /// `onlyInFile` restricts the result to diagnostics whose location is that
    /// file (compared by last path component, which is how Typst prints it). An
    /// error inside an imported module carries *that* module's line numbers;
    /// rewriting the shadow file with them would corrupt an unrelated line.
    /// Pass nil to keep every error line (legacy behaviour).
    nonisolated static func parseRawErrorLines(from output: String, onlyInFile: String? = nil) -> [Int] {
        var rawLines: [Int] = []
        for diagnostic in TypstDiagnosticParser.parse(output) {
            guard diagnostic.severity == .error, let location = diagnostic.location else { continue }
            if let onlyInFile,
               (location.path as NSString).lastPathComponent != (onlyInFile as NSString).lastPathComponent {
                continue
            }
            if !rawLines.contains(location.line) {
                rawLines.append(location.line)
            }
        }
        return rawLines
    }

    func parseRawErrorLines(from output: String) -> [Int] {
        Self.parseRawErrorLines(from: output)
    }

    /// Applies the lenient fallback fix (Strategy 1: escape special characters; Strategy 2: wrap in #raw())
    /// to the specified source file URL for the offending error lines. Returns true if file was modified.
    @discardableResult
    func applyFallbackFix(to fileURL: URL, rawErrorLines: [Int], attempts: inout [Int: Int], isHybrid: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }

        // Group the offending lines by which strategy we should try next.
        // Lines we've already maxed out (attempt >= 2) are skipped.
        var escapeTargets: [Int] = []
        var rawWrapTargets: [Int] = []
        for line in rawErrorLines {
            let attempt = attempts[line, default: 0]
            if attempt == 0 { escapeTargets.append(line) }
            else if attempt == 1 { rawWrapTargets.append(line) }
        }
        guard !(escapeTargets.isEmpty && rawWrapTargets.isEmpty) else {
            print("[FallbackFix] All error lines already maxed out — skipping.")
            return false
        }

        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            var fileLines = content.components(separatedBy: "\n")
            var modified = false

            // Lines that belong to a live Typst code region (`#figure(…)`,
            // `#show …`, `#let …`) are the user's own code, not generated
            // Markdown. Escaping them corrupts the document instead of
            // repairing it: one `#figure(` call missing its closing `)` is
            // enough to make the region scanner treat the following lines as
            // code, and rewriting them turned 38 figure labels into literal
            // `\<gen-34-14>` text, producing 34 bogus "label does not exist"
            // errors. Surface the original diagnostic instead.
            //
            // Spans are computed on this file (not the source) so the 1-based
            // line numbers match `rawErrorLines` exactly, preambles included.
            let codeLines: Set<Int> = isHybrid
                ? Set(AICompletionService.typstRegionLineSpans(in: content)
                    .flatMap { ($0.start...$0.end).map { $0 + 1 } })
                : []

            // --- Strategy 1: escape special characters ---
            for rawLine in escapeTargets {
                let idx = rawLine - 1  // 1-based → 0-based
                guard idx >= 0 && idx < fileLines.count else { continue }

                let original = fileLines[idx]
                let trimmed = original.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }                          // nothing to escape
                if trimmed.hasPrefix("#raw(\"") { continue }             // already a raw block
                if codeLines.contains(rawLine) {
                    attempts[rawLine] = 2  // never repair live code
                    print("[FallbackFix][skip] line \(rawLine): live Typst region — \(trimmed.prefix(40))")
                    continue
                }
                if isProtectedTypstDirective(trimmed, isHybrid: isHybrid) {
                    attempts[rawLine] = 2  // mark as maxed so we don't keep retrying
                    print("[FallbackFix][skip] line \(rawLine): protected directive — \(trimmed.prefix(40))")
                    continue
                }

                fileLines[idx] = escapeTypstLine(original)
                attempts[rawLine] = 1
                modified = true
                print("[FallbackFix][escape] line \(rawLine): \(original.prefix(60))")
            }

            // --- Strategy 2: wrap the whole line in #raw("...", block: true) ---
            for rawLine in rawWrapTargets {
                let idx = rawLine - 1
                guard idx >= 0 && idx < fileLines.count else { continue }

                let original = fileLines[idx]
                let trimmed = original.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if trimmed.hasPrefix("#raw(\"") { continue }             // idempotent
                if codeLines.contains(rawLine) {
                    attempts[rawLine] = 2
                    print("[FallbackFix][skip] line \(rawLine): live Typst region — \(trimmed.prefix(40))")
                    continue
                }
                if isProtectedTypstDirective(trimmed, isHybrid: isHybrid) {
                    attempts[rawLine] = 2
                    print("[FallbackFix][skip] line \(rawLine): protected directive — \(trimmed.prefix(40))")
                    continue
                }

                // Escape backslashes and double-quotes so the line is a valid Typst string.
                let escaped = original
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                fileLines[idx] = "#raw(\"\(escaped)\", block: true)"
                attempts[rawLine] = 2
                modified = true
                print("[FallbackFix][raw-wrap] line \(rawLine): \(original.prefix(60))")
            }

            if modified {
                let newContent = fileLines.joined(separator: "\n")
                try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
                return true
            }
        } catch {
            print("[FallbackFix] Failed to apply fallback fix: \(error)")
        }
        return false
    }

    /// Applies the lenient fallback repair to the shadow file. Returns whether
    /// the file was actually rewritten — the caller keys `pendingFallbackRewrite`
    /// (and the fix-chase budget) off a real rewrite, not an attempted one.
    @discardableResult
    private func attemptFallbackFix(rawErrorLines: [Int]) -> Bool {
        guard let shadowURL = currentShadowSourceURL else { return false }
        let modified = applyFallbackFix(to: shadowURL, rawErrorLines: rawErrorLines, attempts: &fallbackAttempts, isHybrid: currentFileExtension == "note")
        if modified {
            print("[FallbackFix] Shadow file updated — typst watch will recompile.")
        }
        return modified
    }

    /// Returns true if `line` is intentional Typst code that should never be touched by
    /// the lenient fallback fixer.
    ///
    /// Top-level directives (`#import`, `#include`, `#let`, `#set`, `#show`, `#return`)
    /// are always protected in every file type — for example, a `#import` that briefly
    /// fails while a package is downloading should never be escaped, otherwise the rest
    /// of the document (which depends on that import) breaks too.
    ///
    /// In hybrid `.note` files we additionally protect any `#word(…)` / `#word[…]` call.
    /// `.note` files mix Markdown and intentional Typst, so a line like
    /// `#score(generated-abc, width: 100%)` is user-written Typst, not generated
    /// Markdown output. We still allow the fallback to act on Markdown-converted
    /// constructs (`#link`, `#image`, `#table`, `#strike`, `#figure`, `#align`,
    /// `#line`, `#footnote`, `#super`, `#sub`, `#underline`, `#highlight`, `#raw`,
    /// `#quote`)
    /// which are the functions `sanitizeMarkdownToTypst` is known to emit.
    private func isProtectedTypstDirective(_ line: String, isHybrid: Bool) -> Bool {
        // Always-protected top-level keywords.
        let topLevel = ["#import", "#include", "#let", "#set", "#show", "#return"]
        if topLevel.contains(where: { line.hasPrefix($0) }) { return true }

        // Only apply the user-Typst heuristic in hybrid `.note` files. Pure `.md` files
        // don't contain user Typst, so a stray `#word(…)` there is more likely a typo.
        guard isHybrid else { return false }

        // Match `#identifier` followed by `(`, `[`, or a space-and-keyword (e.g. `#let x`).
        // The negative lookahead filters out the Markdown converter's known outputs so
        // the fallback can still repair broken converter-generated tables/links/images.
        let markdownConverterFuncs = [
            "link", "image", "table", "strike", "figure", "align", "line",
            "footnote", "super", "sub", "underline", "highlight", "raw", "quote",
        ]
        let nsLine = line as NSString
        guard let match = CompilerRegex.markdownConverterFunc.firstMatch(in: line, options: [], range: NSRange(0..<nsLine.length)) else {
            return false
        }
        let name = nsLine.substring(with: match.range(at: 1))
        return !markdownConverterFuncs.contains(name)
    }

    /// Escapes all Typst special characters in a line so it compiles as literal plain text.
    /// Safely handles strings that might already be partially escaped by removing existing
    /// escapes first, preventing double-escaping (e.g., \$ turning into \\\$).
    private func escapeTypstLine(_ line: String) -> String {
        var result = line
        
        // 1. Remove existing standard Typst escapes to prevent double-escaping
        result = result.replacingOccurrences(of: "\\#", with: "#")
        result = result.replacingOccurrences(of: "\\$", with: "$")
        result = result.replacingOccurrences(of: "\\@", with: "@")
        result = result.replacingOccurrences(of: "\\<", with: "<")
        result = result.replacingOccurrences(of: "\\`", with: "`")
        
        // 2. Escape all special characters
        result = result.replacingOccurrences(of: "#",  with: "\\#")
        result = result.replacingOccurrences(of: "$",  with: "\\$")
        result = result.replacingOccurrences(of: "@",  with: "\\@")
        result = result.replacingOccurrences(of: "<",  with: "\\<")
        result = result.replacingOccurrences(of: "`",  with: "\\`")
        
        return result
    }

    // MARK: - Missing-Font Substitution

    /// Fonts that don't ship on macOS, mapped to the metric-compatible face
    /// every Mac has. Substituting keeps the intended metrics of a document
    /// authored against e.g. Liberation Serif; without it typst falls back to
    /// its default face and emits an "unknown font family" warning.
    private nonisolated static let missingFontAliases: [String: String] = [
        "liberation serif": "Times New Roman",
        "liberation sans": "Arial",
        "liberation sans narrow": "Arial",
        "liberation mono": "Courier New",
        "dejavu sans mono": "Menlo",
        "consolas": "Menlo",
    ]

    /// Rewrites colours for the dark preview: strokes, `luma()` values and explicit black.
    nonisolated static func applyDarkModeRewrites(_ source: String) -> String {
        var finalSource = source
        // 1. Inject the color into partial strokes safely
        finalSource = CompilerRegex.stroke.stringByReplacingMatches(
            in: finalSource,
            options: [],
            range: NSRange(0..<finalSource.utf16.count),
            withTemplate: "$1 + rgb(\"#d1d1d1\")"
        )

        // 2. Automatically invert luma() for dark mode (e.g., luma(220) -> luma(35))
        let nsString = NSMutableString(string: finalSource)
        let matches = CompilerRegex.luma.matches(in: finalSource, options: [], range: NSRange(0..<finalSource.utf16.count))

        // Iterate in reverse so replacing text doesn't shift the ranges of earlier matches
        for match in matches.reversed() {
            let valString = nsString.substring(with: match.range(at: 1))
            let isPercent = match.range(at: 2).length > 0

            if let val = Double(valString) {
                // If it's a percentage use 100 - x, otherwise use 255 - x
                let invertedVal = isPercent ? max(0, 100.0 - val) : max(0, 255.0 - val)

                // Format cleanly without trailing decimals if it's a whole number
                let formattedVal = invertedVal.truncatingRemainder(dividingBy: 1) == 0 ?
                                   String(format: "%.0f", invertedVal) :
                                   String(format: "%.1f", invertedVal)

                let replacement = "luma(\(formattedVal)\(isPercent ? "%" : ""))"
                nsString.replaceCharacters(in: match.range, with: replacement)
            }
        }
        finalSource = nsString as String

        // 3. Catch explicit black colors used in parameters and invert them
        // Matches "fill: black" or "stroke: rgb(0,0,0)" but ignores the word "black" in regular text
        finalSource = CompilerRegex.black.stringByReplacingMatches(
            in: finalSource,
            options: [],
            range: NSRange(0..<finalSource.utf16.count),
            withTemplate: "$1rgb(\"#d1d1d1\")"
        )
        return finalSource
    }

    /// Rewrites `font:` named-argument values naming fonts that don't ship on
    /// macOS to their metric-compatible installed equivalents
    /// (`font: "Liberation Serif"` → `font: "Times New Roman"`). Matches are
    /// whole string literals only — `"MyLiberation Serif"` is left alone —
    /// and cover both `font: "X"` and `font: ("X", "Y")` forms. Shadow-source
    /// only: the user's file itself is never modified.
    nonisolated static func substituteMissingFonts(_ source: String) -> String {
        guard source.contains("font") else { return source }
        let nsSource = source as NSString
        let mutable = NSMutableString(string: source)
        // Right-to-left so earlier match ranges survive the replacements.
        for match in CompilerRegex.fontArgument.matches(
            in: source, options: [], range: NSRange(0..<nsSource.length)
        ).reversed() {
            let argument = nsSource.substring(with: match.range)
            var rebuilt = ""
            var cursor = argument.startIndex
            var changed = false
            for literal in CompilerRegex.quotedString.matches(
                in: argument, options: [], range: NSRange(0..<argument.utf16.count)
            ) {
                guard let fullRange = Range(literal.range, in: argument),
                      let valueRange = Range(literal.range(at: 1), in: argument) else { continue }
                rebuilt += argument[cursor..<fullRange.lowerBound]
                let name = String(argument[valueRange]).lowercased()
                if let installed = missingFontAliases[name] {
                    rebuilt += "\"\(installed)\""
                    changed = true
                } else {
                    rebuilt += String(argument[fullRange])
                }
                cursor = fullRange.upperBound
            }
            rebuilt += argument[cursor...]
            if changed {
                mutable.replaceCharacters(in: match.range, with: rebuilt)
            }
        }
        return mutable as String
    }

    // MARK: - Raw Code-Block Language Normalization

    /// Maps raw-block language tags that the Typst CLI's bundled syntax set
    /// fails to resolve — verified empirically: each key below renders with NO
    /// highlighting (and `c#` / `c++` even leak `#` / `++` into the output,
    /// breaking the fence) — to a tag that DOES highlight. Values were each
    /// verified to resolve on the bundled Typst binaries.
    nonisolated static let rawLanguageAliases: [String: String] = [
        "csharp": "cs",
        "c#": "cs",
        "c++": "cpp",
        "cxx": "cpp",
        "cc": "cpp",
        "shell": "bash",
        "zsh": "bash",
        "console": "bash",
        "terminal": "bash",
        "docker": "dockerfile",
        "objc": "objective-c",
        "obj-c": "objective-c",
        "fsharp": "fs",
        "json5": "json",
        "jsonl": "json",
        "node": "javascript",
        "nodejs": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
    ]

    /// Language tags verified to resolve in the bundled Typst syntax set. When
    /// one of these is separated from its fence by whitespace (`"``` json"`),
    /// the space is closed up — Typst otherwise treats the tag as the block's
    /// first content line and the block compiles untagged (no highlighting).
    nonisolated static let knownRawLanguages: Set<String> = [
        "bash", "c", "cc", "console", "cpp", "csharp", "css", "cjs", "cs",
        "dart", "diff", "docker", "dockerfile", "fs", "fsharp", "go",
        "golang", "html", "javascript", "java", "json", "json5", "jsonc",
        "jsonl", "js", "kotlin", "lua", "makefile", "mjs", "node", "nodejs",
        "nix", "objc", "obj-c", "objective-c", "perl", "python", "ruby",
        "rust", "rb", "scala", "shell", "sh", "sql", "swift", "terminal",
        "toml", "typescript", "ts", "xml", "yaml", "yml", "zsh",
        "c#", "c++", "cxx",
    ]

    /// Rewrites raw-block OPENING fence lines so the language tag is one the
    /// Typst CLI can actually highlight: alias tags the bundled syntax set
    /// does not know (`csharp` → `cs`) are mapped, tags that would corrupt
    /// the fence (`c#`, `c++`) are replaced, and a space between the fence
    /// and a known tag ("``` json" → "```json") is closed up. Line-for-line
    /// and within-line only, so shadow-file line numbers still map back to
    /// the editor source, and code-block CONTENT is never touched — only
    /// opening fence lines are rewritten. Shadow-source only: the user's
    /// file itself is never modified.
    nonisolated static func normalizeRawLanguages(_ source: String) -> String {
        guard source.contains("`") else { return source }
        var lines = source.components(separatedBy: "\n")
        // Backtick length of the raw block currently open; 0 = outside any block.
        var fenceRun = 0
        for i in lines.indices {
            let line = lines[i]
            if fenceRun > 0 {
                // Inside a raw block: only a pure backtick run at least as
                // long as the opener ends it. Content lines are never rewritten.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "`" }), trimmed.count >= fenceRun {
                    fenceRun = 0
                }
                continue
            }
            let nsLine = line as NSString
            guard let match = CompilerRegex.rawFenceOpen.firstMatch(
                in: line, range: NSRange(0..<nsLine.length)
            ) else { continue }
            let fence = nsLine.substring(with: match.range(at: 1))
            let gap = nsLine.substring(with: match.range(at: 2))
            let tag = nsLine.substring(with: match.range(at: 3))
            let rest = nsLine.substring(with: match.range(at: 4))
            let key = tag.lowercased()
            if let mapped = rawLanguageAliases[key] {
                lines[i] = fence + mapped + rest
            } else if !gap.isEmpty, knownRawLanguages.contains(key) {
                lines[i] = fence + tag + rest
            }
            // A second backtick run later in the line means the block opens
            // and closes on this line ("```rust let x = 1```") — stay outside.
            if !rest.contains("`") {
                fenceRun = fence.filter { $0 == "`" }.count
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Auto-Fix Broken Syntax (.note)

    /// Proactively repairs broken or incomplete syntax in `.note` files prior to compilation,
    /// ensuring quick compilation without having to fail and recompile through watch cycles.
    ///
    /// Fixes:
    /// - Unclosed code fences (odd count of ```) -> closed at EOF
    /// - Unclosed single-line math expressions ($... without closing $) -> closed with $
    /// - Dangling exponents and subscripts in math ($...^$ or $..._$) -> completed with ^{} or _{}
    /// - Dangling binary / relational operators before closing $ -> completed with ""
    /// - Unbalanced delimiters within math blocks (parentheses, brackets, braces)
    /// - Trailing lone carets (^) in content mode outside math -> escaped as \^
    /// - Trailing bare hash (#) in content mode -> escaped as \#
    nonisolated static func autoFixBrokenNoteSyntax(_ source: String) -> String {
        guard !source.isEmpty else { return source }
        
        var lines = source.components(separatedBy: "\n")
        
        // 1. Check code fences: if count of triple-backtick lines is odd, close at EOF
        var inCodeBlock = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
            }
        }
        if inCodeBlock {
            lines.append("```")
        }

        // 1b. Join a construct opener whose block brace lands on the next line
        // (`#show heading…: it =>` ⏎ `{`). Typst ends a statement at a newline
        // — only an unclosed bracket continues one — so a trailing `=>` or `=`
        // is a hard "expected expression" error even though the intent is
        // obvious. Rejoin opener + brace into the one-line form Typst accepts;
        // everything between the braces keeps its lines and indentation.
        var joined: [String] = []
        var joinFence = false
        var joinIndex = 0
        while joinIndex < lines.count {
            let line = lines[joinIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                joinFence.toggle()
                joined.append(line)
                joinIndex += 1
                continue
            }
            if !joinFence, joinIndex + 1 < lines.count,
               Self.isBlockOpenerLine(trimmed),
               lines[joinIndex + 1].trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                // Keep the brace line's full content: `{ x * 2 }` on one line
                // must come up whole, not lose its body.
                let braceLine = lines[joinIndex + 1].trimmingCharacters(in: .whitespaces)
                joined.append("\(trimmed) \(braceLine)")
                joinIndex += 2  // the brace line has moved up into the opener
                continue
            }
            joined.append(line)
            joinIndex += 1
        }
        lines = joined

        // 2. Process line by line for inline math and syntax fixes outside code blocks
        var currentlyInCode = false
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                currentlyInCode.toggle()
                continue
            }
            if currentlyInCode { continue }
            
            var line = lines[i]

            // Inline code spans are blanked (length-preserving) before any math
            // heuristics run: a lone `$` inside `code` (e.g. the register `$2002`)
            // is not unclosed math, and code contents (`_`, `=`, `\` …) must not
            // veto the currency heuristic for real dollars elsewhere on the line.
            let codeRanges = Self.inlineCodeRanges(in: line)
            let maskedLine = Self.lineMaskingCodeSpans(line, ranges: codeRanges)
            let nsMasked = maskedLine as NSString

            // Fix unclosed single-line math $...
            // Count unescaped $ signs outside code spans (UTF-16 offsets, matching NSRegularExpression)
            var dollarIndices: [Int] = []
            for j in 0..<nsMasked.length {
                if nsMasked.character(at: j) == 0x24 { // $
                    let isEscaped = (j > 0 && nsMasked.character(at: j - 1) == 0x5C) // backslash
                    if !isEscaped {
                        dollarIndices.append(j)
                    }
                }
            }

            // If odd number of $, close the math — unless every `$` on the line is
            // a literal token: a register/address (`$FF4F`, `$DC10`, `$3DF8`) or a
            // currency amount (`$5`, with no math operators on the line). Closing
            // those would pair two literal dollars into a bogus math region that
            // swallows the rest of the line; the delimiting pass escapes them as
            // literal text instead. Register tokens start with a hex letter
            // (`$FF4F`), so decimal-only detection is not enough; and the single
            // hex char of a math variable (`$B=…`) must NOT read as a register.
            if dollarIndices.count % 2 != 0 {
                // `_` only counts as a math operator when it is not part of an
                // identifier (`TASK_FADE_MIRROR`); otherwise a filename vetoes the
                // literal-token heuristic for lines full of `$XX` hex tokens.
                let hasMathSubscript = maskedLine.range(
                    of: "(?<![A-Za-z0-9])_|_(?![A-Za-z0-9])", options: .regularExpression
                ) != nil
                let hasMathOperators = maskedLine.contains("=") || maskedLine.contains("^")
                    || maskedLine.contains("\\") || hasMathSubscript
                let allLiteral = dollarIndices.allSatisfy { idx in
                    Self.isRegisterDollarToken(nsMasked, at: idx)
                        || (idx + 1 < nsMasked.length
                            && Self.isHexDigit(nsMasked.character(at: idx + 1))
                            && !hasMathOperators)
                }
                if !allLiteral {
                    line.append("$")
                }
            }

            // Fix dangling ^ or _ or binary operators inside math blocks: $...$ or $$...$$
            let nsLine = line as NSString
            let matches = CompilerRegex.mathBlock.matches(in: line, options: [], range: NSRange(0..<nsLine.length))
            var fixedLine = line
            for m in matches.reversed() {
                // Never "fix" content inside inline code spans (`` `$x +$` `` is
                // the user's code, not broken math).
                if codeRanges.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                    continue
                }
                let mathContent = nsLine.substring(with: m.range(at: 1))
                var fixedMath = mathContent
                
                // Replace trailing ^ or _ before end of math: e.g. "k=1^" -> "k=1^{}"
                fixedMath = CompilerRegex.trailSupSub.stringByReplacingMatches(in: fixedMath, options: [], range: NSRange(0..<fixedMath.utf16.count), withTemplate: "$1{}")
                
                // Replace trailing binary/relational operators before end of math: e.g. "x + " -> "x + \"\""
                fixedMath = CompilerRegex.trailOp.stringByReplacingMatches(in: fixedMath, options: [], range: NSRange(0..<fixedMath.utf16.count), withTemplate: "$1 \"\"")
                
                // Replace trailing lone backslash
                if fixedMath.hasSuffix("\\") && !fixedMath.hasSuffix("\\\\") {
                    fixedMath.removeLast()
                }
                
                // Check balanced delimiters inside this math block: ( ), [ ], { }
                var parenCount = 0
                var bracketCount = 0
                var braceCount = 0
                for c in fixedMath {
                    if c == "(" { parenCount += 1 }
                    else if c == ")" { parenCount = max(0, parenCount - 1) }
                    else if c == "[" { bracketCount += 1 }
                    else if c == "]" { bracketCount = max(0, bracketCount - 1) }
                    else if c == "{" { braceCount += 1 }
                    else if c == "}" { braceCount = max(0, braceCount - 1) }
                }
                if braceCount > 0 { fixedMath.append(String(repeating: "}", count: braceCount)) }
                if bracketCount > 0 { fixedMath.append(String(repeating: "]", count: bracketCount)) }
                if parenCount > 0 { fixedMath.append(String(repeating: ")", count: parenCount)) }
                
                if fixedMath != mathContent {
                    let fullMatchRange = m.range
                    let delimiter = (nsLine.substring(with: fullMatchRange).hasPrefix("$$")) ? "$$" : "$"
                    let replacement = "\(delimiter)\(fixedMath)\(delimiter)"
                    fixedLine = (fixedLine as NSString).replacingCharacters(in: fullMatchRange, with: replacement)
                }
            }
            line = fixedLine
            
            // Content mode fixes:
            // Escape lone trailing ^ at end of line (outside math):
            line = CompilerRegex.loneCaret.stringByReplacingMatches(in: line, options: [], range: NSRange(0..<line.utf16.count), withTemplate: "\\\\^")
            
            // Bare trailing # at end of line:
            line = CompilerRegex.bareHash.stringByReplacingMatches(in: line, options: [], range: NSRange(0..<line.utf16.count), withTemplate: "\\\\#")
            
            lines[i] = line
        }
        
        return lines.joined(separator: "\n")
    }

    /// True for ASCII hex digits (`0-9`, `A-F`, `a-f`), used to recognize
    /// register-style `$XX` tokens (`$4017`, `$FF4F`, `$DC10`) as literal text
    /// rather than the start of a math region.
    nonisolated static func isHexDigit(_ c: unichar) -> Bool {
        (0x30...0x39).contains(c) || (0x41...0x46).contains(c) || (0x61...0x66).contains(c)
    }

    /// True when the `$` at `idx` begins a register/address literal: at least
    /// two hex digits followed by a non-alphanumeric boundary (`$FF4F`, `$DC10`,
    /// `$3DF8/`, `$00,`). The two-digit minimum keeps a math variable (`$B=…`,
    /// `$E = mc^2$`) from being mistaken for a register.
    nonisolated static func isRegisterDollarToken(_ s: NSString, at idx: Int) -> Bool {
        guard idx >= 0, idx < s.length, s.character(at: idx) == 0x24 else { return false }
        var k = idx + 1
        var run = 0
        while k < s.length, isHexDigit(s.character(at: k)) { run += 1; k += 1 }
        guard run >= 2 else { return false }
        guard k < s.length else { return true }
        let next = s.character(at: k)
        let isAlnum = (0x30...0x39).contains(next) || (0x41...0x5A).contains(next) || (0x61...0x7A).contains(next)
        return !isAlnum
    }

    /// True when `trimmed` is a construct opener whose block brace may sit on
    /// the next line: a closure arrow (`it =>`) or a bare assignment `=`
    /// directly after a value (`#let x =`, `#let f = (n) =`). A value head is
    /// required so a `===` setext underline, a `==` comparison tail or an
    /// empty line never joins.
    nonisolated static func isBlockOpenerLine(_ trimmed: String) -> Bool {
        if trimmed.hasSuffix("=>") {
            let head = trimmed.dropLast(2)
            return head.contains { $0.isLetter || $0.isNumber }
        }
        if trimmed.hasSuffix("=") {
            var head = trimmed.dropLast()
            while let last = head.last, last == " " || last == "\t" { head = head.dropLast() }
            guard let last = head.last else { return false }
            return last.isLetter || last.isNumber
                || last == ")" || last == "]" || last == "\"" || last == "}"
        }
        return false
    }

    /// Ranges of inline code spans (`` `…` ``) in a single line, using the same
    /// matching-backtick-run rule as the sanitizer and `delimitImproperOperators`.
    nonisolated static func inlineCodeRanges(in line: String) -> [NSRange] {
        let ns = line as NSString
        guard ns.length > 0 else { return [] }
        return CompilerRegex.codeSpan.matches(in: line, options: [], range: NSRange(0..<ns.length)).map { $0.range }
    }

    /// Returns a copy of `line` where every character inside `ranges` is replaced by a
    /// space (newlines preserved). The result has exactly the same UTF-16 length, so
    /// offsets in the masked string address the original line.
    nonisolated static func lineMaskingCodeSpans(_ line: String, ranges: [NSRange]) -> String {
        let ns = line as NSString
        guard ns.length > 0 else { return line }
        var chars: [unichar] = (0..<ns.length).map { ns.character(at: $0) }
        for r in ranges {
            let end = min(r.location + r.length, chars.count)
            guard r.location < end else { continue }
            for i in r.location..<end where chars[i] != 0x0A {
                chars[i] = 0x20
            }
        }
        return NSString(characters: chars, length: chars.count) as String
    }

    // MARK: - Improper Operator Delimiting (.note)

    /// For hybrid `.note` files, locates Typst operator characters (`@ # $ < >`)
    /// that are NOT used as valid Typst syntax and delimits each with a backslash
    /// so the parser doesn't have to guess their meaning (and silently mis-render).
    ///
    /// Left untouched (i.e. legitimate Typst / Markdown that we must not break):
    ///   - `@label`            references (an `@` followed by an identifier that
    ///                          isn't glued to a preceding word / email)
    ///   - `#word`, `#"…"`, `#(…)`, `#{…}`, `#123`   top-level code expressions
    ///   - `$ … $`             math (masked out before scanning)
    ///   - `<label>`, `<tag>`, `</tag>`, `<!--…-->`  labels & HTML (handled later)
    ///   - anything inside inline/fenced code spans or math regions (masked out)
    ///   - string literals on code lines (`#link("mailto:a@b.com")`) — a `\@`
    ///     there would be an invalid string escape, so they are masked out
    ///
    /// Each source line that needed delimiting produces a single `.warning`
    /// `TypstError` (1-based line numbers refer to the user's original file). The
    /// returned `output` is meant to feed into `sanitizeMarkdownToTypst`, whose
    /// hybrid escape rules are idempotent (`(?<!\\)`) so they won't double-escape.
    nonisolated static func delimitImproperOperators(_ source: String) -> (output: String, warnings: [TypstError]) {
        let ns = source as NSString
        let length = ns.length
        guard length > 0 else { return (source, []) }

        // 1. Build a mask of the same length where protected regions (code spans
        //    and math) are blanked to spaces — newlines preserved — so operator
        //    scanning can't match inside them while every line offset stays exact.
        var masked: [unichar] = Array(repeating: 0, count: length)
        for i in 0..<length { masked[i] = ns.character(at: i) }
        func blank(_ r: NSRange) {
            guard r.location != NSNotFound, r.location < length, r.length > 0 else { return }
            let end = min(r.location + r.length, length)
            for i in r.location..<end where masked[i] != 0x0A { masked[i] = 0x20 }
        }
        // Inline / fenced code spans with matching backtick runs (same pattern the
        // sanitizer uses).
        CompilerRegex.codeSpan.enumerateMatches(in: source, options: [], range: NSRange(0..<length)) { m, _, _ in
            if let m = m { blank(m.range) }
        }
        // Math regions: $$…$$, $…$, \[…\], \(…\).
        CompilerRegex.mathRegion.enumerateMatches(in: source, options: [], range: NSRange(0..<length)) { m, _, _ in
            if let m = m { blank(m.range) }
        }
        // Live Typst code regions: a line whose first non-space character is
        // `#` opens a region that continues while its bracket depth is unclosed
        // (the same scanner the hybrid sanitizer uses to extract them). The
        // operators inside are Typst code — `parts.len() >= 3`, comparison
        // chains, ref targets — and MUST NOT be escaped: `\>` is invalid in
        // code mode and one such escape cascades into thousands of compile
        // errors (which is also what floods the stderr pipe on Save).
        let lineStarts = Self.lineStartOffsets(in: ns)
        for span in AICompletionService.typstRegionLineSpans(in: source) {
            guard span.start < lineStarts.count else { continue }
            let start = lineStarts[span.start]
            let end: Int
            if span.end + 1 < lineStarts.count {
                end = lineStarts[span.end + 1] - 1          // up to (excluding) that "\n"
            } else {
                end = length
            }
            blank(NSRange(location: start, length: end - start))
        }
        // Typst string literals: a backslash inside "…" is a STRING escape, so
        // auto-inserting `\@` there would be an invalid escape sequence that
        // breaks the compile (`#link("mailto:a@b.com")`). When a line carries a
        // code expression — an unescaped `#` before its first quote — mask the
        // quoted interiors like code: operators inside them are neither flagged
        // nor escaped. Prose quotes (no `#` before the first quote, or a `#`
        // that only appears after it, like She said "#hi") keep getting scanned
        // so stray operators in quoted prose are still auto-escaped. The quote
        // characters themselves stay visible so the `#"…"` hash-continuation
        // check keeps working.
        var stringLineStart = 0
        while stringLineStart < length {
            var lineEnd = stringLineStart
            while lineEnd < length, masked[lineEnd] != 0x0A { lineEnd += 1 }

            // First unescaped `#` and `"` on the line (code spans and math are
            // already blanked, so their quotes never open a string here).
            var hashLoc: Int?
            var quoteLoc: Int?
            var i = stringLineStart
            while i < lineEnd {
                let c = masked[i]
                if c == 0x5C { i += 2; continue }                    // escaped char (\")
                if c == 0x23 { hashLoc = hashLoc ?? i }              // '#'
                if c == 0x22 { quoteLoc = quoteLoc ?? i }            // '"'
                i += 1
            }

            if let hash = hashLoc, let firstQuote = quoteLoc, hash < firstQuote {
                var inString = false
                var stringStart = 0
                var j = firstQuote
                while j < lineEnd {
                    let c = masked[j]
                    if c == 0x5C { j += 2; continue }
                    if c == 0x22 {
                        if inString {
                            blank(NSRange(location: stringStart + 1, length: j - stringStart - 1))
                            inString = false
                        } else {
                            inString = true
                            stringStart = j
                        }
                    }
                    j += 1
                }
                // An unterminated span (odd quote count) is left unmasked —
                // typst has no multi-line strings, so it was never a string.
            }
            stringLineStart = lineEnd + 1
        }
        let maskedString = NSString(characters: masked, length: length) as String

        // 2. Precompute a line number for every character index (O(1) lookup later).
        var lineOf: [Int] = Array(repeating: 1, count: length + 1)
        var running = 1
        for i in 0..<length {
            lineOf[i] = running
            if masked[i] == 0x0A { running += 1 }
        }
        lineOf[length] = running

        // 3. Character-class helpers (ASCII code points).
        func charAt(_ i: Int) -> unichar? { (i >= 0 && i < length) ? masked[i] : nil }
        func isDigit(_ x: unichar?) -> Bool { guard let x = x else { return false }; return (0x30...0x39).contains(x) }
        func isAlpha(_ x: unichar?) -> Bool { guard let x = x else { return false }; return (0x41...0x5A).contains(x) || (0x61...0x7A).contains(x) }
        func isAlnum(_ x: unichar?) -> Bool { isAlpha(x) || isDigit(x) }
        func isIdentStart(_ x: unichar?) -> Bool { x == 0x5F || isAlpha(x) }                 // [_A-Za-z]
        func isHashContinuation(_ x: unichar?) -> Bool {                                       // valid after '#'
            guard let x = x else { return false }
            if isAlnum(x) || x == 0x5F { return true }                                         // word / number
            return x == 0x22 || x == 0x7B || x == 0x28                                         // " { (
        }
        func isTagStart(_ x: unichar?) -> Bool {                                               // valid after '<'
            guard let x = x else { return false }
            return isAlpha(x) || x == 0x2F || x == 0x21                                        // letter / !
        }
        func isTagEndPrev(_ x: unichar?) -> Bool {                                             // valid before '>'
            guard let x = x else { return false }
            if isAlnum(x) || x == 0x5F { return true }                                         // name char
            return x == 0x2D || x == 0x2F || x == 0x22 || x == 0x27 || x == 0x3D              // - / " ' =
        }
        // An ATX Markdown heading (`#`, `##` … followed by a space, at line start,
        // optionally inside a blockquote). The sanitizer converts these to Typst `=`
        // headings, so every `#` of the heading run must reach it unescaped.
        func isMarkdownHeadingStart(_ loc: Int) -> Bool {
            var i = loc - 1
            // Skip back over the rest of the heading run, then any blockquote/space prefix.
            while i >= 0, let c = charAt(i), c == 0x23 { i -= 1 }                              // '#'
            while i >= 0, let c = charAt(i), c == 0x20 || c == 0x09 || c == 0x3E { i -= 1 }    // space, tab, '>'
            if i >= 0, let c = charAt(i), c != 0x0A { return false }                           // not at line start
            var j = loc
            while let c = charAt(j), c == 0x23 { j += 1 }                                      // run of '#'
            guard let after = charAt(j) else { return true }
            return after == 0x20 || after == 0x09
        }
        // A Markdown blockquote marker: `>` at line start (optionally nested after
        // other `>`), which the sanitizer's heading/list rules recognize as a prefix.
        func isBlockquoteMarker(_ loc: Int) -> Bool {
            var i = loc - 1
            while i >= 0, let c = charAt(i), c == 0x20 || c == 0x09 || c == 0x3E { i -= 1 }    // space, tab, '>'
            if i >= 0, let c = charAt(i), c != 0x0A { return false }
            guard let next = charAt(loc + 1) else { return true }                              // bare '>' line
            return next == 0x20 || next == 0x09 || next == 0x0A
        }

        // 4. Enumerate every unescaped operator and classify it against its context.
        // `silent` marks an operator that is escaped so it renders literally but
        // must not raise an advisory warning: ordinary prose punctuation (`<`,
        // `>`, `@`, and register/address `$`). The escape is transparent (the
        // user sees the same characters), so warning about it is noise for
        // technical notes. `#` and currency `$` stay noisy because they are more
        // likely to be intended Typst.
        var improper: [(loc: Int, op: Character, silent: Bool)] = []
        for m in CompilerRegex.operatorRe.matches(in: maskedString, options: [], range: NSRange(0..<length)) {
            let loc = m.range.location
            guard loc < length else { continue }
            let u = masked[loc]
            let prev = charAt(loc - 1)
            let next = charAt(loc + 1)
            let improperNow: Bool
            switch u {
            case 0x40: // @  — must begin a reference (not be glued to a word/email)
                improperNow = isAlnum(prev) || !isIdentStart(next)
            case 0x23: // #  — must be the start of a code expression
                improperNow = !isHashContinuation(next) && !isMarkdownHeadingStart(loc)
            case 0x24: // $  — any leftover $ is stray once math is masked
                improperNow = true
            case 0x3C: // <  — must open a label / HTML tag
                improperNow = !isTagStart(next)
            case 0x3E: // >  — must close a label / HTML tag (or open a blockquote)
                improperNow = !isTagEndPrev(prev) && !isBlockquoteMarker(loc)
            default:
                improperNow = false
            }
            if improperNow, let scalar = UnicodeScalar(u) {
                let silent: Bool
                switch u {
                case 0x24: silent = Self.isRegisterDollarToken(maskedString as NSString, at: loc)
                case 0x3C, 0x3E, 0x40: silent = true
                default: silent = false
                }
                improper.append((loc, Character(scalar), silent))
            }
        }
        guard !improper.isEmpty else { return (source, []) }

        // 5. Group delimitations per source line → one warning per line.
        var byLine: [Int: [Character]] = [:]
        var lineOrder: [Int] = []
        for (loc, op, silent) in improper where !silent {
            let ln = lineOf[loc]
            if byLine[ln] == nil { lineOrder.append(ln) }
            var arr = byLine[ln] ?? []
            if !arr.contains(op) { arr.append(op) }
            byLine[ln] = arr
        }
        let warnings: [TypstError] = lineOrder.sorted().map { ln in
            let ops = (byLine[ln] ?? []).map { String($0) }.joined(separator: ", ")
            let msg = "Auto-escaped \(ops) — not valid Typst here, so the parser would " +
                      "guess its meaning. Use proper Typst syntax or escape it yourself (e.g. \\@)."
            return TypstError(line: ln, message: msg, severity: .warning)
        }

        // 6. Apply the backslash escapes to the original source (right-to-left so
        //    earlier insert locations aren't shifted by later ones).
        let mutable = NSMutableString(string: source)
        for (loc, _, _) in improper.sorted(by: { $0.loc > $1.loc }) {
            mutable.insert("\\", at: loc)
        }
        return ((mutable as String), warnings)
    }

    // --- Export Functions ---
    
    nonisolated static func exportDestinationURL(for format: String, requested: URL) -> URL {
        let normalizedFormat = format.lowercased()
        let validImageFormats = Set(["png", "svg"])
        guard validImageFormats.contains(normalizedFormat) else {
            return requested
        }

        let templateName = "{0p}"
        let baseName = requested.deletingPathExtension().lastPathComponent
        if baseName.contains("{p}") || baseName.contains("{0p}") {
            return requested
        }

        let directory = requested.deletingLastPathComponent()
        let pagePatternURL = directory.appendingPathComponent("\(baseName)-\(templateName).\(normalizedFormat)")
        return pagePatternURL
    }

    nonisolated static func firstGeneratedExportURL(for templateURL: URL) -> URL? {
        let directory = templateURL.deletingLastPathComponent()
        let templateName = templateURL.deletingPathExtension().lastPathComponent
        let extensionName = templateURL.pathExtension.lowercased()
        // "out-{0p}" → stem "out": typst writes out-1.png, out-01.png, …
        var stem = templateName
            .replacingOccurrences(of: "{0p}", with: "")
            .replacingOccurrences(of: "{p}", with: "")
        if stem.hasSuffix("-") { stem.removeLast() }

        guard let fileEnumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }

        let matches = fileEnumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == extensionName }
            .filter { url in
                let name = url.deletingPathExtension().lastPathComponent
                if name == stem { return true }
                guard name.hasPrefix(stem + "-") else { return false }
                let page = name.dropFirst(stem.count + 1)
                return !page.isEmpty && page.allSatisfy(\.isNumber)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        return matches.first
    }
    
    // MARK: - Export as Standard Typst

    /// Outcome of `exportStandardTypst`.
    struct StandardTypstExport {
        var success: Bool
        /// Every file written: the document, plus the bridge and WASM core
        /// when runtime calculator functions remain.
        var files: [URL] = []
        /// What was done, for the user (inlined values, sidecars, …).
        var notes: [String] = []
        var error: String?
    }

    /// Writes a version of the document that compiles in *stock* Typst.
    ///
    /// - Markdown / Note sources are converted to Typst (a note's helper
    ///   preamble is inlined, so it no longer depends on TypstEdit).
    /// - Calculator static compilation runs: literal-bound loops are
    ///   specialised and every `#calc(…)` / `#calc-table(…)` becomes a value.
    /// - What must still run at compile time (`plot`, `BesselJ`, `calc-call`)
    ///   keeps working through Typst's standard plugin API: the bridge module
    ///   and the WASM core are written next to the document and imported.
    ///   If only `calc-param` remains it is inlined (it is the identity).
    /// - The result is verified by compiling it with the plain `typst` binary,
    ///   with none of TypstEdit's preview preambles.
    func exportStandardTypst(content: String, fileExtension: String, destination: URL) async -> StandardTypstExport {
        var export = StandardTypstExport(success: false)
        let ext = fileExtension.lowercased()
        let directory = destination.deletingLastPathComponent()
        var text = content

        if ext == "md" || ext == "note" {
            let isHybrid = ext == "note"
            let prepared = isHybrid ? Self.autoFixBrokenNoteSyntax(text) : text
            let aiService = AICompletionService.shared
            text = await Task.detached {
                let delimited = isHybrid ? Self.delimitImproperOperators(prepared).output : prepared
                return aiService.sanitizeMarkdownToTypst(delimited, isHybrid: isHybrid)
            }.value
            if isHybrid { text = Self.notePreamble + text }
            export.notes.append(isHybrid ? "Converted the note to Typst and inlined its helper definitions."
                                         : "Converted the Markdown to Typst.")
        }

        let pipeline = await applyCalcPipeline(text, fileExtension: ext, bridgeDirectory: directory, prependImport: false)
        text = pipeline.content
        let remaining = CalcFeatureScanner.scan(text)
        if remaining.usesCalcCall || remaining.usesCalcTable {
            let reasons = pipeline.diagnostics.map { "line \($0.line.map(String.init) ?? "?"): \($0.message)" }
            export.error = "Some calculator calls could not be evaluated, so the document cannot be made standard Typst:\n"
                + (reasons.isEmpty ? "(the CAS helper may be missing — see Docs/calculator.md)" : reasons.joined(separator: "\n"))
            return export
        }
        if pipeline.summary.needsResolution {
            export.notes.append("Evaluated the #calc / #calc-table calls with the calculator and inserted their values.")
        }

        if remaining.usesBridge {
            guard CalcPlugin.install(into: directory) else {
                export.error = "The document uses runtime calculator functions (\(remaining.bridgeNames.joined(separator: ", "))), but the WASM core is not built. Run Tools/calc-plugin/build_calc_plugin.sh."
                return export
            }
            text = CalcPlugin.importStatement + text
            export.files.append(directory.appendingPathComponent(CalcPlugin.bridgeFileName))
            export.files.append(directory.appendingPathComponent(CalcPlugin.wasmFileName))
            export.notes.append("Uses \(remaining.bridgeNames.joined(separator: ", ")) at compile time: wrote \(CalcPlugin.bridgeFileName) and \(CalcPlugin.wasmFileName) next to the file. Keep the three files together; stock Typst loads the WASM core through its plugin API.")
        } else if remaining.usesCalcParam {
            // calc-param is the identity function: inline it.
            text = text.replacingOccurrences(of: #"(?<![A-Za-z0-9_.-])calc-param\s*\("#, with: "(", options: .regularExpression)
            export.notes.append("Inlined calc-param(…) parameters as plain values.")
        }

        do {
            try text.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            export.error = "Could not write \(destination.lastPathComponent): \(error.localizedDescription)"
            return export
        }
        export.files.insert(destination, at: 0)

        // Verify with the plain typst binary: no preambles, no shadow file.
        guard let typstPath = resolveTypstPath() else {
            export.success = true
            export.notes.append("Not verified: the typst binary was not found.")
            return export
        }
        let check = FileManager.default.temporaryDirectory.appendingPathComponent("standard-typst-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: check) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        process.arguments = ["compile", destination.path, check.path, "--root", directory.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
            // Drain concurrently with the wait: a broken document can emit
            // megabytes of diagnostics, enough to fill the pipe buffer and
            // deadlock a wait-then-read sequence.
            let result = BlockingProcess.run(process, draining: [pipe.fileHandleForReading])
            if result.status == 0 {
                export.success = true
                export.notes.append("Verified: the exported file compiles with the standard typst compiler.")
            } else {
                export.error = "The exported file was written, but it does not compile with standard Typst:\n"
                    + result.output
            }
        } catch {
            export.error = "Could not run typst to verify the export: \(error.localizedDescription)"
        }
        return export
    }

    // MARK: - Calculator static compilation (shared by preview and every export)

    /// Outcome of `applyCalcPipeline`.
    struct CalcPipelineResult {
        /// The content with loops specialised, `#calc`/`#calc-table` replaced by
        /// values and (when requested) the bridge import prepended.
        var content: String
        /// Features found in the *input* (before resolution).
        var summary: CalcFeatureSummary
        var diagnostics: [TypstError]
        var parameters: [CalculatorStoredVariable]
        /// Runtime bridge functions remain and the import was prepended.
        var bridgeImported: Bool
        /// Runtime bridge functions remain but the WASM core is not built.
        var bridgeMissing: Bool
        /// Loop specialisation changed the line count (diagnostics need a line map).
        var lineCountChanged: Bool
    }

    /// The one implementation of the calculator's "static compilation" step:
    ///
    /// 1. specialise literal-bound loops that call the CAS,
    /// 2. evaluate every `#calc(…)` / `#calc-table(…)` with the CAS and splice
    ///    the values in as literals,
    /// 3. if runtime functions remain (`plot`, `BesselJ`, `calc-call`,
    ///    `calc-param`…), install the bridge + WASM core into `bridgeDirectory`
    ///    and prepend the import.
    ///
    /// The live preview, PDF export, Markdown/Note exports, image exports and
    /// "Export as Standard Typst" all call this, so they cannot drift apart.
    func applyCalcPipeline(
        _ content: String,
        fileExtension: String,
        bridgeDirectory: URL,
        prependImport: Bool = true
    ) async -> CalcPipelineResult {
        let summary = CalcFeatureScanner.scan(content)
        var result = CalcPipelineResult(
            content: content, summary: summary, diagnostics: [], parameters: [],
            bridgeImported: false, bridgeMissing: false, lineCountChanged: false)
        guard summary.usesAny else {
            // The document no longer uses calculator features: its cached
            // results are unreachable, so release them and the stored
            // parameters rather than keeping both for the window's lifetime.
            if !calcResolutionCache.isEmpty {
                calcResolutionCache.removeAll()
                calcStoredParameters = []
            }
            return result
        }

        if summary.needsResolution {
            let resolved = await CalcResolutionPass.resolve(
                content,
                fileExtension: fileExtension,
                settings: CalcResolutionSettings.fromDefaults(),
                cache: calcResolutionCache,
                storedParameters: calcStoredParameters)
            calcResolutionCache = resolved.cache
            if calcResolutionCache.count > Self.maxCalcCacheEntries {
                // Over budget: the cache only saves CAS round-trips, so
                // dropping it costs a few evaluations and nothing else.
                calcResolutionCache.removeAll()
            }
            calcStoredParameters = resolved.storedParameters
            result.lineCountChanged = Self.lineCount(of: resolved.outcome.output) != Self.lineCount(of: content)
            result.content = resolved.outcome.output
            result.diagnostics = resolved.outcome.diagnostics
            result.parameters = resolved.outcome.parameters
        }

        if summary.needsBridge && prependImport {
            if CalcPlugin.install(into: bridgeDirectory) {
                result.content = CalcPlugin.importStatement + result.content
                result.bridgeImported = true
            } else {
                result.bridgeMissing = true
            }
        }
        return result
    }

    nonisolated static func lineCount(of text: String) -> Int {
        text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
    }

    /// UTF-16 offsets where each line of `text` starts (line 0 starts at 0).
    /// `components(separatedBy:)`-style indices in one pass over the NSString,
    /// for mapping line indices (e.g. from `typstRegionLineSpans`) to ranges.
    nonisolated static func lineStartOffsets(in text: NSString) -> [Int] {
        var offsets: [Int] = [0]
        var index = 0
        while index < text.length {
            if text.character(at: index) == 0x0A { offsets.append(index + 1) }
            index += 1
        }
        return offsets
    }

    func export(sourceURL: URL, outputURL: URL, format: String, projectRoot: URL? = nil) async -> (success: Bool, error: String?) {
        guard let typstPath = resolveTypstPath() else {
            return (false, "Error: 'typst' executable not found.")
        }
        
        let effectiveOutputURL = Self.exportDestinationURL(for: format, requested: outputURL)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        
        var arguments = ["compile", sourceURL.path, effectiveOutputURL.path, "--format", format]
        
        // Pass root if available
        if let root = projectRoot {
            arguments.append(contentsOf: ["--root", root.path])
            process.currentDirectoryURL = root
        }
        
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        
        do {
            try process.run()
            // Drain concurrently: a large diagnostic dump would otherwise fill
            // the pipe buffer and block typst while we wait for it to exit.
            let result = BlockingProcess.run(process, draining: [pipe.fileHandleForReading])
            let output = result.output
            
            if result.status != 0 {
                print("[TYPST-EXPORT-ERROR]: \(output)")
                if output.contains("error:") {
                    parseErrors(from: output, sourceFileName: sourceURL.lastPathComponent)
                }
                return (false, output.isEmpty ? "Unknown Typst error (exit code \(result.status))" : output)
            }
            
            print("[TYPST-EXPORT-SUCCESS]: \(effectiveOutputURL.lastPathComponent)")
            return (true, nil)
        } catch {
            print("[TYPST-EXPORT] Failed to run: \(error)")
            return (false, error.localizedDescription)
        }
    }

    /// Exports note/markdown content to PNG, SVG, or PDF by preprocessing Markdown,
    /// adding necessary preambles, resolving images, and applying fallback fixes on error.
    func exportFormatted(content: String, fileExtension: String, originalFileURL: URL, outputURL: URL, format: String, projectRoot: URL? = nil) async -> (success: Bool, error: String?) {
        guard let typstPath = resolveTypstPath() else {
            return (false, "Error: 'typst' executable not found.")
        }
        
        let preferredDirectory = originalFileURL.deletingLastPathComponent()
        let tempDir = ensureTempDirectory(in: preferredDirectory)
        let tempID = UUID().uuidString
        let sourceURL = tempDir.appendingPathComponent(".export-\(tempID.prefix(8)).typ")
        
        var finalContent = content
        let ext = fileExtension.lowercased()
        let isHybrid = (ext == "note")
        
        if isHybrid {
            finalContent = Self.autoFixBrokenNoteSyntax(finalContent)
        }
        
        if ext == "md" || ext == "note" {
            let aiService = AICompletionService.shared
            let textToProcess = finalContent
            finalContent = await Task.detached {
                let input = isHybrid ? Self.delimitImproperOperators(textToProcess).output : textToProcess
                return aiService.sanitizeMarkdownToTypst(input, isHybrid: isHybrid)
            }.value
        }
        if ext == "note" {
            finalContent = Self.notePreamble + finalContent
        }

        // Match the live preview's "Keep with Next" behavior so exported
        // pages break in the same places.
        if GeneralSettingsManager.shared.keepWithNextHeadings {
            finalContent = Self.keepWithNextPreamble + finalContent
        }

        // Same missing-font substitution the live preview applies (shadow-only).
        finalContent = Self.substituteMissingFonts(finalContent)

        // Same raw-language normalization the live preview applies (shadow-only),
        // so exported code blocks highlight like the preview does.
        finalContent = Self.normalizeRawLanguages(finalContent)

        // Same calculator static compilation as the live preview and PDF
        // export: loops, #calc values and the bridge (into the temp dir the
        // export compiles from).
        finalContent = await applyCalcPipeline(finalContent, fileExtension: ext, bridgeDirectory: tempDir).content

        finalContent = await self.rewriteRelativeImports(in: finalContent, sourceDirectory: preferredDirectory, tempDirectory: tempDir)
        
        // The shadow may sit outside the project (OS-temp storage): widen the
        // root to contain it and make `/…` references relative so they still
        // point at project files.
        let compileRoot = Self.compileRoot(projectRoot: preferredDirectory, shadowDirectory: tempDir)
        if compileRoot.isWidened {
            finalContent = Self.rewriteRootAbsolutePaths(
                in: finalContent, projectRoot: preferredDirectory, shadowDirectory: tempDir)
        }
        finalContent = await resolveWebImages(
            in: finalContent, projectRoot: preferredDirectory, shadowDirectory: tempDir)
        
        do {
            try finalContent.write(to: sourceURL, atomically: true, encoding: .utf8)
        } catch {
            return (false, "Failed to write temp export source: \(error.localizedDescription)")
        }
        
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        
        let effectiveRoot = compileRoot.url
        let effectiveOutputURL = Self.exportDestinationURL(for: format, requested: outputURL)
        var arguments = ["compile", sourceURL.path, effectiveOutputURL.path, "--format", format]
        arguments.append(contentsOf: ["--root", effectiveRoot.path])
        
        var cleanFallbackAttempts: [Int: Int] = [:]
        var iteration = 0
        var lastOutput = ""
        
        while iteration < 3 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: typstPath)
            process.currentDirectoryURL = effectiveRoot
            process.arguments = arguments
            
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = pipe
            
            do {
                try process.run()
                // Drain concurrently with the wait: a broken document's
                // diagnostic dump can exceed the pipe buffer and deadlock a
                // wait-then-read sequence (the Save freeze).
                let result = BlockingProcess.run(process, draining: [pipe.fileHandleForReading])
                lastOutput = result.output
                
                if result.status == 0 {
                    return (true, nil)
                }
                
                if ext == "note" || ext == "md" {
                    let rawLines = Self.parseRawErrorLines(from: lastOutput, onlyInFile: sourceURL.lastPathComponent)
                    if !rawLines.isEmpty {
                        let modified = applyFallbackFix(to: sourceURL, rawErrorLines: rawLines, attempts: &cleanFallbackAttempts, isHybrid: isHybrid)
                        if modified {
                            iteration += 1
                            continue
                        }
                    }
                }
                
                return (false, lastOutput.isEmpty ? "Unknown Typst error (exit code \(result.status))" : lastOutput)
            } catch {
                return (false, error.localizedDescription)
            }
        }
        
        return (false, lastOutput)
    }

    func compileClean(content: String, fileExtension: String? = nil, originalFileURL: URL? = nil, projectRoot: URL?) async -> (success: Bool, pdfURL: URL?, error: String?) {
        guard let typstPath = resolveTypstPath() else {
            return (false, nil, "Error: 'typst' executable not found.")
        }
        
        let preferredDirectory = originalFileURL?.deletingLastPathComponent()
        
        let tempDir: URL
        if let pref = preferredDirectory {
            tempDir = ensureTempDirectory(in: pref)
        } else {
            tempDir = FileManager.default.temporaryDirectory
        }
        
        let tempID = UUID().uuidString
        let sourceURL = tempDir.appendingPathComponent(".clean-\(tempID.prefix(8)).typ")
        
        // The shadow may sit outside the project (OS-temp storage): widen the
        // root to contain it and make `/…` references relative so they still
        // point at project files.
        let rootSource = preferredDirectory ?? projectRoot ?? tempDir
        let compileRoot = Self.compileRoot(projectRoot: rootSource, shadowDirectory: tempDir)
        
        let pdfURL: URL
        if let original = originalFileURL {
            let tempFolder = tempDir.appendingPathComponent(tempID)
            try? FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
            let pdfFilename = original.deletingPathExtension().appendingPathExtension("pdf").lastPathComponent
            pdfURL = tempFolder.appendingPathComponent(pdfFilename)
        } else {
            pdfURL = tempDir.appendingPathComponent(".clean-\(tempID.prefix(8)).pdf")
        }
        
        var finalContent = content
        
        let ext = fileExtension ?? currentFileExtension
        let isHybrid = (ext == "note")
        
        if isHybrid {
            finalContent = Self.autoFixBrokenNoteSyntax(finalContent)
        }
        
        if ext == "md" || ext == "note" {
            let aiService = AICompletionService.shared
            let textToProcess = finalContent
            finalContent = await Task.detached {
                // Delimit improper operators first (same pass as the live preview)
                // so exports of `.note` files don't break on stray @/#/$/</>.
                let input = isHybrid ? Self.delimitImproperOperators(textToProcess).output : textToProcess
                return aiService.sanitizeMarkdownToTypst(input, isHybrid: isHybrid)
            }.value
        }
        if ext == "note" {
            finalContent = Self.notePreamble + finalContent
        }

        // Match the live preview's "Keep with Next" behavior so exported
        // pages break in the same places.
        if GeneralSettingsManager.shared.keepWithNextHeadings {
            finalContent = Self.keepWithNextPreamble + finalContent
        }

        // Same missing-font substitution the live preview applies (shadow-only).
        finalContent = Self.substituteMissingFonts(finalContent)

        // Same raw-language normalization the live preview applies (shadow-only).
        finalContent = Self.normalizeRawLanguages(finalContent)

        // Same calculator static compilation as the live preview.
        finalContent = await applyCalcPipeline(finalContent, fileExtension: ext, bridgeDirectory: tempDir).content

        finalContent = await self.rewriteRelativeImports(in: finalContent, sourceDirectory: preferredDirectory ?? tempDir, tempDirectory: tempDir)
        
        // With a widened root, `/…` no longer resolves to the project folder.
        if compileRoot.isWidened {
            finalContent = Self.rewriteRootAbsolutePaths(
                in: finalContent, projectRoot: rootSource, shadowDirectory: tempDir)
        }
        
        finalContent = await resolveWebImages(
            in: finalContent, projectRoot: preferredDirectory ?? projectRoot, shadowDirectory: tempDir)
        
        do {
            try finalContent.write(to: sourceURL, atomically: true, encoding: .utf8)
        } catch {
            return (false, nil, "Failed to write temp source: \(error.localizedDescription)")
        }
        
        let effectiveRoot = compileRoot.url
        var arguments = ["compile", sourceURL.path, pdfURL.path]
        arguments.append(contentsOf: ["--root", effectiveRoot.path])
        
        defer {
            // Clean up temp source file
            try? FileManager.default.removeItem(at: sourceURL)
        }
        
        var cleanFallbackAttempts: [Int: Int] = [:]
        var iteration = 0
        var lastOutput = ""
        
        while iteration < 3 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: typstPath)
            process.currentDirectoryURL = effectiveRoot
            process.arguments = arguments
            
            let pipe = Pipe()
            process.standardError = pipe
            
            do {
                try process.run()
                // Drain concurrently with the wait: this is the Save path's
                // clean compile, and a broken note can dump megabytes of
                // diagnostics — a wait-then-read sequence deadlocks on the
                // full pipe buffer while the whole app waits on this task.
                let result = BlockingProcess.run(process, draining: [pipe.fileHandleForReading])
                
                if result.status == 0 {
                    return (true, pdfURL, nil)
                }
                
                lastOutput = result.output.isEmpty ? "Unknown error" : result.output
                
                if ext == "note" || ext == "md" {
                    let rawLines = Self.parseRawErrorLines(from: lastOutput, onlyInFile: sourceURL.lastPathComponent)
                    if !rawLines.isEmpty {
                        let modified = applyFallbackFix(to: sourceURL, rawErrorLines: rawLines, attempts: &cleanFallbackAttempts, isHybrid: isHybrid)
                        if modified {
                            iteration += 1
                            continue
                        }
                    }
                }
                
                return (false, nil, lastOutput)
            } catch {
                return (false, nil, error.localizedDescription)
            }
        }
        
        return (false, nil, lastOutput)
    }

    // MARK: - Web Image Resolver
    
    func resolveWebImages(in text: String, projectRoot: URL?, shadowDirectory: URL? = nil) async -> String {
        let matches = CompilerRegex.webImage.matches(in: text, options: [], range: NSRange(0..<text.utf16.count))
        var urlsToFetch: Set<String> = []
        
        let nsText = text as NSString
        for match in matches {
            let url = nsText.substring(with: match.range(at: 1))
            if url.lowercased().hasPrefix("http") {
                urlsToFetch.insert(url)
            }
        }
        
        guard !urlsToFetch.isEmpty, let root = projectRoot else { return text }
        
        // Replace web URLs with cached local copies inside the project's temp/ folder
        var processed = text
        let tempDir: URL
        let tempDirPath = SafeDirectoryManager.safeTempDirectory(in: root)
        if !FileManager.default.fileExists(atPath: tempDirPath.path) {
            try? SafeDirectoryManager.createDirectorySafely(at: tempDirPath, withIntermediateDirectories: true)
        }
        tempDir = tempDirPath

        for url in urlsToFetch {
            if let (data, ext) = await WebImageCache.shared.download(urlString: url) {
                let safeName = "web_img_\(abs(url.hashValue)).\(ext)"
                let localURL = tempDir.appendingPathComponent(safeName)
                
                // Always overwrite to clear out any corrupted HTML 403 pages from previous runs
                try? data.write(to: localURL, options: .atomic)
                
                // Point at the download from the shadow file, not from the
                // project root: with OS-temp scratch files the shadow is not
                // under `<project>/temp`, so a `/temp/…` reference would miss.
                let rewrittenPath: String
                if let shadowDirectory {
                    let relative = Self.relativePath(from: shadowDirectory, to: localURL)
                    rewrittenPath = relative.isEmpty ? safeName : relative
                } else {
                    rewrittenPath = "/temp/\(safeName)"
                }
                processed = processed.replacingOccurrences(of: "\"\(url)\"", with: "\"\(rewrittenPath)\"")
            }
        }
        
        return processed
    }
    
    // MARK: - Relative Import Rewriter
    
    /// Rewrites relative `#import`, `#include`, and `#image` paths so they remain valid
    /// when the shadow source is written into a temporary folder. If the original source
    /// is nested under a subdirectory, we compute the path relative to the temp directory
    /// rather than blindly prepending `../`.
    private static let relativeImportExceptBridge = try! NSRegularExpression(
        pattern: #"(\b(?:import|include)\s+")(?!"# + NSRegularExpression.escapedPattern(for: CalcPlugin.bridgeFileName) + #"")([^/@.][^"]*)(")"#)

    func rewriteRelativeImports(in content: String, sourceDirectory: URL?, tempDirectory: URL?) async -> String {
        // Preserve the old behavior when no source context is available.
        guard let sourceDirectory, let tempDirectory else {
            return await rewriteRelativeImports(in: content)
        }

        let relativePrefix = (tempDirectory == sourceDirectory) ? "" : Self.relativePath(from: tempDirectory, to: sourceDirectory)
        let prefixForImports = relativePrefix.isEmpty || relativePrefix == "." ? "" : relativePrefix + "/"

        var processed = content

        let importMatches = CompilerRegex.relativeImport.matches(
            in: processed,
            options: [],
            range: NSRange(0..<processed.utf16.count)
        ).reversed()

        for match in importMatches {
            let prefix = (processed as NSString).substring(with: match.range(at: 1))
            let rawPath = (processed as NSString).substring(with: match.range(at: 2))
            let suffix = (processed as NSString).substring(with: match.range(at: 3))

            // The calculator bridge is installed next to the compiled file on
            // purpose; its import must not be redirected to the source folder.
            if rawPath == CalcPlugin.bridgeFileName { continue }

            var rewrittenPath = resolveRelativeImportPath(rawPath, relativePrefix: prefixForImports)
            
            if (rawPath.hasSuffix(".note") || rawPath.hasSuffix(".md")), let loader = self.fileLoader {
                let filename = (rawPath as NSString).lastPathComponent
                if let fileContent = loader(filename) {
                    let isHybrid = rawPath.hasSuffix(".note")
                    let textToProcess = isHybrid ? Self.autoFixBrokenNoteSyntax(fileContent) : fileContent
                    let aiService = AICompletionService.shared
                    var converted = await Task.detached {
                        let input = isHybrid ? Self.delimitImproperOperators(textToProcess).output : textToProcess
                        return aiService.sanitizeMarkdownToTypst(input, isHybrid: isHybrid)
                    }.value
                    
                    if isHybrid {
                        converted = Self.notePreamble + converted
                    }
                    
                    let newFilename = filename.replacingOccurrences(of: ".note", with: ".typ").replacingOccurrences(of: ".md", with: ".typ")
                    let tempFileURL = tempDirectory.appendingPathComponent(newFilename)
                    try? converted.write(to: tempFileURL, atomically: true, encoding: .utf8)
                    
                    // We point the import directly to the newly compiled .typ file in the temp directory!
                    rewrittenPath = newFilename
                }
            }

            let rewritten = prefix + rewrittenPath + suffix
            let fullRange = Range(match.range, in: processed)!
            processed.replaceSubrange(fullRange, with: rewritten)
        }

        let imageMatches = CompilerRegex.relativeImage.matches(
            in: processed,
            options: [],
            range: NSRange(0..<processed.utf16.count)
        ).reversed()

        for match in imageMatches {
            let prefix = (processed as NSString).substring(with: match.range(at: 1))
            let rawPath = (processed as NSString).substring(with: match.range(at: 2))
            let suffix = (processed as NSString).substring(with: match.range(at: 3))
            let rewritten = prefix + resolveRelativeImportPath(rawPath, relativePrefix: prefixForImports) + suffix
            let fullRange = Range(match.range, in: processed)!
            processed.replaceSubrange(fullRange, with: rewritten)
        }

        return processed
    }

    private func rewriteRelativeImports(in content: String) async -> String {
        var processed = content

        // Same exemption as above: the bridge sits next to the compiled file.
        processed = Self.relativeImportExceptBridge.stringByReplacingMatches(
            in: processed,
            options: [],
            range: NSRange(0..<processed.utf16.count),
            withTemplate: "$1../$2$3"
        )

        processed = CompilerRegex.relativeImage.stringByReplacingMatches(
            in: processed,
            options: [],
            range: NSRange(0..<processed.utf16.count),
            withTemplate: "$1../$2$3"
        )

        return processed
    }

    nonisolated static func relativePath(from tempDirectory: URL, to target: URL) -> String {
        let from = tempDirectory.standardizedFileURL.pathComponents
        let to = target.standardizedFileURL.pathComponents

        var common = 0
        let count = min(from.count, to.count)
        while common < count, from[common] == to[common] {
            common += 1
        }

        let upCount = max(0, from.count - common)
        let downComponents = Array(to.dropFirst(common))
        let upComponents = Array(repeating: "..", count: upCount)
        let combined = upComponents + downComponents
        return combined.joined(separator: "/")
    }

    private func resolveRelativeImportPath(_ rawPath: String, relativePrefix: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return rawPath }
        if relativePrefix.isEmpty { return trimmed }
        return relativePrefix + trimmed
    }

    // MARK: - Testing Hooks (DEBUG)

    #if DEBUG
    /// Lets `DiagnosticFloodTests` drive the watch-output pipeline with
    /// synthetic `typst watch` output and aim the diagnostics at a fake shadow
    /// document, without launching a `typst` process.
    func setDiagnosticDocumentForTesting(fileName: String) {
        diagnosticDocument = (fileName, true)
        currentFileExtension = "md"
    }

    func setShadowURLForTesting(_ url: URL?) {
        currentShadowSourceURL = url
    }

    func feedWatchOutputForTesting(_ text: String) {
        handleCompilerOutput(text, outputURL: currentShadowPDFURL ?? URL(fileURLWithPath: "/tmp/typstedit-tests.pdf"))
    }

    /// Observability for the flood gates (asserted on in tests).
    struct FloodGuardDebugState {
        var batchDiagnosticCount: Int
        var fallbackCycleCount: Int
        var pendingRewrite: Bool
        var pendingFallbackLineCount: Int
    }

    var floodGuardDebugState: FloodGuardDebugState {
        FloodGuardDebugState(
            batchDiagnosticCount: batchDiagnosticCount,
            fallbackCycleCount: fallbackCycleCount,
            pendingRewrite: pendingFallbackRewrite,
            pendingFallbackLineCount: pendingFallbackRawLines.count
        )
    }
    #endif
} // End of TypstCompiler class

// MARK: - Watch process ownership

/// Holds the preview compiler's long-lived `typst watch` and guarantees it
/// stops: on `stop()`, on `adopt` of a replacement, and when the owner itself
/// is released. Not actor-bound, so its `deinit` can run from the compiler's
/// nonisolated `deinit` path without touching main-actor state.
final class WatchProcessOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var pipe: Pipe?
    private var sourcePath: String?

    /// Every live owner by the shadow file it watches. Two `typst watch`
    /// processes on one file are never useful (they write the same PDF), so
    /// adopting a watch evicts whichever owner held that file before —
    /// whatever created the second compiler.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var ownersByPath: [String: WeakOwner] = [:]
    private final class WeakOwner {
        weak var owner: WatchProcessOwner?
        init(_ owner: WatchProcessOwner) { self.owner = owner }
    }

    /// Takes ownership of a started watch on `sourcePath`, stopping this
    /// owner's previous watch and any other owner's watch on the same file.
    func adopt(_ process: Process, pipe: Pipe, sourcePath: String) {
        Self.registryLock.lock()
        let rival = Self.ownersByPath[sourcePath]?.owner
        Self.ownersByPath[sourcePath] = WeakOwner(self)
        Self.registryLock.unlock()
        if let rival, rival !== self {
            AppDelegate.debugLog("typst watch: second watch on \((sourcePath as NSString).lastPathComponent); stopping the older one")
            rival.stop()
        }

        lock.lock()
        let old = (self.process, self.pipe, self.sourcePath)
        self.process = process
        self.pipe = pipe
        self.sourcePath = sourcePath
        lock.unlock()
        if let oldPath = old.2, oldPath != sourcePath { Self.unregister(self, path: oldPath) }
        Self.end(old.0, old.1)
        AppDelegate.debugLog("typst watch: started pid \(process.processIdentifier) for \((sourcePath as NSString).lastPathComponent)")
    }

    func stop() {
        lock.lock()
        let old = (process, pipe, sourcePath)
        process = nil
        pipe = nil
        sourcePath = nil
        lock.unlock()
        if let path = old.2 { Self.unregister(self, path: path) }
        Self.end(old.0, old.1)
    }

    deinit {
        if let sourcePath { Self.unregister(self, path: sourcePath) }
        Self.end(process, pipe)
    }

    /// Number of watches currently owned app-wide. For tests and diagnostics.
    static var liveWatchCount: Int {
        registryLock.lock(); defer { registryLock.unlock() }
        return ownersByPath.values.filter { $0.owner?.isRunning == true }.count
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning == true
    }

    private static func unregister(_ owner: WatchProcessOwner, path: String) {
        registryLock.lock()
        if let entry = ownersByPath[path], entry.owner === owner || entry.owner == nil {
            ownersByPath[path] = nil
        }
        registryLock.unlock()
    }

    /// Detaches the reader, then SIGTERMs the child; SIGKILL follows if it is
    /// still alive shortly after, so a wedged compiler cannot linger.
    private static func end(_ process: Process?, _ pipe: Pipe?) {
        pipe?.fileHandleForReading.readabilityHandler = nil
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        AppDelegate.debugLog("typst watch: stopping pid \(pid)")
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

// MARK: - Blocking process helper

/// Runs short-lived helper processes (`typst compile`, `typst --version`, …)
/// without the two classic pipe deadlocks:
///
/// 1. **Full pipe buffer.** `Process.waitUntilExit()` blocks until the child
///    exits — but a child attached to an unread `Pipe` blocks once the pipe's
///    ~64 KB buffer fills, so both sides wait forever. A broken `.note`
///    produces megabytes of typst diagnostics, which reliably triggered this
///    deadlock on Save (the app runs on the main actor) and hung it for good.
///    Draining concurrently with the wait keeps both sides making progress.
/// 2. **Main-actor blocking.** `TypstCompiler` is `@MainActor`, so a
///    synchronous `waitUntilExit()` also froze the UI for the whole compile.
///    `launch(…)` runs the child in a detached task instead.
enum BlockingProcess {
    struct Result: Sendable {
        let status: Int32
        let output: String
    }

    /// Starts draining `handle` on a background queue immediately. The
    /// returned closure waits for EOF and delivers the bytes; call it once the
    /// process has exited (e.g. from its termination handler).
    nonisolated static func startDraining(
        _ handle: FileHandle,
        on queue: DispatchQueue = DispatchQueue.global(qos: .userInitiated)
    ) -> @Sendable () -> Data {
        let box = DataBox()
        queue.async { box.data = handle.readDataToEndOfFile() }
        return { box.wait() }
    }

    /// Waits for an already-running process while draining `pipes`
    /// concurrently. Safe for output of any size.
    nonisolated static func run(
        _ process: Process,
        draining pipes: [FileHandle],
        on queue: DispatchQueue = DispatchQueue.global(qos: .userInitiated)
    ) -> Result {
        let readers = pipes.map { startDraining($0, on: queue) }
        process.waitUntilExit()
        let output = readers.compactMap { String(data: $0(), encoding: .utf8) }.joined()
        return Result(status: process.terminationStatus, output: output)
    }

    /// Launches `executable` off the main actor, captures stdout + stderr,
    /// waits for it to exit and returns its status plus the combined output.
    /// A launch failure is reported as status `-1` with the error text in
    /// `output`, mirroring the old do/catch call sites.
    nonisolated static func launch(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async -> Result {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }
            if let environment { process.environment = environment }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                return Result(status: -1, output: "Failed to launch \(executable): \(error.localizedDescription)")
            }
            return run(process, draining: [pipe.fileHandleForReading])
        }.value
    }
}

/// Thread-safe one-shot box handing a background pipe read's result back to
/// the waiter.
private final class DataBox: @unchecked Sendable {
    private var _data: Data?
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)

    var data: Data {
        get {
            lock.lock(); defer { lock.unlock() }
            return _data ?? Data()
        }
        set {
            lock.lock()
            _data = newValue
            lock.unlock()
            semaphore.signal()
        }
    }

    func wait() -> Data {
        semaphore.wait()
        return data
    }
}

// MARK: - Web Image Caching Actor
/// Downloads images referenced with `http(s)` in a document so the preview can
/// embed them. Results are cached because a recompile re-resolves every image
/// in the document, and a burst of network requests per keystroke would be
/// worse than useless.
///
/// The cache is bounded, oldest-first, by bytes: a page of photos can otherwise
/// hold tens of megabytes of `Data` for images that were scrolled past and will
/// never be compiled again. `MemoryPressureMonitor` empties it outright.
actor WebImageCache {
    static let shared = WebImageCache()

    /// How much decoded-free image bytes the cache may hold. One image is
    /// always kept even when it alone exceeds this, so a single large figure
    /// still does not re-download on every compile.
    private static let maxBytes = 32 * 1024 * 1024

    private var cache: [String: (Data, String)] = [:]
    /// Insertion order, oldest first, so eviction is O(1) from the front.
    private var order: [String] = []
    private var cachedBytes = 0
    private var activeDownloads: [String: Task<(Data, String)?, Never>] = [:]
    private var memoryObserver: NSObjectProtocol?

    /// Registered on first use rather than in `init`, so the observer closure
    /// can capture the fully-formed actor.
    private func observeMemoryPressureIfNeeded() {
        guard memoryObserver == nil else { return }
        MemoryPressureMonitor.shared.start()
        memoryObserver = NotificationCenter.default.addObserver(
            forName: MemoryPressureMonitor.willFreeMemory,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.removeAll() }
        }
    }

    func download(urlString: String) async -> (Data, String)? {
        observeMemoryPressureIfNeeded()
        if let cached = cache[urlString] { return cached }
        
        // If we are already downloading this image, wait for it
        if let active = activeDownloads[urlString] {
            return await active.value
        }

        let task = Task { () -> (Data, String)? in
            guard let url = URL(string: urlString) else { return nil }
            do {
                var request = URLRequest(url: url)
                // Masquerade as Safari to prevent servers (like Wikimedia) from returning 403 Forbidden HTML pages
                request.addValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
                
                let (data, response) = try await URLSession.shared.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    print("[ImageCache] HTTP Error \(httpResponse.statusCode) downloading \(urlString)")
                    return nil
                }
                
                var ext = url.pathExtension.lowercased()
                if ext.isEmpty { ext = "png" }
                
                if let mimeType = response.mimeType {
                    if mimeType == "image/png" { ext = "png" }
                    else if mimeType == "image/jpeg" { ext = "jpg" }
                    else if mimeType == "image/gif" { ext = "gif" }
                    else if mimeType == "image/svg+xml" { ext = "svg" }
                }
                
                // Magic bytes fallback (supercedes MIME type if it's wrong, like the GitHub issue)
                if data.count > 4 {
                    let bytes = [UInt8](data.prefix(4))
                    if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
                        ext = "png"
                    } else if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
                        ext = "jpg"
                    } else if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 {
                        ext = "gif"
                    }
                }
                
                return (data, ext)
            } catch {
                print("[ImageCache] Failed to download \(urlString): \(error)")
                return nil
            }
        }

        activeDownloads[urlString] = task
        let result = await task.value
        if let res = result { store(res, for: urlString) }
        activeDownloads[urlString] = nil
        return result
    }

    /// Inserts one entry, evicting the oldest until the byte budget holds.
    private func store(_ entry: (Data, String), for key: String) {
        if let existing = cache[key] {
            cachedBytes -= existing.0.count
            order.removeAll { $0 == key }
        }
        cache[key] = entry
        order.append(key)
        cachedBytes += entry.0.count

        while cachedBytes > Self.maxBytes, order.count > 1 {
            let oldest = order.removeFirst()
            if let evicted = cache.removeValue(forKey: oldest) {
                cachedBytes -= evicted.0.count
            }
        }
    }

    /// Drops every cached image. Called under memory pressure; anything still
    /// on screen has already been copied into the shadow document's temp
    /// folder, so nothing visible disappears.
    func removeAll() {
        cache.removeAll()
        order.removeAll()
        cachedBytes = 0
    }
}

/// All three are posted with the `TypstCompiler` as `object`. Each window
/// subscribes to its own compiler only, so one window's compile never
/// changes another window's preview, issues or calculator panel.
extension Notification.Name {
    /// `userInfo["url"]`: the preview PDF that was written.
    static let pdfDidUpdate = Notification.Name("pdfDidUpdate")
    /// `userInfo["errors"]`: `[TypstError]`.
    static let typstErrorsUpdated = Notification.Name("typstErrorsUpdated")
    /// Posted after a compile pass resolved a document's
    /// `#let x = calc-param(…)` declarations. `userInfo["parameters"]` is
    /// `[CalculatorStoredVariable]`. `EditorController` mirrors the list onto
    /// `CalculatorSession.documentParameters` so the Calculator panel shows
    /// the open document's parameters.
    static let calcDocumentParametersChanged = Notification.Name("calcDocumentParametersChanged")
}