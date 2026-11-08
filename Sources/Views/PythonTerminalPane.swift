import SwiftUI
import AppKit
import SwiftTerm

/// The Python pane: a real terminal on the right side of the window where a
/// Typst or Markdown document would show its PDF preview.
///
/// It hosts the user's login shell in the file's folder, so running a script,
/// a test suite or a package installer needs no separate terminal window. The
/// pane header keeps the four actions that matter for a script (`Run`,
/// `Interrupt`, `Clear`, `Restart`) one click away.
struct PythonTerminalPane: View {
    @ObservedObject var model: PythonTerminalModel
    @ObservedObject var editorController: EditorController

    @EnvironmentObject var themeManager: ThemeManager

    /// The folder a fresh shell starts in: the Python file's folder, or the
    /// project root when the file has none yet.
    let directory: URL

    /// Runs the current file. Owned by `ContentView`, because a clean run
    /// saves the buffer first.
    let onRun: () -> Void

    /// True while the Python file has unsaved edits. The Run button's tooltip
    /// explains that Run saves first.
    let hasUnsavedChanges: Bool

    @State private var didFocus = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            terminalBody
        }
        .background(terminalBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(themeManager.textColor.opacity(0.8))

            Text("Terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(themeManager.textColor.opacity(0.85))

            Text(abbreviatedDirectory)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(themeManager.textColor.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.head)
                .help(model.currentDirectory.path)

            if !model.isRunning {
                Text("exited")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(Capsule())
            }

            Spacer(minLength: 6)

            headerButton(
                icon: "play.fill",
                help: hasUnsavedChanges
                    ? "Run \(editorController.currentFileURL?.lastPathComponent ?? "file") (saves first)"
                    : "Run \(editorController.currentFileURL?.lastPathComponent ?? "file")"
            ) { onRun() }

            headerButton(
                icon: "stop.fill",
                help: "Interrupt the running command (Ctrl-C)"
            ) { model.interrupt() }

            headerButton(
                icon: "eraser",
                help: "Clear the screen (Ctrl-L)"
            ) { model.clear() }

            headerButton(
                icon: "arrow.clockwise",
                help: "Restart the shell in this file's folder"
            ) { model.restart(directory: directory); didFocus = false }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
    }

    private func headerButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .foregroundColor(themeManager.textColor.opacity(0.8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var abbreviatedDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = model.currentDirectory.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: - Terminal

    private var terminalBody: some View {
        ZStack {
            PythonTerminalRepresentable(
                model: model,
                directory: directory,
                isDark: editorController.isPreviewDarkMode
            )
            // A new session is a new NSView; the old one (and its scrollback)
            // must go, not be reused.
            .id(model.sessionID)

            if model.didExit {
                exitedOverlay
            }
        }
        .onAppear {
            // Give the shell view first-responder status once the window has
            // ordered it in, so typing works without a click.
            guard !didFocus else { return }
            didFocus = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                model.focusInput()
            }
        }
    }

    /// Shown when the user types `exit`, a crash ends the shell, or the
    /// process is stopped. The scrollback stays readable underneath.
    private var exitedOverlay: some View {
        VStack(spacing: 8) {
            Text("The shell has exited.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.textColor)
            Button("Start a New Shell") {
                model.restart(directory: directory)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var terminalBackground: SwiftUI.Color {
        SwiftUI.Color(nsColor: editorController.isPreviewDarkMode
            ? NSColor(calibratedWhite: 0.07, alpha: 1.0)
            : NSColor(calibratedWhite: 0.99, alpha: 1.0))
    }
}

// MARK: - The AppKit view

/// Wraps the PTY-backed SwiftTerm view. The model owns the terminal, so
/// SwiftUI updates (theme changes, view resizes) never restart the shell.
/// Each instance has its own `TerminalContainer`, so a layout switch moves the
/// terminal between panes instead of tearing it out of the visible one.
private struct PythonTerminalRepresentable: NSViewRepresentable {
    @ObservedObject var model: PythonTerminalModel
    let directory: URL
    let isDark: Bool

    func makeNSView(context: Context) -> TerminalContainer {
        let container = TerminalContainer()
        container.host(model.terminalView(directory: directory, isDark: isDark))
        return container
    }

    func updateNSView(_ container: TerminalContainer, context: Context) {
        model.updateAppearance(isDark: isDark)
        container.host(model.terminalView(directory: directory, isDark: isDark))
    }
}
