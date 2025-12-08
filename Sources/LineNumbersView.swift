import SwiftUI
import AppKit

struct LineNumbersView: NSViewRepresentable {
    @ObservedObject var controller: EditorController
    @EnvironmentObject var themeManager: ThemeManager
    
    func makeNSView(context: Context) -> NSScrollView {
        print("[LineNumbers] Creating gutter view")
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        
        let gutter = LineNumberGutter()
        gutter.controller = controller
        
        scrollView.documentView = gutter
        context.coordinator.gutter = gutter
        
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let gutter = nsView.documentView as? LineNumberGutter,
              let editorScrollView = controller.textView?.enclosingScrollView else {
            return
        }
        
        // Ensure gutter has reference to the active controller/textView
        if gutter.controller !== controller {
            gutter.controller = controller
        }
        
        // Sync scroll Y
        let editorVisibleRect = editorScrollView.contentView.bounds
        let newOrigin = NSPoint(x: 0, y: editorVisibleRect.origin.y)
        if nsView.contentView.bounds.origin != newOrigin {
            nsView.contentView.setBoundsOrigin(newOrigin)
        }
        
        // Sync Height to match editor document, so scrolling works
        var newFrame = gutter.frame
        let editorHeight = editorScrollView.documentView?.frame.height ?? 0
        // Ensure minimal width
        newFrame.size.width = nsView.contentSize.width > 0 ? nsView.contentSize.width : 50
        
        if abs(newFrame.height - editorHeight) > 1 {
            newFrame.size.height = editorHeight
            gutter.frame = newFrame
        }
        
        // Request redraw
        gutter.needsDisplay = true
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject {
        var parent: LineNumbersView
        weak var gutter: LineNumberGutter?
        
        init(_ parent: LineNumbersView) {
            self.parent = parent
        }
    }
}

class LineNumberGutter: NSView {
    weak var controller: EditorController?
    
    override var isFlipped: Bool { true }
    
    private func hasError(at line: Int) -> Bool {
        return controller?.errors.contains(where: { $0.line == line }) ?? false
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let controller = controller,
              let textView = controller.textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let textStorage = textView.textStorage else { return }
        
        let string = textStorage.string as NSString
        let length = string.length
        
        // Define attributes
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
            .paragraphStyle: paragraphStyle
        ]
        
        let errorAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white, // Bright white for error
            .paragraphStyle: paragraphStyle
        ]
        
        var lineNumber = 1
        var start = 0
        
        // Iterate through all logical lines
        while start < length {
            var lineEnd = 0
            var contentEnd = 0
            string.getLineStart(nil, end: &lineEnd, contentsEnd: &contentEnd, for: NSRange(location: start, length: 0))
            
            // Get the bounding rect for the first line fragment of this logical line
            let charRange = NSRange(location: start, length: contentEnd - start)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            
            if glyphRange.length > 0 {
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect.origin.y += textView.textContainerInset.height
                
                if rect.intersects(dirtyRect) || dirtyRect.contains(rect.origin) {
                    let hasErr = hasError(at: lineNumber)
                    let numStr = "\(lineNumber)" as NSString
                    // Use full width for center alignment
                    let drawRect = NSRect(x: 0, y: rect.origin.y, width: self.bounds.width, height: 20)
                    
                    if hasErr {
                        // Draw red circle perfectly centered
                        let circleSize: CGFloat = 18
                        let circleRect = NSRect(
                            x: (self.bounds.width - circleSize) / 2,
                            y: drawRect.origin.y + (drawRect.height - circleSize) / 2 - 1,
                            width: circleSize,
                            height: circleSize
                        )
                        NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.8).setFill()
                        let path = NSBezierPath(ovalIn: circleRect)
                        path.fill()
                        
                        numStr.draw(in: drawRect, withAttributes: errorAttrs)
                    } else {
                        numStr.draw(in: drawRect, withAttributes: normalAttrs)
                    }
                }
            } else if contentEnd - start == 0 {
                // Empty line
                let charRange = NSRange(location: start, length: lineEnd - start)
                let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                 rect.origin.y += textView.textContainerInset.height
                 
                 if rect.intersects(dirtyRect) {
                     let hasErr = hasError(at: lineNumber)
                     let numStr = "\(lineNumber)" as NSString
                     let drawRect = NSRect(x: 0, y: rect.origin.y, width: self.bounds.width, height: 20)
                     
                     if hasErr {
                         let circleSize: CGFloat = 18
                         let circleRect = NSRect(
                             x: (self.bounds.width - circleSize) / 2,
                             y: drawRect.origin.y + (drawRect.height - circleSize) / 2 - 1,
                             width: circleSize,
                             height: circleSize
                         )
                         NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.8).setFill()
                         NSBezierPath(ovalIn: circleRect).fill()
                         numStr.draw(in: drawRect, withAttributes: errorAttrs)
                     } else {
                         numStr.draw(in: drawRect, withAttributes: normalAttrs)
                     }
                 }
            }
            
            start = lineEnd
            lineNumber += 1
        }
        
        // Handle trailing newline
        if length > 0 && string.character(at: length - 1) == 10 {
             var rect = layoutManager.extraLineFragmentRect
             rect.origin.y += textView.textContainerInset.height
             
             if rect.intersects(dirtyRect) {
                 let hasErr = hasError(at: lineNumber)
                 let numStr = "\(lineNumber)" as NSString
                 let drawRect = NSRect(x: 0, y: rect.origin.y, width: self.bounds.width, height: 20)
                 
                 if hasErr {
                     let circleSize: CGFloat = 18
                     let circleRect = NSRect(
                         x: (self.bounds.width - circleSize) / 2,
                         y: drawRect.origin.y + (drawRect.height - circleSize) / 2 - 1,
                         width: circleSize,
                         height: circleSize
                     )
                     NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.8).setFill()
                     NSBezierPath(ovalIn: circleRect).fill()
                     numStr.draw(in: drawRect, withAttributes: errorAttrs)
                 } else {
                     numStr.draw(in: drawRect, withAttributes: normalAttrs)
                 }
             }
        } else if length == 0 {
            // Empty document -> Line 1
            let hasErr = hasError(at: 1)
            let numStr = "1" as NSString
            let drawRect = NSRect(x: 0, y: textView.textContainerInset.height, width: self.bounds.width, height: 20)
            
            if hasErr {
                let circleSize: CGFloat = 18
                let circleRect = NSRect(
                    x: (self.bounds.width - circleSize) / 2,
                    y: drawRect.origin.y + (drawRect.height - circleSize) / 2 - 1,
                    width: circleSize,
                    height: circleSize
                )
                NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.8).setFill()
                NSBezierPath(ovalIn: circleRect).fill()
                numStr.draw(in: drawRect, withAttributes: errorAttrs)
            } else {
                numStr.draw(in: drawRect, withAttributes: normalAttrs)
            }
        }
    }
}
