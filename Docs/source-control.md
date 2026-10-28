# Git source control

The **Source Control** panel appears below the file tree in the **Projects** sidebar. Each project window uses its own repository.

The panel finds repositories in parent folders and supports Git worktrees. Change paths refer to the repository root, which can differ from the project folder.

Git must be available at `/usr/bin/git`.

## Review and commit changes

1. Open a project folder.
2. If the project has no repository, click **Initialize Repository**.
3. Save your editor changes.
4. Expand **Changes** to review the changed files.
5. Click a file to open its diff preview.
6. Click **+** beside a file to stage its changes.
7. Enter a commit message.
8. Click **Commit**, or press **⌘Enter** in the message field.

**Commit** includes staged changes only. **Staged Changes** compares HEAD with the index. **Changes** compares the index with saved files. Neither diff includes unsaved editor changes.

Changes use **Tree** mode by default. The **… → Changes View** menu also offers **List** mode.

The arrow beside **Commit** opens more commit actions:

| Action | Result |
|---|---|
| **Commit (Amend)** | Replaces the last commit with the staged changes and the message. An empty message box gets the last message. |
| **Commit & Push** | Commits, then pushes. |
| **Commit & Sync** | Commits, then pulls and pushes. |
| **Undo Last Commit** | Removes the last commit. Its changes stay staged, and its message goes back to the message box. |

Amend and **Undo Last Commit** are available only for a commit that is not pushed.

## Edit commits that are not pushed

The **Graph** shows each commit that is not pushed with a hollow dot. HEAD has a ring.

To change the message of a commit that is not pushed:

1. Open the context menu on the commit in **Graph**.
2. Click **Reword Message…**.
3. Edit the message.
4. Click **Save**.

Reword changes the commit message only. It does not change your files or the index. If later commits exist, TypstEdit creates them again with the same contents and authors. Only the current branch moves to the new commits. Other branches and tags keep the old commits.

Reword is not available for pushed commits, because a change would need a force push.

The context menu of a commit also has **Undo Commit**, **Checkout (Detached)…**, **Create Branch Here…**, **Create Tag Here…**, **Cherry-pick**, **Revert…**, **Copy Hash**, and **Copy Message**.

## Branches, tags, and remotes

The branch menu can switch to local or remote branches. It can also create, rename, delete, merge, and rebase branches. It also creates and deletes tags.

The button on the branch bar shows incoming (↓) and outgoing (↑) commits. Click it to sync: TypstEdit pulls, then pushes. If the branch has no upstream, the button shows **Publish Branch**.

The arrow beside the sync button offers **Pull (Fast-forward Only)**, **Pull (Merge)**, **Pull (Rebase)**, **Fetch**, and **Push**.

While a network action runs, the panel shows its name and a **Cancel** button. A network action stops after 5 minutes.

If Git needs a password, a passphrase, or a host-key answer, TypstEdit shows a macOS dialog. Saved credentials from the macOS keychain and your SSH configuration work as before.

## Merge conflicts

A merge, rebase, cherry-pick, or revert can stop with conflicts. Then a banner shows the operation, and files with conflicts appear in **Merge Changes**.

For each file with conflicts, use one of these actions:

- **Accept Current** keeps your version of the file.
- **Accept Incoming** keeps the other version of the file.
- **Open File** opens the file to edit the conflict markers.
- **Mark as Resolved** stages the file after you edit it.

Click **Continue** in the banner after all conflicts are resolved. Click **Abort** to cancel the operation and go back to the previous state.

## Stashes

The **…** menu can stash changes, with or without untracked files. It can also apply or pop the latest stash. The **Stashes** section lists all stashes, with apply, pop, and drop actions.

## Discard changes

CAUTION: Review the file path before you discard changes. Discard removes saved, unstaged changes. Staged changes stay.

1. Open the context menu on a file in **Changes**.
2. Click **Discard Changes…**.
3. Review the file path in the confirmation dialog.
4. Click **Discard**.

**Discard All Changes…** discards all unstaged changes. Discarded untracked files go to the Trash, so you can restore them. Discarded changes to tracked files cannot be restored.

## Open files and unsaved edits

Pull, sync, checkout, stash, merge, and similar actions can change files on disk. After each action, every editor window examines its open file:

- An open file with no unsaved edits reloads at once.
- An open file with unsaved edits keeps your edits. The reload button in the toolbar lights up.
- If the action removed the open file, the editor keeps the text and shows a status message.

TypstEdit blocks actions that rewrite files while the open file has unsaved edits. Save the file to enable these actions.

## Refresh

The panel refreshes after Git actions, project saves, and file operations. It also refreshes when the app becomes active.

If another tool changes the repository while TypstEdit remains active, click the refresh button beside **Source Control**.

## Limits

- File names that are not valid UTF-8 can show incorrectly, and actions on them can fail.
- TypstEdit does not show a 3-way merge editor. Edit the conflict markers in the file, or accept one version.
- Commit signing and hooks use your Git configuration. Reword creates new commits without a signature.
