import Foundation

/// Shared visibility rules for sidebar tabs and selection fallback.
struct SidebarVisibility: Equatable {
    var files = true
    var projects = true
    var notebooks = true
    var calculator = true
    var sourceControl = true
    var aiChat = false

    var browserModes: [Int] {
        (projects ? [0] : []) + (notebooks ? [1] : [])
    }

    var panels: [EditorController.SidebarContent] {
        var result: [EditorController.SidebarContent] = []
        if files && !browserModes.isEmpty { result.append(.files) }
        if aiChat { result.append(.aiChat) }
        if calculator { result.append(.calculator) }
        return result
    }

    func resolvedPanel(_ selection: EditorController.SidebarContent) -> EditorController.SidebarContent? {
        panels.contains(selection) ? selection : panels.first
    }

    func resolvedBrowserMode(_ selection: Int) -> Int? {
        browserModes.contains(selection) ? selection : browserModes.first
    }

    var showsSourceControl: Bool {
        files && projects && sourceControl
    }
}
