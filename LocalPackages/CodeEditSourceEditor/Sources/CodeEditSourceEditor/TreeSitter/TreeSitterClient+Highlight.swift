//
//  TreeSitterClient+Highlight.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 3/10/23.
//

import Foundation
import SwiftTreeSitter
import CodeEditLanguages

extension TreeSitterClient {
    func queryHighlightsForRange(range: NSRange) -> [HighlightRange] {
        guard let state = self.state else { return [] }

        var highlights: [HighlightRange] = []
        var primarySet = IndexSet(integersIn: range)

        // Injected layers must be queried in a deterministic priority order.
        // When two layers produce captures for the same range, the first-queried
        // layer's capture wins (StyledRangeContainer.applyHighlightResult skips
        // later overlapping captures). The layer order in `state.layers` is
        // otherwise non-deterministic — it depends on Swift's per-process
        // Dictionary hash seed — which is why in .note files Typst *bold*
        // sometimes rendered as bold (Typst wins) and sometimes as italic
        // (markdown_inline wins) across app launches.
        let injectedLayers = state.layers
            .filter { $0.id != state.primaryLayer.id }
            .sorted { Self.injectionLayerPriority($0.id) < Self.injectionLayerPriority($1.id) }

        // Layers that style content the primary grammar never captures (the Typst
        // overlay in .note files, embedded html/yaml in .md) are queried BEFORE the
        // primary layer and consume their ranges, exactly as before.
        let prePrimaryLayers = injectedLayers.filter { $0.id != .markdownInline }

        // markdown_inline re-parses the very same inline nodes the primary grammar
        // captures at the block level — e.g. `(atx_heading (inline) @text.title)`
        // styles Markdown headings. Querying it first consumed those ranges so the
        // primary capture was never produced, leaving headings (and all other
        // block-level markup) unstyled. It is therefore queried AFTER the primary
        // layer, and only for ranges the pre-primary layers did not claim — in
        // .note files the Typst overlay claims whole paragraphs, so Markdown's
        // `*emphasis*` must not compete with Typst's `*bold*` there.
        let postPrimaryLayers = injectedLayers.filter { $0.id == .markdownInline }

        for layer in prePrimaryLayers {
            // Query injected only if a layer's ranges intersects with `range`
            for layerRange in layer.ranges {
                if let rangeIntersection = range.intersection(layerRange) {
                    let queryResult = queryLayerHighlights(
                        layer: layer,
                        range: rangeIntersection
                    )

                    highlights.append(contentsOf: queryResult)
                    primarySet.remove(integersIn: rangeIntersection)
                }
            }
        }

        // Query primary for any ranges that weren't used in the pre-primary layers.
        for range in primarySet.rangeView {
            let queryResult = queryLayerHighlights(
                layer: state.layers[0],
                range: NSRange(range)
            )
            highlights.append(contentsOf: queryResult)
        }

        for layer in postPrimaryLayers {
            for layerRange in layer.ranges {
                guard let rangeIntersection = range.intersection(layerRange) else { continue }
                // Restrict to ranges the pre-primary layers didn't claim.
                let unclaimed = primarySet.intersection(IndexSet(integersIn: rangeIntersection))
                for claimed in unclaimed.rangeView {
                    let queryResult = queryLayerHighlights(
                        layer: layer,
                        range: NSRange(claimed)
                    )
                    highlights.append(contentsOf: queryResult)
                }
            }
        }

        return highlights
    }

    /// Sort priority for injected language layers. Lower values are queried first
    /// and therefore win for overlapping ranges. In `.note` files the Typst overlay
    /// must take precedence over the Markdown inline parser so that Typst markup
    /// (`*bold*`, `_italic_`, `#func()`, `$math$`) is highlighted correctly instead
    /// of being overridden by Markdown's interpretation of the same delimiters.
    private static func injectionLayerPriority(_ id: TreeSitterLanguage) -> Int {
        switch id {
        case .typst: return 0
        case .markdownInline: return 1
        default: return 2
        }
    }

    /// Queries the given language layer for any highlights.
    /// - Parameters:
    ///   - layer: The layer to query.
    ///   - range: The range to query for.
    /// - Returns: Any ranges to highlight.
    internal func queryLayerHighlights(
        layer: LanguageLayer,
        range: NSRange
    ) -> [HighlightRange] {
        guard let tree = layer.tree,
              let rootNode = tree.rootNode else {
            return []
        }

        // This needs to be on the main thread since we're going to use the `textProvider` in
        // the `highlightsFromCursor` method, which uses the textView's text storage.
        guard let queryCursor = layer.languageQuery?.execute(node: rootNode, in: tree) else {
            return []
        }
        queryCursor.setRange(range)
        queryCursor.matchLimit =  Constants.matchLimit

        var highlights: [HighlightRange] = []

        // See https://github.com/CodeEditApp/CodeEditSourceEditor/pull/228
        if layer.id == .jsdoc {
            highlights.append(HighlightRange(range: range, capture: .comment))
        }

        highlights += highlightsFromCursor(cursor: queryCursor, includedRange: range)

        // Deterministic ordering: at equal locations the LONGER capture — a parent
        // node like `emphasis`/`strong_emphasis`/`code_fence_content` — must come
        // before its shorter child captures (delimiters, tokens). The downstream
        // `applyHighlightResult` skips any range starting before the last applied
        // one, so without this tie-break the shorter child capture could win the
        // arbitrary sort and erase the parent markup's styling entirely (this is
        // why `**bold**` rendered unstyled in Markdown documents).
        highlights.sort { a, b in
            if a.range.location != b.range.location {
                return a.range.location < b.range.location
            }
            return a.range.length > b.range.length
        }

        return highlights
    }

    /// Resolves a query cursor to the highlight ranges it contains.
    /// **Must be called on the main thread**
    /// - Parameters:
    ///     - cursor: The cursor to resolve.
    ///     - includedRange: The range to include highlights from.
    /// - Returns: Any highlight ranges contained in the cursor.
    internal func highlightsFromCursor(
        cursor: QueryCursor,
        includedRange: NSRange
    ) -> [HighlightRange] {
        guard let readCallback else { return [] }
        var ranges: [NSRange: Int] = [:]
        return cursor
            .resolve(with: .init(textProvider: readCallback)) // Resolve our cursor against the query
            .flatMap { $0.captures }
            .reversed() // SwiftTreeSitter returns captures in the reverse order of what we need to filter with.
            .compactMap { capture in
                let range = capture.range
                let index = capture.index

                // Lower indexed captures are favored over higher, this is why we reverse it above
                if let existingLevel = ranges[range], existingLevel <= index {
                    return nil
                }

                guard let captureName = CaptureName.fromString(capture.name) else {
                    return nil
                }

                // Update the filter level to the current index since it's lower and a 'valid' capture
                ranges[range] = index

                // Validate range and capture name
                let intersectionRange = range.intersection(includedRange) ?? .zero
                guard intersectionRange.length > 0 else {
                    return nil
                }

                return HighlightRange(range: intersectionRange, capture: captureName)
            }
    }
}
