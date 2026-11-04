import Foundation
import Combine
import SwiftUI

/// Everything project-scoped that one document window owns: the semantic
/// index, the AI chat sessions, the MCP server processes, and the skills.
///
/// Each `EditorController` has exactly one context, and a project folder is
/// open in at most one window (`ProjectWindowRouter` focuses the existing
/// window instead of opening a second one). So two projects never share an
/// index, a chat history or a running MCP server, the same way each VS Code
/// window has its own extension host.
@MainActor
final class ProjectContext: ObservableObject {
    /// A context that never has a project root. Used where no window exists:
    /// the Settings window with every document window closed, and tests.
    static let detached = ProjectContext()

    /// Short, stable for this context's lifetime. Keeps the window's compiler
    /// scratch files apart from every other window's.
    let instanceID: String = String(UUID().uuidString.prefix(8)).lowercased()

    let rag = RAGManager()
    let skills = SkillsManager()
    let mcp = MCPManager()
    private(set) lazy var chat: AIChatSessionStore = AIChatSessionStore(context: self)

    @Published private(set) var projectRoot: URL?

    init() {}

    /// Called by `EditorController` when its project folder changes
    /// (including to `nil`, for a standalone file or the welcome screen).
    func setProjectRoot(_ url: URL?) {
        guard self !== Self.detached else { return }
        guard projectRoot != url else { return }
        if projectRoot != nil, url != projectRoot {
            rag.disableForStandaloneMode()
        }
        projectRoot = url
        skills.setProjectRoot(url)
        mcp.setProjectRoot(url)
    }

    /// The window is closing: stop every process and close the index. The
    /// chat sessions are already saved on disk.
    func close() {
        guard self !== Self.detached else { return }
        chat.close()
        mcp.stopAll()
        rag.disableForStandaloneMode()
    }
}

/// The frontmost document window's editor and context. The menu bar acts on
/// this window. The Settings window has no project of its own, so it edits
/// the project-scoped skills and MCP servers of the window the user was last
/// working in, like VS Code's settings editor edits the active workspace.
@MainActor
final class ActiveProjectContext: ObservableObject {
    static let shared = ActiveProjectContext()

    private(set) weak var controller: EditorController?
    @Published private(set) var generation = 0

    private init() {}

    var context: ProjectContext { controller?.projectContext ?? .detached }

    func activate(_ controller: EditorController) {
        guard self.controller !== controller else { return }
        self.controller = controller
        generation += 1
    }

    /// A window closed. When it was the active one, fall back until the next
    /// window becomes key.
    func deactivate(_ controller: EditorController) {
        guard self.controller === controller else { return }
        self.controller = nil
        generation += 1
    }
}

extension Notification.Name {
    /// Posted by a `SkillsManager` or `MCPManager` after it changed a global
    /// (app-wide) skill or MCP server, so every other window's manager
    /// reloads its list. The object is the manager that made the change.
    static let globalAIConfigurationDidChange = Notification.Name("globalAIConfigurationDidChange")
}

/// Re-renders its content with the frontmost window's context whenever the
/// user switches windows.
struct ActiveProjectContextReader<Content: View>: View {
    @ObservedObject private var active = ActiveProjectContext.shared
    private let content: (ProjectContext) -> Content

    init(@ViewBuilder content: @escaping (ProjectContext) -> Content) {
        self.content = content
    }

    var body: some View {
        content(active.context).id(ObjectIdentifier(active.context))
    }
}
