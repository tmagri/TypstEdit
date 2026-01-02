import SwiftUI
import PDFKit

struct PreviewView: NSViewRepresentable {
    var url: URL?
    var reloadToken: UUID?
    var colorBlindnessMode: EditorController.ColorBlindnessMode = .none

    @EnvironmentObject var themeManager: ThemeManager

    func makeNSView(context: Context) -> PDFView {
        print("[DEBUG] PreviewView makeNSView called")
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .clear 
        
        // Enable layer for CoreImage filters
        pdfView.wantsLayer = true
        
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        // Update Theme Appearance
        pdfView.backgroundColor = .clear
        pdfView.autoScales = true
        pdfView.appearance = NSAppearance(named: .darkAqua)
        
        // Update Background Color from ThemeManager (translucent)
        pdfView.backgroundColor = NSColor(themeManager.pdfBackground)
        
        // Apply Color Blindness Filter
         applyColorBlindnessFilter(to: pdfView, mode: colorBlindnessMode)
        
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
    
    private func applyColorBlindnessFilter(to view: NSView, mode: EditorController.ColorBlindnessMode) {
        guard let layer = view.layer else { return }
        
        if mode == .none {
            layer.filters = []
            return
        }
        
        let matrix: [CGFloat]
        switch mode {
        case .protanopia:
            matrix = [
                0.567, 0.433, 0.0, 0.0,
                0.558, 0.442, 0.0, 0.0,
                0.0, 0.242, 0.758, 0.0,
                0.0, 0.0, 0.0, 1.0
            ]
        case .deuteranopia:
            matrix = [
                0.625, 0.375, 0.0, 0.0,
                0.7, 0.3, 0.0, 0.0,
                0.0, 0.3, 0.7, 0.0,
                0.0, 0.0, 0.0, 1.0
            ]
        case .tritanopia:
            matrix = [
                0.95, 0.05, 0.0, 0.0,
                0.0, 0.433, 0.567, 0.0,
                0.0, 0.475, 0.525, 0.0,
                0.0, 0.0, 0.0, 1.0
            ]
        case .none:
            return
        }
        
        if let filter = CIFilter(name: "CIColorMatrix") {
            let vectorR = CIVector(values: [matrix[0], matrix[1], matrix[2], matrix[3]], count: 4)
            let vectorG = CIVector(values: [matrix[4], matrix[5], matrix[6], matrix[7]], count: 4)
            let vectorB = CIVector(values: [matrix[8], matrix[9], matrix[10], matrix[11]], count: 4)
            let vectorA = CIVector(values: [matrix[12], matrix[13], matrix[14], matrix[15]], count: 4)
            
            filter.setValue(vectorR, forKey: "inputRVector")
            filter.setValue(vectorG, forKey: "inputGVector")
            filter.setValue(vectorB, forKey: "inputBVector")
            filter.setValue(vectorA, forKey: "inputAVector")
            
            layer.filters = [filter]
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
