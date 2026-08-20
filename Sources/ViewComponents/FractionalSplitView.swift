import SwiftUI
import AppKit

/// A split view that gives its leading pane a fixed, explorer-style default
/// width (like VS Code's side bar) while remaining fully user-resizable, and
/// supports hiding the leading pane without recreating the trailing pane.
///
/// SwiftUI's built-in `HSplitView` re-derives pane widths from min/ideal/max
/// frames on every layout, so a user-resized width never sticks; this wraps a
/// plain `NSSplitView` (the same `CustomSplitView` styling used by the
/// editor/preview split), positions the divider at the requested width when the
/// leading pane appears, then leaves the user's drags in control.
///
/// Note: this deliberately does NOT use `NSSplitViewController` — when embedded
/// through `NSViewControllerRepresentable` the controller never installs its
/// items' views into the split view, leaving both panes blank.
struct FractionalSplitView<Left: View, Right: View>: NSViewRepresentable {
    var showLeft: Bool
    var initialLeftWidth: CGFloat
    var minimumLeftWidth: CGFloat
    let left: Left
    let right: Right

    init(
        showLeft: Bool,
        initialLeftWidth: CGFloat = 180,
        minimumLeftWidth: CGFloat = 150,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) {
        self.showLeft = showLeft
        self.initialLeftWidth = initialLeftWidth
        self.minimumLeftWidth = minimumLeftWidth
        self.left = left()
        self.right = right()
    }

    func makeNSView(context: Context) -> FractionalCustomSplitView {
        let splitView = FractionalCustomSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator
        context.coordinator.minimumLeftWidth = minimumLeftWidth

        let leftHost = NSHostingController(rootView: left)
        let rightHost = NSHostingController(rootView: right)
        leftHost.view.translatesAutoresizingMaskIntoConstraints = false
        rightHost.view.translatesAutoresizingMaskIntoConstraints = false
        leftHost.view.wantsLayer = true
        rightHost.view.wantsLayer = true

        let leftContainer = NSView()
        let rightContainer = NSView()
        leftContainer.addSubview(leftHost.view)
        rightContainer.addSubview(rightHost.view)
        NSLayoutConstraint.activate([
            leftHost.view.topAnchor.constraint(equalTo: leftContainer.topAnchor),
            leftHost.view.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor),
            leftHost.view.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor),
            leftHost.view.bottomAnchor.constraint(equalTo: leftContainer.bottomAnchor),

            rightHost.view.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            rightHost.view.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            rightHost.view.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            rightHost.view.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),
        ])

        context.coordinator.leftHost = leftHost
        context.coordinator.rightHost = rightHost
        context.coordinator.leftContainer = leftContainer
        context.coordinator.rightContainer = rightContainer

        // The content pane absorbs window resizes; the sidebar holds its width.
        splitView.addArrangedSubview(rightContainer)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        if showLeft {
            context.coordinator.showLeft(splitView, position: initialLeftWidth)
        }
        return splitView
    }

    func updateNSView(_ splitView: FractionalCustomSplitView, context: Context) {
        context.coordinator.leftHost?.rootView = left
        context.coordinator.rightHost?.rootView = right
        context.coordinator.minimumLeftWidth = minimumLeftWidth

        let isShowing = context.coordinator.leftContainer?.superview === splitView
        if showLeft && !isShowing {
            context.coordinator.showLeft(splitView, position: initialLeftWidth)
        } else if !showLeft && isShowing {
            context.coordinator.hideLeft(splitView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var leftHost: NSHostingController<Left>?
        var rightHost: NSHostingController<Right>?
        var leftContainer: NSView?
        var rightContainer: NSView?
        var minimumLeftWidth: CGFloat = 150

        /// Insert the leading pane at the head and (re)apply its default width
        /// on the next layout pass.
        func showLeft(_ splitView: NSSplitView, position: CGFloat) {
            guard let leftContainer else { return }
            splitView.insertArrangedSubview(leftContainer, at: 0)
            splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
            if let rightContainer, let rightIndex = splitView.subviews.firstIndex(of: rightContainer) {
                splitView.setHoldingPriority(.defaultLow, forSubviewAt: rightIndex)
            }
            (splitView as? FractionalCustomSplitView)?.pendingDividerPosition = position
        }

        func hideLeft(_ splitView: NSSplitView) {
            leftContainer?.removeFromSuperview()
        }

        // Keep the sidebar drag-resizable but never narrower than its minimum.
        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard dividerIndex == 0, leftContainer?.superview === splitView else {
                return proposedMinimumPosition
            }
            return max(proposedMinimumPosition, minimumLeftWidth)
        }
    }
}

/// `CustomSplitView` that positions its first divider at a fixed width the next
/// time it lays out with a non-empty size (i.e. right after the leading pane
/// appears), then leaves the user in control.
final class FractionalCustomSplitView: CustomSplitView {
    var pendingDividerPosition: CGFloat?

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard let position = pendingDividerPosition, bounds.width > 0, subviews.count >= 2 else { return }
        pendingDividerPosition = nil
        // Never starve the content pane if the window is very narrow.
        setPosition(min(position, bounds.width - 100), ofDividerAt: 0)
    }
}
