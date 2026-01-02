import SwiftUI
import AppKit

struct EditorView: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var controller: EditorController
    @EnvironmentObject var themeManager: ThemeManager
    var onCommit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = context.coordinator.scrollView
        let textView = context.coordinator.textView
        
        // --- MODIFICATION TRANSPARENCE ---
        // On force le fond transparent au démarrage
        textView.backgroundColor = .clear
        textView.textColor = NSColor(themeManager.textColor)
        textView.insertionPointColor = NSColor(themeManager.textColor)
        
        // Connecter le contrôleur
        DispatchQueue.main.async {
            controller.textView = textView
            // Connect the delegate for equation editor
            textView.editorDelegate = controller
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            scrollView.verticalRulerView?.needsDisplay = true
        }
        
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = context.coordinator.textView
        let textStorage = context.coordinator.textStorage
        let highlighter = context.coordinator.highlighter
        
        // Always use dark appearance
        nsView.appearance = NSAppearance(named: .darkAqua)
        
        // Update text if changed
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
            // Re-apply highlighting to be safe (though textStorage delegate handles it)
            highlighter.applyHighlighting(to: textStorage)
            textStorage.endEditing()
            if selectedRange.location + selectedRange.length <= text.count {
                textView.setSelectedRange(selectedRange)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorView
        let highlighter = SyntaxHighlighter()
        
        let scrollView: NSScrollView
        let textView: TypstEditorTextView
        let textStorage: NSTextStorage
        let layoutManager: NSLayoutManager
        let textContainer: NSTextContainer

        @MainActor init(_ parent: EditorView) {
            self.parent = parent
            
            self.textStorage = NSTextStorage()
            self.layoutManager = NSLayoutManager()
            self.textStorage.addLayoutManager(layoutManager)
            
            self.textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            self.textContainer.widthTracksTextView = true
            self.layoutManager.addTextContainer(textContainer)
            
            self.textView = TypstEditorTextView(frame: .zero, textContainer: textContainer)
            self.scrollView = NSScrollView()
            
            super.init()
            
            // --- CONFIGURATION SCROLLVIEW ---
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .noBorder
            
            // --- MODIFICATION TRANSPARENCE ---
            scrollView.drawsBackground = false // CRUCIAL: Désactive le fond gris par défaut
            scrollView.backgroundColor = .clear
            
            scrollView.documentView = textView
            
            // --- CONFIGURATION TEXTVIEW ---
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainerInset = NSSize(width: 0, height: 10)
            
            // --- MODIFICATION TRANSPARENCE ---
            textView.drawsBackground = false // CRUCIAL: Désactive le fond blanc par défaut
            textView.backgroundColor = .clear
            
            textView.isRichText = false
            textView.allowsUndo = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            
            textView.delegate = self
            textStorage.delegate = highlighter
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? TypstEditorTextView else { return }
            self.parent.text = textView.string
            self.parent.onCommit()
            self.parent.controller.needsRedraw()
        }
    }
}