import SwiftUI
import AppKit

/// Compact menu for switching which model a feature (AI Chat, AI Prompt, …)
/// sends its requests to: the default Chat & Actions model or any saved
/// model from Settings → AI Assistant → Chat & Actions. The choice is
/// persisted, so it is also what that feature starts with next time.
struct AIModelPickerMenu: View {
    let feature: AIFeature
    var font: Font = .caption2

    @ObservedObject private var settings = AISettingsManager.shared

    private var selection: Binding<UUID?> {
        Binding(
            get: { settings.modelProfileID(for: feature) },
            set: { settings.setModelProfileID($0, for: feature) }
        )
    }

    var body: some View {
        Menu {
            Picker("Model", selection: selection) {
                Text("Default — \(settings.defaultModelDisplayName)").tag(UUID?.none)
                ForEach(settings.modelProfiles) { profile in
                    Text(profile.detailedName).tag(Optional(profile.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            if settings.modelProfiles.isEmpty {
                Text("Save more models in Settings → AI Assistant → Chat & Actions.")
            }

            Divider()

            Button("Manage Models…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        } label: {
            Label(settings.activeModelShortName(for: feature), systemImage: "cpu")
                .font(font)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model used for \(feature.displayName): \(settings.modelProfile(for: feature)?.detailedName ?? "Default — \(settings.defaultModelDisplayName)")")
    }
}
