//
//  CodeSuggestionLabelView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/24/25.
//

import AppKit
import SwiftUI

struct CodeSuggestionLabelView: View {
    static let HORIZONTAL_PADDING: CGFloat = 13

    let suggestion: CodeSuggestionEntry
    let labelColor: NSColor
    let secondaryLabelColor: NSColor
    let font: NSFont
    let isSelected: Bool

    init(
        suggestion: CodeSuggestionEntry,
        labelColor: NSColor,
        secondaryLabelColor: NSColor,
        font: NSFont,
        isSelected: Bool = false
    ) {
        self.suggestion = suggestion
        self.labelColor = labelColor
        self.secondaryLabelColor = secondaryLabelColor
        self.font = font
        self.isSelected = isSelected
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            suggestion.image
                .font(.system(size: font.pointSize + 2))
                .foregroundStyle(
                    isSelected ? .white : .white,
                    suggestion.deprecated ? .gray : (isSelected ? .white : suggestion.imageColor)
                )

            // Main label
            HStack(spacing: font.charWidth) {
                Text(suggestion.label)
                    .foregroundStyle(
                        isSelected ? .white : (suggestion.deprecated ? Color(secondaryLabelColor) : Color(labelColor))
                    )

                if let detail = suggestion.detail {
                    Text(detail)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : Color(secondaryLabelColor))
                }
            }
            .font(Font(font))

            Spacer(minLength: 0)

            // Right side indicators
            if suggestion.deprecated {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: font.pointSize + 2))
                    .foregroundStyle(
                        isSelected ? .white : Color(labelColor),
                        isSelected ? .white.opacity(0.7) : Color(secondaryLabelColor)
                    )
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, Self.HORIZONTAL_PADDING)
        .buttonStyle(PlainButtonStyle())
    }
}
