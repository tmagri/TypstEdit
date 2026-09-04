//
//  TextView+Point.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 1/18/24.
//

import Foundation
import CodeEditTextView
import SwiftTreeSitter

extension TextView {
    func pointForLocation(_ location: Int) -> Point? {
        let clampedLocation = max(0, min(location, layoutManager.lineStorage.length))
        guard let linePosition = layoutManager.textLineForOffset(clampedLocation) else { return nil }
        let column = max(0, clampedLocation - linePosition.range.location)
        // Tree-sitter requires column to be in bytes. In UTF-16 mode each code unit is 2 bytes.
        return Point(row: linePosition.index, column: column * 2)
    }
}
