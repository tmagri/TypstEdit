import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem {
                    Label("Appearance", systemImage: "paintpalette")
                }
                .tag("appearance")
            
            // Placeholder for General settings
            Text("General Settings")
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag("general")
        }
        .padding()
        .frame(width: 400, height: 250)
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        Form {
            Section {
                Text("The application uses a default dark theme designed for optimal readability.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("UI Theme")
            }
            .padding()
        }
        .padding()
    }
}
