import AppKit

class LineNumberRulerView: NSRulerView {
    
    // We can inject errors here to show markers
    var errors: [Int] = [] {
        didSet {
            self.needsDisplay = true
        }
    }
    
    var font: NSFont {
        return NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    }
    
    var textColor: NSColor {
        return NSColor.gray // Visible gray color
    }
    
    var backgroundColor: NSColor {
        // More opaque to make ruler visible
        return NSColor(white: 0.0, alpha: 0.4)
    }
    
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        self.ruleThickness = 40
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = self.clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return
        }
        
        // Define toolbar height (must match textContainerInset in EditorView)
        let toolbarHeight: CGFloat = 58
        
        // Only draw below the toolbar area
        let drawingRect = NSRect(
            x: rect.minX,
            y: max(rect.minY, toolbarHeight),
            width: rect.width,
            height: max(0, rect.maxY - toolbarHeight)
        )
        
        // Background
        backgroundColor.setFill()
        drawingRect.fill()
        
        // Draw Border (only below toolbar)
        NSColor.separatorColor.setStroke()
        let borderPath = NSBezierPath()
        borderPath.move(to: NSPoint(x: ruleThickness, y: drawingRect.minY))
        borderPath.line(to: NSPoint(x: ruleThickness, y: drawingRect.maxY))
        borderPath.lineWidth = 1
        borderPath.stroke()
        
        // Get container origin offset (handles padding/inset)
        let containerOrigin = textView.textContainerOrigin
        
        // Convert visible rect to container coords
        let visibleRect = textView.visibleRect
        // We calculate the range of glyphs that are actually visible
        // We can just ask for the whole range in the rect, shifting by origin
        let visibleRectInContainer = visibleRect.offsetBy(dx: -containerOrigin.x, dy: -containerOrigin.y)
        
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRectInContainer, in: textContainer)
        
        // Start counting lines from beginning to finding correct number for first visible line
        // (Optimization: In a real large app, you'd want something smarter than O(N) from start)
        var lineNumber = 1
        let fullString = textView.string as NSString
        if visibleGlyphRange.location > 0 {
            let substring = fullString.substring(to: visibleGlyphRange.location)
            lineNumber += substring.filter { $0 == "\n" }.count
            // If the last character before visible range is NOT a newline, we are in the middle of a line, 
            // so the current line number is correct for this fragment.
            // If it IS a newline, we are starting a new line, so increment.
            // Actually, if substring ends in \n, the NEXT char is on next line.
            // So count of \n gives us how many lines *completed*. 
            // Current line index is count + 1. So `lineNumber` is correct.
        }
        
        // Iterate visible glyphs
        var glyphIndex = visibleGlyphRange.location
        while glyphIndex < NSMaxRange(visibleGlyphRange) {
            var lineRange = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
            
            // Calculate Y position in View Coordinates
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let yInView = lineRect.origin.y + containerOrigin.y
            let yPos = self.convert(NSPoint(x: 0, y: yInView), from: textView).y
            
            // Check if this fragment starts a new line
            var isNewLine = true
            if glyphIndex > 0 {
                let charRange = layoutManager.characterRange(forGlyphRange: NSRange(location: glyphIndex - 1, length: 1), actualGlyphRange: nil)
                if charRange.location < fullString.length {
                    let prevChar = fullString.substring(with: charRange)
                    isNewLine = (prevChar == "\n")
                }
            }
            
            // Draw
            if isNewLine {
                let label = "\(lineNumber)" as NSString
                
                // Active Line Highlight could be added here
                
                let size = label.size(withAttributes: [.font: font])
                
                // Draw Line Number
                let xPos = ruleThickness - size.width - 8
                // Center vertically relative to line height
                let centeredY = yPos + (lineRect.height - size.height) / 2
                
                let numberRect = NSRect(x: xPos, y: centeredY, width: size.width, height: size.height)
                
                label.draw(in: numberRect, withAttributes: [
                    .font: font,
                    .foregroundColor: NSColor.gray // Better contrast
                ])
                
                // Draw Error if needed
                if errors.contains(lineNumber) {
                    let errorRect = NSRect(x: 4, y: centeredY + 3, width: 6, height: 6)
                    NSColor.systemRed.setFill()
                    let path = NSBezierPath(ovalIn: errorRect)
                    path.fill()
                }
            }
            
            // Advance
            glyphIndex = NSMaxRange(lineRange)
            
            // Check if we need to increment line number for next loop
            let charRange = layoutManager.characterRange(forGlyphRange: lineRange, actualGlyphRange: nil)
            if charRange.location + charRange.length <= fullString.length {
               let fragmentString = fullString.substring(with: charRange)
               if fragmentString.last == "\n" {
                   lineNumber += 1
               }
            }
        }
    }
}
