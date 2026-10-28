import Foundation

// MARK: - Raw commit object

/// A commit object split into byte-exact pieces, so a rewrite can preserve
/// everything except the parts that must change: author and committer lines
/// (identity and dates), the encoding header, other headers such as
/// `mergetag`, and the full message bytes of every untouched commit.
struct RawCommit: Sendable {
    var tree: String
    var parents: [String]
    /// All headers other than `tree`/`parent`, in their original order and
    /// original byte form (continuation lines included). Signature headers
    /// (`gpgsig`, `gpgsig-sha256`) are dropped: they cannot survive a rewrite.
    var otherHeaders: [Data]
    /// The complete message, byte-exact, starting right after the blank line.
    var message: Data

    private static let space = Data(" ".utf8)

    /// Parses the output of `git cat-file commit <id>`.
    static func parse(_ data: Data) -> RawCommit? {
        let blankLine = Data("\n\n".utf8)
        let headerData: Data
        let messageData: Data
        if let range = data.firstRange(of: blankLine) {
            headerData = data.subdata(in: data.startIndex..<range.lowerBound)
            messageData = data.subdata(in: range.upperBound..<data.endIndex)
        } else {
            // A commit object always has a blank line, but tolerate one that
            // does not: treat everything as headers, no message.
            headerData = data
            messageData = Data()
        }

        // Header lines; a line starting with a space continues the previous
        // header (e.g. a folded gpgsig).
        var lines: [Data] = []
        var lineStart = headerData.startIndex
        for index in headerData.indices where headerData[index] == UInt8(ascii: "\n") {
            lines.append(headerData.subdata(in: lineStart..<index))
            lineStart = headerData.index(after: index)
        }
        if lineStart < headerData.endIndex {
            lines.append(headerData.subdata(in: lineStart..<headerData.endIndex))
        }

        var blocks: [(name: String, bytes: Data)] = []
        var current: (name: String, bytes: Data)?
        for line in lines {
            if line.first == UInt8(ascii: " "), let existing = current {
                var bytes = existing.bytes
                bytes.append(UInt8(ascii: "\n"))
                bytes.append(line)
                current = (existing.name, bytes)
                continue
            }
            if let existing = current {
                blocks.append(existing)
                current = nil
            }
            // A header line is "name<space>value".
            guard let range = line.firstRange(of: space) else { continue }
            let name = String(decoding: line.subdata(in: line.startIndex..<range.lowerBound), as: UTF8.self)
            current = (name, line)
        }
        if let existing = current {
            blocks.append(existing)
        }

        var tree: String?
        var parents: [String] = []
        var others: [Data] = []
        for block in blocks {
            switch block.name {
            case "tree", "parent":
                guard let range = block.bytes.firstRange(of: space) else { continue }
                let value = String(
                    decoding: block.bytes.subdata(in: range.upperBound..<block.bytes.endIndex),
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                if block.name == "tree" { tree = value } else { parents.append(value) }
            case "gpgsig", "gpgsig-sha256":
                continue
            default:
                others.append(block.bytes)
            }
        }
        guard let tree else { return nil }
        return RawCommit(tree: tree, parents: parents, otherHeaders: others, message: messageData)
    }

    /// Rebuilds the commit object with new parents and a new message.
    /// Headers are emitted in their original order after the tree/parent lines.
    func serialized(parents newParents: [String], message newMessage: Data) -> Data {
        var out = Data()
        out.append(Data("tree \(tree)\n".utf8))
        for parent in newParents {
            out.append(Data("parent \(parent)\n".utf8))
        }
        for header in otherHeaders {
            out.append(header)
            out.append(UInt8(ascii: "\n"))
        }
        out.append(UInt8(ascii: "\n"))
        out.append(newMessage)
        return out
    }

    /// The message as a String (UTF-8; non-UTF-8 bodies surface as replacement
    /// characters, matching the rest of the app's display behavior).
    var messageText: String {
        String(decoding: message, as: UTF8.self)
    }
}

// MARK: - Reword via plumbing

extension SourceControlManager {

