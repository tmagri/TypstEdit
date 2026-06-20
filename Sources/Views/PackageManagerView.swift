import SwiftUI

struct PackageManagerView: View {
    @ObservedObject private var manager = PackageManager.shared
    @State private var searchText = ""
    
    var filteredPackages: [TypstPackageInfo] {
        if searchText.isEmpty { return manager.packages }
        return manager.packages.filter { 
            $0.name.localizedCaseInsensitiveContains(searchText) || 
            $0.description.localizedCaseInsensitiveContains(searchText) 
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search packages...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                
                Button(action: { Task { await manager.fetchPackages() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh list")
            }
            .padding()
            
            Divider()
            
            // List
            if manager.isLoading {
                VStack {
                    Spacer()
                    ProgressView("Loading packages...")
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredPackages, id: \.id) { pkg in
                    PackageRowView(pkg: pkg, manager: manager)
                }
                .listStyle(.inset)
            }
            
            // Status Footer
            if let status = manager.statusMessage {
                Divider()
                HStack {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(status.contains("Failed") ? .red : .secondary)
                    Spacer()
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .onAppear {
            if manager.packages.isEmpty {
                Task { await manager.fetchPackages() }
            }
        }
    }
}

struct PackageRowView: View {
    let pkg: TypstPackageInfo
    @ObservedObject var manager: PackageManager
    
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(pkg.name).font(.headline)
                    Text("v\(pkg.version)").font(.caption).foregroundColor(.secondary)
                }
                Text(pkg.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            Spacer()
            
            if manager.isInstalled(pkg) {
                Button("Reinstall") {
                    Task { await manager.installPackage(pkg) }
                }
                .disabled(manager.isInstalling)
            } else {
                Button("Install") {
                    Task { await manager.installPackage(pkg) }
                }
                .disabled(manager.isInstalling)
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }
        }
        .padding(.vertical, 4)
    }
}