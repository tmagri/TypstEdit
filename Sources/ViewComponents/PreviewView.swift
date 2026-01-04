import SwiftUI
@preconcurrency import PDFKit

struct PreviewView: NSViewRepresentable {
    var url: URL?
    var reloadToken: UUID?
    var colorBlindnessMode: EditorController.ColorBlindnessMode = .none
    var isPreviewDarkMode: Bool = true
    var onWordCountChange: ((Int) -> Void)?

    @EnvironmentObject var themeManager: ThemeManager

    func makeNSView(context: Context) -> PDFView {
        print("[DEBUG] PreviewView makeNSView called")
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = isPreviewDarkMode ? NSColor(calibratedWhite: 0.1, alpha: 1.0) : .white
        
        pdfView.wantsLayer = true
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        // 1. Sync Background Color with Dark/Light state to avoid flicker
        let targetColor = isPreviewDarkMode ? NSColor(calibratedWhite: 0.1, alpha: 1.0) : .white
        if pdfView.backgroundColor != targetColor {
            pdfView.backgroundColor = targetColor
        }
        
        if pdfView.appearance?.name != .darkAqua {
            pdfView.appearance = NSAppearance(named: .darkAqua)
        }
        
        applyFilters(to: pdfView)
        
        guard !context.coordinator.isTransitioning else { return }
        
        if context.coordinator.lastUrl != url || context.coordinator.lastToken != reloadToken {
            print("[DEBUG] PreviewView: url/token changed. newURL=\(url?.lastPathComponent ?? "nil")")
            
            // Avoid unnecessary reloads if URL is nil and we already have nil
            if url == nil && pdfView.document == nil { return }
            
            guard let url = url else {
                print("[DEBUG] PreviewView: clearing document (url is nil)")
                pdfView.document = nil
                context.coordinator.lastUrl = nil
                return
            }

            // Defensive: Check if file exists, is not empty, and is readable
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path),
                  let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int64, size > 0,
                  fm.isReadableFile(atPath: url.path) else {
                print("[DEBUG] PreviewView: file not ready for PDFDocument (exists=\(fm.fileExists(atPath: url.path)), size=\((try? fm.attributesOfItem(atPath: url.path)[.size]) ?? "nil"), readable=\(fm.isReadableFile(atPath: url.path)))")
                // Don't clear document yet, maybe it's just a transient state during typst re-writing
                return
            }

            print("[DEBUG] PreviewView: attempting to load PDFDocument for \(url.lastPathComponent)")
            if let document = PDFDocument(url: url), document.pageCount > 0 {
                let point = pdfView.currentDestination?.point ?? .zero
                let pageIndex = pdfView.currentPage.map { pdfView.document?.index(for: $0) ?? 0 } ?? 0
                
                // --- OVERLAP TRANSITION LOGIC ---
                if let oldDocument = pdfView.document, oldDocument.pageCount > 0 {
                    context.coordinator.isTransitioning = true
                    let snapshotView = NSImageView(frame: pdfView.bounds)
                    snapshotView.imageScaling = .scaleProportionallyUpOrDown
                    
                    let bitmap = pdfView.bitmapImageRepForCachingDisplay(in: pdfView.bounds)
                    if let bitmap = bitmap {
                        pdfView.cacheDisplay(in: pdfView.bounds, to: bitmap)
                        let image = NSImage(size: pdfView.bounds.size)
                        image.addRepresentation(bitmap)
                        snapshotView.image = image
                    }
                    
                    snapshotView.wantsLayer = true
                    snapshotView.layer?.opacity = 1.0
                    pdfView.addSubview(snapshotView)
                    
                    pdfView.document = document
                    if let page = document.page(at: pageIndex) {
                        pdfView.go(to: PDFDestination(page: page, at: point))
                    }
                    
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.2
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        snapshotView.animator().alphaValue = 0.0
                    } completionHandler: {
                        DispatchQueue.main.async {
                            snapshotView.removeFromSuperview()
                            context.coordinator.isTransitioning = false
                        }
                    }
                } else {
                    pdfView.document = document
                }
                
                context.coordinator.lastUrl = url
                context.coordinator.lastToken = reloadToken
                
                DispatchQueue.global(qos: .userInitiated).async {
                    let text = document.string ?? ""
                    let words = text.split { $0.isWhitespace || $0.isNewline }
                    let count = words.count
                    
                    DispatchQueue.main.async {
                        // Check if document is still relevant
                        if context.coordinator.lastUrl == url {
                            self.onWordCountChange?(count)
                        }
                    }
                }
            } else {
                pdfView.document = nil
                context.coordinator.lastUrl = url
            }
        }
    }
    
    private func applyFilters(to view: PDFView) {
        guard let layer = view.layer else { return }
        
        var filters: [CIFilter] = []
        
        // Dark Mode / Night Mode: We now use a Typst preamble for "True Dark Mode"
        // which renders text and page colors correctly without inverting images.
        
        // Color Blindness
        if colorBlindnessMode != .none {
            let matrix: [CGFloat]
            switch colorBlindnessMode {
            case .protanopia:
                matrix = [0.567, 0.433, 0.0, 0.0, 0.558, 0.442, 0.0, 0.0, 0.0, 0.242, 0.758, 0.0, 0.0, 0.0, 0.0, 1.0]
            case .deuteranopia:
                matrix = [0.625, 0.375, 0.0, 0.0, 0.7, 0.3, 0.0, 0.0, 0.0, 0.3, 0.7, 0.0, 0.0, 0.0, 0.0, 1.0]
            case .tritanopia:
                matrix = [0.95, 0.05, 0.0, 0.0, 0.0, 0.433, 0.567, 0.0, 0.0, 0.475, 0.525, 0.0, 0.0, 0.0, 0.0, 1.0]
            case .none:
                matrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
            }
            
            if let colorMatrix = CIFilter(name: "CIColorMatrix") {
                colorMatrix.setValue(CIVector(values: [matrix[0], matrix[1], matrix[2], matrix[3]], count: 4), forKey: "inputRVector")
                colorMatrix.setValue(CIVector(values: [matrix[4], matrix[5], matrix[6], matrix[7]], count: 4), forKey: "inputGVector")
                colorMatrix.setValue(CIVector(values: [matrix[8], matrix[9], matrix[10], matrix[11]], count: 4), forKey: "inputBVector")
                colorMatrix.setValue(CIVector(values: [matrix[12], matrix[13], matrix[14], matrix[15]], count: 4), forKey: "inputAVector")
                filters.append(colorMatrix)
            }
        }
        
        layer.filters = filters
    }
    
    private func applyColorBlindnessFilter(to view: NSView, mode: EditorController.ColorBlindnessMode) {
        // Obsolete, functionality merged into applyFilters
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var lastUrl: URL?
        var lastToken: UUID?
        var isTransitioning: Bool = false
    }
}
