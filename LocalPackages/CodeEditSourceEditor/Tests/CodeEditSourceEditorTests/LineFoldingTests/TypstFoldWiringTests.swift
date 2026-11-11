//
//  TypstFoldWiringTests.swift
//  CodeEditSourceEditorTests
//
//  The app never builds a LineFoldModel by hand: GutterView creates a
//  LineFoldRibbonView, and the ribbon owns the LineFoldModel. This test runs
//  that real chain (controller → gutter → ribbon → model) on the exact
//  `#show` block from the bug report, in a window, so any wiring gap between
//  the model-in-isolation tests and the editor shows up.
//

import Testing
import AppKit
import CodeEditTextView
@testable import CodeEditSourceEditor

@MainActor
struct TypstFoldWiringTests {

    /// The reported construct: a level-1 heading show rule with a code block.
    private static let doc = """
    // Every major (level-1) chapter heading starts on a fresh page.
    #show heading.where(level: 1): it => {
      pagebreak(weak: true)
      it
    }

    #include "header.typ"
    """

    @Test
    func foldSurvivesTheRealGutterRibbon() async throws {
        let (folds, ns) = try await buildFolds(document: Self.doc)

        // The fold starts at the end of the `{` line and closes exactly at
        // the start of the `}` line — not at the document end.
        let showRule = ns.range(of: "it => {")
        let foldStart = showRule.location + showRule.length
        let braceLineStart = ns.range(of: "\n}").location + 1

        print("[wiring] folds: \(folds.map { "\($0.range.lowerBound)..\($0.range.upperBound) (d\($0.depth))" })")
        #expect(
            folds.contains { $0.range.lowerBound == foldStart && $0.range.upperBound == braceLineStart },
            "the show-rule fold must exist through the real gutter ribbon, got: \(folds)"
        )
    }

    /// The exact construct from Revelation.note: a same-line figure rule
    /// followed by a heading rule whose `{` opens on its OWN line. Both folds
    /// must close exactly at their `}` lines through the real ribbon model.
    @Test
    func foldsMatchTheRealNoteFileLayout() async throws {
        let doc = """
        #show figure.where(kind: "verse"): it => {
          let parts = str(it.label).split("-")
          super(parts.at(2)) + h(0.15em) + it.body + [ ]
        }
        // Every major (level-1) chapter heading starts on a fresh page.
        #show heading.where(level: 1): it =>
        {
          pagebreak(weak: true)
          it
        }

        #include "header.typ"
        """
        let (folds, ns) = try await buildFolds(document: doc)
        print("[wiring] real-note folds: \(folds.map { "\($0.range.lowerBound)..\($0.range.upperBound) (d\($0.depth))" })")

        // Same-line style: fold from end of the `{` line to the `}` line.
        let figureRule = ns.range(of: "it => {")
        let figureStart = figureRule.location + figureRule.length
        let figureEnd = ns.range(of: "\n}\n// Every").location + 1
        #expect(
            folds.contains { $0.range.lowerBound == figureStart && $0.range.upperBound == figureEnd },
            "the figure rule fold must close at its `}` line, got: \(folds)"
        )

        // Brace-on-next-line style: fold from the END of the opener line
        // (`it =>`) to the `}` line — zipping hides `{` and body, stops at `}`.
        // `it =>\n{` matches only the heading opener, not the figure rule's
        // same-line `it => {`.
        let headingRule = ns.range(of: "it =>\n{")
        let headingStart = headingRule.location + ns.range(of: "it =>").length
        let headingEnd = ns.range(of: "\n}\n\n#include").location + 1
        #expect(
            folds.contains { $0.range.lowerBound == headingStart && $0.range.upperBound == headingEnd },
            "the heading rule fold must start at the opener line and close at its `}` line, got: \(folds)"
        )
    }

    /// Builds a real controller → gutter → ribbon → model chain, loads
    /// `document`, and drains the initial + post-setText cache values.
    private func buildFolds(document: String) async throws -> (folds: [FoldRange], ns: NSString) {
        // TypstEdit's config for .typ files: two-space indent units.
        var config = Mock.config()
        config.behavior.indentOption = .spaces(count: 2)
        let controller = TextViewController(
            string: "",
            language: .typst,
            configuration: config,
            cursorPositions: [],
            highlightProviders: [TreeSitterClient()]
        )
        controller.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view

        // Use the model the ribbon created — not a hand-built one.
        let model = try #require(
            controller.gutterView.foldingRibbon.model,
            "the fold ribbon must own a LineFoldModel"
        )
        controller.setText(document)
        controller.textView.layoutManager.layoutLines()

        // The rebuild is debounced then async. Drain the cache stream exactly
        // as LineFoldingModelTests does (initial build + the post-setText
        // rebuild); polling the run loop from a MainActor test starves the
        // @MainActor cache listener and never sees updates.
        var iterator = model.$foldCache.values.makeAsyncIterator()
        var last: LineFoldStorage?
        for _ in 0..<2 {
            if let value = await iterator.next() { last = value }
        }
        let ns = document as NSString
        return (last?.folds(in: 0..<ns.length) ?? [], ns)
    }
}
