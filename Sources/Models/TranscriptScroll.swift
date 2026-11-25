import CoreGraphics

/// Where the transcript sits relative to its own content, reduced to the one
/// question the chat asks of it: is the newest turn on screen?
///
/// The answer decides two things. It lets a streamed reply keep scrolling the
/// window while the reader is following it, and it stops doing so the moment
/// they scroll up to re-read something older — so the transcript offers a
/// Jump to Bottom button instead of dragging them back to the end. Like
/// `ChatPlacement`, this is arithmetic on frames: no window, no view, and no
/// scroll view needed to test it.
enum TranscriptScroll {
    /// Slack, in points, for "at the bottom". A trackpad fling rarely comes
    /// to rest exactly on the last pixel, and the transcript's own 12pt of
    /// bottom padding should not read as having scrolled away.
    static let atBottomTolerance: CGFloat = 24

    /// Whether a scroll view showing content of `contentHeight` in a
    /// `viewportHeight` tall window, scrolled `offsetY` points from its
    /// top, has reached its newest row.
    ///
    /// `flipped` is the usual AppKit question: a flipped document scrolls
    /// from 0 (its top) to `contentHeight - viewportHeight` (its bottom), an
    /// unflipped one the other way around. SwiftUI's hosting views are
    /// flipped, so the default is the branch that runs in practice.
    ///
    /// Content that fits in the viewport has nothing below the fold, so it
    /// counts as being at the bottom however it is scrolled.
    static func isAtBottom(
        offsetY: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat,
        flipped: Bool = true,
        tolerance: CGFloat = atBottomTolerance
    ) -> Bool {
        let maximumOffset = max(0, contentHeight - viewportHeight)
        guard maximumOffset > 0 else { return true }
        return flipped
            ? offsetY >= maximumOffset - tolerance
            : offsetY <= tolerance
    }

    /// The offset that brings a blank transcript back into view, or `nil` when
    /// the window still shows content where it is.
    ///
    /// A transcript shrinks under the window all the time: a finished turn's
    /// live row is replaced by the answer, the previous turn's tool calls fold
    /// into one line, a compaction summary replaces a long stretch of turns,
    /// and a tab switch swaps a long chat for a short one. AppKit leaves the
    /// clip view's origin where it was, so the window can end up scrolled past
    /// the end of the content it is showing, and nothing above that offset is
    /// drawn. A resize appears to "fix" it because new geometry forces a
    /// layout, which is what this correction does without the resize.
    ///
    /// Only the blank case is corrected. An ordinary overscroll from a fling
    /// still overlaps the content, and writing the offset then would cut the
    /// rubber band short.
    ///
    /// The visible rect stops overlapping the content at `offsetY ==
    /// contentHeight` whichever way the document runs — both orientations run
    /// out of content at that same distance — so the test for "blank" needs no
    /// orientation. Where to go back to does: a flipped document counts down
    /// from its top and lands on its bottom, an unflipped one counts up from
    /// its bottom and so returns to zero. A document with no height yet is
    /// mid-layout, not blank, and is left alone.
    static func recoveryOffset(
        offsetY: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat,
        flipped: Bool = true
    ) -> CGFloat? {
        guard contentHeight > 0, offsetY >= contentHeight else { return nil }
        return flipped ? max(0, contentHeight - viewportHeight) : 0
    }

    /// Whether the transcript's geometry just changed in a way that can leave
    /// rows unmeasured although the offset is valid.
    ///
    /// A fallback, not the first line of defence: the transcript is an eager
    /// `VStack` now, so it lays out what it is given and cannot estimate its
    /// way into blank space (see `TranscriptWindow`). This still covers the
    /// geometry that changes without either a scroll or a resize. The cases
    /// that do it:
    ///
    /// - the viewport changed height: a docked panel (plan, case, an
    ///   approval strip) appeared, went away, or was zipped;
    /// - the content shrank: a live row replaced by its answer, a run folded
    ///   into one line, a compaction;
    /// - the content jumped by more than half a screen at once: a tab switch,
    ///   a long reply landing whole.
    ///
    /// Ordinary streaming growth is none of these, so following a reply does
    /// not nudge the view on every token. The first measurement has nothing
    /// to compare with and never counts.
    static func needsRealizationKick(
        oldContentHeight: CGFloat?,
        newContentHeight: CGFloat,
        oldViewportHeight: CGFloat?,
        newViewportHeight: CGFloat
    ) -> Bool {
        guard let oldContentHeight, let oldViewportHeight, newContentHeight > 0 else { return false }
        if abs(newViewportHeight - oldViewportHeight) > 0.5 { return true }
        if newContentHeight < oldContentHeight - 0.5 { return true }
        return newContentHeight - oldContentHeight > newViewportHeight / 2
    }

    /// After the geometry changed, an offset below the last full screen of
    /// content leaves the bottom of the window empty: the content ended, the
    /// window did not move. `recoveryOffset` only catches the case where *no*
    /// content is left in view; this one pulls a partly empty window back to
    /// the bottom too. Only applied on a geometry change — never on a plain
    /// scroll — so a trackpad's rubber band is left alone.
    static func clampedOffsetAfterGeometryChange(
        offsetY: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat,
        flipped: Bool = true
    ) -> CGFloat? {
        guard contentHeight > 0 else { return nil }
        let maximumOffset = max(0, contentHeight - viewportHeight)
        if flipped {
            return offsetY > maximumOffset + 1 ? maximumOffset : nil
        }
        return offsetY < -1 ? 0 : nil
    }
}
