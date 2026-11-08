import AppKit
import SwiftTerm
import Foundation

/// One Python pane's shell session.
///
/// The Python pane replaces the PDF preview for `.py` files. It is a real
/// login shell on a PTY (via SwiftTerm), so anything a terminal can do works
/// there: `python3`, `pip`, `pytest`, `git`, `ls`, a REPL, and so on. The
/// project's own "Run" button just types a quoted `python3 <file>` command
/// into that shell, so the user sees and keeps the command, and Ctrl-C keeps
/// working exactly like it does in Terminal.app.
///
/// One model belongs to one document window, so each window keeps its own
/// shell, its own scrollback, and its own working directory. The shell keeps
/// running while the user switches to a Markdown document and back; it stops
/// when the window is closed (and `ChildProcessGuard` stops it if the app
/// quits or crashes).
@MainActor
final class PythonTerminalModel: ObservableObject {

    /// Changes whenever a brand-new terminal view is created. The SwiftUI
    /// representable uses it as its identity so "Restart" can replace the
    /// PTY-backed view (and its buffered scrollback) cleanly.
    @Published private(set) var sessionID = UUID()

    /// True while a shell process is attached to the view.
    @Published private(set) var isRunning = false

    /// The directory the shell was started in. Shown in the pane header.
    @Published private(set) var startDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    /// The shell's live working directory, from its OSC 7 report. Falls back to
    /// `startDirectory` when the shell does not report one.
    @Published private(set) var currentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    /// Set when the shell exits (typing `exit`, a crash, …) so the pane can
    /// offer a Restart button instead of a dead view.
    @Published private(set) var didExit = false

    /// The last command TypstEdit typed into the shell, for the pane header.
    @Published private(set) var lastCommand: String?

    /// Dark/light appearance currently applied to the view.
    private var isDark: Bool = true

    /// The live AppKit view. Created on demand and reused until `restart()`.
    private var terminal: PythonTerminal?

    /// True once the session was ended deliberately (window closed, app
    /// quitting). A view that is asked for afterwards returns nil instead of
    /// starting another shell; only `restart()` clears this.
    private var isStopped = false

    // MARK: - View

    /// The session's terminal view, starting the shell the first time it is
    /// needed. The same instance is returned for the life of the session, so
    /// SwiftUI view updates never restart the shell.
    ///
    /// Callers must not hand this view to SwiftUI directly. They should place
    /// it inside a `TerminalContainer` of their own (see that type for why).
    func terminalView(directory: URL, isDark: Bool) -> PythonTerminal? {
        self.isDark = isDark
        if let terminal { return terminal }
        // The window closed or the app is quitting. SwiftUI may still rebuild
        // the row (a reset to the Welcome screen re-lays out the window), and
        // that must not silently start a new shell after the old one was
        // deliberately stopped.
        if isStopped { return nil }

        let view = PythonTerminal(onEnd: { [weak self] in
            self?.handleProcessEnded()
        })
        view.onDirectoryChange = { [weak self] url in
            guard let self, self.currentDirectory != url else { return }
            self.currentDirectory = url
        }
        terminal = view

        start(in: view, directory: directory)
        applyAppearance(to: view)
        return view
    }

    /// Applies the window's dark/light appearance. Cheaper than restarting:
    /// it only changes the native colours SwiftTerm draws with.
    func updateAppearance(isDark: Bool) {
        guard self.isDark != isDark else { return }
        self.isDark = isDark
        if let terminal { applyAppearance(to: terminal) }
    }

    // MARK: - Session control

    /// Starts a fresh shell in `directory`, replacing the old view entirely.
    /// Used by "Restart" and when a first shell was never started.
    func restart(directory: URL) {
        stop()
        sessionID = UUID()
        terminal = nil
        isStopped = false
        didExit = false
        lastCommand = nil
        startDirectory = directory
        currentDirectory = directory
    }

    /// Follows the Python file the window is showing.
    ///
    /// Moving to a Python file in another folder should not leave the pane in
    /// the old folder, but killing a shell the user is working in would be
    /// worse. So the shell is only replaced while it is still pristine (no
    /// command has been typed through `run`); after that, Restart is explicit.
    func adopt(directory: URL) {
        guard let terminal else {
            startDirectory = directory
            currentDirectory = directory
            return
        }
        guard terminal.process.running, lastCommand == nil, startDirectory != directory else { return }
        restart(directory: directory)
    }

    /// Ends the shell, if one is running. Safe to call more than once.
    func stop() {
        isStopped = true
        guard let terminal else { return }
        self.terminal = nil
        terminal.shutdown()
        isRunning = false
        didExit = true
    }

    /// Types `command` into the shell and presses Return.
    func run(command: String) {
        guard let terminal else { return }
        lastCommand = command
        terminal.send(txt: command + "\n")
    }

    /// Runs `file` with the shell's own `python3`. The absolute path is quoted
    /// so spaces, quotes and non-ASCII directory names all work, and `--` stops
    /// a path that begins with `-` from being read as an option.
    func runPythonFile(_ file: URL) {
        run(command: PythonTerminalModel.runCommand(for: file))
    }

