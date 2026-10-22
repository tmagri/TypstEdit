import SwiftUI

/// Per-project overrides, editable from the project itself rather than the
/// app-wide Settings window: where this project's temp/vector-cache folders
/// live, and which skills/MCP servers are enabled by default whenever the AI
/// Prompt panel opens for it. Persisted to `<project>/.typstedit/config.json`.
struct ProjectSettingsView: View {
    @ObservedObject var controller: EditorController
    @ObservedObject private var skillsManager = SkillsManager.shared
    @ObservedObject private var mcpManager = MCPManager.shared
    @Environment(\.dismiss) private var dismiss

    private enum StorageChoice: String, CaseIterable, Identifiable {
        case inherit = "Use Global Default"
        case inProject = "Always Store in Project"
        case osTemp = "Always Use OS Temp"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project Settings").font(.headline)
                    if let root = controller.projectRootURL {
                        Text(root.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            if let settings = controller.projectSettings {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        SettingsCard(
                            title: "Storage Location",
                            icon: "externaldrive",
                            description: "Overrides the global defaults set in Settings → General, for this project only."
                        ) {
                            VStack(alignment: .leading, spacing: 14) {
                                SettingsRow(label: "Temp Files:") {
                                    Picker("", selection: storageBinding(\.storeTempInProject, settings: settings)) {
                                        ForEach(StorageChoice.allCases) { Text($0.rawValue).tag($0) }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                }
                                SettingsRow(label: "Vector Cache:") {
                                    Picker("", selection: storageBinding(\.storeVectorCacheInProject, settings: settings)) {
                                        ForEach(StorageChoice.allCases) { Text($0.rawValue).tag($0) }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                }
                            }
                        }

                        SettingsCard(
                            title: "Default Skills for This Project",
                            icon: "sparkles.square.filled.on.square",
                            description: "Pre-checked whenever the AI Prompt panel opens in this project. Still adjustable per request."
                        ) {
                            let skills = skillsManager.allSkills
                            if skills.isEmpty {
                                Text("No skills configured yet — add some in Settings → AI Assistant → Skills.")
                                    .font(.caption).foregroundColor(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(skills) { skill in
                                        Toggle(isOn: enabledSkillBinding(skill.id, settings: settings)) {
                                            Text("\(skill.name)  ·  \(skill.scope.label)")
                                        }
                                    }
                                }
                            }
                        }

                        SettingsCard(
                            title: "Default MCP Servers for This Project",
                            icon: "wrench.and.screwdriver",
                            description: "Pre-checked whenever the AI Prompt panel opens in this project. Still adjustable per request."
                        ) {
                            let servers = mcpManager.allServers.filter { $0.config.isConfigured }
                            if servers.isEmpty {
                                Text("No MCP servers configured yet — add some in Settings → AI Assistant → MCP Servers.")
                                    .font(.caption).foregroundColor(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(servers) { server in
                                        Toggle(isOn: enabledServerBinding(server.id, settings: settings)) {
                                            Text("\(server.config.name)  ·  \(server.scope.label)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            } else {
                Text("No project is currently open.")
                    .foregroundColor(.secondary)
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
    }

    private func storageBinding(_ keyPath: WritableKeyPath<ProjectConfig, Bool?>, settings: ProjectSettingsManager) -> Binding<StorageChoice> {
        Binding(
            get: {
                switch settings.config[keyPath: keyPath] {
                case .none: return .inherit
                case .some(true): return .inProject
                case .some(false): return .osTemp
                }
            },
            set: { choice in
                settings.update { config in
                    switch choice {
                    case .inherit: config[keyPath: keyPath] = nil
                    case .inProject: config[keyPath: keyPath] = true
                    case .osTemp: config[keyPath: keyPath] = false
                    }
                }
            }
        )
    }

    private func enabledSkillBinding(_ id: String, settings: ProjectSettingsManager) -> Binding<Bool> {
        Binding(
            get: { settings.config.enabledSkillIDs?.contains(id) ?? false },
            set: { isOn in
                settings.update { config in
                    var ids = Set(config.enabledSkillIDs ?? [])
                    if isOn { ids.insert(id) } else { ids.remove(id) }
                    config.enabledSkillIDs = Array(ids)
                }
            }
        )
    }

    private func enabledServerBinding(_ id: String, settings: ProjectSettingsManager) -> Binding<Bool> {
        Binding(
            get: { settings.config.enabledMCPServerIDs?.contains(id) ?? false },
            set: { isOn in
                settings.update { config in
                    var ids = Set(config.enabledMCPServerIDs ?? [])
                    if isOn { ids.insert(id) } else { ids.remove(id) }
                    config.enabledMCPServerIDs = Array(ids)
                }
            }
        )
    }
}
