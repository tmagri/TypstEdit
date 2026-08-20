import SwiftUI

struct WelcomeView: View {
    @ObservedObject var model: FileSystemModel
    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var recents = RecentFilesManager.shared
    /// Called when the user taps a recent file. Receives the full RecentFile so the
    /// caller can decide whether to open in project or standalone mode.
    var onOpen: (RecentFilesManager.RecentFile) -> Void
    
    @State private var showingTemplateSelection = false
    @State private var showClearConfirmation = false
    @State private var openingFileId: UUID? = nil
    
    private var appIconImage: Image {
        // Try simple name first (standard Asset Catalog)
        if let image = NSImage(named: "AppIcon") {
            print("[DEBUG] WelcomeView: Loaded AppIcon via NSImage(named:)")
            return Image(nsImage: image)
        }
        
        // Try looking in the module bundle specifically (SPM)
        if let path = ModuleResources.main.path(forResource: "AppIcon", ofType: "png") {
            if let image = NSImage(contentsOfFile: path) {
                print("[DEBUG] WelcomeView: Loaded AppIcon via Bundle.module.path (Root)")
                return Image(nsImage: image)
            }
        }
        
        // Try looking in the bundle by path (Loose file in Media.xcassets/AppIcon.imageset if not compiled)
        if let path = ModuleResources.main.path(forResource: "AppIcon", ofType: "png", inDirectory: "Media.xcassets/AppIcon.imageset") {
            if let image = NSImage(contentsOfFile: path) {
                print("[DEBUG] WelcomeView: Loaded AppIcon via Bundle.module.path (xcassets)")
                return Image(nsImage: image)
            }
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
                        Button(action: { NotificationCenter.default.post(name: Notification.Name("openNotebooks"), object: nil) }) {
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
                                        Image(systemName: file.isProject ? "folder" : "doc.text")
                                            .foregroundColor(file.isProject ? .blue : .secondary)
                                    }
                                    VStack(alignment: .leading) {
                                        Text(file.name)
                                            .foregroundColor(themeManager.textColor)
                                            .truncationMode(.middle)
                                        HStack(spacing: 4) {
                                            Text(file.isProject ? "Project" : "File")
                                                .font(.caption2)
                                                .foregroundColor(file.isProject ? .blue.opacity(0.8) : .secondary)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 3)
                                                        .fill(file.isProject ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.1))
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
