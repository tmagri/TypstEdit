import Foundation

// MARK: - Credential prompt script

/// Generates the askpass script used by network operations (fetch, pull,
/// push, sync) so git and ssh can ask for credentials through a macOS dialog.
///
/// Security rules this helper follows:
/// - The prompt text is passed as `"$PROMPT"` on the command line and handed
///   to `osascript` as an argument referenced via `item 1 of argv`; it is
///   never interpolated into the AppleScript source.
/// - Password/passphrase prompts use `with hidden answer`; the answer is never
///   written anywhere, only printed to stdout for git to read.
/// - Cancelling the dialog makes the script exit 1.
/// - The script lives in a unique 0700 directory in the app temp area.
enum GitAskpass {
    static let scriptFileName = "askpass.sh"
    /// Touched by the script on every prompt; the network runner watches its
    /// modification date to restart the timeout while a dialog is up.
    static let activityFileName = "askpass-activity"

    /// The heartbeat file that belongs next to `scriptURL`.
    static func activityFileURL(forScript scriptURL: URL) -> URL {
        scriptURL.deletingLastPathComponent().appendingPathComponent(activityFileName)
    }

    /// The full, static script text. No user input ever enters this string.
    static func scriptBody() -> String {
        """
        #!/bin/sh
        # TypstEdit credential prompt for git and ssh.
        # The prompt arrives as the first argument and is handed to osascript
        # as an argument; it is never interpolated into the AppleScript source
        # and never written anywhere.
        PROMPT=${1:-"Git needs your input."}
        # Heartbeat: record that a credential dialog is about to open, so the
        # app restarts its network timeout while the user answers it. Failure
        # to write the file is harmless (the prompt still works).
        printf '%s\\n' "$$" > "${0%/*}/askpass-activity" 2>/dev/null || :
        case "$PROMPT" in
        *[Pp]assword*|*[Pp]assphrase*)
            if ANSWER=$(/usr/bin/osascript -e 'on run argv
        display dialog (item 1 of argv) default answer "" with hidden answer with title "TypstEdit" buttons {"Cancel", "OK"} default button "OK"
        return text returned of result
        end run' "$PROMPT"); then
                printf '%s\\n' "$ANSWER"
            else
                exit 1
            fi
            ;;
        *yes/no*|*Yes/No*|*YES/NO*)
            if REPLY=$(/usr/bin/osascript -e 'on run argv
        return button returned of (display dialog (item 1 of argv) with title "TypstEdit" buttons {"Cancel", "Yes"} default button "Yes")
        end run' "$PROMPT"); then
                case "$REPLY" in
                [Yy]es) printf 'yes\\n' ;;
                *) printf 'no\\n' ;;
                esac
            else
                exit 1
            fi
            ;;
        *)
            if ANSWER=$(/usr/bin/osascript -e 'on run argv
        display dialog (item 1 of argv) default answer "" with title "TypstEdit" buttons {"Cancel", "OK"} default button "OK"
        return text returned of result
        end run' "$PROMPT"); then
                printf '%s\\n' "$ANSWER"
            else
                exit 1
            fi
            ;;
        esac
        """
    }

    /// Environment variables pointing git and ssh at `scriptURL`.
    static func environment(for scriptURL: URL) -> [String: String] {
        [
            "GIT_ASKPASS": scriptURL.path,
            "SSH_ASKPASS": scriptURL.path,
            "SSH_ASKPASS_REQUIRE": "force",
        ]
    }

    /// Writes the script into a fresh, unique 0700 directory in the temp area
    /// and returns its URL. Returns nil when the script could not be created
    /// (the caller then leaves prompting disabled and lets git fail).
    static func installAskpassScript() -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypstEdit-askpass-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(scriptFileName)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data(scriptBody().utf8),
                attributes: [.posixPermissions: 0o700]
            ) else { return nil }
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Network runner

/// Runs git commands that may need the network. Each command:
/// - times out after `timeout` seconds, then the git process is killed;
/// - inherits the credential prompt environment from `runner`;
/// - cancels cleanly (killing git) when its task is cancelled.
///
/// While a credential dialog is up, the askpass script touches
/// `askpassActivityURL`; every touch restarts the timeout, so time spent
/// typing a password never counts toward the deadline.
struct NetworkGitRunner: Sendable {
    var runner: GitRunner
    var timeout: TimeInterval
    /// Watched for changes so the timeout restarts on each askpass prompt.
    var askpassActivityURL: URL?

    private enum Outcome {
        case done(GitCommandResult)
        case failed(Error)
        case timedOut
    }

    func run(
        _ arguments: [String],
        in directory: URL,
        input: Data? = nil,
        acceptedExitCodes: Set<Int32> = [0]
    ) async throws -> GitCommandResult {
        let seconds = max(0, timeout)
        // Race the command against the timer; whichever finishes first wins.
        return try await withThrowingTaskGroup(of: Outcome.self, returning: GitCommandResult.self) { group in
            group.addTask {
                do {
                    return .done(try await self.runner.run(arguments, in: directory, input: input, acceptedExitCodes: acceptedExitCodes))
                } catch {
                    return .failed(error)
                }
            }
            group.addTask {
                await self.countDown(seconds: seconds)
            }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            switch first {
            case .done(let result):
                return result
            case .failed(let error):
                throw error
            case .timedOut:
                throw GitError.timedOut(seconds: Int(seconds.rounded(.up)))
            }
        }
    }

    /// Returns `.timedOut` after `seconds` without an askpass heartbeat; each
    /// change of the activity file's modification date restarts the clock.
    /// Cancelling (a finished command) throws instead.
    private func countDown(seconds: TimeInterval) async -> Outcome {
        let activityURL = askpassActivityURL
        let pollNanoseconds: UInt64 = 500_000_000
        let pollInterval = TimeInterval(pollNanoseconds) / 1_000_000_000
        var lastActivity = Self.activityDate(of: activityURL)
        var waited: TimeInterval = 0
        while waited < seconds {
            do {
                try await Task.sleep(nanoseconds: pollNanoseconds)
            } catch {
                return .failed(CancellationError())
            }
            waited += pollInterval
            let current = Self.activityDate(of: activityURL)
            if current != lastActivity {
                // A credential dialog just opened: restart the countdown so
                // the user has the full timeout to answer it.
                lastActivity = current
                waited = 0
            }
        }
        return .timedOut
    }

    private static func activityDate(of url: URL?) -> Date? {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }
}
