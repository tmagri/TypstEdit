//
//  IndexSet+NSRange.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 1/12/23.
//

import Foundation

extension NSRange {
    /// Convenience getter for safely creating a `Range<Int>` from an `NSRange`
    var intRange: Range<Int> {
        self.location..<NSMaxRange(self)
    }
}

/// Helpers for working with `NSRange`s and `IndexSet`s.
extension IndexSet {
    /// Initializes the  index set with a range of integers
    init(integersIn range: NSRange) {
        self.init(integersIn: range.intRange)
    }

    /// Remove all the integers in the `NSRange`
    mutating func remove(integersIn range: NSRange) {
        self.remove(integersIn: range.intRange)
    }

    /// Insert all the integers in the `NSRange`
    mutating func insert(integersIn range: NSRange) {
        self.insert(integersIn: range.intRange)
    }

    /// Returns true if self contains all of the integers in range.
    func contains(integersIn range: NSRange) -> Bool {
        return self.contains(integersIn: range.intRange)
    }

    /// Adjusts the index set to account for an edit at `range` (in pre-edit coordinates) with a length change of `delta`.
    func applyingEdit(range: NSRange, delta: Int) -> IndexSet {
        var newSet = IndexSet()
        let editStart = range.location
        let editEnd = NSMaxRange(range)

        for r in self.rangeView {
            // Unaffected indices before the edit
            if r.lowerBound < editStart {
                let end = Swift.min(r.upperBound, editStart)
                newSet.insert(integersIn: r.lowerBound..<end)
            }
            // Shifted indices after the edit
            if r.upperBound > editEnd {
                let start = Swift.max(r.lowerBound, editEnd)
                let shiftedStart = start + delta
                let shiftedEnd = r.upperBound + delta
                if shiftedEnd > shiftedStart && shiftedStart >= 0 {
                    newSet.insert(integersIn: shiftedStart..<shiftedEnd)
                }
            }
        }
        return newSet
    }
}
