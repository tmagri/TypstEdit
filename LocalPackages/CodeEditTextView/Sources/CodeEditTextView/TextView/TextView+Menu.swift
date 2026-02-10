//
//  TextView+Menu.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextView {
    override public func menu(for event: NSEvent) -> NSMenu? {
        // Check if delegate provides a menu
        if let customMenu = delegate?.textView(self, contextMenuFor: event) {
            return customMenu
        }
        
        guard event.type == .rightMouseDown else { return nil }

        let menu = NSMenu()

        menu.items = [
            NSMenuItem(title: "Cut", action: #selector(cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")
        ]

        return menu
    }
}
