import Foundation

/// Change paths are relative to the repository, not the opened subfolder.
/// Keep full paths as identities so files with the same name stay distinct.
struct GitChangeTreeNode: Identifiable {
    let path: String
    let name: String
    let change: GitChange?
    let children: [GitChangeTreeNode]
    var duplicateIndex = 0

    var id: String { "\(isDirectory ? "directory" : "file\(duplicateIndex)"):\(path)" }
    var isDirectory: Bool { change == nil }

    static func build(from changes: [GitChange]) -> [GitChangeTreeNode] {
        build(changes.map { ($0, $0.path.split(separator: "/").map(String.init)) }, prefix: "")
    }

    private static func build(_ entries: [(GitChange, [String])], prefix: String) -> [GitChangeTreeNode] {
        let groups = Dictionary(grouping: entries.filter { !$0.1.isEmpty }, by: { $0.1[0] })
        return groups.flatMap { name, group -> [GitChangeTreeNode] in
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let leaves = group.filter { $0.1.count == 1 }
            let descendants = group.filter { $0.1.count > 1 }.map { ($0.0, Array($0.1.dropFirst())) }
            var nodes: [GitChangeTreeNode] = []
            // Replacing a tracked file with a directory can report both the
            // deleted file and new descendants at the same path.
            if !descendants.isEmpty {
                nodes.append(GitChangeTreeNode(path: path, name: name, change: nil, children: build(descendants, prefix: path)))
            }
            // Git reports one entry per path and group. Keep any extra entry
            // visible instead of dropping it from Tree mode.
            for (index, leaf) in leaves.enumerated() {
                nodes.append(GitChangeTreeNode(path: path, name: name, change: leaf.0, children: [],
                                               duplicateIndex: index))
            }
            return nodes
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// Lane transitions for a topologically ordered history, including forks and
/// merges. Coordinates use one row (0...1) so the view can choose its density.
struct GitGraphSegment {
    let startLane: Int
    let endLane: Int
    let startY: Double
    let endY: Double
    let colorLane: Int
}

struct GitGraphRow: Identifiable {
    let commit: GitCommit
    let lane: Int
    let laneCount: Int
    let segments: [GitGraphSegment]

    var id: String { commit.id }

    static func build(from commits: [GitCommit]) -> [GitGraphRow] {
        var lanes: [String] = []
        return commits.map { original in
            var commit = original
            var seen = Set<String>()
            commit.parents = original.parents.filter { seen.insert($0).inserted }
            let hasIncoming = lanes.contains(commit.id)
            if !hasIncoming { lanes.append(commit.id) }
            let before = lanes
            let lane = before.firstIndex(of: commit.id)!
            lanes.remove(at: lane)

            for (index, parent) in commit.parents.enumerated() where !lanes.contains(parent) {
                if index == 0 {
                    lanes.insert(parent, at: min(lane, lanes.count))
                } else {
                    lanes.append(parent)
                }
            }

            var segments: [GitGraphSegment] = []
            for (index, hash) in before.enumerated() where hash != commit.id {
                if let end = lanes.firstIndex(of: hash) {
                    segments.append(GitGraphSegment(startLane: index, endLane: end, startY: 0, endY: 1, colorLane: index))
                }
            }
            if hasIncoming {
                segments.append(GitGraphSegment(startLane: lane, endLane: lane, startY: 0, endY: 0.5, colorLane: lane))
            }
            for parent in commit.parents {
                if let end = lanes.firstIndex(of: parent) {
                    segments.append(GitGraphSegment(startLane: lane, endLane: end, startY: 0.5, endY: 1, colorLane: end))
                }
            }
            return GitGraphRow(commit: commit, lane: lane, laneCount: max(before.count, lanes.count), segments: segments)
        }
    }
}

// MARK: - Pure helpers shared with the Source Control UI

/// How one commit's dot is drawn in the history graph.
struct GitGraphDotMark: Equatable {
    /// Unpushed commits draw as a hollow dot: they exist only locally.
    let isHollow: Bool
    /// HEAD gets a ring around its dot so the current commit stands out.
    let hasHeadRing: Bool

    static func mark(isHead: Bool, isUnpushed: Bool) -> GitGraphDotMark {
        GitGraphDotMark(isHollow: isUnpushed, hasHeadRing: isHead)
    }
}

enum GitRefName {
    /// Shortens a remote branch such as "origin/feature" to "feature" for
    /// menus. Names without a remote prefix are returned unchanged.
    static func shortName(ofRemoteBranch name: String) -> String {
        guard let slash = name.firstIndex(of: "/"),
              slash != name.startIndex,
              name.index(after: slash) != name.endIndex else { return name }
        return String(name[name.index(after: slash)...])
    }
}

/// Validation shared by the branch, rename and tag sheets, so bad names are
/// rejected before Git runs. The rules follow `git check-ref-format` closely
/// enough for user-facing feedback; Git remains the final authority.
enum GitRefNameRules {
    /// Every single character Git forbids in a ref name (besides space, which
    /// the whitespace rule already covers).
    private static let forbiddenCharacters = Set(" ~^:?*[\\")

    /// A user-facing problem with the candidate name, or nil when the name is
    /// acceptable. Empty input returns nil; callers disable empty separately.
    static func problem(with candidate: String, reserved: Set<String> = []) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if reserved.contains(trimmed) { return "“\(trimmed)” is a reserved name." }
        if trimmed.hasPrefix("-") { return "A name cannot start with “-”." }
        if trimmed.hasPrefix("/") { return "A name cannot start with “/”." }
        if trimmed.hasSuffix("/") { return "A name cannot end with “/”." }
        if trimmed.hasSuffix(".lock") { return "A name cannot end with “.lock”." }
        if trimmed.contains("..") { return "A name cannot contain “..”." }
        if trimmed.contains("@{") { return "A name cannot contain “@{”." }
        if trimmed.contains(where: \.isWhitespace) { return "A name cannot contain spaces or tabs." }
        if let forbidden = trimmed.first(where: { forbiddenCharacters.contains($0) }) {
            return "A name cannot contain “\(forbidden)”."
        }
        if trimmed.contains(where: isControlCharacter) {
            return "A name cannot contain control characters."
        }
        return nil
    }

    private static func isControlCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// The "↓behind ↑ahead" counter shown on the sync button.
enum GitSyncBadge {
    static func label(ahead: Int, behind: Int) -> String? {
        guard ahead > 0 || behind > 0 else { return nil }
        return "↓\(behind) ↑\(ahead)"
    }
}
