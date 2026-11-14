//
//  VisibleRangeProvider.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 10/13/24.
//

import AppKit
import CodeEditTextView

@MainActor
protocol VisibleRangeProviderDelegate: AnyObject {
    func visibleSetDidUpdate(_ newIndices: IndexSet)
}

/// Provides information to ``HighlightProviderState``s about what text is visible in the editor. Keeps it's contents
/// in sync with a text view and notifies listeners about changes so highlights can be applied to newly visible indices.
@MainActor
class VisibleRangeProvider {
    private weak var textView: TextView?
    private weak var minimapView: MinimapView?
    weak var delegate: VisibleRangeProviderDelegate?

    var documentRange: NSRange {
        textView?.documentRange ?? .notFound
    }

    /// The set of visible indexes in the text view
    var visibleSet: IndexSet = IndexSet()

    init(textView: TextView, minimapView: MinimapView?) {
        self.textView = textView
        self.minimapView = minimapView
        updateVisibleSet()

        if let scrollView = textView.enclosingScrollView {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibleTextChanged),
                name: NSView.frameDidChangeNotification,
                object: scrollView
            )

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibleTextChanged),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleTextChanged),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
    }

    /// Updates `visibleSet` from the text view and minimap without notifying the delegate.
    func updateVisibleSet() {
        guard let textViewVisibleRange = textView?.visibleTextRange else {
            return
        }
        var set = IndexSet(integersIn: textViewVisibleRange)
        if !(minimapView?.isHidden ?? true), let minimapVisibleRange = minimapView?.visibleTextRange {
            set.formUnion(IndexSet(integersIn: minimapVisibleRange))
        }
        self.visibleSet = set
    }

    /// Updates the view to highlight newly visible text when the textview is scrolled or bounds change.
    @objc func visibleTextChanged() {
        updateVisibleSet()
        delegate?.visibleSetDidUpdate(visibleSet)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
