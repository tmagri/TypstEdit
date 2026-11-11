//
//  TypstIndentFoldTests.swift
//  CodeEditSourceEditorTests
//
//  A `#show … : it => { … }` block must fold, whatever width the file's
//  indentation uses. The provider used to divide indent lengths by the
//  configured indent width, so a tab-indented (or 4-space) block in a
//  2-space document truncated every depth to 0 and the fold never appeared
//  — the braces read as if they never closed.
//

import Testing
import AppKit
import CodeEditTextView
@testable import CodeEditSourceEditor

@MainActor
struct TypstIndentFoldTests {

    /// The show-rule block in three indentation styles, followed by content
    /// that must NOT be swallowed by the fold.
    private static func document(indent: String) -> String {
        """
        #show heading.where(level: 1): it => {
        \(indent)pagebreak(weak: true)
        \(indent)it
        }

        #include "header.typ"
        = The Apocalypse of St. John the Apostle <apoc>

        #outline()
        """
    }

    private func makeController(indentCount: Int) -> TextViewController {
        var config = Mock.config()
        config.behavior.indentOption = .spaces(count: indentCount)
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
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        return controller
    }

    private func foldClosingAtBrace(
        controller: TextViewController,
        document: String,
        expectedStart: Int
    ) async -> Bool {
        let model = LineFoldModel(controller: controller, foldView: NSView())
        controller.setText(document)
        controller.textView.layoutManager.layoutLines()

        var iterator = model.$foldCache.values.makeAsyncIterator()
        var last: LineFoldStorage?
        for _ in 0..<2 {
            if let value = await iterator.next() { last = value }
        }

        let ns = document as NSString
        // The `}` line is the first line that starts with "}".
        let braceLineStart = ns.range(of: "\n}").location + 1
        let folds = last?.folds(in: 0..<ns.length) ?? []
        print("[folds] \(folds.map { "\($0.range.lowerBound)..\($0.range.upperBound) (d\($0.depth))" })")
        // One fold must start at the end of the opener line and close exactly
        // at the start of the `}` line — not run on to the document end.
        return folds.contains { $0.range.lowerBound == expectedStart && $0.range.upperBound == braceLineStart }
    }

    @Test
    func foldsWithTwoSpaceIndent() async {
        let doc = Self.document(indent: "  ")
        // `{` sits at the end of line 0; the fold starts right after it.
        #expect(await foldClosingAtBrace(controller: makeController(indentCount: 2), document: doc, expectedStart: 38))
    }

    /// The regression: a tab-indented block in a 2-space document.
    @Test
    func foldsWithTabIndent() async {
        let doc = Self.document(indent: "\t")
        #expect(await foldClosingAtBrace(controller: makeController(indentCount: 2), document: doc, expectedStart: 38))
    }

    /// A file indented wider than the editor's configured indent unit.
    @Test
    func foldsWithWiderIndentThanConfigured() async {
        let doc = Self.document(indent: "    ")
        #expect(await foldClosingAtBrace(controller: makeController(indentCount: 2), document: doc, expectedStart: 38))
    }

    /// The style used in Revelation.note: the `{` opens on its OWN line under
    /// the `it =>`. The fold must start at the END of the opener line (not at
    /// the bare `{` line, and not at the document end) and close exactly at
    /// the `}` line.
    @Test
    func foldsWhenBraceOpensOnNextLine() async {
        let doc = """
        #show heading.where(level: 1): it =>
        {
          pagebreak(weak: true)
          it
        }

        #include "header.typ"
        """
        let ns = doc as NSString
        let openerLineLength = ns.range(of: "\n").location
        #expect(await foldClosingAtBrace(controller: makeController(indentCount: 2), document: doc, expectedStart: openerLineLength))
    }

    /// The construct opener may also be a binding (`#let f =`) or tagged
    /// argument (`#set page(`) — anything ending in `=>`, `=`, `:`, `(`.
    @Test
    func foldsWhenBindingBraceOpensOnNextLine() async {
        let doc = """
        #let make = (n) =>
        {
          n * 2
        }

        #include "header.typ"
        """
        let ns = doc as NSString
        let openerLineLength = ns.range(of: "\n").location
        #expect(await foldClosingAtBrace(controller: makeController(indentCount: 2), document: doc, expectedStart: openerLineLength))
    }

    /// The `}` must close its fold even when it lands on the FIRST line of
    /// the calculator's second 50-line chunk. `ChunkedLineIterator` used to
    /// reset `previousDepth` to 0 at every chunk start, so the dedent on that
    /// line was never detected and the fold ran to the document end. 46
    /// filler lines put the opener at index 46 and the `}` exactly at index
    /// 50 — the layout of the real Revelation.note report.
    @Test
    func foldClosesAcrossChunkBoundary() async {
        let filler = Array(repeating: "// filler line", count: 46).joined(separator: "\n")
        let doc = """
        \(filler)
        #show heading.where(level: 1): it =>
        {
          pagebreak(weak: true)
          it
        }

        #include "header.typ"
        """
        let ns = doc as NSString
        let opener = ns.range(of: "it =>\n{")
        let expectedStart = opener.location + ns.range(of: "it =>").length
        #expect(await foldClosingAtBrace(controller: makeController(indentCount: 2), document: doc, expectedStart: expectedStart))
    }
}