    /// Ctrl-C: what a terminal user presses to interrupt the foreground job.
    func interrupt() {
        guard let terminal else { return }
        terminal.send([0x03])
    }

    /// Ctrl-L: clears the screen without losing the shell or its history.
    func clear() {
        guard let terminal else { return }
        terminal.send([0x0c])
    }

    /// Sends an empty line so a fresh shell draws its prompt (and its startup
    /// files' output) without the user having to click and press Return.
    func focusInput() {
        guard let terminal else { return }
        terminal.window?.makeFirstResponder(terminal)
    }

    // MARK: - Pure helpers (also used by tests)

    /// The command typed by "Run". `python3` comes from the shell's `PATH`, so
    /// a Homebrew, pyenv or venv interpreter wins over the system one exactly
    /// as it would in Terminal.app.
    static func runCommand(for file: URL) -> String {
        "python3 -- \(shellQuoted(file.path))"
    }

    /// POSIX single-quote escaping: safe for every byte except NUL.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The environment handed to the shell.
    ///
    /// SwiftTerm's own default omits `PATH`, which would break `python3`,
    /// `git` and everything else the user expects. TypstEdit's environment is
    /// passed through and the terminal variables are set/overridden: `TERM`
    /// for curses programs, `COLORTERM` for true-colour output, and `LANG` (a
    /// GUI app can start without one, which makes Python's stdout ASCII-only).
    static func environment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // The app bundle's PATH can be the minimal system one. macOS login
        // shells run path_helper from /etc/zprofile, but a user who set a
        // custom SHELL without a login profile would still lose Homebrew.
        let fallback = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for path in fallback.reversed() where !(env["PATH"] ?? "").split(separator: ":").contains(Substring(path)) {
            env["PATH"] = env["PATH"].map { "\(path):\($0)" } ?? path
        }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// The login shell to host. A login shell reads the user's profile, so
    /// Homebrew/pyenv/venv setup done there is active in the pane.
    static func shellPath(base: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let shell = base["SHELL"], !shell.isEmpty,
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    // MARK: - Private

    private func start(in view: PythonTerminal, directory: URL) {
        startDirectory = directory
        currentDirectory = directory
        didExit = false

        let shell = Self.shellPath()
        view.startProcess(
            executable: shell,
            args: ["-l"],
            environment: Self.environment(),
            execName: (shell as NSString).lastPathComponent,
            currentDirectory: directory.path
        )
        isRunning = true
    }

    private func handleProcessEnded() {
        isRunning = false
        didExit = true
    }

    private func applyAppearance(to view: PythonTerminal) {
        let background = isDark
            ? NSColor(calibratedWhite: 0.07, alpha: 1.0)
            : NSColor(calibratedWhite: 0.99, alpha: 1.0)
        let foreground = isDark
            ? NSColor(calibratedWhite: 0.90, alpha: 1.0)
            : NSColor(calibratedWhite: 0.11, alpha: 1.0)
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = isDark ? .white : .black
        view.selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.wantsLayer = true
        view.layer?.backgroundColor = background.cgColor
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

// MARK: - AppKit terminal

/// One SwiftUI pane's host for the session's terminal.
///
/// The window's three layouts (editor only, terminal only, split) are separate
/// branches of an `if`. So a layout switch makes SwiftUI build a new pane
/// *before* it tears down the old one, and that teardown calls
/// `removeFromSuperview()` on the old pane's view. If both panes shared one
/// view, that teardown would remove it from the pane that was just built, and
/// the terminal would be detached and blank until something forced a redraw.
///
/// So each pane gets its own container, and only the terminal moves between
/// containers. The old pane's teardown then removes an empty container, and
/// the shell, scrollback and drawn screen stay in the pane on screen.
final class TerminalContainer: NSView {
    private weak var terminal: PythonTerminal?

    init() {
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("TerminalContainer is created in code only")
    }

    /// Places `terminal` in this container, taking it from another container
    /// if needed. Safe to call on every SwiftUI update.
    func host(_ terminal: PythonTerminal?) {
        self.terminal = terminal
        guard let terminal else { return }
        guard terminal.superview !== self else { return }

        terminal.removeFromSuperview()
        addSubview(terminal)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scheduleRepaint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A pane that SwiftUI shows again (for example, after a modal sheet)
        // can still hold the terminal. If another pane took it in the
        // meantime, take it back while this pane is the one on screen.
        if window != nil, let terminal, terminal.superview !== self {
            host(terminal)
        }
        scheduleRepaint()
    }

    private var lastLaidOutSize: NSSize = .zero

    override func layout() {
        super.layout()
        // A freshly built pane is often attached at zero size and only gets
        // its real size on a later layout pass. Repaint once it has one.
        if bounds.size != lastLaidOutSize {
            lastLaidOutSize = bounds.size
            scheduleRepaint()
        }
    }

    /// Paints after the current layout pass, when the view has its final size.
    /// A moved view gets a new backing store, and SwiftTerm only repaints lines
    /// that changed, so without a full repaint the pane would stay blank until
    /// the shell writes something new.
    private func scheduleRepaint() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, let terminal = self.terminal,
                  terminal.superview === self else { return }
            terminal.refreshDisplay()
        }
    }
}

/// A `LocalProcessTerminalView` that owns its delegate, so nothing else has to
/// stay alive alongside the view.
///
/// The delegate is a separate object on purpose: `LocalProcessTerminalView`
/// already implements the internal `LocalProcessDelegate` method named
/// `processTerminated(_:exitCode:)`, and a subclass that also tried to adopt
/// `LocalProcessTerminalViewDelegate` would collide with it.
final class PythonTerminal: LocalProcessTerminalView {

