import SwiftUI

struct WelcomeView: View {
    @ObservedObject var model: FileSystemModel
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var recents = RecentFilesManager.shared
    /// Called when the user taps a recent file. Receives the full RecentFile so
    /// the caller can reopen it the way it was last used: in its project, in
    /// the Notes window, or on its own.
    var onOpen: (RecentFilesManager.RecentFile) -> Void
    
    @State private var showingTemplateSelection = false
    @State private var showClearConfirmation = false
    @State private var openingFileId: UUID? = nil

    private func recentIcon(for file: RecentFilesManager.RecentFile) -> String {
        switch file.kind {
        case .project: return "folder"
        case .notebook: return "book.closed"
        case .standalone: return "doc.text"
        }
    }

    private func recentIconColor(for file: RecentFilesManager.RecentFile) -> Color {
        switch file.kind {
        case .project: return .blue
        case .notebook: return .indigo
        case .standalone: return .secondary
        }
    }
    
    /// Resolves "System" to the actual current appearance so the welcome
    /// screen's logo always matches the Dock icon's light/dark artwork.
    private var isDarkTheme: Bool {
        switch themeManager.appTheme {
        case .dark: return true
        case .light: return false
        case .system: return colorScheme == .dark
        }
    }
    
    private var appIconImage: Image {
        let resourceName = isDarkTheme ? "AppIconDark" : "AppIcon"
        
        // Try simple name first (standard Asset Catalog)
        if let image = NSImage(named: resourceName) {
            print("[DEBUG] WelcomeView: Loaded \(resourceName) via NSImage(named:)")
            return Image(nsImage: image)
        }
        
        // Try looking in the module bundle specifically (SPM)
        if let path = ModuleResources.main.path(forResource: resourceName, ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            print("[DEBUG] WelcomeView: Loaded \(resourceName) via Bundle.module.path (Root)")
            return Image(nsImage: image)
        }
        
        // If the dark artwork is somehow missing, fall back to the light icon
        // rather than the generic system glyph.
        if resourceName != "AppIcon",
           let path = ModuleResources.main.path(forResource: "AppIcon", ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            print("[DEBUG] WelcomeView: \(resourceName) unavailable, fell back to AppIcon")
            return Image(nsImage: image)
        }
        
        print("[ERROR] WelcomeView: Failed to load AppIcon image from all known locations")
        // Fallback to system icon if all fails
        return Image(systemName: "doc.text.fill")
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left Panel: Actions (Centered)
            VStack(spacing: 30) {
                Spacer()
                appIconImage
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 160, height: 160)
                    .shadow(radius: 10)
                
                Text("Welcome to TypstEdit")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(themeManager.textColor)
                
                Text("Create beautiful documents with the power of Typst.")
                    .font(.body)
                    .foregroundColor(themeManager.textColor.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                VStack(spacing: 20) {
                    HStack(spacing: 20) {
                        Button(action: { model.createNewFile() }) {
                            VStack {
                                Image(systemName: "doc.badge.plus")
                                    .font(.system(size: 24))
                                    .padding(.bottom, 5)
                                    .foregroundColor(.blue)
                                Text("New File")
                                    .font(.headline)
                                    .foregroundColor(themeManager.textColor)
                            }
                            .frame(width: 140, height: 100)
                            .background(Color.primary.opacity(0.1))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: { showingTemplateSelection = true }) {
                            VStack {
                                Image(systemName: "plus.square.fill")
                                    .font(.system(size: 24))
                                    .padding(.bottom, 5)
                                    .foregroundColor(.blue)
                                Text("New Project")
                                    .font(.headline)
                                    .foregroundColor(themeManager.textColor)
                            }
                            .frame(width: 140, height: 100)
                            .background(Color.primary.opacity(0.1))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    
                    HStack(spacing: 20) {
                        Button(action: { model.openFile() }) {
                            VStack {
                                Image(systemName: "doc")
                                    .font(.system(size: 24))
                                    .padding(.bottom, 5)
                                    .foregroundColor(.blue)
                                Text("Open File")
                                    .font(.headline)
                                    .foregroundColor(themeManager.textColor)
                            }
                            .frame(width: 140, height: 100)
                            .background(Color.primary.opacity(0.1))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: { model.openFolder() }) {
                            VStack {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 24))
                                    .padding(.bottom, 5)
                                    .foregroundColor(.blue)
                                Text("Open Project")
                                    .font(.headline)
                                    .foregroundColor(themeManager.textColor)
                            }
                            .frame(width: 140, height: 100)
                            .background(Color.primary.opacity(0.1))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 20) {
                        Button(action: {
                            AppDelegate.shared?.openNotebooks()
                        }) {
                            VStack {
                                Image(systemName: "book.closed")
                                    .font(.system(size: 24))
                                    .padding(.bottom, 5)
                                    .foregroundColor(.indigo)
                                Text("Notebooks")
                                    .font(.headline)
                                    .foregroundColor(themeManager.textColor)
                            }
                            .frame(width: 140, height: 100)
                            .background(Color.primary.opacity(0.1))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 20)
                
                Button("Open Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.currentFolder?.path ?? FileManager.default.homeDirectoryForCurrentUser.path)
                }
                .buttonStyle(.link)
                .foregroundColor(themeManager.textColor.opacity(0.7))
                Spacer()
            }
            .frame(maxWidth: .infinity)
            
            // Divider
            Rectangle().fill(Color.primary.opacity(0.2)).frame(width: 1)
            
            // Right Panel: Recent Files
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent Files")
                        .font(.headline)
                        .foregroundColor(themeManager.textColor)
                    Spacer()
                    if !recents.recentFiles.isEmpty {
                        Button(action: { showClearConfirmation = true }) {
                            Text("Clear")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .confirmationDialog("Clear Recent Files", isPresented: $showClearConfirmation, titleVisibility: .visible) {
                            Button("Clear All", role: .destructive) {
                                recents.clearAll()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This will remove all entries from the recent files list.")
                        }
                    }
                }
                .padding()
                .padding(.top, 20)
                
                if recents.recentFiles.isEmpty {
                    Spacer()
                    Text("No recent files")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                } else {
                    List {
                        ForEach(recents.recentFiles) { file in
                            Button(action: {
                                openingFileId = file.id
                                // Use Task to yield to main runloop so the spinner appears before the blocking read
                                Task {
                                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                                    onOpen(file)
                                    openingFileId = nil
                                }
                            }) {
                                HStack {
                                    if openingFileId == file.id {
                                        ProgressView()
                                            .controlSize(.small)
                                            .frame(width: 16, height: 16)
                                    } else {
                                        Image(systemName: recentIcon(for: file))
                                            .foregroundColor(recentIconColor(for: file))
                                    }
                                    VStack(alignment: .leading) {
                                        Text(file.name)
                                            .foregroundColor(themeManager.textColor)
                                            .truncationMode(.middle)
                                        HStack(spacing: 4) {
                                            Text(file.kindLabel)
                                                .font(.caption2)
                                                .foregroundColor(recentIconColor(for: file))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 3)
                                                        .fill(recentIconColor(for: file).opacity(0.1))
                                                )
                                            Text(file.path)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 270)
            .background(Color.primary.opacity(0.1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.mainBackground.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Funnel through the shared, debounced entry point so a double-click
            // that is also seen by the AppKit title-bar monitor zooms exactly once.
            AppDelegate.toggleWindowZoom()
        }
        .sheet(isPresented: $showingTemplateSelection) {
            TemplateSelectionView { template in
                model.createNewProject(template: template)
            }
            .environmentObject(themeManager)
        }
        .onAppear {
            recents.validateRecentFiles()
        }
    }
}
