import SwiftUI

/// What happens when a project, the Notes folder or a file would open in an
/// additional window because every window is in use.
enum WindowOpenBehavior: String, CaseIterable, Identifiable {
    case ask
    case newWindow
    case replace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask: return "Ask Every Time"
        case .newWindow: return "Open a New Window"
        case .replace: return "Replace the Current Window"
        }
    }
}

enum TypstUpdateMode: String, CaseIterable, Identifiable {
    case stableBinary = "Stable Binary (Recommended)"
    case bleedingEdgeSource = "Bleeding Edge (Build from Source)"
    
    var id: String { self.rawValue }
}

@MainActor
class GeneralSettingsManager: ObservableObject {
    static let shared = GeneralSettingsManager()
    
    @AppStorage("useCustomTypst") var useCustomTypst: Bool = false
    @AppStorage("customTypstPath") var customTypstPath: String = ""
    @AppStorage("typstUpdateMode") var updateModeString: String = TypstUpdateMode.stableBinary.rawValue
    @AppStorage("checkForTypstUpdatesOnLaunch") var checkForTypstUpdatesOnLaunch: Bool = true
    
    /// "Keep with next": when on, TypstEdit injects a show rule into the
    /// compiled source so a heading can never be the last thing on a page.
    /// If the paragraph after a heading would start on the next page, the
    /// heading moves to the next page together with it. Requires Typst 0.12+
    /// (`block.sticky`).
    @AppStorage("keepWithNextHeadings") var keepWithNextHeadings: Bool = true

    /// Seconds without edits after which a window's live-preview compiler
    /// (`typst watch`) is stopped to give its memory back. The PDF and the
    /// issue list stay; the next edit starts it again (one full compile, then
    /// fast incremental ones). `0` keeps it running while a document is open.
    @AppStorage("previewIdleStopSeconds") var previewIdleStopSeconds: Int = 60

    /// Above this document size (in thousands of UTF-16 units), a `.note` or Markdown document is shown as
    /// plain text instead of being syntax colored. `0` (the default) never does this.
    ///
    /// This is an opt-in battery/CPU saver, not a responsiveness fix. The Markdown block grammar re-parses most
    /// of the document on every keystroke (tree-sitter spends the time in its C parser, so there is no cheap
    /// fix), but that work now runs on a background thread against a text snapshot, and the main thread is not
    /// blocked at any size. Measured in a release build at 1.6 MB while typing: ~0-10 ms of main-thread stall,
    /// but the hybrid grammar keeps ~82% of one core busy, against ~9% for plain text.
    ///
    /// Real `.typ` files stay incremental and are never affected.
    @AppStorage("markdownHighlightLimitKilochars")
    var markdownHighlightLimitKilochars: Int = GeneralSettingsManager.defaultMarkdownHighlightLimitKilochars

    /// The shipped default for ``markdownHighlightLimitKilochars``: never turn coloring off.
    static let defaultMarkdownHighlightLimitKilochars = 0

    @AppStorage("windowOpenBehavior") private var windowOpenBehaviorRaw: String = WindowOpenBehavior.ask.rawValue {
        willSet { objectWillChange.send() }
    }

    var windowOpenBehavior: WindowOpenBehavior {
        get { WindowOpenBehavior(rawValue: windowOpenBehaviorRaw) ?? .ask }
        set { windowOpenBehaviorRaw = newValue.rawValue }
    }

    // MARK: Sidebar visibility (shared by the View menu and Settings)

    @AppStorage("showFiles") var showFiles: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("showProjects") var showProjects: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("showNotebooks") var showNotebooks: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("showSourceControl") var showSourceControl: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("showCalculator") var showCalculator: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("showIssues") var showIssues: Bool = true {
        willSet { objectWillChange.send() }
    }

    func sidebarVisibility(chatEnabled: Bool) -> SidebarVisibility {
        SidebarVisibility(files: showFiles, projects: showProjects,
                          notebooks: showNotebooks, calculator: showCalculator,
                          sourceControl: showSourceControl, aiChat: chatEnabled,
                          issues: showIssues)
    }

    // MARK: Calculator defaults (used when a session starts or opens without
    // its own modes — each session's own modes override these once saved).

    /// Default angle unit for new calculator sessions ("RAD"/"DEG").
    @AppStorage("calcAngleMode") var calcAngleModeString: String = CASAngleMode.radians.rawValue
    /// Default exact/approx mode for new calculator sessions.
    @AppStorage("calcExactMode") var calcExactModeString: String = CASExactMode.auto.rawValue
    /// Displayed significant digits, like the TI-89's Digits setting.
    @AppStorage("calcDisplayDigits") var calcDisplayDigits: Int = 12
    /// Seconds before a running CAS evaluation is interrupted.
    @AppStorage("calcTimeout") var calcTimeout: Double = 10

    var calcAngleMode: CASAngleMode {
        get { CASAngleMode(rawValue: calcAngleModeString) ?? .radians }
        set { calcAngleModeString = newValue.rawValue }
    }

    var calcExactMode: CASExactMode {
        get { CASExactMode(rawValue: calcExactModeString) ?? .auto }
        set { calcExactModeString = newValue.rawValue }
    }

    var updateMode: TypstUpdateMode {
        get { TypstUpdateMode(rawValue: updateModeString) ?? .stableBinary }
        set { updateModeString = newValue.rawValue }
    }
    
    private init() {}
    
    var resolvedCustomTypstPath: String? {
        if customTypstPath.isEmpty { return nil }
        let path = NSString(string: customTypstPath).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