    /// Rewrites history so `commitID` carries `message`, rebuilding every
    /// descendant commit on the `--ancestry-path` from it to HEAD with
    /// plumbing only (`cat-file` + `hash-object` + `update-ref`). The index
    /// and the working tree are never touched, and the branch ref is updated
    /// with a compare-and-swap on the old value.
    nonisolated static func reword(
        commitID: String,
        message: String,
        root: URL,
        runner: GitRunner
    ) async throws {
        // Resolve to a full commit id.
        let resolved = try await runner.run(
            ["rev-parse", "--verify", "\(commitID)^{commit}"],
            in: root
        ).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { throw GitError.invalidInput("Unknown commit.") }

        // Only unpushed commits reachable from HEAD may be reworded.
        let reachable = try await runner.runRaw(
            ["merge-base", "--is-ancestor", resolved, "HEAD"],
            in: root
        )
        guard reachable.exitCode == 0 else {
            throw GitError.invalidInput("The commit is not reachable from the current branch.")
        }
        guard try await isUnpushed(resolved, root: root, runner: runner) else {
            throw GitError.invalidInput("The commit has already been pushed and cannot be rewritten.")
        }
        guard await operationState(root: root, runner: runner) == .none else {
            throw GitError.invalidInput("An operation is in progress; finish or abort it first.")
        }

        // All commits strictly between the target and HEAD, parents first.
        let descendants = try await runner.run(
            ["rev-list", "--topo-order", "--reverse", "--ancestry-path", "\(resolved)..HEAD"],
            in: root
        ).stdoutString.split(separator: "\n").map(String.init).filter { !$0.isEmpty }

        let oldHead = try await runner.run(["rev-parse", "HEAD"], in: root)
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldHead.isEmpty else { throw GitError.invalidInput("Could not resolve HEAD.") }

        // Rewritten ids keyed by original id. Merge parents are mapped through
        // this table; parents outside the rewritten range stay unchanged.
        var rewritten: [String: String] = [:]

        // 1. The commit being reworded: same tree, same parents, new message.
        let original = try await rawCommit(resolved, root: root, runner: runner)
        var newMessage = Data(message.utf8)
        if !newMessage.isEmpty, newMessage.last != UInt8(ascii: "\n") {
            newMessage.append(UInt8(ascii: "\n"))
        }
        rewritten[resolved] = try await writeCommit(
            original.serialized(parents: original.parents, message: newMessage),
            root: root,
            runner: runner
        )

        // 2. Every descendant: same tree, message bytes untouched, parents
        // remapped. Reverse topo order guarantees parents were rebuilt first.
        for oid in descendants {
            let commit = try await rawCommit(oid, root: root, runner: runner)
            let newParents = commit.parents.map { rewritten[$0] ?? $0 }
            rewritten[oid] = try await writeCommit(
                commit.serialized(parents: newParents, message: commit.message),
                root: root,
                runner: runner
            )
        }

        guard let newHead = rewritten[oldHead] ?? rewritten[resolved] else {
            throw GitError.invalidInput("Could not rebuild history.")
        }

        // 3. Compare-and-swap the ref (detached: --no-deref HEAD).
        let symref = try await runner.runRaw(["symbolic-ref", "--quiet", "HEAD"], in: root)
        if symref.exitCode == 0 {
            let ref = symref.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ref.isEmpty else { throw GitError.invalidInput("Could not determine the current branch.") }
            _ = try await runner.run(
                ["update-ref", "-m", "TypstEdit: reword", ref, newHead, oldHead],
                in: root
            )
        } else {
            _ = try await runner.run(
                ["update-ref", "-m", "TypstEdit: reword", "--no-deref", "HEAD", newHead, oldHead],
                in: root
            )
        }
    }

    nonisolated private static func rawCommit(_ oid: String, root: URL, runner: GitRunner) async throws -> RawCommit {
        let data = try await runner.run(["cat-file", "commit", oid], in: root).stdout
        guard let parsed = RawCommit.parse(data) else {
            throw GitError.invalidInput("Could not read commit \(oid).")
        }
        return parsed
    }

    nonisolated private static func writeCommit(_ raw: Data, root: URL, runner: GitRunner) async throws -> String {
        let oid = try await runner.run(["hash-object", "-t", "commit", "-w", "--stdin"], in: root, input: raw)
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oid.isEmpty else { throw GitError.invalidInput("Could not write the rewritten commit.") }
        return oid
    }
}
