//
//  NSRange+clamped.swift
//  CodeEditTextView
//
//  Created by Troy Magri on 11/15/26.
//

import Foundation

public extension NSRange {
    /// Returns a copy of the receiver that is guaranteed to be usable with `NSString`/`NSTextStorage`
    /// APIs for a document of `length` UTF-16 units.
    ///
    /// Many Foundation APIs raise `NSRangeException` (or `NSInvalidArgumentException`) when handed a
    /// range whose location or length falls outside the string. A single stale offset — for example a
    /// caret left behind after the document shrank — is therefore enough to abort the app. Passing
    /// ranges through this method before handing them to Foundation keeps that overflow contained.
    ///
    /// - Parameter length: The length of the document the range will be applied to.
    /// - Returns: A range with `0...length` location and a non-negative length that does not exceed
    ///            `length`. Returns `{0, 0}` when `length` is not positive.
    @inline(__always)
    func clampedToDocument(_ length: Int) -> NSRange {
        guard location != NSNotFound, length > 0 else { return NSRange(location: 0, length: 0) }
        let clampedLocation = Swift.max(0, Swift.min(location, length))
        // `length` here refers to the document length; guard against negative requested lengths too.
        let requested = Swift.max(0, self.length)
        let clampedLength = Swift.min(requested, length - clampedLocation)
        return NSRange(location: clampedLocation, length: clampedLength)
    }

    /// Returns a copy of the receiver that casts a valid character range for `length` UTF-16 units.
    ///
    /// Unlike ``clampedToDocument(_:)``, the length is preserved where possible by pulling `location`
    /// back so that `location + length <= length`. Use this when the caller means "the `length`
    /// characters ending here" rather than "as much as fits from `location`".
    ///
    /// - Parameter length: The length of the document the range will be applied to.
    /// - Returns: A range that satisfies `0 <= location`, `length >= 0`, and `max <= length`.
    @inline(__always)
    func fittingInDocument(_ length: Int) -> NSRange {
        guard location != NSNotFound, length > 0 else { return NSRange(location: 0, length: 0) }
        let requested = Swift.max(0, Swift.min(self.length, length))
        let clampedLocation = Swift.max(0, Swift.min(location, length - requested))
        return NSRange(location: clampedLocation, length: requested)
    }

    /// `true` when the range can be handed to an `NSString` of `length` UTF-16 units without raising.
    @inline(__always)
    func isValid(inDocumentOfLength length: Int) -> Bool {
        location != NSNotFound && location >= 0 && self.length >= 0 && location <= length && max <= length
    }
}
