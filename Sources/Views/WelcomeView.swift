import SwiftUI

struct WelcomeView: View {
    @ObservedObject var model: FileSystemModel
    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var recents = RecentFilesManager.shared
    var onOpen: (URL) -> Void
    
    @State private var showingTemplateSelection = false
    
    private var appIconImage: Image {
        // Try simple name first (standard Asset Catalog)
        if let image = NSImage(named: "AppIcon") {
            print("[DEBUG] WelcomeView: Loaded AppIcon via NSImage(named:)")
            return Image(nsImage: image)
        }
        
        // Try looking in the module bundle specifically (SPM)
        if let path = Bundle.module.path(forResource: "AppIcon", ofType: "png") {
            if let image = NSImage(contentsOfFile: path) {
                print("[DEBUG] WelcomeView: Loaded AppIcon via Bundle.module.path (Root)")
                return Image(nsImage: image)
            }
        }
        
        // Try looking in the bundle by path (Loose file in Media.xcassets/AppIcon.imageset if not compiled)
        if let path = Bundle.module.path(forResource: "AppIcon", ofType: "png", inDirectory: "Media.xcassets/AppIcon.imageset") {
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
                Text("Recent Files")
                    .font(.headline)
                    .foregroundColor(themeManager.textColor)
                    .padding()
                    .padding(.top, 20)
                
                List {
                    ForEach(recents.recentFiles) { file in
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading) {
                                Text(file.name)
                                    .foregroundColor(themeManager.textColor)
                                .truncationMode(.middle)
                                Text(file.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onOpen(file.url)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .frame(width: 250)
            .background(Color.primary.opacity(0.1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.mainBackground.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let window = NSApp.keyWindow {
                window.zoom(nil)
            }
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
