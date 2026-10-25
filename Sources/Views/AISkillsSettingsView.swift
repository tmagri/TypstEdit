import SwiftUI
import AppKit

/// Settings UI for AI Skills: portable `SKILL.md` folders (frontmatter
/// `name`/`description` + a markdown instructions body) that the user can
/// enable per-request from the AI Prompt panel. Global skills apply to every
/// project; project skills live in `.typstedit/skills/` inside the active
/// project and are git-shareable with collaborators.
struct AISkillsSettingsView: View {
    @ObservedObject private var skillsManager = SkillsManager.shared
    @ObservedObject private var aiSettings = AISettingsManager.shared
    @State private var editingSkill: AISkill?
    @State private var isCreatingNew = false
    @State private var newSkillScope: ConfigScope = .global

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SettingsCard(
                    title: "What are Skills?",
                    icon: "sparkles.square.filled.on.square",
                    description: "A skill is a reusable set of instructions (formatting conventions, citation styles, house rules) the AI follows when you enable it for a request in the AI Prompt panel. Only the name and description are shown while browsing — the full instructions are only sent to the model once you turn a skill on. Tick \"On by default\" to have new AI chats start with a skill enabled; by default no skills start on, and toggles made in a chat apply for the rest of that session."
                ) {
                    EmptyView()
                }

                skillsCard(title: "Built-in Skills", scope: .builtin, skills: skillsManager.builtinSkills)
                skillsCard(title: "Global Skills", scope: .global, skills: skillsManager.globalSkills)

                if let projectRoot = skillsManager.projectRoot {
                    skillsCard(title: "Project Skills", scope: .project, skills: skillsManager.projectSkills, subtitle: projectRoot.path)
                } else {
                    SettingsCard(
                        title: "Project Skills",
                        icon: "folder.badge.gearshape",
                        description: "Open a project folder to add skills scoped to it (stored in .typstedit/skills/, shareable via git)."
                    ) {
                        EmptyView()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
        }
        .sheet(item: $editingSkill) { skill in
            SkillEditorSheet(mode: .edit(skill))
        }
        .sheet(isPresented: $isCreatingNew) {
            SkillEditorSheet(mode: .create(scope: newSkillScope))
        }
    }

    @ViewBuilder
    private func skillsCard(title: String, scope: ConfigScope, skills: [AISkill], subtitle: String? = nil) -> some View {
        SettingsCard(
            title: title,
            icon: scope == .builtin ? "shippingbox" : (scope == .global ? "globe" : "folder"),
            description: subtitle
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if skills.isEmpty {
                    Text("No skills yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(skills) { skill in
                        skillRow(skill)
                        if skill.id != skills.last?.id {
                            Divider()
                        }
                    }
                }

                if scope.isUserManageable {
                    Button {
                        newSkillScope = scope
                        isCreatingNew = true
                    } label: {
                        Label("Add Skill…", systemImage: "plus.circle")
                    }
                    .padding(.top, 4)
                } else {
                    Text("Built into TypstEdit — enable them from the Skills menu in the AI panel. They update with the app.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func skillRow(_ skill: AISkill) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.body.weight(.medium))
                Text(skill.description.isEmpty ? "No description" : skill.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                if !skill.attachments.isEmpty {
                    Label("\(skill.attachments.count) attached file\(skill.attachments.count == 1 ? "" : "s")", systemImage: "paperclip")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Toggle("On by default", isOn: defaultEnabledBinding(for: skill))
                .toggleStyle(.checkbox)
                .help("When checked, new AI chats start with this skill enabled. Toggles made in a chat apply for the rest of that session. Note: project skills are matched by folder name, so same-named skills in different projects share one default.")
            Spacer()
            if skill.scope.isUserManageable {
                Button {
                    editingSkill = skill
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                Button {
                    skillsManager.deleteSkill(skill)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Reads/writes membership in the per-skill "on by default" list
    /// (`AISettingsManager.chatDefaultSkillIDs`) — the list new AI chats
    /// start from.
    private func defaultEnabledBinding(for skill: AISkill) -> Binding<Bool> {
        Binding(
            get: { aiSettings.chatDefaultSkillIDs.contains(skill.id) },
            set: { isOn in
                var ids = aiSettings.chatDefaultSkillIDs
                if isOn {
                    if !ids.contains(skill.id) { ids.append(skill.id) }
                } else {
                    ids.removeAll { $0 == skill.id }
                }
                aiSettings.chatDefaultSkillIDs = ids
            }
        )
    }
}

private enum SkillEditorMode {
    case create(scope: ConfigScope)
    case edit(AISkill)
}

private struct SkillEditorSheet: View {
    let mode: SkillEditorMode
    @ObservedObject private var skillsManager = SkillsManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var skillDescription: String = ""
    @State private var skillBody: String = ""
    @State private var scope: ConfigScope = .global
    @State private var attachments: [String] = []

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var editingSkill: AISkill? {
        if case .edit(let skill) = mode { return skill }
        return nil
    }

    private var canUseProjectScope: Bool { skillsManager.projectRoot != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit Skill" : "New Skill")
                .font(.headline)

            TextField("Name (e.g. \"Formal Resume Style\")", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("One-line description — used to decide when this applies", text: $skillDescription)
                .textFieldStyle(.roundedBorder)

            if !isEditing {
                Picker("Scope", selection: $scope) {
                    Text("Global").tag(ConfigScope.global)
                    Text("Project").tag(ConfigScope.project).disabled(!canUseProjectScope)
                }
                .pickerStyle(.segmented)
            }

            Text("Instructions")
                .font(.caption.bold())
                .foregroundColor(.secondary)
            TextEditor(text: $skillBody)
                .font(.system(.body, design: .monospaced))
                .frame(height: 220)
                .padding(4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))

            if let skill = editingSkill {
                attachmentsSection(skill)
            } else {
                Text("Save this skill, then reopen it to attach reference files (specs, templates, examples) the AI can pull in on demand without them bloating every prompt.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(isEditing ? "Save" : "Create") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func attachmentsSection(_ skill: AISkill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Attached Files").font(.caption.bold()).foregroundColor(.secondary)
                Spacer()
                Button {
                    addAttachment(to: skill)
                } label: {
                    Label("Add Files…", systemImage: "paperclip")
                }
                .buttonStyle(.plain)
                .font(.caption)
            }

            if attachments.isEmpty {
                Text("None yet. Attachments stay out of the prompt until the AI decides this skill's instructions call for one, then it reads it with a dedicated tool.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(attachments, id: \.self) { fileName in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").foregroundColor(.secondary)
                            Text(fileName).font(.caption)
                            Spacer()
                            Button {
                                skillsManager.removeAttachment(fileName, from: skill)
                                attachments = skill.attachments
                            } label: {
                                Image(systemName: "trash").foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func addAttachment(to skill: AISkill) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            skillsManager.addAttachment(to: skill, from: url)
        }
        attachments = skill.attachments
    }

    private func load() {
        switch mode {
        case .create(let initialScope):
            scope = initialScope
        case .edit(let skill):
            name = skill.name
            skillDescription = skill.description
            skillBody = skill.body
            scope = skill.scope
            attachments = skill.attachments
        }
    }

    private func save() {
        switch mode {
        case .create:
            skillsManager.createSkill(name: name, description: skillDescription, body: skillBody, scope: scope, projectRoot: skillsManager.projectRoot)
        case .edit(let skill):
            skillsManager.updateSkill(skill, name: name, description: skillDescription, body: skillBody)
        }
        dismiss()
    }
}
