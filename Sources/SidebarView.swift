import SwiftUI

struct FileNode: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?
}

@MainActor
class FileSystemModel: ObservableObject {
    @Published var rootNodes: [FileNode] = []
    @Published var currentFolder: URL?
    @Published var expandedFolders: Set<URL> = []
    
    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK {
            self.currentFolder = panel.url
            loadFiles()
        }
    }
    
    func loadFiles() {
        guard let folder = currentFolder else { return }
        self.rootNodes = loadDirectory(at: folder)
    }
    
    private func loadDirectory(at url: URL) -> [FileNode] {
        var nodes: [FileNode] = []
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            
            let sortedContents = contents.sorted { lhs, rhs in
                let lhsDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let rhsDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                
                if lhsDir != rhsDir {
                    return lhsDir // Directories first
                }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            
            for file in sortedContents {
                let isDir = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                var children: [FileNode]? = nil
                
                if isDir {
                    children = loadDirectory(at: file)
                }
                
                nodes.append(FileNode(url: file, name: file.lastPathComponent, isDirectory: isDir, children: children))
            }
        } catch {
            print("Error listing directory: \(error)")
        }
        return nodes
    }
    
    func createNewProject(template: ProjectTemplate) {
        let panel = NSSavePanel()
        panel.title = "Create New Project Folder"
        panel.nameFieldStringValue = "New Project"
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                let mainFile = url.appendingPathComponent("main.typ")
                let content = template.content
                try content.write(to: mainFile, atomically: true, encoding: .utf8)
                self.currentFolder = url
                loadFiles()
            } catch {
                print("Error creating project: \(error)")
            }
        }
    }
    
    func toggleExpansion(for node: FileNode) {
        if expandedFolders.contains(node.url) {
            expandedFolders.remove(node.url)
        } else {
            expandedFolders.insert(node.url)
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: FileSystemModel
    @Binding var selectedFile: URL?
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var compiler = TypstCompiler()
    @StateObject private var editorController = EditorController()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 0) {
                if let folderName = model.currentFolder?.lastPathComponent {
                    HStack {
                        Text(folderName.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1)
                            .foregroundColor(themeManager.textColor.opacity(0.6))
                        Spacer()
                        
                        Button(action: { model.loadFiles() }) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(themeManager.textColor.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: { model.openFolder() }) {
                            Image(systemName: "folder.badge.plus")
                                .foregroundColor(themeManager.textColor.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }
                
                // File Tree
                List(model.rootNodes, children: \.children) { node in
                    SidebarRow(node: node, selectedFile: $selectedFile)
                        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            selectedFile == node.url ? Color.blue.opacity(0.2) : Color.clear
                        )
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            
            Divider()
                .background(themeManager.secondaryTextColor.opacity(0.3))
            
            // Error Panel
            ErrorPanelView(compiler: compiler, editorController: editorController)
                .environmentObject(themeManager)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.sidebarBackground.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: .typstErrorsUpdated)) { notification in
            if let errors = notification.object as? [TypstError] {
                compiler.errors = errors
            }
        }
    }
}

struct SidebarRow: View {
    let node: FileNode
    @Binding var selectedFile: URL?
    @EnvironmentObject var themeManager: ThemeManager
    
    var isSelected: Bool {
        selectedFile == node.url
    }
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: node))
                .foregroundColor(iconColor(for: node))
                .font(.system(size: 13))
            
            Text(node.name)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .white : themeManager.textColor)
            
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle()) // Make full row clickable
        .onTapGesture {
            if !node.isDirectory {
                selectedFile = node.url
            }
        }
    }
    
    func iconName(for node: FileNode) -> String {
        if node.isDirectory {
            return "folder.fill"
        }
        if node.name.hasSuffix(".typ") {
            return "doc.text.fill"
        }
        if node.name.hasSuffix(".pdf") {
            return "doc.text" // PDF icon? 
        }
        return "doc"
    }
    
    func iconColor(for node: FileNode) -> Color {
        if node.isDirectory {
            return .blue
        }
        if node.name.hasSuffix(".typ") {
            return .orange
        }
        return themeManager.textColor // Match text color for better visibility in light mode
    }
}
