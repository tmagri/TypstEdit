# Git source control

The **Source Control** panel appears below the file tree in the **Projects** sidebar. Each project window uses its own repository.

The panel finds repositories in parent folders and supports Git worktrees. Change paths refer to the repository root, which can differ from the project folder.

Git must be available at `/usr/bin/git`. Remote actions use your existing Git credentials and SSH configuration. TypstEdit does not provide a login dialog.

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

A file can appear in both groups if its saved contents changed after staging. Binary files show a Git summary instead of a text diff.

Changes use **Tree** mode by default. The **… → Changes View** menu also offers **List** mode. Folders and change groups can collapse independently.

The **+** beside **Changes** stages all changes. The **−** beside **Staged Changes** unstages all changes. Each file also has a staging or unstaging button.

## Branches and remotes

The branch menu shows local branches. **Create Branch…** creates a branch and switches to it. Branch actions do not overwrite unsaved editor changes.

The **Graph** section shows recent commits, branch labels, forks, and merges. Commit tooltips show the author, date, and hash. The context menu can copy a commit hash or message.

The **Graph** toolbar and **…** menu provide **Fetch**, **Pull**, and **Push**. Pull uses fast-forward only. Git errors appear in the panel; failed commits keep the message.

Remote actions require an existing remote. Git must have access to credentials without an interactive terminal prompt.

## Discard changes

CAUTION: Review the file path before you discard changes. Discard permanently removes saved, unstaged changes. It keeps staged changes.

1. Open the context menu on a tracked file in **Changes**.
2. Click **Discard Changes…**.
3. Review the file path in the confirmation dialog.
4. Click **Discard**.

The panel does not discard untracked files or files with merge conflicts. It disables discard for an open file with unsaved editor changes.

## Refresh

The panel refreshes after Git actions, project saves, and file operations. It also refreshes when the app becomes active.

If another tool changes the repository while TypstEdit remains active, click the refresh button beside **Source Control**.
