//
//  TextViewController+FindPanelTarget.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 3/16/25.
//

import AppKit
import CodeEditTextView

extension TextViewController: FindPanelTarget {
    public var findPanelTargetView: NSView {
        textView
    }

    public func findPanelWillShow(panelHeight: CGFloat) {
        updateContentInsets()
    }

    public func findPanelWillHide(panelHeight: CGFloat) {
        updateContentInsets()
    }

    public func findPanelModeDidChange(to mode: FindPanelMode) {
        updateContentInsets()
    }

    var emphasisManager: EmphasisManager? {
        textView?.emphasisManager
    }
}
