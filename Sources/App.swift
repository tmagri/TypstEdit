import SwiftUI

@main
struct TypstEditApp: App {
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var editorController = EditorController()
    @State private var selectedFile: URL?
    
    var body: some Scene {
        WindowGroup {
            ContentView(selectedFile: $selectedFile, editorController: editorController)
                .environmentObject(themeManager)
                // Applique l'effet de flou (Acrylic/Vibrancy) à tout le fond de la fenêtre
                .background(VisualEffectView().ignoresSafeArea())
        }
        .windowStyle(.hiddenTitleBar) // Cache la barre de titre native opaque
        .windowToolbarStyle(.unified) // Unifie la barre d'outils avec le contenu
        .commands {
            AppMenuCommands(themeManager: themeManager, selectedFile: $selectedFile, editorController: editorController)
        }
    }
}