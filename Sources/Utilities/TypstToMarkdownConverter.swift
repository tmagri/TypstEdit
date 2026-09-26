import Foundation

enum MarkdownRegex {
    static let nonBreakingSpace = try! NSRegularExpression(pattern: "(?<=\\w)~(?=\\w)")
    static let labelRef = try! NSRegularExpression(pattern: "@([A-Za-z0-9_:.-]+)")
    static let numberedListStart = try! NSRegularExpression(pattern: "^\\+\\s")
    static let numberedListNewline = try! NSRegularExpression(pattern: "\\n\\+\\s")
    static let consecutiveNewlines = try! NSRegularExpression(pattern: "\\n(?:\\s*\\n){2,}")
}

/// The public entry point used by the app and tests.
///
/// Pipeline: markup parse (TypstParser) → interpret `#`-code (TypstInterpreter) →
/// render (MarkdownRenderer) → regex cleanup. A markup-layer parse failure throws,
/// and `convert` returns the original source unchanged; a failing `#` snippet only
/// leaks its own raw source while the rest of the document converts.
public struct TypstToMarkdownConverter {
    public var fileLoader: ((String) -> String?)?

    public init(fileLoader: ((String) -> String?)? = nil) {
        self.fileLoader = fileLoader
    }

    public static func convert(_ source: String, isAlreadyMarkdown: Bool = false, fileLoader: ((String) -> String?)? = nil) -> String {
        if isAlreadyMarkdown {
            return source
        }

        do {
            return try TypstToMarkdownConverter(fileLoader: fileLoader).convert(source: source)
        } catch {
            return source
        }
    }

    public func convert(source: String) throws -> String {
        let parser = TypstParser(input: source)
        guard case .document(let nodes) = try parser.parse() else {
            throw TypstEvalError("markup parser produced no document")
        }

        let interpreter = TypstInterpreter(environment: TypstEnvironment(), fileLoader: fileLoader)
        var markdown = MarkdownRenderer().render(content: interpreter.evalRoot(nodes))

        // Clean up excessive newlines left by stripped configuration directives.
        markdown = MarkdownRegex.consecutiveNewlines.stringByReplacingMatches(
            in: markdown,
            options: [],
            range: NSRange(0..<markdown.utf16.count),
            withTemplate: "\n\n"
        )

        return markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
