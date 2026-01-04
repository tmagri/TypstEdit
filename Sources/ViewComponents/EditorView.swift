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
        
        // Initialize with current text
        textView.string = text
        
        // Connecter le contrôleur
        DispatchQueue.main.async {
            controller.textView = textView
            // Connect the delegate for equation editor
            textView.editorDelegate = controller
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            
            // --- CONFIGURATION RULER ---
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
            let ruler = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
            ruler.clientView = textView
            scrollView.verticalRulerView = ruler
        }
        
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = context.coordinator.textView
        let textStorage = context.coordinator.textStorage
        let highlighter = context.coordinator.highlighter
        
        if textView.string.count != text.count {
            print("[DEBUG] EditorView.updateNSView: text lengths differ (\(textView.string.count) vs \(text.count))")
        }
        
        // Always use dark appearance
        nsView.appearance = NSAppearance(named: .darkAqua)
        
        // Update font based on zoom
        let baseSize: CGFloat = 14
        let scaledSize = baseSize * controller.zoomLevel
        if textView.font?.pointSize != scaledSize {
            textView.font = NSFont.monospacedSystemFont(ofSize: scaledSize, weight: .regular)
        }
        
        // Update cursor size
        if textView.cursorWidth != controller.cursorSize {
            textView.cursorWidth = controller.cursorSize
        }
        
        // Update ruler errors and redraw
        if let ruler = nsView.verticalRulerView as? LineNumberRulerView {
            let errorLines = Set(controller.errors.map { $0.line })
            ruler.errorLines = errorLines
            ruler.needsDisplay = true // Always force redraw on update to catch font changes
        }
        
        // Update text wrapping
        let textContainer = context.coordinator.textContainer
        if controller.wrapLines {
            textContainer.widthTracksTextView = true
            textView.isHorizontallyResizable = false
        } else {
            textContainer.widthTracksTextView = false
            textView.isHorizontallyResizable = true
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        // Update text if changed
        if textView.string != text {
            print("[DEBUG] EditorView.updateNSView: text content mismatch, length: \(textView.string.count) -> \(text.count)")
            let selectedRange = textView.selectedRange()
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
            // Re-apply highlighting to be safe (though textStorage delegate handles it)
            highlighter.applyHighlighting(to: textStorage)
            
            context.coordinator.isUpdating = true
            textStorage.endEditing()
            context.coordinator.isUpdating = false
            
            // Fix: Use UTF-16 count for range validation as NSRange is based on code units
            if selectedRange.location + selectedRange.length <= (text as NSString).length {
                textView.setSelectedRange(selectedRange)
            }
            
            // Enforce layout and redraw to ensure content is immediately visible
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            textView.needsDisplay = true
            
            print("[DEBUG] EditorView.updateNSView: text update complete")
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
        var isUpdating: Bool = false

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
            guard !isUpdating else { return }
            guard let textView = notification.object as? TypstEditorTextView else { return }
            let newText = textView.string
            if self.parent.text != newText {
                self.parent.text = newText
                self.parent.onCommit()
                self.parent.controller.needsRedraw()
            }
        }
    }
}