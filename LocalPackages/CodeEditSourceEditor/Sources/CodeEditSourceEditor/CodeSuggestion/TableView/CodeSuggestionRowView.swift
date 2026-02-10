//
//  CodeSuggestionRowView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/22/25.
//

import AppKit

/// Used to draw a custom selection highlight for the table row
final class CodeSuggestionRowView: NSTableRowView {
    var getSelectionColor: (() -> NSColor)?

    init(getSelectionColor: (() -> NSColor)? = nil) {
        self.getSelectionColor = getSelectionColor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        defer { context.restoreGState() }

        let selectionRect = NSRect(
            x: SuggestionController.WINDOW_PADDING,
            y: 0,
            width: bounds.width - (SuggestionController.WINDOW_PADDING * 2),
            height: bounds.height
        )
        let cornerRadius: CGFloat = 5
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: cornerRadius, yRadius: cornerRadius)
        
        var selectionColor = getSelectionColor?() ?? NSColor.selectedTextBackgroundColor
        if selectionColor.alphaComponent == 0 {
            selectionColor = NSColor.selectedTextBackgroundColor
        }

        context.setFillColor(selectionColor.cgColor)
        path.fill()
    }
}
