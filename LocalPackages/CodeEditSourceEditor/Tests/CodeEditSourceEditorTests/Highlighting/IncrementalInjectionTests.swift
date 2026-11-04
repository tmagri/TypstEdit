import XCTest
import CodeEditTextView
import CodeEditLanguages
@testable import CodeEditSourceEditor

/// Edits only re-parse and re-query the injected layers they can affect. After any series of edits, the layers
/// must match a full parse of the final text.
final class IncrementalInjectionTests: XCTestCase {
    final class NoAttributes: ThemeAttributesProviding {
        func attributesFor(_ capture: CaptureName?) -> [NSAttributedString.Key: Any] { [:] }
    }

    private let source = """
    # Heading

    First paragraph with *bold* and $x^2$ math.

    Second paragraph #text(fill: red)[red] here.

    ```python
    print("hi")
    ```

    Third paragraph with `code` and a [link](https://example.com).

    #set page(
      footer: [Page]
    )

    Last paragraph.
    """

    private struct LayerKey: Hashable, CustomStringConvertible {
        let id: String
        let ranges: [NSRange]
        var description: String { "\(id) \(ranges.map { "\($0.location)+\($0.length)" })" }
    }

    @MainActor
    private func makeEditor() -> (TextView, TreeSitterClient, Highlighter) {
        let textView = Mock.textView()
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textView.setText(source)
        let client = TreeSitterClient()
        client.forceSyncOperation = true
        let highlighter = Mock.highlighter(
            textView: textView,
            highlightProviders: [client],
            attributeProvider: NoAttributes()
        )
        textView.addStorageDelegate(highlighter)
        highlighter.setLanguage(language: .note)
        return (textView, client, highlighter)
    }

    private func keys(_ state: TreeSitterState?) -> [LayerKey] {
        (state?.layers ?? [])
            .map { LayerKey(id: $0.id.rawValue, ranges: $0.ranges) }
            .sorted { ($0.ranges.first?.location ?? -1, $0.id) < ($1.ranges.first?.location ?? -1, $1.id) }
    }

    @MainActor
    private func assertMatchesFullParse(_ textView: TextView, _ client: TreeSitterClient, file: StaticString = #filePath, line: UInt = #line) {
        let fresh = TreeSitterState(
            codeLanguage: .note,
            readCallback: textView.createReadCallback(),
            readBlock: textView.createReadBlock()
        )
        XCTAssertEqual(keys(client.state), keys(fresh), file: file, line: line)

        let freshClient = TreeSitterClient()
        freshClient.forceSyncOperation = true
        freshClient.setUp(textView: textView, codeLanguage: .note)
        var incremental: [HighlightRange] = []
        var full: [HighlightRange] = []
        client.queryHighlightsFor(textView: textView, range: textView.documentRange) { result in
            if case .success(let ranges) = result { incremental = ranges }
        }
        freshClient.queryHighlightsFor(textView: textView, range: textView.documentRange) { result in
            if case .success(let ranges) = result { full = ranges }
        }
        XCTAssertEqual(
            incremental.map { "\($0.range)\(String(describing: $0.capture))" },
            full.map { "\($0.range)\(String(describing: $0.capture))" },
            file: file,
            line: line
        )
    }

    @MainActor
    private func type(_ text: String, after anchor: String, in textView: TextView) {
        let location = NSMaxRange((textView.string as NSString).range(of: anchor))
        precondition(location != NSNotFound, "missing \(anchor)")
        for (offset, char) in text.enumerated() {
            textView.replaceCharacters(in: NSRange(location: location + offset, length: 0), with: String(char))
        }
    }

    @MainActor
    private func delete(_ text: String, in textView: TextView) {
        let range = (textView.string as NSString).range(of: text)
        precondition(range.location != NSNotFound, "missing \(text.debugDescription) in \(textView.string.debugDescription)")
        textView.replaceCharacters(in: range, with: "")
    }

    @MainActor
    func test_typingInsideOneParagraph() {
        let (textView, client, highlighter) = makeEditor()
        type(" more *words*", after: "Second paragraph", in: textView)
        assertMatchesFullParse(textView, client)
        withExtendedLifetime(highlighter) {}
    }

    @MainActor
    func test_splittingAndJoiningParagraphs() {
        let (textView, client, highlighter) = makeEditor()
        type("\n\n", after: "First paragraph with", in: textView)
        assertMatchesFullParse(textView, client)
        delete("\n\n *bold*", in: textView)
        assertMatchesFullParse(textView, client)
        withExtendedLifetime(highlighter) {}
    }

    @MainActor
    func test_openingTypstRegionAcrossParagraphs() {
        let (textView, client, highlighter) = makeEditor()
        type("#let f = {", after: "Second paragraph #text(fill: red)[red] here.\n\n", in: textView)
        assertMatchesFullParse(textView, client)
        type("}", after: "#let f = {", in: textView)
        assertMatchesFullParse(textView, client)
        withExtendedLifetime(highlighter) {}
    }

    @MainActor
    func test_changingFenceLanguage() {
        let (textView, client, highlighter) = makeEditor()
        delete("python", in: textView)
        type("swift", after: "```", in: textView)
        assertMatchesFullParse(textView, client)
        withExtendedLifetime(highlighter) {}
    }

    @MainActor
    func test_editsBeforeLaterLayersShiftThem() {
        let (textView, client, highlighter) = makeEditor()
        type(" Extended", after: "# Heading", in: textView)
        assertMatchesFullParse(textView, client)
        delete("# Heading Extended\n\n", in: textView)
        assertMatchesFullParse(textView, client)
        withExtendedLifetime(highlighter) {}
    }
}
