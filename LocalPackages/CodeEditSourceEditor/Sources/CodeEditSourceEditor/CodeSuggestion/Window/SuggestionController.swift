//
//  SuggestionController.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 6/18/24.
//

import AppKit
import CodeEditTextView
import Combine

public final class SuggestionController: NSWindowController {
    public static var shared: SuggestionController = SuggestionController()

    // MARK: - Properties

    /// Whether the suggestion window is visible
    var isVisible: Bool {
        window?.isVisible ?? false || popover?.isShown ?? false
    }

    public var model: SuggestionViewModel = SuggestionViewModel()

    // MARK: - Private Properties

    /// Maximum number of visible rows (8.5)
    static let MAX_VISIBLE_ROWS: CGFloat = 8.5
    /// Padding at top and bottom of the window
    static let WINDOW_PADDING: CGFloat = 5

    /// Tracks when the window is placed above the cursor
    var isWindowAboveCursor = false

    var popover: NSPopover?

    /// Holds the observer for the window resign notifications
    private var windowResignObserver: NSObjectProtocol?

    // MARK: - Initialization

    public init() {
        let window = Self.makeWindow()

        let controller = SuggestionViewController()
        controller.model = model
        window.contentViewController = controller

        super.init(window: window)

        controller.windowController = self

        if window.isVisible {
            window.close()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Show Completions

    func showCompletions(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        cursorPosition: CursorPosition,
        asPopover: Bool = false
    ) {
        model.showCompletions(
            textView: textView,
            delegate: delegate,
            cursorPosition: cursorPosition
        ) { parentWindow, cursorRect in
            if asPopover {
                self.popover?.close()
                self.popover = nil

                let windowPosition = parentWindow.convertFromScreen(cursorRect)
                let textViewPosition = textView.textView.convert(windowPosition, from: nil)
                let popover = NSPopover()
                popover.behavior = .transient

                let controller = SuggestionViewController()
                controller.model = self.model
                controller.windowController = self
                controller.tableView.reloadData()
                controller.styleView(using: textView)

                popover.contentViewController = controller
                popover.show(relativeTo: textViewPosition, of: textView.textView, preferredEdge: .maxY)
                self.popover = popover
            } else {
                self.showWindow(attachedTo: parentWindow)
                self.constrainWindowToScreenEdges(cursorRect: cursorRect, font: textView.font)

                if let controller = self.contentViewController as? SuggestionViewController {
                    controller.styleView(using: textView)
                }
            }
        }
    }

    public func showCompletions(
        items: [any CodeSuggestionEntry],
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) {
        guard let parentWindow = textView.view.window,
              let resolvedPos = textView.resolveCursorPosition(cursorPosition),
              let cursorRect = textView.textView.layoutManager.rectForOffset(resolvedPos.range.location),
              let screenRect = textView.view.window?.convertToScreen(textView.textView.convert(cursorRect, to: nil))
        else { return }
        
        self.model.items = items
        self.model.activeTextView = textView
        self.showWindow(attachedTo: parentWindow)
        self.constrainWindowToScreenEdges(cursorRect: screenRect, font: textView.font)
        if let controller = self.contentViewController as? SuggestionViewController {
            controller.styleView(using: textView)
            controller.tableView.reloadData()
        }
    }

    /// Opens the window as a child of another window.
    public func showWindow(attachedTo parentWindow: NSWindow) {
        guard let window = window else { return }
        parentWindow.addChildWindow(window, ordered: .above)

        // Close on window switch observer
        // Initialized outside of `setupEventMonitors` in order to grab the parent window
        if let existingObserver = windowResignObserver {
            NotificationCenter.default.removeObserver(existingObserver)
        }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: parentWindow,
            queue: .main
        ) { [weak self] _ in
            self?.close()
        }

        super.showWindow(nil)
        window.orderFront(nil)
        window.contentViewController?.viewWillAppear()
    }

    /// Close the window
    public override func close() {
        model.willClose()

        if popover != nil {
            popover?.close()
            popover = nil
        } else {
            contentViewController?.viewWillDisappear()
        }

        super.close()
    }

    // MARK: - Cursors Updated

    /// Notifies the suggestion window that the cursor moved. The window is
    /// dismissed if it can't follow the cursor — it is never (re)opened from
    /// here; opening is exclusively a manual-trigger action.
    func cursorsUpdated(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        position: CursorPosition
    ) {
        if popover != nil {
            close()
        }

        model.cursorsUpdated(textView: textView, delegate: delegate, position: position) {
            close()
        }
    }

    // MARK: - Navigation

    func moveSelectionUp() {
        if let controller = (popover?.contentViewController as? SuggestionViewController) ?? (contentViewController as? SuggestionViewController) {
            controller.moveSelectionUp()
        }
    }

    func moveSelectionDown() {
        if let controller = (popover?.contentViewController as? SuggestionViewController) ?? (contentViewController as? SuggestionViewController) {
            controller.moveSelectionDown()
        }
    }
}
