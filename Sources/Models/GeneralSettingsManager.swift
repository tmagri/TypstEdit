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
