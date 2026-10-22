import SwiftUI
import AppKit

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { self.rawValue }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
class ThemeManager: ObservableObject {
    @AppStorage("appTheme") var appTheme: AppTheme = .system {
        willSet { objectWillChange.send() }
        didSet { Self.applyDockIcon(for: appTheme) }
    }

    init() {
        // Picks up a persisted "Dark" preference immediately on launch, before
        // any explicit theme change happens this session.
        Self.applyDockIcon(for: appTheme)
    }

    /// The Dock tile normally stays the default light/blue artwork. When the
    /// user explicitly forces Dark theme in Settings, swap the running app's
    /// Dock icon for the black "dark mode" variant so it matches the rest of
    /// the system's dark utility icons (FaceTime, Phone, Reminders, ...).
    /// This only affects the live running app; Finder/Launchpad keep showing
    /// the bundle's default icon.
    private static func applyDockIcon(for theme: AppTheme) {
        NSApp.applicationIconImage = (theme == .dark) ? darkIconImage : nil
    }

    private static let darkIconImage: NSImage? = {
        if let path = ModuleResources.main.path(forResource: "AppIconDark", ofType: "png") {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }()
    
    var mainBackground: Color { .clear }
    var sidebarBackground: Color { .clear }
    
    var editorBackground: Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 
            NSColor.black.withAlphaComponent(0.25) : NSColor.white.withAlphaComponent(0.5)
        })
    }
    
    var pdfBackground: Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 
            NSColor.black.withAlphaComponent(0.35) : NSColor.black.withAlphaComponent(0.1)
        })
    }
    
    var textColor: Color { Color.primary }
    var secondaryTextColor: Color { Color.secondary }
    var accentColor: Color { Color.accentColor }
    var shadowColor: Color { Color.black.opacity(0.3) }
    var shadowRadius: CGFloat { 10 }
    var contentOverlay: Color { .clear }
    
    var sidebarOverlay: Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 
            NSColor.black : NSColor.white
        })
    }
    
    var searchPanelBackground: Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 
            NSColor.black.withAlphaComponent(0.6) : NSColor.white.withAlphaComponent(0.8)
        })
    }
    
    var searchFieldBackground: Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 
            NSColor.black.withAlphaComponent(0.3) : NSColor.black.withAlphaComponent(0.1)
        })
    }
    
    var searchMatchHighlight: Color { Color.yellow.opacity(0.3) }
    var searchCurrentMatchHighlight: Color { Color.yellow.opacity(0.5) }
}