    /// Called when the shell process ends, for any reason.
    private let onEnd: @MainActor () -> Void
    /// Called when the shell reports a new working directory (OSC 7).
    var onDirectoryChange: (@MainActor (URL) -> Void)?

    private lazy var bridge = PythonTerminalDelegate(
        onEnd: onEnd,
        onDirectoryChange: { [weak self] url in self?.onDirectoryChange?(url) }
    )

    /// The window this view was last placed in, and the close-notification
    /// observer for it. SwiftUI does not guarantee an `onDisappear` when a
    /// window closes (and hiding the pane must *not* end the shell), so the
    /// view watches its own window instead: closing the window must not leave
    /// a shell, or a running script, behind.
    private weak var observedWindow: NSWindow?
    /// `nonisolated(unsafe)`: written only on the main thread, and read in
    /// `deinit` so the token can be removed if the view outlives its window.
    nonisolated(unsafe) private var closeObserver: NSObjectProtocol?

    init(onEnd: @escaping @MainActor () -> Void) {
        self.onEnd = onEnd
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        processDelegate = bridge
    }

    required init?(coder: NSCoder) {
        fatalError("PythonTerminal is created in code only")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Only observe the window's close once per window. The container
        // handles repainting after a layout move.
        guard let window, observedWindow !== window else { return }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        observedWindow = window
        let terminateAction: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main,
            using: terminateAction
        )
    }

    /// Ends the shell and everything it started.
    ///
    /// SwiftTerm's own `terminate()` sends SIGTERM to the shell only. An
    /// *interactive* zsh or bash deliberately ignores SIGTERM, and a running
    /// script is a separate child that would survive, so that alone can leave
    /// processes behind. This sends SIGHUP (what a terminal sends when its
    /// window closes) to the shell's whole process group — which, because
    /// `forkpty` makes the shell a session leader, is the shell, its job, and
    /// anything that job started — then SIGKILLs whatever is still there.
    func shutdown() {
        let pid = process.shellPid
        if pid > 0 {
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
        terminate()
    }

    /// Repaints the whole screen from the terminal's buffer.
    ///
    /// SwiftTerm normally repaints only the lines that changed, so a view that
    /// was detached and re-attached (SwiftUI rebuilds this pane when the
    /// window switches between editor-only, terminal-only and split) comes
    /// back blank: its backing store is new, and nothing new arrived from the
    /// shell to mark lines dirty. Asking for a full-screen update fixes that
    /// without touching the shell or its scrollback.
    func refreshDisplay() {
        guard window != nil, bounds.size != .zero else { return }
        getTerminal().updateFullScreen()
        needsDisplay = true
    }

    deinit {
        let observer = closeObserver
        closeObserver = nil
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
    }
}

// MARK: - Focus

extension PythonTerminal {
    /// The terminal that currently has keyboard focus, if any. The app's Edit
    /// and Find menu items use this to decide whether a command belongs to
    /// the editor or to the shell running beside it.
    static var focused: PythonTerminal? {
        if let responder = NSApp.keyWindow?.firstResponder as? PythonTerminal { return responder }
        if let responder = NSApp.mainWindow?.firstResponder as? PythonTerminal { return responder }
        return nil
    }

    /// Opens the terminal's own Find bar. SwiftTerm exposes it through the
    /// standard text-finder action, so no private API is needed.
    func showFind() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        performTextFinderAction(item)
    }
}

/// Receives SwiftTerm's process callbacks and hands them to the model on the
/// main actor. SwiftTerm dispatches them on the main queue already; the hops
/// make that requirement explicit for Swift 6.
private final class PythonTerminalDelegate: NSObject, LocalProcessTerminalViewDelegate {
    let onEnd: @MainActor () -> Void
    let onDirectoryChange: @MainActor (URL) -> Void

    init(onEnd: @escaping @MainActor () -> Void, onDirectoryChange: @escaping @MainActor (URL) -> Void) {
        self.onEnd = onEnd
        self.onDirectoryChange = onDirectoryChange
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 from the shell reports its live working directory. Ignore
        // non-file URLs (some prompts report `file://host/path`).
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        let handler = onDirectoryChange
        Task { @MainActor in handler(url) }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let handler = onEnd
        Task { @MainActor in handler() }
    }
}
