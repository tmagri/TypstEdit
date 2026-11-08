//
//  TextSelectionManager+AddCursor.swift
//  CodeEditTextView
//

import AppKit

extension TextSelectionManager {
    /// Adds a cursor one visual line above the topmost selection, or below the bottommost selection.
    ///
    /// Mirrors VS Code's "Add Cursor Above/Below" (⌘⌥↑ / ⌘⌥↓). The new cursor keeps the horizontal position of the
    /// selection it was created from, so repeated presses build a straight column of cursors even across shorter
    /// lines.
    ///
    /// When the cursors were added in the opposite direction from the primary cursor, this removes the farthest
    /// cursor instead, so ⌘⌥↑ undoes a ⌘⌥↓ and the other way around.
    /// - Parameter up: `true` to add the cursor above, `false` to add it below.
    /// - Returns: The offset of the cursor at the edge that changed (the new cursor, or the cursor that is now the
    ///   farthest one after a removal), so the caller can scroll it into view. `nil` if nothing changed.
    @discardableResult
    public func addCursorVertically(up: Bool) -> Int? {
        guard let layoutManager else { return nil }

        if textSelections.isEmpty {
            setSelectedRange(NSRange(location: 0, length: 0))
        }

        guard let topmost = textSelections.min(by: { $0.range.location < $1.range.location }),
              let bottommost = textSelections.max(by: { $0.range.max < $1.range.max }) else {
            return nil
        }

        let primary = primaryTextSelection.flatMap { primary in textSelections.first(where: { $0 === primary }) }
        if let primary, textSelections.count > 1 {
            if up && primary === topmost {
                removeTextSelection(bottommost)
                return textSelections.max(by: { $0.range.max < $1.range.max })?.range.max
            } else if !up && primary === bottommost {
                removeTextSelection(topmost)
                return textSelections.min(by: { $0.range.location < $1.range.location })?.range.location
            }
        }

        let source = up ? topmost : bottommost
        if primary == nil {
            primaryTextSelection = source
        }

        let offset = up ? source.range.location : source.range.max
        guard let rect = layoutManager.rectForOffset(offset) else { return nil }

        let xPos = source.suggestedXPos ?? rect.minX
        let lineHeight = layoutManager.estimateLineHeight()
        let targetY = up ? rect.minY - lineHeight / 2 : rect.maxY + lineHeight / 2
        guard targetY >= 0 else { return nil }

        // The target line may be outside the visible rect and not laid out yet; hit-testing it would use stale
        // fragment data and put the cursor in the wrong column.
        layoutManager.layoutLines(
            in: NSRect(x: 0, y: targetY - lineHeight, width: layoutManager.maxLineWidth, height: lineHeight * 2)
        )

        guard let newOffset = layoutManager.textOffsetAtPoint(CGPoint(x: xPos, y: targetY)),
              let newRect = layoutManager.rectForOffset(newOffset) else {
            return nil
        }

        // Stop at the first/last visual line instead of jumping to the start/end of the document.
        if up ? newRect.minY >= rect.minY : newRect.minY <= rect.minY {
            return nil
        }

        let newRange = NSRange(location: newOffset, length: 0)
        guard !textSelections.contains(where: { $0.range == newRange }) else { return nil }

        let newSelection = TextSelection(range: newRange)
        newSelection.suggestedXPos = xPos
        textSelections.append(newSelection)
        textSelections.sort(by: { $0.range.location < $1.range.location })

        updateSelectionViews()
        delegate?.setNeedsDisplay()
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
        return newOffset
    }

    private func removeTextSelection(_ selection: TextSelection) {
        selection.view?.removeFromSuperview()
        selection.view = nil
        textSelections.removeAll(where: { $0 === selection })

        updateSelectionViews()
        delegate?.setNeedsDisplay()
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
    }

    /// Merges selections that ended up on the same position or overlap, e.g. after several cursors moved to the
    /// start of the document. Without this, two cursors on one spot type every character twice and leave an extra
    /// cursor view behind.
    func mergeOverlappingSelections() {
        guard textSelections.count > 1 else { return }
        textSelections.sort(by: { $0.range.location < $1.range.location })

        var merged: [TextSelection] = []
        for selection in textSelections {
            guard let previous = merged.last else {
                merged.append(selection)
                continue
            }
            let overlaps = selection.range == previous.range
                || (selection.range.location < previous.range.max)
                || (previous.range.isEmpty && selection.range.location == previous.range.location)
            guard overlaps else {
                merged.append(selection)
                continue
            }
            previous.range = previous.range.union(selection.range)
            if primaryTextSelection === selection {
                primaryTextSelection = previous
            }
            selection.view?.removeFromSuperview()
            selection.view = nil
        }
        textSelections = merged
    }

    /// Collapses multiple selections back to a single one.
    ///
    /// Keeps the cursor the user started adding cursors from when it still exists, otherwise the first selection.
    /// - Returns: `true` if there were multiple selections to collapse.
    @discardableResult
    public func collapseToPrimarySelection() -> Bool {
        guard textSelections.count > 1 else { return false }
        let primary = primaryTextSelection.flatMap { primary in
            textSelections.first(where: { $0 === primary })
        } ?? textSelections.first
        primaryTextSelection = nil
        guard let primary else { return false }
        setSelectedRange(primary.range)
        return true
    }
}
