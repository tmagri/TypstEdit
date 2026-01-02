import SwiftUI

class ThemeManager: ObservableObject {
    // Single dark theme - no theme switching needed
    
    // MARK: - Theme Colors
    
    // Backgrounds are clear to let VisualEffectView show through
    var mainBackground: Color {
        return .clear
    }
    
    var sidebarBackground: Color {
        return .clear
    }
    
    // Editor and PDF are semi-transparent "plates"
    var editorBackground: Color {
        return Color.black.opacity(0.25)
    }
    
    var pdfBackground: Color {
        return Color.black.opacity(0.35)
    }
    
    var textColor: Color {
        return Color.white.opacity(0.9)
    }
    
    var secondaryTextColor: Color {
        return Color.white.opacity(0.6)
    }
    
    var accentColor: Color {
        return Color(red: 0.27, green: 0.60, blue: 0.96)
    }
    
    var shadowColor: Color {
        return Color.black.opacity(0.3)
    }
    
    var shadowRadius: CGFloat {
        return 10
    }
    
    var contentOverlay: Color {
        return Color.clear
    }
    
    var sidebarOverlay: Color {
        return Color.black
    }
    
    // Search panel
    var searchPanelBackground: Color {
        return Color.black.opacity(0.6)
    }
    
    var searchFieldBackground: Color {
        return Color.black.opacity(0.3)
    }
    
    var searchMatchHighlight: Color {
        return Color.yellow.opacity(0.3)
    }
    
    var searchCurrentMatchHighlight: Color {
        return Color.yellow.opacity(0.5)
    }
}
