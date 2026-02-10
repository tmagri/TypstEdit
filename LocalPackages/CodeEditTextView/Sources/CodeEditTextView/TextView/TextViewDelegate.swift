//
//  TextViewDelegate.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/3/23.
//

import Foundation
import AppKit

public protocol TextViewDelegate: AnyObject {
    func textView(_ textView: TextView, willReplaceContentsIn range: NSRange, with string: String)
    func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String)
    func textView(_ textView: TextView, shouldReplaceContentsIn range: NSRange, with string: String) -> Bool
    
    // Optional: Context Menu Customization
    // If implemented, the delegate can return a menu to display, or nil to use default.
    // Ideally it would take the default menu and allow modification.
    func textView(_ textView: TextView, contextMenuFor event: NSEvent) -> NSMenu?
}

public extension TextViewDelegate {
    func textView(_ textView: TextView, willReplaceContentsIn range: NSRange, with string: String) { }
    func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) { }
    func textView(_ textView: TextView, shouldReplaceContentsIn range: NSRange, with string: String) -> Bool { true }
    func textView(_ textView: TextView, contextMenuFor event: NSEvent) -> NSMenu? { nil }
}
