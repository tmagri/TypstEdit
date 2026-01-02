import SwiftUI
import AppKit

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .active
    var emphasized: Bool = false
    
    init(material: NSVisualEffectView.Material = .hudWindow,
         blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
         state: NSVisualEffectView.State = .active,
         emphasized: Bool = true) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.emphasized = emphasized
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = emphasized
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.isEmphasized = emphasized
    }
}
