import Foundation
import CodeEditLanguages
import UniformTypeIdentifiers

/// The single table that decides how TypstEdit opens a file, and with which
/// tree-sitter grammar it highlights it.
///
/// TypstEdit started as a Typst editor, so several places used to keep their
/// own short list of "extensions we can edit" (file loading, highlighting,
/// the paste pipeline, the AI's semantic index). Those lists drifted apart,
/// which is why a `.py` or `.xml` file could be selected in the sidebar and
/// then never actually load its text. Everything now asks this type instead,
/// so adding a language in one place adds it everywhere.
///
/// Files fall into four groups:
/// - **Typst family** (`.typ`, `.note`) — compiled documents.
/// - **Markdown** (`.md`) — compiled documents.
/// - **Code** — opened as plain text with a tree-sitter grammar.
/// - **Plain text** — opened as plain text, no grammar.
///
/// Anything else (images, PDFs, the calculator's `.tcalc`, unknown binaries)
/// is not editable text and is left to the preview views.
enum EditorFileTypes {

    /// A resolved grammar plus the label shown in the status bar.
    struct Syntax {
        let language: CodeLanguage
        let displayName: String
    }

    /// Stored form: only `Sendable` values, so this can live in static tables
    /// under Swift 6 strict concurrency. The `CodeLanguage` is resolved on
    /// demand from `CodeLanguage.allLanguages`.
    private struct Entry: Sendable {
        /// Raw value of a `TreeSitterLanguage` case.
        let languageID: String
        let displayName: String
    }

    // MARK: - Typst family

    static let typstExtensions: Set<String> = ["typ"]
    static let noteExtensions: Set<String> = ["note"]
    static let markdownExtensions: Set<String> = [
        "md", "markdown", "mkd", "mkdn", "mdwn", "mdown",
    ]

    // MARK: - Code

    /// Extension → grammar. Registers every tree-sitter grammar the app ships
    /// that actually has a highlights query (a grammar without one would parse
    /// but never color anything, so it is not worth claiming).
    private static let codeTable: [String: Entry] = {
        var table: [String: Entry] = [:]

        func add(_ id: String, _ name: String, _ extensions: [String]) {
            let entry = Entry(languageID: id, displayName: name)
            for ext in extensions { table[ext] = entry }
        }

        add("python", "Python", ["py", "pyw", "pyi", "pyx"])
        add("json", "JSON", [
            "json", "jsonc", "json5", "jsonl", "ndjson", "geojson",
            "webmanifest", "ipynb",
        ])
        add("yaml", "YAML", ["yml", "yaml"])
        add("toml", "TOML", ["toml", "ini", "cfg", "conf", "properties"])
        add("html", "HTML", ["html", "htm", "xhtml"])
        // No XML grammar ships with the app. The HTML grammar tokenises tags,
        // attributes, quoted values and `<!-- -->` comments the same way XML
        // does, so it is a faithful highlighter for XML-family files.
        add("html", "XML", [
            "xml", "xsd", "xsl", "xslt", "svg", "rss", "atom",
            "csproj", "vbproj", "fsproj", "nuspec", "kml", "gpx", "rdf", "wsdl",
        ])
        add("css", "CSS", ["css", "scss", "sass", "less"])
        add("javascript", "JavaScript", ["js", "mjs", "cjs"])
        add("jsx", "JSX", ["jsx"])
        add("typescript", "TypeScript", ["ts", "mts", "cts"])
        add("tsx", "TSX", ["tsx"])
        add("bash", "Shell", ["sh", "bash", "zsh", "ksh", "fish"])
        add("c", "C", ["c", "h"])
        add("cpp", "C++", ["cc", "cpp", "cxx", "hpp", "hxx", "c++", "h++"])
        add("objc", "Objective-C", ["m", "mm"])
        add("c_sharp", "C#", ["cs", "csx"])
        add("java", "Java", ["java"])
        add("kotlin", "Kotlin", ["kt", "kts"])
        add("swift", "Swift", ["swift"])
        add("go", "Go", ["go"])
        add("rust", "Rust", ["rs"])
        add("ruby", "Ruby", ["rb", "rake", "gemspec"])
        add("php", "PHP", ["php", "phtml"])
        add("scala", "Scala", ["scala", "sc"])
        add("dart", "Dart", ["dart"])
        add("lua", "Lua", ["lua"])
        add("elixir", "Elixir", ["ex", "exs"])
        add("haskell", "Haskell", ["hs"])
        add("ocaml", "OCaml", ["ml", "mli"])
        add("sql", "SQL", ["sql"])
        add("zig", "Zig", ["zig"])
        add("dockerfile", "Dockerfile", ["dockerfile", "containerfile"])

        return table
    }()

    /// Files recognized by name, because they have no reliable extension.
    private static let fileNameTable: [String: Entry] = [
        "Dockerfile": Entry(languageID: "dockerfile", displayName: "Dockerfile"),
        "Containerfile": Entry(languageID: "dockerfile", displayName: "Dockerfile"),
        "Gemfile": Entry(languageID: "ruby", displayName: "Ruby"),
        "Rakefile": Entry(languageID: "ruby", displayName: "Ruby"),
        "Podfile": Entry(languageID: "ruby", displayName: "Ruby"),
        // Shell startup files, so their comments and variables color in.
        ".zshrc": Entry(languageID: "bash", displayName: "Shell"),
        ".zshenv": Entry(languageID: "bash", displayName: "Shell"),
        ".zprofile": Entry(languageID: "bash", displayName: "Shell"),
        ".zlogin": Entry(languageID: "bash", displayName: "Shell"),
        ".bashrc": Entry(languageID: "bash", displayName: "Shell"),
        ".bash_profile": Entry(languageID: "bash", displayName: "Shell"),
        ".bash_login": Entry(languageID: "bash", displayName: "Shell"),
        ".profile": Entry(languageID: "bash", displayName: "Shell"),
    ]

