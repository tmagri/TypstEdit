//
//  MultiStorageDelegate.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/25/23.
//

import AppKit

public class MultiStorageDelegate: NSObject, NSTextStorageDelegate {
    private struct WeakDelegate {
        weak var value: NSTextStorageDelegate?
    }

    private var delegates: [WeakDelegate] = []

    public func addDelegate(_ delegate: NSTextStorageDelegate) {
        delegates.removeAll { $0.value == nil || $0.value === delegate }
        // Ensure TextLayoutManager is prioritized first so line storage is updated
        // before any other consumers (like Highlighter) query line positions.
        if delegate is TextLayoutManager {
            delegates.insert(WeakDelegate(value: delegate), at: 0)
        } else {
            delegates.append(WeakDelegate(value: delegate))
        }
    }

    public func removeDelegate(_ delegate: NSTextStorageDelegate) {
        delegates.removeAll { $0.value == nil || $0.value === delegate }
    }

    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        delegates.compactMap(\.value).forEach { delegate in
            delegate.textStorage?(textStorage, didProcessEditing: editedMask, range: editedRange, changeInLength: delta)
        }
    }

    public func textStorage(
        _ textStorage: NSTextStorage,
        willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        delegates.compactMap(\.value).forEach { delegate in
            delegate
                .textStorage?(textStorage, willProcessEditing: editedMask, range: editedRange, changeInLength: delta)
        }
    }
}
