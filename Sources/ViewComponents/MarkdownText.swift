import SwiftUI
import Markdown

/// Renders model-authored markdown as SwiftUI views.
///
/// Foundation's `AttributedString(markdown:)` flattens block boundaries into
/// a single run-on line — headings, lists and paragraphs lose their
/// separation — so the text is parsed with swift-markdown and each block
/// becomes its own view instead. Models emit single newlines as visual line
/// breaks, so a soft break inside a paragraph renders as a real line break.
///
/// Supported: headings, paragraphs, bullet/numbered lists (nested), fenced
/// and indented code blocks, tables, block quotes, thematic breaks, and
/// inline bold/italic/strikethrough/code/links. Unknown nodes fall back to
/// their inline text.
struct MarkdownText: View, Equatable {
    let text: String
    /// Base font for paragraphs and inline content.
    var font: Font = .callout

    var body: some View {
        let document = Document(parsing: text, options: .disableSmartOpts)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(document.children.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: - Blocks

    /// Type-erased because lists and quotes contain nested blocks, which
    /// would make the view's opaque type recursive.
    private func blockView(_ block: any Markup) -> AnyView {
        switch block {
        case let heading as Markdown.Heading:
            AnyView(inline(heading.children).font(headingFont(heading.level)))
        case let paragraph as Markdown.Paragraph:
            AnyView(inline(paragraph.children).font(font))
        case let codeBlock as Markdown.CodeBlock:
            AnyView(codeBlockView(codeBlock.code))
        case let list as Markdown.UnorderedList:
            AnyView(listView(items: list.children.compactMap { $0 as? ListItem }, ordered: false, start: 1))
        case let list as Markdown.OrderedList:
            AnyView(listView(items: list.children.compactMap { $0 as? ListItem }, ordered: true, start: Int(list.startIndex)))
        case let quote as Markdown.BlockQuote:
            AnyView(blockQuoteView(quote))
        case let table as Markdown.Table:
            AnyView(tableView(table))
        case is Markdown.ThematicBreak:
            AnyView(Divider())
        case let html as Markdown.HTMLBlock:
            AnyView(SwiftUI.Text(html.rawHTML)
                .font(.caption)
                .foregroundColor(.secondary))
        default:
            // Unhandled block: render its inline content, if any.
            AnyView(inline(block.children).font(font))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.bold()
        case 2: return .headline.bold()
        default: return .subheadline.bold()
        }
    }

    private func codeBlockView(_ code: String) -> some View {
        SwiftUI.Text(code.trimmingCharacters(in: .newlines))
            .font(.system(size: 12, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(6)
    }

    private func listView(items: [ListItem], ordered: Bool, start: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 6) {
                    SwiftUI.Text(ordered ? "\(start + index)." : "•")
                        .font(font)
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            blockView(child)
                        }
                    }
                }
            }
        }
    }

    private func blockQuoteView(_ quote: Markdown.BlockQuote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(quote.children.enumerated()), id: \.offset) { _, child in
                    blockView(child)
                }
            }
        }
    }

    private func tableView(_ table: Markdown.Table) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(table.head.cells.enumerated()), id: \.offset) { _, cell in
                    inline(cell.children)
                        .font(font.bold())
                        .gridColumnAlignment(.leading)
                }
            }
            ForEach(Array(table.body.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        inline(cell.children)
                            .font(font)
                            .gridColumnAlignment(.leading)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Inline content

    /// Concatenates a run of inline nodes into one `SwiftUI.Text`.
    private func inline(_ content: some Sequence<any Markup>) -> SwiftUI.Text {
        var result = SwiftUI.Text("")
        for node in content {
            result = result + inlineNode(node)
        }
        return result
    }

    private func inlineNode(_ node: any Markup) -> SwiftUI.Text {
        switch node {
        case let text as Markdown.Text:
            return SwiftUI.Text(text.string)
        case is SoftBreak, is LineBreak:
            // Models emit single newlines as visual line breaks; render them
            // as real ones instead of markdown's collapsible soft breaks.
            return SwiftUI.Text("\n")
        case let strong as Strong:
            return inline(strong.children).bold()
        case let emphasis as Emphasis:
            return inline(emphasis.children).italic()
        case let strike as Strikethrough:
            return inline(strike.children).strikethrough()
        case let code as InlineCode:
            return SwiftUI.Text(code.code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.accentColor)
        case let link as Markdown.Link:
            return inline(link.children)
                .foregroundColor(.accentColor)
                .underline()
        case let image as Markdown.Image:
            // No inline image rendering; show the alt text.
            return inline(image.children).italic().foregroundColor(.secondary)
        case let html as InlineHTML:
            return SwiftUI.Text(html.rawHTML).foregroundColor(.secondary)
        default:
            // Unknown inline node: render its children's plain text.
            return inline(node.children)
        }
    }
}
