import SwiftUI

/// The View menu and Settings use the same controls and saved preferences.
/// Dependent toggles are disabled while their parent feature is hidden, so a
/// switch never looks on while it has no effect.
struct SidebarVisibilityToggles: View {
    @ObservedObject private var settings = GeneralSettingsManager.shared
    @ObservedObject private var aiSettings = AISettingsManager.shared

    var body: some View {
        Toggle("Show Files", isOn: $settings.showFiles)
        Toggle("Show Projects", isOn: $settings.showProjects)
            .disabled(!settings.showFiles)
        Toggle("Show Notebooks", isOn: $settings.showNotebooks)
            .disabled(!settings.showFiles)
        // Git lives inside the Projects view.
        Toggle("Show Git Source Control", isOn: $settings.showSourceControl)
            .disabled(!settings.showFiles || !settings.showProjects)
        Toggle("Show Calculator", isOn: $settings.showCalculator)
        // Reuse the existing AI Chat opt-in, not a second visibility setting.
        Toggle("Show AI Chat", isOn: $aiSettings.chatEnabled)
    }
}