    // MARK: - Plain text

    /// Text files that open in the editor but have no grammar worth using.
    /// `.tex` and `.bib` are here because the app has no TeX or BibTeX
    /// grammar — they stay editable, just uncolored.
    static let plainTextExtensions: Set<String> = [
        "txt", "text", "log", "csv", "tsv", "bib", "tex", "sty", "cls",
        "rst", "lyx", "env", "nfo",
    ]

    /// Extensionless dotfiles that are still plain text.
    private static let plainTextFileNames: Set<String> = [
        ".gitignore", ".gitattributes", ".gitmodules", ".editorconfig", ".env",
        ".npmrc", ".prettierrc",
    ]

    /// Images the preview pane can show.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "heif", "webp",
    ]

    static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    // MARK: - Queries

    /// True for `.typ` and `.note`.
    static func isTypstFamily(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return typstExtensions.contains(ext) || noteExtensions.contains(ext)
    }

    /// True for Markdown files, which TypstEdit compiles like Typst.
    static func isMarkdownFile(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// The grammar used to highlight `url`, or `nil` when the file has no
    /// grammar (plain text) or is not a text file at all.
    static func syntax(for url: URL) -> Syntax? {
        guard let entry = entry(for: url),
              let languageID = TreeSitterLanguage(rawValue: entry.languageID),
              let language = CodeLanguage.allLanguages.first(where: { $0.id == languageID }) else {
            return nil
        }
        return Syntax(language: language, displayName: entry.displayName)
    }

    private static func entry(for url: URL) -> Entry? {
        if let named = fileNameTable[url.lastPathComponent] { return named }
        return codeTable[url.pathExtension.lowercased()]
    }

    /// True for text files the editor opens without a grammar.
    static func isPlainTextFile(_ url: URL) -> Bool {
        if plainTextFileNames.contains(url.lastPathComponent) { return true }
        return plainTextExtensions.contains(url.pathExtension.lowercased())
    }

    /// True when the file should open in the text editor rather than a
    /// preview. The tables above answer first; only then is LaunchServices
    /// asked, so extensions the system already maps to text (`.log`, `.csv`,
    /// `.conf`, …) keep working without being listed one by one.
    static func isEditableTextFile(_ url: URL) -> Bool {
        if isTypstFamily(url) || isMarkdownFile(url) || isPlainTextFile(url) { return true }
        if entry(for: url) != nil { return true }

        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .text)
            || type.conforms(to: .sourceCode)
            || type.conforms(to: .plainText)
    }

    /// The label shown in the status bar for an editable file, e.g.
    /// "Python", "JSON", "Markdown", "Plain Text".
    static func displayName(for url: URL?) -> String {
        guard let url else { return "Typst" }
        let ext = url.pathExtension.lowercased()
        if typstExtensions.contains(ext) { return "Typst" }
        if noteExtensions.contains(ext) { return "Note" }
        if isMarkdownFile(url) { return "Markdown" }
        if let syntax = syntax(for: url) { return syntax.displayName }
        if isPlainTextFile(url) { return "Plain Text" }
        return ext.isEmpty ? "Text" : ext.uppercased()
    }

    // MARK: - Comment syntax

    /// Line-comment prefix for ⌘/, or `nil` when the language has none.
    ///
    /// The grammar's own `lineCommentString` is used where it is right, but
    /// Markdown and notes are overridden: their grammar claims a footnote
    /// label (`[comment]: #`) as a "comment", which is not what the user
    /// means when they comment out a paragraph.
    static func lineCommentPrefix(for url: URL?) -> String? {
        guard let url else { return "//" }
        if isMarkdownFile(url) || noteExtensions.contains(url.pathExtension.lowercased()) {
            return nil // HTML comment — handled as a block
        }
        if let syntax = syntax(for: url), !syntax.language.lineCommentString.isEmpty {
            return syntax.language.lineCommentString
        }
        // Typst family, and plain text viewed in a Typst-ish window.
        if isTypstFamily(url) { return "//" }
        return isPlainTextFile(url) ? "//" : nil
    }

    /// Block-comment delimiters for the language, or `nil` when it has none.
    static func blockCommentDelimiters(for url: URL?) -> (open: String, close: String)? {
        guard let url else {
            return ("/*", "*/")
        }
        if isMarkdownFile(url) || noteExtensions.contains(url.pathExtension.lowercased()) {
            return ("<!--", "-->")
        }
        if let syntax = syntax(for: url) {
            let strings = syntax.language.rangeCommentStrings
            if !strings.0.isEmpty, !strings.1.isEmpty { return strings }
            return nil
        }
        if isTypstFamily(url) { return ("/*", "*/") }
        return isPlainTextFile(url) ? ("/*", "*/") : nil
    }
}
