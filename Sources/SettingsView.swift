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
                Picker("Theme", selection: $themeManager.currentTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("UI Theme")
            }
            .padding()
        }
        .padding()
    }
}
