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
