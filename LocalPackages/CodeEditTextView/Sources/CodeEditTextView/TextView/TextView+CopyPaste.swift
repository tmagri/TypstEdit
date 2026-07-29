//
//  TextView+CopyPaste.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextView {
    /// App-supplied paste override. When set, `paste(_:)` calls this first and skips the
    /// default behavior if it returns `true`. This lets the hosting app funnel every
    /// responder-chain paste (menu, key bindings, `interpretKeyEvents`, `sendAction`)
    /// through a single code path — the default path inserts the clipboard at *every*
    /// cursor/selection, which duplicates the content once per line when a multi-line
    /// column selection is active.
    ///
    /// Invoked on the main thread from AppKit event handling.
    nonisolated(unsafe) public static var appPasteHandler: ((TextView) -> Bool)?

    @objc open func copy(_ sender: AnyObject) {
        guard let textSelections = selectionManager?
            .textSelections
            .compactMap({ textStorage.attributedSubstring(from: $0.range) }),
              !textSelections.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(textSelections)
    }

    @objc open func paste(_ sender: AnyObject) {
        if let handler = TextView.appPasteHandler, handler(self) { return }
        guard let stringContents = NSPasteboard.general.string(forType: .string) else { return }
        insertText(stringContents, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @objc open func cut(_ sender: AnyObject) {
        copy(sender)
        deleteBackward(sender)
    }

    @objc open func delete(_ sender: AnyObject) {
        deleteBackward(sender)
    }
}
