import SwiftUI
import AppKit

// A native NSButton wrapper that shows the SharingServicePicker relative to itself
struct ShareButton: NSViewRepresentable {
    var fileURL: URL?
    
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.bezelStyle = .texturedRounded
        button.toolTip = "Share"
        return button
    }
    
    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.parent = self
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSSharingServicePickerDelegate {
        var parent: ShareButton
        
        init(_ parent: ShareButton) {
            self.parent = parent
        }
        
        @objc func clicked(_ sender: NSButton) {
            print("[DEBUG] ShareButton clicked")
            print("[DEBUG] fileURL: \(String(describing: parent.fileURL))")
            
            guard let url = parent.fileURL else {
                print("[ERROR] ShareButton: fileURL is nil")
                return
            }
            
            print("[DEBUG] ShareButton: Showing sharing picker for URL: \(url)")
            let picker = NSSharingServicePicker(items: [url])
            picker.delegate = self
            // This anchors the picker to the button
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
