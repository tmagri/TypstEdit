//
//  TextSelectionManager+Update.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 10/22/23.
//

import Foundation

extension TextSelectionManager {
    public func didReplaceCharacters(in range: NSRange, replacementLength: Int) {
        // Correct net delta: how much the document length changed at/after `range`.
        // Old code used bare `replacementLength` when replacementLength > 0, which
        // was wrong for replacement edits (range.length > 0 AND replacementLength > 0)
        // because it ignored the characters being removed, pushing the cursor past EOF.
        let delta = replacementLength - range.length
        for textSelection in self.textSelections {
            if textSelection.range.location > range.max {
                textSelection.range.location = max(0, textSelection.range.location + delta)
                textSelection.range.length = 0
            } else if textSelection.range.intersection(range) != nil
                        || textSelection.range == range
                        || (textSelection.range.isEmpty && textSelection.range.location == range.max) {
                if replacementLength > 0 {
                    textSelection.range.location = range.location + replacementLength
                } else {
                    textSelection.range.location = range.location
                }
                textSelection.range.length = 0
            } else {
                textSelection.range.length = 0
            }
        }

        // Clamp all selections to valid document bounds (safety net for any edge case).
        let docLen = textStorage?.length ?? 0
        for textSelection in self.textSelections {
            let loc = max(0, min(textSelection.range.location, docLen))
            let len = max(0, min(textSelection.range.length, docLen - loc))
            textSelection.range = NSRange(location: loc, length: len)
        }

        // Clean up duplicate selection ranges
        var allRanges: Set<NSRange> = []
        for (idx, selection) in self.textSelections.enumerated().reversed() {
            if allRanges.contains(selection.range) {
                self.textSelections.remove(at: idx)
            } else {
                allRanges.insert(selection.range)
            }
        }
    }

    public func notifyAfterEdit(force: Bool = false) {
        updateSelectionViews(force: force)
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
    }
}
