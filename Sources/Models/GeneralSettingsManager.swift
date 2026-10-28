import SwiftUI

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
