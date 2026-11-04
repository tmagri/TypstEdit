//
//  TreeSitterClient+Edit.swift
//  
//
//  Created by Khan Winter on 3/10/23.
//

import Foundation
import SwiftTreeSitter
import CodeEditLanguages

extension TreeSitterClient {
    /// The largest block, in characters, that is treated as the region an edit can affect. Injected layers outside
    /// this region and outside the parser's changed ranges are not re-parsed or re-queried.
    static let maxEditRegionLength = 10_000

    /// Applies the given edit to the current state and calls the editState's completion handler.
    ///
    /// Concurrency note: This method checks for task cancellation between layer edits, after editing all layers, and
    /// before setting the client's state.
    ///
    /// - Parameter edit: The edit to apply to the internal tree sitter state.
    /// - Returns: The set of ranges invalidated by the edit operation.
    func applyEdit(edit: InputEdit) -> IndexSet {
        guard let state = state?.copy(), let readBlock, let readCallback else { return IndexSet() }
        let pendingEdits = pendingEdits.value() // Grab pending edits.
        let edits = pendingEdits + [edit]

        // TypstEdit: with a single edit, only the layers the edit touches are re-parsed. Documents such as `.note`
        // files have one injected layer per paragraph, and re-parsing all of them made every keystroke scale with
        // the document. Queued edits use offsets relative to each other, so they keep the full path.
        let isSingleEdit = edits.count == 1

        var invalidatedRanges = IndexSet()
        var reparsedLayers = Set<ObjectIdentifier>()

        // Loop through all layers, apply edits & find changed byte ranges.
        for (idx, layer) in state.layers.enumerated().reversed() {
            if Task.isCancelled { return IndexSet() }

            if layer.id != state.primaryLayer.id {
                let touchedByEdit = !isSingleEdit || Self.edit(edit, touches: layer.ranges)
                applyEditTo(layer: layer, edits: edits)

                if layer.ranges.isEmpty {
                    state.removeLanguageLayer(at: idx)
                    continue
                }

                if !touchedByEdit {
                    // The layer's text did not change. Shift its tree so node positions stay correct, and leave the
                    // re-parse for when an edit reaches it.
                    for edit in edits {
                        layer.tree?.edit(edit)
                    }
                    continue
                }
            }

            reparsedLayers.insert(ObjectIdentifier(layer))
            layer.parser.includedRanges = layer.ranges.map { $0.tsRange }
            let ranges = layer.findChangedByteRanges(
                edits: edits,
                timeout: Constants.parserTimeout,
                readBlock: readBlock
            )
            invalidatedRanges.insert(ranges: ranges)
        }

        if Task.isCancelled { return IndexSet() }

        let nonPrimaryLayers = state.layers.filter { $0.id != state.primaryLayer.id }
        let candidateLayers: Set<LanguageLayer>
        let shouldQuery: (LanguageLayer) -> Bool

        if isSingleEdit {
            var dirtyRegion = invalidatedRanges
            dirtyRegion.insert(range: Self.newRange(of: edit))
            if let block = Self.enclosingBlockRange(of: edit, in: state.layers.first?.tree) {
                dirtyRegion.insert(range: block)
            }
            let dirtyLayers = nonPrimaryLayers.filter { Self.ranges($0.ranges, touch: dirtyRegion) }
            let dirtyIds = Set(dirtyLayers.map { ObjectIdentifier($0) })
            let existingIds = Set(state.layers.map { ObjectIdentifier($0) })
            candidateLayers = Set(dirtyLayers)
            // Query the primary layer, layers in the dirty region, and layers added during this update.
            // An injected layer outside the region kept its text, so its injections are unchanged.
            shouldQuery = { layer in
                let id = ObjectIdentifier(layer)
                return layer.id == state.primaryLayer.id || dirtyIds.contains(id) || !existingIds.contains(id)
            }
        } else {
            candidateLayers = Set(nonPrimaryLayers)
            shouldQuery = { _ in true }
        }

        // Update the state object for any new injections that may have been caused by this edit.
        invalidatedRanges.formUnion(state.updateInjectedLayers(
            readCallback: readCallback,
            readBlock: readBlock,
            touchedLayers: candidateLayers,
            shouldQuery: shouldQuery
        ))

        if Task.isCancelled { return IndexSet() }

        self.state = state // Apply the copied state
        self.pendingEdits.mutate { edits in // Clear the queue
            edits = []
        }

        return invalidatedRanges
    }

    private func applyEditTo(layer: LanguageLayer, edits: [InputEdit]) {
        // Reversed for safe removal while looping
        for rangeIdx in (0..<layer.ranges.count).reversed() {
            for edit in edits {
                layer.ranges[rangeIdx].applyInputEdit(edit)
            }

            if layer.ranges[rangeIdx].length <= 0 {
                layer.ranges.remove(at: rangeIdx)
            }
        }
    }

    /// True when the edit (in pre-edit coordinates) overlaps or touches any of the ranges.
    private static func edit(_ edit: InputEdit, touches ranges: [NSRange]) -> Bool {
        let start = Int(edit.startByte) / 2
        let oldEnd = Int(edit.oldEndByte) / 2
        return ranges.contains { start <= NSMaxRange($0) && oldEnd >= $0.location }
    }

    /// True when any of the ranges overlaps or touches the index set.
    private static func ranges(_ ranges: [NSRange], touch set: IndexSet) -> Bool {
        ranges.contains { range in
            let lower = max(0, range.location - 1)
            return set.intersects(integersIn: lower..<(NSMaxRange(range) + 1))
        }
    }

    /// The edited range in post-edit coordinates, at least one character long.
    private static func newRange(of edit: InputEdit) -> NSRange {
        let start = Int(edit.startByte) / 2
        let newEnd = Int(edit.newEndByte) / 2
        return NSRange(location: start, length: max(1, newEnd - start))
    }

    /// The range of the largest node, up to ``maxEditRegionLength`` characters, that encloses the edit in the
    /// primary tree. Edits such as changing a code fence's language can change injections without a structural
    /// change, so this block is always treated as affected.
    private static func enclosingBlockRange(of edit: InputEdit, in tree: MutableTree?) -> NSRange? {
        guard let root = tree?.rootNode else { return nil }
        let start = edit.startByte
        let end = max(edit.newEndByte, start + 2)
        guard var node = root.descendant(in: start..<end) else { return nil }
        var best = node.range
        while let parent = node.parent, parent.range != root.range {
            guard parent.range.length <= maxEditRegionLength else { break }
            best = parent.range
            node = parent
        }
        return best
    }
}
