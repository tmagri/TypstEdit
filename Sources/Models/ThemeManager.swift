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

class ThemeManager: ObservableObject {
    @AppStorage("appTheme") var appTheme: AppTheme = .system {
        willSet { objectWillChange.send() }
    }
    
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