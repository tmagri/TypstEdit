import Foundation

// MARK: - Branches, tags, merge/rebase, stash, conflicts, sync

extension SourceControlManager {

    // MARK: Sync

    /// Pulls with `mode` and then pushes; a failed pull skips the push.
    /// When no upstream is configured the pull is skipped and the push sets
    /// the upstream.
    func sync(mode: GitPullMode) async {
        guard hasRemote else {
            errorMessage = "This repository has no remote."
            return
        }
        let network = makeNetworkGit()
        let pullArguments = upstream == nil ? nil : Self.pullArguments(for: mode)
        var pushArguments = ["push", "--quiet"]
        if upstream == nil {
            guard !isDetached, !isUnborn, !branch.isEmpty else {
                errorMessage = isUnborn ? "Create a commit before pushing." : "Check out a branch before pushing."
                return
            }
            let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
            pushArguments += ["--set-upstream", remote, "refs/heads/\(branch):refs/heads/\(branch)"]
        }
        await perform(label: "Syncing…", touchesWorkingTree: true) { root, _ in
            if let pullArguments {
                _ = try await network.run(pullArguments, in: root)
            }
            _ = try await network.run(pushArguments, in: root)
        }
    }

    nonisolated private static func pullArguments(for mode: GitPullMode) -> [String] {
        switch mode {
        case .fastForwardOnly: return ["pull", "--no-rebase", "--ff-only", "--quiet"]
        case .merge: return ["pull", "--no-rebase", "--quiet"]
        case .rebase: return ["pull", "--rebase", "--quiet"]
        }
    }

    // MARK: Branches

