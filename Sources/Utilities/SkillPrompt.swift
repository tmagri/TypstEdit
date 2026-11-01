import Foundation

/// Decides how much of each enabled skill goes into the system prompt.
///
/// Inlining every skill body is a context catastrophe for a big reference
/// pack: the bundled `typst-reference` skill is over 200 KB on disk, and one
/// of its files alone is 165 KB. But always deferring is wasteful the other
/// way — most user-written skills are a couple of paragraphs, and spending a
/// whole tool round trip to read two sentences costs more than inlining them.
///
/// So the rule is size-based:
///
///   * a short skill is inlined in full, because it is cheaper than a call;
///   * a long skill contributes only its name and description, and the model
///     pulls the body with the `read_skill` tool when it decides the skill
///     applies.
///
/// Both forms name the skill's id, so a deferred skill is always one call away
/// and the model knows exactly what to ask for.
enum SkillPrompt {

    /// Bodies at or below this many characters are inlined.
    ///
    /// Sized so a typical hand-written skill (a page or two of guidance) goes
    /// in whole while a reference pack does not. Four characters per token
    /// puts this at roughly 400 tokens per inlined skill, which is a round
    /// trip's worth.
    static let inlineBodyLimit = 1_600

    struct Split: Equatable {
        /// Skills whose bodies are written into the prompt.
        var inlined: [String] = []
        /// Skills listed by name and description, body readable on demand.
        var deferred: [String] = []

        var isEmpty: Bool { inlined.isEmpty && deferred.isEmpty }
    }

    /// Which skills are inlined, by id. Pure, so the rule is testable without
    /// a SkillsManager.
    static func split(_ skills: [(id: String, body: String)]) -> Split {
        var split = Split()
        for skill in skills {
            if skill.body.count <= inlineBodyLimit {
                split.inlined.append(skill.id)
            } else {
                split.deferred.append(skill.id)
            }
        }
        return split
    }

    /// The system-prompt section for the enabled skills.
    ///
    /// `readable` says whether the `read_skill` tool is actually offered this
    /// turn. Without it a deferred body would be unreachable, so the skill's
    /// description carries a note saying so rather than silently promising a
    /// tool that isn't there.
    static func block(
        skills: [AISkill],
        readable: Bool,
        attachmentFiles: [String: [String]] = [:]
    ) -> String? {
        guard !skills.isEmpty else { return nil }
        let split = split(skills.map { (id: $0.id, body: $0.body) })
        let deferredIDs = Set(split.deferred)

        var sections: [String] = []
        for skill in skills where !deferredIDs.contains(skill.id) {
            var section = "SKILL (id: \(skill.id)): \(skill.name)\n\(skill.body)"
            section += attachmentNote(for: skill, files: attachmentFiles[skill.id] ?? [])
            sections.append(section)
        }

        // Deferred skills are listed together so the model can see the whole
        // catalogue at a glance and load just what it needs.
        let deferred = skills.filter { deferredIDs.contains($0.id) }
        if !deferred.isEmpty {
            var listing = "AVAILABLE SKILLS (large reference sets, not loaded yet). "
            listing += readable
                ? "Call read_skill with the id to load one when it applies to the job."
                : "These are referenced but cannot be loaded in this request."
            for skill in deferred {
                listing += "\n- \(skill.id) — \(skill.name): \(skill.description)"
                let files = attachmentFiles[skill.id] ?? []
                if !files.isEmpty {
                    listing += " (files: \(files.prefix(10).joined(separator: ", "))\(files.count > 10 ? ", …" : ""))"
                }
            }
            sections.append(listing)
        }

        return sections.isEmpty ? nil : sections.joined(separator: "\n\n---\n\n")
    }

    /// Names a skill's supplementary files so the model can pull one in with
    /// `read_skill_file` without guessing at filenames.
    private static func attachmentNote(for skill: AISkill, files: [String]) -> String {
        guard !files.isEmpty else { return "" }
        return "\n\nAttached files you can pull in with read_skill_file (skill: \"\(skill.id)\"): \(files.joined(separator: ", "))"
    }

    /// The tool result for a deferred skill's body, wrapped the way opencode
    /// wraps one so a model that has seen the shape before recognizes it.
    ///
    /// The base directory matters as much as the text: a skill's own
    /// instructions routinely say things like "see scripts/" or "read
    /// reference/", which only resolve against the skill's folder.
    static func loadedBody(
        name: String,
        id: String,
        body: String,
        directory: URL,
        files: [String]
    ) -> String {
        var text = "<skill_content name=\"\(name)\" id=\"\(id)\">\n"
        text += "# Skill: \(name)\n\n"
        text += body.trimmingCharacters(in: .whitespacesAndNewlines)
        text += "\n\nBase directory for this skill: \(directory.path)"
        text += "\nRelative paths in this skill (e.g. scripts/, reference/) are relative to this base directory."
        if !files.isEmpty {
            text += "\n\n<skill_files>\n"
            text += files.prefix(10).map { "<file>\($0)</file>" }.joined(separator: "\n")
            text += "\n</skill_files>"
        }
        text += "\n</skill_content>"
        return text
    }
}
