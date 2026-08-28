import SwiftUI
import UniformTypeIdentifiers

struct NotebookSidebarView: View {
    @StateObject private var notebookManager = NotebookManager.shared
    @Binding var selectedFile: URL?
    @EnvironmentObject var themeManager: ThemeManager
    
    @State private var showNewNotebookAlert = false
    @State private var newNotebookName = ""
    
    @State private var showNewPageAlert = false
    @State private var newPageName = ""
    @State private var selectedNotebookForNewPage: Notebook?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("NOTEBOOKS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundColor(themeManager.textColor.opacity(0.6))
                
                Spacer()
                
                Button(action: {
                    notebookManager.loadNotebooks()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(themeManager.textColor.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Refresh Notebooks")
                
                Button(action: {
                    if let firstNotebook = notebookManager.notebooks.first {
                        selectedNotebookForNewPage = firstNotebook
                    } else {
                        // Auto-create default notebook if none exists
                        notebookManager.createNotebook(name: "My Notes")
                        if let newlyCreated = notebookManager.notebooks.first {
                            selectedNotebookForNewPage = newlyCreated
                        }
                    }
                    showNewPageAlert = true
                }) {
                    Image(systemName: "square.and.pencil")
                        .foregroundColor(themeManager.textColor.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("New Note")
                
                Button(action: { showNewNotebookAlert = true }) {
                    Image(systemName: "folder.badge.plus")
                        .foregroundColor(themeManager.textColor.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("New Notebook")
                
                Button(action: {
                    importNotebook()
                }) {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundColor(themeManager.textColor.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Restore Notebook from Zip")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            // List of Notebooks
            List {
                if notebookManager.notebooks.isEmpty {
                    VStack(alignment: .center, spacing: 12) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 32))
                            .foregroundColor(themeManager.textColor.opacity(0.4))
                        Text("No Notebooks")
                            .font(.headline)
                            .foregroundColor(themeManager.textColor.opacity(0.7))
                        Text("Create a notebook or add a note to get started.")
                            .font(.caption)
                            .foregroundColor(themeManager.textColor.opacity(0.5))
                            .multilineTextAlignment(.center)
                        
                        Button(action: { showNewNotebookAlert = true }) {
                            Text("Create Notebook")
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.indigo)
                                .foregroundColor(.white)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(notebookManager.notebooks) { notebook in
                        DisclosureGroup {
                            ForEach(notebook.pages) { page in
                                NotebookPageRow(page: page, selectedFile: $selectedFile)
                                    .environmentObject(themeManager)
                            }
                            
                            Button(action: {
                                selectedNotebookForNewPage = notebook
                                showNewPageAlert = true
                            }) {
                                HStack {
                                    Image(systemName: "plus")
                                    Text("New Page")
                                    Spacer()
                                }
                                .font(.system(size: 12))
                                .foregroundColor(themeManager.textColor.opacity(0.5))
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                        } label: {
                            NotebookRow(notebook: notebook, manager: notebookManager, onAddNote: {
                                selectedNotebookForNewPage = notebook
                                showNewPageAlert = true
                            })
                            .environmentObject(themeManager)
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            // Same density rule as the project sidebar: .plain rows hug
            // their content; .sidebar forces tall platform rows.
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.sidebarBackground.ignoresSafeArea())
        .alert("New Notebook", isPresented: $showNewNotebookAlert) {
            TextField("Notebook Name", text: $newNotebookName)
            Button("Cancel", role: .cancel) { newNotebookName = "" }
            Button("Create") {
                if !newNotebookName.isEmpty {
                    notebookManager.createNotebook(name: newNotebookName)
                    newNotebookName = ""
                }
            }
        }
        .alert("New Page", isPresented: $showNewPageAlert) {
            TextField("Page Name", text: $newPageName)
            Button("Cancel", role: .cancel) { newPageName = "" }
            Button("Create") {
                if !newPageName.isEmpty, let notebook = selectedNotebookForNewPage {
                    if let url = notebookManager.createPage(in: notebook, name: newPageName) {
                        selectedFile = url
                    }
                    newPageName = ""
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshNotebooks)) { _ in
            notebookManager.loadNotebooks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuCommand)) { notification in
            if let command = notification.object as? String, command == "refreshNotebooks" {
                notebookManager.loadNotebooks()
            }
        }
    }
    
    private func importNotebook() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.zip]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Restore Notebook"
        panel.message = "Select a .zip file to restore."
        
        if panel.runModal() == .OK, let zipURL = panel.url {
            let defaultName = zipURL.deletingPathExtension().lastPathComponent
            let alert = NSAlert()
            alert.messageText = "Restore Notebook"
            alert.informativeText = "Enter a name for the restored notebook:"
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Cancel")
            
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            input.stringValue = defaultName
            alert.accessoryView = input
            
            if alert.runModal() == .alertFirstButtonReturn {
                let name = input.stringValue.isEmpty ? defaultName : input.stringValue
                Task {
                    _ = await notebookManager.restoreNotebook(from: zipURL, name: name)
                }
            }
        }
    }
}

struct NotebookRow: View {
    let notebook: Notebook
    let manager: NotebookManager
    var onAddNote: () -> Void
    @EnvironmentObject var themeManager: ThemeManager
    @State private var showDeleteAlert = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "book.closed.fill")
                .foregroundColor(.indigo)
                .font(.system(size: 12))
            Text(explorerAbbreviatedName(notebook.name))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.textColor)
                .lineLimit(1)
            Spacer()

            Button(action: onAddNote) {
                Image(systemName: "plus")
                    .foregroundColor(themeManager.textColor.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Add Note")
        }
        .padding(.vertical, 2)
        .help(notebook.name)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Refresh Notebooks") {
                manager.loadNotebooks()
            }
            
            Divider()
            
            Button("Rename Notebook") {
                renameText = notebook.name
                showRenameAlert = true
            }
            
            Button("Open as Project") {
                NotificationCenter.default.post(name: .openProjectFolder, object: notebook.url)
            }
            
            Divider()
            
            Button("Export Notebook to Zip") {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType.zip]
                panel.nameFieldStringValue = "\(notebook.name).zip"
                if panel.runModal() == .OK, let url = panel.url {
                    Task {
                        _ = await manager.exportNotebook(notebook, to: url)
                    }
                }
            }
            Divider()
            Button("Delete Notebook", role: .destructive) {
                showDeleteAlert = true
            }
        }
        .alert("Rename Notebook", isPresented: $showRenameAlert) {
            TextField("New Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameText = "" }
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != notebook.name {
                    _ = manager.renameNotebook(url: notebook.url, newName: trimmed)
                }
                renameText = ""
            }
        }
        .alert("Delete Notebook '\(notebook.name)'?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                manager.deleteNotebook(url: notebook.url)
            }
        } message: {
            Text("This will permanently delete the notebook and all its pages.")
        }
    }
}

struct NotebookPageRow: View {
    let page: NotebookPage
    @Binding var selectedFile: URL?
    @EnvironmentObject var themeManager: ThemeManager
    @State private var showDeleteAlert = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    
    var isSelected: Bool {
        selectedFile == page.url
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text.fill")
                .foregroundColor(.orange)
                .font(.system(size: 12))
            Text(explorerAbbreviatedName(page.name))
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .white : themeManager.textColor)
                .lineLimit(1)
            Spacer()
        }
        .help(page.name)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.8) : Color.clear)
        .cornerRadius(4)
        .listRowSeparator(.hidden)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedFile = page.url
        }
        .contextMenu {
            Button("Refresh Notebooks") {
                NotebookManager.shared.loadNotebooks()
            }
            
            Divider()
            
            Button("Rename Page") {
                renameText = page.name
                showRenameAlert = true
            }
            Divider()
            Button("Delete Page", role: .destructive) {
                showDeleteAlert = true
            }
        }
        .alert("Rename Page", isPresented: $showRenameAlert) {
            TextField("New Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameText = "" }
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != page.name {
                    if let newURL = NotebookManager.shared.renamePage(url: page.url, newName: trimmed) {
                        // Update selectedFile if the renamed page was currently open
                        if selectedFile == page.url {
                            selectedFile = newURL
                        }
                    }
                }
                renameText = ""
            }
        }
        .alert("Delete Page '\(page.name)'?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                NotebookManager.shared.deletePage(url: page.url)
                if selectedFile == page.url {
                    selectedFile = nil
                }
            }
        } message: {
            Text("This will move the page to the Trash.")
        }
    }
}
