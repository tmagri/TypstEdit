import XCTest
import SwiftTreeSitter
import CodeEditLanguages
@testable import TypstEdit

final class MarkdownHighlightProbeTests: XCTestCase {

    /// Parses `source` with the language's parser, runs its highlights query,
    /// and prints every capture so we can see exactly what the primary layer sees.
    private func probe(name: String, language: CodeLanguage, source: String) {
        let parser = Parser()
        guard let lang = language.language else {
            print("[\(name)] NO LANGUAGE")
            return
        }
        try? parser.setLanguage(lang)
        guard let tree = parser.parse(source), let root = tree.rootNode else {
            print("[\(name)] PARSE FAILED")
            return
        }
        print("[\(name)] tree root children=\(root.childCount)")

        guard let queryURL = language.queryURL else {
            print("[\(name)] NO QUERY URL")
            return
        }
        guard let data = FileManager.default.contents(atPath: queryURL.path) else {
            print("[\(name)] NO QUERY DATA at \(queryURL.path)")
            return
        }
        guard let query = try? Query(language: lang, data: data) else {
            print("[\(name)] QUERY COMPILE FAILED: \(queryURL.lastPathComponent)")
            return
        }
        let cursor = query.execute(node: root, in: tree)
        cursor.setRange(NSRange(location: 0, length: (source as NSString).length))
        let context = SwiftTreeSitter.Predicate.Context(textProvider: { nsRange, _ in
            return (source as NSString).substring(with: nsRange)
        })
        let resolved = cursor.resolve(with: context)
        print("[\(name)] captures from \(queryURL.lastPathComponent):")
        for match in resolved {
            for cap in match.captures {
                let text = (source as NSString).substring(with: cap.range)
                print("   \(cap.name) → '\(text)'")
            }
        }
    }

    func testMarkdownQueryCaptures() {
        probe(name: "markdown", language: .markdown,
              source: "# My Heading\n\nSome *emphasis* and **bold** text.\n\n- list item\n")
    }

    func testNoteQueryCaptures() {
        probe(name: "note", language: .note,
              source: "# My Heading\n\nSome *emphasis* text.\n")
    }

    /// The markdown_inline injected layer must be able to compile its query and
    /// capture inline constructs — this is what styles `*emphasis*` / `**strong**`.
    func testMarkdownInlineQueryCaptures() {
        probe(name: "markdown-inline", language: .markdownInline,
              source: "Some *emphasis* and **bold** and `code` text.")
    }

    /// Mirrors how the editor actually runs the injected layer: the markdown_inline
    /// parser parses the FULL document with `includedRanges` limited to an inline
    /// node, then the inline query runs on that tree.
    func testMarkdownInlineWithIncludedRanges() throws {
        let source = "# Heading\n\nSome *emphasis* and **bold** text.\n"
        let parser = Parser()
        guard let lang = CodeLanguage.markdownInline.language else {
            return XCTFail("no markdown_inline language")
        }
        try parser.setLanguage(lang)

        // The paragraph inline node covers "Some *emphasis* and **bold** text." —
        // UTF-16 units 12..47 in the source above. The editor's convention doubles
        // UTF-16 offsets into tree-sitter "byte" offsets and feeds UTF-16-encoded
        // data (see NSRange+TSRange and TextView+createReadBlock).
        let sourceNS = source as NSString
        let inlineRange = sourceNS.range(of: "Some *emphasis* and **bold** text.")
        let utf16 = String.Encoding(rawValue: 0x94000100) // String.nativeUTF16Encoding (internal)
        parser.includedRanges = [TSRange(
            points: Point(row: 0, column: 0)..<Point(row: 0, column: 0),
            bytes: (UInt32(inlineRange.location) * 2)..<(UInt32(inlineRange.location + inlineRange.length) * 2)
        )]

        let data = source.data(using: utf16)!
        let readBlock: Parser.ReadBlock = { byteOffset, _ in
            // Same convention as TextView+createReadBlock: byteOffset / 2 → UTF-16 location.
            let location = byteOffset / 2
            guard location < sourceNS.length else { return nil }
            let end = min(location + 4096, sourceNS.length)
            return sourceNS.substring(with: NSRange(location..<end)).data(using: utf16)
        }
        guard let tree = parser.parse(tree: nil as Tree?, readBlock: readBlock),
              let root = tree.rootNode else {
            return XCTFail("parse failed")
        }
        print("[inline-included] root: type=\(root.nodeType ?? "nil") childCount=\(root.childCount) span=\(root.range)")

        guard let queryData = FileManager.default.contents(atPath: CodeLanguage.markdownInline.queryURL!.path),
              let query = try? Query(language: lang, data: queryData) else {
            return XCTFail("query failed")
        }
        let cursor = query.execute(node: root, in: tree)
        cursor.setRange(inlineRange)
        let context = SwiftTreeSitter.Predicate.Context(textProvider: { nsRange, _ in
            (source as NSString).substring(with: nsRange)
        })
        for match in cursor.resolve(with: context) {
            for cap in match.captures {
                print("   \(cap.name) → '\((source as NSString).substring(with: cap.range))'")
            }
        }
    }
}
