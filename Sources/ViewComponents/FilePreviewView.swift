import SwiftUI
import PDFKit

struct FilePreviewView: View {
    let fileURL: URL
    let fileType: EditorController.SupportedFileType
    @EnvironmentObject var themeManager: ThemeManager
    @State private var reloadToken: UUID = UUID()
    @State private var isSpinning: Bool = false
    
    var body: some View {
        ZStack {
            themeManager.editorBackground
            
            VStack(spacing: 0) {
                // Header bar with file info and refresh action
                HStack(spacing: 8) {
                    Image(systemName: fileIconName)
                        .foregroundColor(themeManager.textColor.opacity(0.7))
                        .font(.system(size: 13))
                    
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(themeManager.textColor)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Button(action: refreshPreview) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                                .animation(isSpinning ? .linear(duration: 0.6).repeatCount(1, autoreverses: false) : .default, value: isSpinning)
                            Text("Refresh")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(themeManager.textColor.opacity(0.85))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh File Preview (Cmd+R)")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
                .overlay(Divider(), alignment: .bottom)
                
                // Main Preview Area
                VStack(spacing: 20) {
                    if fileType == .image {
                        imageSection
                    } else if fileType == .pdf {
                        pdfSection
                    } else {
                        unsupportedSection
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(reloadToken)
        .onReceive(NotificationCenter.default.publisher(for: .menuCommand)) { notification in
            if let command = notification.object as? String, command == "refreshPreview" {
                refreshPreview()
            }
        }
    }
    
    private var fileIconName: String {
        switch fileType {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        default: return "doc"
        }
    }
    
    private func refreshPreview() {
        isSpinning = true
        reloadToken = UUID()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            isSpinning = false
        }
    }
    
    private var imageSection: some View {
        Group {
            // Read raw data from disk on each reload to bypass NSImage memory cache
            if let data = try? Data(contentsOf: fileURL), let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(radius: 5)
            } else if let nsImage = NSImage(contentsOf: fileURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(radius: 5)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Unable to load image")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private var pdfSection: some View {
        PDFKitRepresentable(url: fileURL, reloadToken: reloadToken)
            .cornerRadius(8)
            .shadow(radius: 5)
    }
    
    private var unsupportedSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.dashed")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Preview Not Available")
                .font(.headline)
            Text(fileURL.lastPathComponent)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("This file type is not supported for editing in TypstEdit.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
    }
}

struct PDFKitRepresentable: NSViewRepresentable {
    let url: URL
    var reloadToken: UUID? = nil
    
    class Coordinator {
        var lastUrl: URL?
        var lastToken: UUID?
        var isTransitioning: Bool = false
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeNSView(context: Context) -> PDFView {
        print("[DEBUG] PDFKitRepresentable: makeNSView for \(url.lastPathComponent)")
        let pdfView = PDFView()
        context.coordinator.lastUrl = url
        context.coordinator.lastToken = reloadToken
        
        // Defensive: Check if file exists, is not empty, and is readable
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path),
           let attributes = try? fm.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int64, size > 0,
           fm.isReadableFile(atPath: url.path),
           let document = PDFDocument(url: url) {
            pdfView.document = document
        } else {
            print("[DEBUG] PDFKitRepresentable: initial document load failed or file not ready")
        }
        
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        return pdfView
    }
    
    func updateNSView(_ nsView: PDFView, context: Context) {
        guard !context.coordinator.isTransitioning else { return }
        
        if context.coordinator.lastUrl != url || context.coordinator.lastToken != reloadToken {
            print("[DEBUG] PDFKitRepresentable: url/token changed to \(url.lastPathComponent)")
            context.coordinator.lastUrl = url
            context.coordinator.lastToken = reloadToken
            
            // Defensive: Check if file exists, is not empty, and is readable
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path),
                  let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int64, size > 0,
                  fm.isReadableFile(atPath: url.path),
                  let document = PDFDocument(url: url) else {
                print("[DEBUG] PDFKitRepresentable: file not ready or invalid PDF")
                nsView.document = nil
                return
            }
            
            if let oldDoc = nsView.document, oldDoc.pageCount > 0 {
                context.coordinator.isTransitioning = true
                
                // Porting the overlap transition logic for smoothness and safety
                let snapshotView = NSImageView(frame: nsView.bounds)
                snapshotView.imageScaling = .scaleProportionallyUpOrDown
                if let bitmap = nsView.bitmapImageRepForCachingDisplay(in: nsView.bounds) {
                    nsView.cacheDisplay(in: nsView.bounds, to: bitmap)
                    let image = NSImage(size: nsView.bounds.size)
                    image.addRepresentation(bitmap)
                    snapshotView.image = image
                }
                snapshotView.wantsLayer = true
                nsView.addSubview(snapshotView)
                
                nsView.document = document
                
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    snapshotView.animator().alphaValue = 0.0
                } completionHandler: {
                    DispatchQueue.main.async {
                        snapshotView.removeFromSuperview()
                        context.coordinator.isTransitioning = false
                    }
                }
            } else {
                nsView.document = document
            }
        }
    }
}
