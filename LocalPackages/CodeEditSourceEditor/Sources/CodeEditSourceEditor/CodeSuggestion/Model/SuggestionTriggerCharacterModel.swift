//
//  SuggestionTriggerCharacterModel.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 8/25/25.
//

import AppKit
import CodeEditTextView
import TextStory

/// Tracks text edits and cursor moves so the suggestion window can dismiss
/// itself when the caret moves. Designed to be called in the
/// ``TextViewDelegate``'s didReplaceCharacters method.
///
/// Was originally a `TextFilter` model, however those are called before text is changed and cursors are updated.
/// The suggestion model expects up-to-date cursor positions as well as complete text contents. This being
/// essentially a textview delegate ensures both of those promises are upheld.
final class SuggestionTriggerCharacterModel {
    weak var controller: TextViewController?
    private var lastPosition: NSRange?

    func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
        let mutation = TextMutation(
            string: string,
            range: range,
            limit: textView.textStorage.length
        )

        // Track the caret position for `selectionUpdated`, but never open the
        // suggestion window from typing. Completions are manual-only (Escape /
        // Ctrl+Space): any key while the window is open dismisses it, so popping
        // it up per keystroke just made it flicker open/closed while typing.
        guard mutation.delta >= 0 else {
            lastPosition = nil
            return
        }

        lastPosition = NSRange(location: mutation.postApplyRange.max, length: 0)
    }

    func selectionUpdated(_ position: CursorPosition) {
        guard let controller, let completionDelegate = controller.completionDelegate else {
            return
        }

        if lastPosition != position.range {
            SuggestionController.shared.cursorsUpdated(
                textView: controller,
                delegate: completionDelegate,
                position: position
            )
        }
    }
}
