import AppKit

class LineNumberRulerView: NSRulerView {
    var errorLines: Set<Int> = []
    
    override var isFlipped: Bool { true }
    
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let textStorage = textView.textStorage else { return }
        
        let fullString = textStorage.string as NSString
        
        // Refresh thickness based on font size and line count
        let textViewFont = textView.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let lineCount = fullString.components(separatedBy: "\n").count
        let digits = max(2, "\(lineCount)".count)
        let newThickness = (textViewFont.pointSize * CGFloat(digits) * 0.6) + 16
        if abs(ruleThickness - newThickness) > 1 {
            ruleThickness = newThickness
        }

        let fontSize = textViewFont.pointSize * 0.85
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.4),
            .paragraphStyle: paragraphStyle
        ]
        
        let errorAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.systemRed,
            .paragraphStyle: paragraphStyle
        ]
        
        // Account for text container insets
        let insetHeight = textView.textContainerInset.height
        
        // Find visible range accurately
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        
        // Start from line 1 and find the first visible logical line
        var lineNumber = 1
        var currentIdx = 0
        
        while currentIdx < charRange.location {
            currentIdx = NSMaxRange(fullString.lineRange(for: NSRange(location: currentIdx, length: 0)))
            lineNumber += 1
        }
        
        // Iterate through lines until we pass the visible range
        let maxIdx = NSMaxRange(charRange)
        
        while currentIdx < maxIdx || (currentIdx == fullString.length && charRange.length == 0) {
            let lineRange = fullString.lineRange(for: NSRange(location: currentIdx, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            
            // Safety check for glyph index
            if glyphIndex >= layoutManager.numberOfGlyphs {
                if currentIdx == fullString.length { break }
                currentIdx = NSMaxRange(lineRange)
                lineNumber += 1
                continue
            }
            
            // Get the rect for the first fragment of this logical line
            let firstFragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            
            let yPos = firstFragmentRect.origin.y + insetHeight
            // Center the number vertically within the line fragment
            let textHeight = font.pointSize * 1.2
            let drawRect = NSRect(
                x: 0, 
                y: yPos + (firstFragmentRect.height - textHeight) / 2, 
                width: ruleThickness - 8, 
                height: textHeight
            )
            
            if drawRect.intersects(rect) {
                let hasErr = errorLines.contains(lineNumber)
                let numStr = "\(lineNumber)" as NSString
                numStr.draw(in: drawRect, withAttributes: hasErr ? errorAttrs : normalAttrs)
            }
            
            if currentIdx == fullString.length { break }
            currentIdx = NSMaxRange(lineRange)
            lineNumber += 1
        }
        
        // Handle trailing newline if visible
        if fullString.length > 0 && fullString.character(at: fullString.length - 1) == 10 {
            let extraRect = layoutManager.extraLineFragmentRect
            let yPos = extraRect.origin.y + insetHeight
            let textHeight = font.pointSize * 1.2
            let drawRect = NSRect(
                x: 0, 
                y: yPos + (extraRect.height - textHeight) / 2, 
                width: ruleThickness - 8, 
                height: textHeight
            )
            
            if drawRect.intersects(rect) && NSMaxRange(charRange) >= fullString.length {
                let hasErr = errorLines.contains(lineNumber)
                let numStr = "\(lineNumber)" as NSString
                numStr.draw(in: drawRect, withAttributes: hasErr ? errorAttrs : normalAttrs)
            }
        }
    }
}
