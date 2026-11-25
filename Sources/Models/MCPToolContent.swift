import CoreServices
import Foundation
import UniformTypeIdentifiers

/// The content blocks of an MCP `tools/call` result, and what the model is
/// told about each one.
///
/// Only `text` used to survive: every other block became "[resource_link
/// content omitted]". A tool that answered "zipped 2 files" with a link to
/// the zip then looked like a success with nothing behind it, and the model
/// told the user the file was "in your downloads" when nothing was saved.
/// A file a tool hands back is now actually saved (see `MCPDownloads`), and
/// the model receives the path, so what it says matches what is on disk.
enum MCPToolContent {

    /// One resource's contents: `resource.{uri, mimeType, text | blob}` in a
    /// tool result, or one entry of a `resources/read` reply.
    struct Contents: Equatable {
        let uri: String
        let mimeType: String?
        let text: String?
        let blob: Data?
        /// A `blob` was sent but is not base64. Kept apart from "no blob", so
        /// the model is told the server's encoding is wrong instead of that
        /// the server sent nothing — the two need different fixes.
        let blobIsInvalid: Bool

        init(uri: String, mimeType: String?, text: String?, blob: Data?, blobIsInvalid: Bool = false) {
            self.uri = uri
            self.mimeType = mimeType
            self.text = text
            self.blob = blob
            self.blobIsInvalid = blobIsInvalid
        }

        init?(_ object: [String: Any]) {
            let uri = object["uri"] as? String ?? ""
            let text = object["text"] as? String
            let rawBlob = object["blob"] as? String
            let blob = rawBlob.flatMap(MCPToolContent.decodeBase64)
            guard text != nil || rawBlob != nil else { return nil }
            self.init(uri: uri, mimeType: object["mimeType"] as? String, text: text, blob: blob,
                      blobIsInvalid: rawBlob != nil && blob == nil)
        }
    }

    /// Strict base64, tolerating only line breaks and spaces (some servers
    /// wrap at 76 columns). `.ignoreUnknownCharacters` is not used: it turns
    /// a server that sent raw bytes instead of base64 into a silently
    /// corrupt file rather than an error. DPKVPT did exactly that, by
    /// assigning raw bytes to the C# SDK's already-base64 `Blob`.
    static func decodeBase64(_ string: String) -> Data? {
        let compact = string.filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return nil }
        return Data(base64Encoded: compact)
    }

    static func invalidBlobLine(_ uri: String) -> String {
        "[Could not save \(uri): the server sent a blob that is not valid base64. MCP requires base64 for binary contents, so this is a bug in the server — the file cannot be recovered from this reply.]"
    }

    /// A `resource_link`: a pointer the client must fetch itself.
    struct Link: Equatable {
        let uri: String
        let name: String?
        let mimeType: String?
    }

    enum Block: Equatable {
        case text(String)
        case embedded(Contents)
        case link(Link)
        /// A block TypstEdit does not unpack (image, audio, or a future type).
        case other(type: String)
    }

    static func blocks(in result: [String: Any]) -> [Block] {
        guard let content = result["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { block in
            guard let type = block["type"] as? String else { return nil }
            switch type {
            case "text":
                return (block["text"] as? String).map(Block.text)
            case "resource":
                guard let resource = block["resource"] as? [String: Any],
                      let contents = Contents(resource) else { return .other(type: type) }
                return .embedded(contents)
            case "resource_link":
                guard let uri = block["uri"] as? String, !uri.isEmpty else { return .other(type: type) }
                return .link(Link(uri: uri, name: block["name"] as? String, mimeType: block["mimeType"] as? String))
            default:
                return .other(type: type)
            }
        }
    }

    /// The entries of a `resources/read` reply.
    static func contents(inReadResult result: [String: Any]) -> [Contents] {
        (result["contents"] as? [[String: Any]] ?? []).compactMap(Contents.init)
    }

    /// Embedded text up to this size is shown to the model inline; longer
    /// text is saved like a blob, so a whole log never floods the context.
    static let inlineTextLimit = 20_000

    /// Text for blocks that need no fetching. Used for an error result,
    /// where nothing is saved, and in tests.
    static func describe(_ block: Block) -> String {
        switch block {
        case .text(let text):
            return text
        case .embedded(let contents):
            if let text = contents.text { return text }
            return "[embedded file \(contents.uri) not saved]"
        case .link(let link):
            return "[resource link \(link.name ?? link.uri): \(link.uri) — not downloaded]"
        case .other(let type):
            return "[\(type) content omitted]"
        }
    }

    /// The model's line for a saved file. Says plainly where it is, so the
    /// reply can point the user at the real path.
    static func savedLine(_ url: URL, bytes: Int, from uri: String) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "[Saved file to \(url.path) (\(size)) from \(uri)]"
    }
}

/// Saves the files MCP tools return, into the user's Downloads folder.
///
/// Three rules, because a tool's server decides the name and the bytes:
/// the name is reduced to one safe path component, nothing is ever
/// overwritten (`report.zip` becomes `report 2.zip`), and each file is
/// quarantined like a browser download, so Gatekeeper still checks an app
/// or script a server sent before it can be opened.
struct MCPDownloads {
    let folder: URL

    /// `~/Downloads`. The app is not sandboxed, so this is the real folder.
    static var defaultFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    init(folder: URL = MCPDownloads.defaultFolder) {
        self.folder = folder
    }

    /// The file name to use for a resource: the link's own name when it has
    /// an extension, else the URI's last path component, else "download";
    /// with an extension from the MIME type when it still has none.
    static func fileName(name: String?, uri: String, mimeType: String?) -> String {
        var candidates: [String] = []
        if let name { candidates.append(name) }
        if let url = URL(string: uri) {
            candidates.append(url.lastPathComponent)
        }
        candidates.append((uri as NSString).lastPathComponent)

        let cleaned = candidates.map(sanitize).filter { !$0.isEmpty }
        var chosen = cleaned.first { !($0 as NSString).pathExtension.isEmpty } ?? cleaned.first ?? "download"

        if (chosen as NSString).pathExtension.isEmpty,
           let mimeType,
           let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension {
            chosen += ".\(ext)"
        }
        return chosen
    }

    /// One path component, never hidden, never a traversal.
    static func sanitize(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters).union(.newlines)
        var name = raw.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 200 { name = String(name.suffix(200)) }
        return name
    }

    /// The first `name`, `name 2`, `name 3`… not already in the folder.
    func uniqueURL(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }

    func save(_ data: Data, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(for: name)
        try data.write(to: url, options: .withoutOverwriting)
        quarantine(url)
        return url
    }

    /// Moves a downloaded temporary file into place.
    func adopt(_ temporary: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(for: name)
        try FileManager.default.moveItem(at: temporary, to: url)
        quarantine(url)
        return url
    }

    private func quarantine(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload,
            kLSQuarantineAgentNameKey as String: "TypstEdit",
        ]
        try? target.setResourceValues(values)
    }
}
