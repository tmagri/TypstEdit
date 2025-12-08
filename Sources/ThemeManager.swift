import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case dark
    case light
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

class ThemeManager: ObservableObject {
    @Published var currentTheme: AppTheme = .dark
    
    // MARK: - Theme Colors
    
    // MARK: - Theme Colors
    
    // Backgrounds are now clear to let VisualEffectView show through
    var mainBackground: Color {
        return .clear
    }
    
    var sidebarBackground: Color {
        return .clear
    }
    
    // Editor and PDF are now semi-transparent "plates" or "cards"
    var editorBackground: Color {
        switch currentTheme {
        case .dark:
            return Color.black.opacity(0.25) // Dark translucent plate
        case .light:
            return Color.black.opacity(0.12) // Lighter transparency variant of dark
        }
    }
    
    var pdfBackground: Color {
        switch currentTheme {
        case .dark:
            return Color.black.opacity(0.35) // Slightly darker plate for PDF
        case .light:
            return Color.black.opacity(0.18) // Slightly heavier than editor, but still transparent black
        }
    }
    
    var textColor: Color {
        switch currentTheme {
        case .dark:
            return Color.white.opacity(0.9)
        case .light:
            return Color.white.opacity(0.9)
        }
    }
    
    var secondaryTextColor: Color {
        switch currentTheme {
        case .dark:
            return Color.white.opacity(0.6)
        case .light:
            return Color.white.opacity(0.7)
        }
    }
    
    var accentColor: Color {
        switch currentTheme {
        case .dark:
            return Color(red: 0.27, green: 0.60, blue: 0.96)
        case .light:
            return Color(red: 0.4, green: 0.7, blue: 1.0)
        }
    }
    
    var shadowColor: Color {
        switch currentTheme {
        case .dark:
            return Color.black.opacity(0.3)
        case .light:
            return Color.black.opacity(0.15)
        }
    }
    
    var shadowRadius: CGFloat {
        return 8 // Subtle shadow
    }
    
    // MARK: - Material Effects
    
    var useBlurEffect: Bool {
        return true // Always use blur effect now
    }
    
    // MARK: - Sidebar Helpers
    
    func sidebarTextColor(isSelected: Bool) -> Color {
        if isSelected {
            return textColor
        } else {
            return secondaryTextColor
        }
    }
    
    func sidebarRowBackground(isSelected: Bool) -> Color {
        // Semi-transparent selection
        return isSelected ? accentColor.opacity(0.3) : .clear
    }
    
    // MARK: - Panel Distinction Overlays
    
    var sidebarOverlay: Color {
        switch currentTheme {
        case .dark:
            return Color.black.opacity(0.15) // More pronounced darkening for sidebar
        case .light:
            return Color.black.opacity(0.05) // Very subtle black tint
        }
    }
    
    var contentOverlay: Color {
        // Main content area overlay (behind editor/pdf boxes)
        switch currentTheme {
        case .dark:
            return Color.white.opacity(0.05) // Subtle lightening to distinguish from sidebar
        case .light:
            return Color.white.opacity(0.1) // Subtle white tint to differentiate
        }
    }
    
    var toolbarBackground: Color {
        switch currentTheme {
        case .dark:
            return Color.black.opacity(0.2)
        case .light:
            return Color.black.opacity(0.1)
        }
    }
    
    var toolbarOverlay: Color {
        // Subtle overlay for top toolbar area
        switch currentTheme {
        case .dark:
            return Color.black.opacity(0.1)
        case .light:
            return Color.black.opacity(0.05)
        }
    }
}
