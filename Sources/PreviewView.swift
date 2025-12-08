import SwiftUI
import PDFKit

struct PreviewView: NSViewRepresentable {
    var url: URL?
    var reloadToken: UUID?

    @EnvironmentObject var themeManager: ThemeManager

    func makeNSView(context: Context) -> PDFView {
        print("[DEBUG] PreviewView makeNSView called")
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .clear 
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        // Update Theme Appearance
        pdfView.appearance = NSAppearance(named: themeManager.currentTheme == .light ? .aqua : .darkAqua)
        
        // Update Background Color explicitly (converting SwiftUI Color to NSColor)
        // We use a helper or simple conversation here since ThemeManager uses Color
        // Update Background Color from ThemeManager (translucent)
        pdfView.backgroundColor = NSColor(themeManager.pdfBackground)
        
        print("[DEBUG] PreviewView updateNSView called")
        print("[DEBUG] URL: \(String(describing: url))")
        print("[DEBUG] reloadToken: \(String(describing: reloadToken))")
        
        if let url = url {
            if context.coordinator.lastUrl != url || context.coordinator.lastToken != reloadToken {
                print("[DEBUG] PDF needs reload - loading from: \(url)")
                
                if let document = PDFDocument(url: url) {
                    print("[DEBUG] ✅ PDF loaded successfully - pages: \(document.pageCount)")
                    
                    // Preserve scroll point
                    let point = pdfView.currentDestination?.point ?? .zero
                    let pageIndex = pdfView.currentPage.map { pdfView.document?.index(for: $0) ?? 0 } ?? 0
                    
                    pdfView.document = document
                    
                    // Restore scroll
                    if let page = document.page(at: pageIndex) {
                         pdfView.go(to: PDFDestination(page: page, at: point))
                    }
                } else {
                    print("[ERROR] ❌ Failed to load PDFDocument from URL: \(url)")
                }
                context.coordinator.lastUrl = url
                context.coordinator.lastToken = reloadToken
            } else {
                print("[DEBUG] PDF already loaded, no reload needed")
            }
        } else {
            print("[DEBUG] No URL provided, clearing document")
            pdfView.document = nil
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var lastUrl: URL?
        var lastToken: UUID?
    }
}
