//
//  NSRange.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/20/24.
//

import Foundation

public extension NSRange {
    /// Creates a range spanning `start..<end`.
    ///
    /// Callers use this as shorthand for "from here to there" and do not always guarantee `start <= end`.
    /// A reversed pair used to produce a silently negative length, which later crashes Foundation APIs
    /// such as `enumerateSubstrings(in:options:)`. The initializer now orders the two bounds so the
    /// result is always a valid range.
    @inline(__always)
    init(start: Int, end: Int) {
        self.init(location: Swift.min(start, end), length: Swift.abs(end - start))
    }
}