    /// Switches to the local branch tracking `remoteBranch`, creating it with
    /// `--track` when it does not exist yet.
    func checkoutRemoteBranch(_ remoteBranch: String) async {
        let trimmed = remoteBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), trimmed.contains("/") else {
            errorMessage = "Invalid remote branch name."
            return
        }
        await perform(label: "Switching branches…", touchesWorkingTree: true) { root, runner in
            let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw GitError.invalidInput("Invalid remote branch name.") }
            let localName = String(parts[1])
            let exists = try await runner.runRaw(
                ["show-ref", "--verify", "--quiet", "refs/heads/\(localName)"],
                in: root
            )
            if exists.exitCode == 0 {
                // The branch exists: use it only if it really tracks the remote branch.
                let upstreamResult = try await runner.runRaw(
                    ["for-each-ref", "--format=%(upstream:short)", "refs/heads/\(localName)"],
                    in: root
                )
                let upstreamName = upstreamResult.stdoutString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard upstreamName == trimmed else {
                    throw GitError.invalidInput(
                        "Branch '\(localName)' already exists and does not track '\(trimmed)'."
                    )
                }
                _ = try await runner.run(["switch", "--quiet", localName], in: root)
            } else {
                // Starting from a remote-tracking branch sets up tracking
                // automatically (checkout/switch default for -c <start-point>).
                _ = try await runner.run(
                    ["switch", "--quiet", "--create", localName, trimmed],
                    in: root
                )
            }
        }
    }

    func checkoutDetached(_ commitID: String) async {
        let trimmed = commitID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            errorMessage = "Invalid commit."
            return
        }
        await perform(label: "Detaching HEAD…", touchesWorkingTree: true) { root, runner in
            _ = try await runner.run(
                ["switch", "--quiet", "--detach", "\(trimmed)^{commit}"],
                in: root
            )
        }
    }

    /// Creates a branch (switching to it), at HEAD or at a specific commit.
    /// Branching at a commit other than HEAD rewrites the working tree.
    func createBranch(name: String, at commitID: String?) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            errorMessage = "Invalid branch name."
            return
        }
        let target = commitID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let touches = !(target?.isEmpty ?? true)
        await perform(label: "Creating branch…", touchesWorkingTree: touches) { root, runner in
            let format = try await runner.runRaw(
                ["check-ref-format", "--branch", trimmed],
                in: root
            )
            guard format.exitCode == 0 else {
                throw GitError.invalidInput("'\(trimmed)' is not a valid branch name.")
            }
            let exists = try await runner.runRaw(
                ["show-ref", "--verify", "--quiet", "refs/heads/\(trimmed)"],
                in: root
            )
            guard exists.exitCode != 0 else {
                throw GitError.invalidInput("A branch named '\(trimmed)' already exists.")
            }
            if let target, !target.isEmpty {
                guard try await Self.headExists(root: root, runner: runner) else {
                    throw GitError.invalidInput("Create a commit before branching from one.")
                }
                _ = try await runner.run(
                    ["switch", "--quiet", "--create", trimmed, "\(target)^{commit}"],
                    in: root
                )
            } else if try await Self.headExists(root: root, runner: runner) {
                _ = try await runner.run(["switch", "--quiet", "--create", trimmed], in: root)
            } else {
                // Unborn HEAD: just repoint HEAD; index and files are untouched.
                _ = try await runner.run(["symbolic-ref", "HEAD", "refs/heads/\(trimmed)"], in: root)
            }
        }
    }

    func createBranch(name: String) async {
        await createBranch(name: name, at: nil)
    }

    func renameBranch(_ old: String, to new: String) async {
        let oldName = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldName.isEmpty, !oldName.hasPrefix("-") else {
            errorMessage = "Invalid branch name."
            return
        }
        guard !newName.isEmpty, !newName.hasPrefix("-") else {
            errorMessage = "Invalid branch name."
            return
        }
        await perform(label: "Renaming branch…", touchesWorkingTree: false) { root, runner in
            let format = try await runner.runRaw(["check-ref-format", "--branch", newName], in: root)
            guard format.exitCode == 0 else {
                throw GitError.invalidInput("'\(newName)' is not a valid branch name.")
            }
            let exists = try await runner.runRaw(
                ["show-ref", "--verify", "--quiet", "refs/heads/\(oldName)"],
                in: root
            )
            guard exists.exitCode == 0 else {
                throw GitError.invalidInput("Branch '\(oldName)' does not exist.")
            }
            _ = try await runner.run(["branch", "--quiet", "-m", oldName, newName], in: root)
        }
    }

    func deleteBranch(_ name: String, force: Bool) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            errorMessage = "Invalid branch name."
            return
        }
        await perform(label: "Deleting branch…", touchesWorkingTree: false) { root, runner in
            let exists = try await runner.runRaw(
                ["show-ref", "--verify", "--quiet", "refs/heads/\(trimmed)"],
                in: root
            )
            guard exists.exitCode == 0 else {
                throw GitError.invalidInput("Branch '\(trimmed)' does not exist.")
            }
            let current = try await runner.runRaw(["symbolic-ref", "--short", "--quiet", "HEAD"], in: root)
            let currentBranch = current.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current.exitCode != 0 || currentBranch != trimmed else {
                throw GitError.invalidInput("Branch '\(trimmed)' is checked out and cannot be deleted.")
            }
            _ = try await runner.run(
                ["branch", "--quiet", force ? "-D" : "-d", trimmed],
                in: root
            )
        }
    }

    // MARK: Merge / rebase

    /// Merges a local or remote branch into the current one. Conflicts leave
    /// `operationState == .merging`.
    func mergeBranch(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            errorMessage = "Invalid branch name."
            return
        }
        await perform(label: "Merging…", touchesWorkingTree: true) { root, runner in
            _ = try await runner.run(["merge", "--no-edit", trimmed], in: root)
        }
    }

    /// Rebases the current branch onto `name`. Conflicts leave
    /// `operationState == .rebasing`.
    func rebaseCurrentBranch(onto name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            errorMessage = "Invalid branch name."
            return
        }
        await perform(label: "Rebasing…", touchesWorkingTree: true) { root, runner in
            _ = try await runner.run(["rebase", trimmed], in: root)
        }
    }

    // MARK: Tags

    func createTag(name: String, message: String?, at commitID: String?) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            errorMessage = "Invalid tag name."
            return
        }
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let annotated = (text?.isEmpty == false)
        let target = commitID?.trimmingCharacters(in: .whitespacesAndNewlines)
        await perform(label: "Creating tag…", touchesWorkingTree: false) { root, runner in
            var arguments = ["tag"]
            if annotated {
                // Message via stdin: no argument parsing issues.
                arguments.append(contentsOf: ["-a", "--file=-"])
            }
            arguments.append(trimmed)
            if let target, !target.isEmpty {
                arguments.append("\(target)^{commit}")
            }
            _ = try await runner.run(
                arguments,
                in: root,
                input: annotated ? Data((text! + "\n").utf8) : nil
            )
        }
    }

    func deleteTag(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            errorMessage = "Invalid tag name."
            return
        }
        await perform(label: "Deleting tag…", touchesWorkingTree: false) { root, runner in
            _ = try await runner.run(["tag", "-d", trimmed], in: root)
        }
    }

    // MARK: Commits from the graph

    func revertCommit(_ commitID: String) async {
        await revertOrCherryPick(["revert", "--no-edit"], commitID: commitID, label: "Reverting…")
    }

    func cherryPick(_ commitID: String) async {
        await revertOrCherryPick(["cherry-pick"], commitID: commitID, label: "Cherry-picking…")
    }

    private func revertOrCherryPick(_ command: [String], commitID: String, label: String) async {
        let trimmed = commitID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            errorMessage = "Invalid commit."
            return
        }
        await perform(label: label, touchesWorkingTree: true) { root, runner in
            // Resolve before touching anything.
            _ = try await runner.run(["rev-parse", "--verify", "\(trimmed)^{commit}"], in: root)
            _ = try await runner.run(command + [trimmed], in: root)
        }
    }

    // MARK: Stash

    func stash(message: String?, includeUntracked: Bool) async {
        var arguments = ["stash", "push", "--quiet"]
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty {
            arguments.append(contentsOf: ["-m", text])
        }
        if includeUntracked {
            arguments.append("-u")
        }
        await perform(label: "Stashing…", touchesWorkingTree: true) { root, runner in
            _ = try await runner.run(arguments, in: root)
        }
    }

    func applyStash(_ stash: GitStash) async {
        await perform(label: "Applying stash…", touchesWorkingTree: true) { root, runner in
            _ = try await runner.run(["stash", "apply", "--quiet", stash.id], in: root)
        }
    }

    func popStash(_ stash: GitStash) async {
        await perform(label: "Applying stash…", touchesWorkingTree: true) { root, runner in
            _ = try await runner.run(["stash", "pop", "--quiet", stash.id], in: root)
        }
    }

    func dropStash(_ stash: GitStash) async {
        await perform(label: "Dropping stash…", touchesWorkingTree: false) { root, runner in
            _ = try await runner.run(["stash", "drop", "--quiet", stash.id], in: root)
        }
    }

    // MARK: Conflicts / in-progress operations

    /// Takes the current side of a conflicted file, then stages it.
    func acceptCurrent(_ change: GitChange) async {
        await accept(change, side: "--ours")
    }

    /// Takes the incoming side of a conflicted file, then stages it.
    func acceptIncoming(_ change: GitChange) async {
        await accept(change, side: "--theirs")
    }

    private func accept(_ change: GitChange, side: String) async {
        let path = change.path
        await perform(label: "Resolving…", touchesWorkingTree: true) { root, runner in
            _ = try await runner.run(["checkout", "--quiet", side, "--", path], in: root)
            _ = try await runner.run(["add", "--", path], in: root)
        }
    }

    /// Stages a conflicted file the user resolved by hand.
    func markResolved(_ change: GitChange) async {
        let path = change.path
        await perform(label: "Resolving…", touchesWorkingTree: false) { root, runner in
            _ = try await runner.run(["add", "--", path], in: root)
        }
    }

    /// Aborts the merge/rebase/cherry-pick/revert in progress.
    func abortOperation() async {
        let state = operationState
        guard state != .none else {
            errorMessage = "No operation is in progress."
            return
        }
        await perform(label: "Aborting…", touchesWorkingTree: true) { root, runner in
            let command: [String]
            switch state {
            case .merging: command = ["merge", "--abort"]
            case .rebasing: command = ["rebase", "--abort"]
            case .cherryPicking: command = ["cherry-pick", "--abort"]
            case .reverting: command = ["revert", "--abort"]
            case .none: throw GitError.invalidInput("No operation is in progress.")
            }
            _ = try await runner.run(command, in: root)
        }
    }

    /// Continues the operation in progress. For merges the commit message is
    /// `message`, or the recorded MERGE_MSG when nil. Refuses while conflicts
    /// remain.
    @discardableResult
    func continueOperation(message: String?) async -> Bool {
        let state = operationState
        guard state != .none else {
            errorMessage = "No operation is in progress."
            return false
        }
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergeMessage = (state == .merging && text?.isEmpty == false) ? text : nil
        let messageData = mergeMessage.map { Data(($0 + "\n").utf8) }
        return await perform(label: "Continuing…", touchesWorkingTree: true) { root, runner in
            // Refuse while conflicts remain (checked live, not from the cache).
            let unmerged = try await runner.runRaw(["ls-files", "-z", "--unmerged"], in: root)
            guard unmerged.exitCode == 0, unmerged.stdout.isEmpty else {
                throw GitError.invalidInput("Resolve the remaining conflicts before continuing.")
            }
            switch state {
            case .merging:
                if let messageData {
                    _ = try await runner.run(
                        ["commit", "--quiet", "--file=-", "--cleanup=strip"],
                        in: root,
                        input: messageData
                    )
                } else {
                    _ = try await runner.run(["commit", "--quiet", "--no-edit"], in: root)
                }
            case .rebasing:
                _ = try await runner.run(["rebase", "--continue"], in: root)
            case .cherryPicking:
                _ = try await runner.run(["cherry-pick", "--continue"], in: root)
            case .reverting:
                _ = try await runner.run(["revert", "--continue"], in: root)
            case .none:
                throw GitError.invalidInput("No operation is in progress.")
            }
        }
    }

    /// The message git recorded for the commit in progress (MERGE_MSG),
    /// for prefilling the commit box.
    func pendingOperationMessage() async -> String? {
        guard let root = repositoryRoot else { return nil }
        guard let path = try? await Self.gitPath("MERGE_MSG", root: root, runner: runner),
              !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
