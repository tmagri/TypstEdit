import XCTest
@testable import TypstEdit

/// Files an MCP tool hands back are saved, and the model is told where.
/// Every test saves into its own temporary folder, never `~/Downloads`.
@MainActor
final class MCPToolContentTests: XCTestCase {

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPToolContentTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let zipBytes = Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3, 4])

    // MARK: - Parsing

    func testBlocksAreParsedByType() {
        let blocks = MCPToolContent.blocks(in: ["content": [
            ["type": "text", "text": "hello"],
            ["type": "resource_link", "uri": "vpt://gangs/1.zip", "name": "1.zip", "mimeType": "application/zip"],
            ["type": "resource", "resource": ["uri": "file:///a.txt", "text": "inline"]],
            ["type": "image", "data": "AAAA", "mimeType": "image/png"],
        ]])
        XCTAssertEqual(blocks, [
            .text("hello"),
            .link(.init(uri: "vpt://gangs/1.zip", name: "1.zip", mimeType: "application/zip")),
            .embedded(.init(uri: "file:///a.txt", mimeType: nil, text: "inline", blob: nil)),
            .other(type: "image"),
        ])
    }

    func testFileNamePrefersANameWithAnExtension() {
        XCTAssertEqual(MCPDownloads.fileName(name: "Gang 7", uri: "https://x.test/files/7.zip", mimeType: nil), "7.zip")
        XCTAssertEqual(MCPDownloads.fileName(name: "gang.zip", uri: "vpt://x/1", mimeType: nil), "gang.zip")
        XCTAssertEqual(MCPDownloads.fileName(name: nil, uri: "vpt://x/1", mimeType: "application/zip"), "1.zip")
        XCTAssertEqual(MCPDownloads.fileName(name: nil, uri: "", mimeType: nil), "download")
    }

    func testFileNameCannotEscapeTheFolder() {
        XCTAssertEqual(MCPDownloads.sanitize("../../.ssh/authorized_keys"), "_.._.ssh_authorized_keys")
        XCTAssertEqual(MCPDownloads.sanitize(".hidden"), "hidden")
        XCTAssertFalse(MCPDownloads.fileName(name: "a/b\nc.zip", uri: "", mimeType: nil).contains("/"))
    }

    func testSavingNeverOverwrites() throws {
        let downloads = MCPDownloads(folder: folder)
        let first = try downloads.save(Data("1".utf8), name: "gang.zip")
        let second = try downloads.save(Data("2".utf8), name: "gang.zip")
        XCTAssertEqual(first.lastPathComponent, "gang.zip")
        XCTAssertEqual(second.lastPathComponent, "gang 2.zip")
        XCTAssertEqual(try Data(contentsOf: first), Data("1".utf8))
    }

    func testSavedFileIsQuarantined() throws {
        let url = try MCPDownloads(folder: folder).save(zipBytes, name: "gang.zip")
        let values = try url.resourceValues(forKeys: [.quarantinePropertiesKey])
        XCTAssertNotNil(values.quarantineProperties, "a server's file must be checked by Gatekeeper like a browser download")
    }

    // MARK: - End to end through MCPClient

    private func client(headers: [String: String] = [:]) async throws -> MCPClient {
        let config = MCPServerConfig(name: "vpt", transport: .http, url: "https://mcp.example.com/mcp", headers: headers)
        let client = MCPClient(config: config, urlSession: FakeMCPServer.session())
        client.downloads = MCPDownloads(folder: folder)
        try await client.start()
        return client
    }

    /// The server answers `tools/call` with a link, and `resources/read` with
    /// `read` (nil: method not found). GETs are served by `get`.
    private func serve(
        link: [String: Any],
        read: [String: Any]?,
        get: ((FakeMCPServer.Received) -> FakeMCPServer.Reply)? = nil
    ) {
        FakeMCPServer.reset { request in
            if request.method == "GET" {
                return get?(request) ?? .init(status: 404)
            }
            guard let json = request.json else { return .init(status: 400) }
            guard let id = json["id"] else { return .init(status: 202, headers: [:], body: Data()) }
            switch json["method"] as? String {
            case "tools/call":
                return .init(body: FakeMCPServer.json(["jsonrpc": "2.0", "id": id, "result": ["content": [
                    ["type": "text", "text": "Found gang — zipped 2 file(s)."],
                    link,
                ]]]))
            case "resources/read":
                if let read {
                    return .init(body: FakeMCPServer.json(["jsonrpc": "2.0", "id": id, "result": read]))
                }
                return .init(body: FakeMCPServer.json(["jsonrpc": "2.0", "id": id,
                                                       "error": ["code": -32601, "message": "Method not found"]]))
            default:
                return .init(body: FakeMCPServer.json(FakeMCPServer.standardResult(for: json)!))
            }
        }
    }

    func testResourceLinkIsReadThroughMCPAndSaved() async throws {
        serve(
            link: ["type": "resource_link", "uri": "vpt://gangs/723250877", "name": "723250877.zip"],
            read: ["contents": [["uri": "vpt://gangs/723250877", "mimeType": "application/zip",
                                 "blob": zipBytes.base64EncodedString()]]]
        )
        let client = try await client()
        defer { client.stop() }

        let output = try await client.callTool(name: "download_gang", arguments: [:])
        let saved = folder.appendingPathComponent("723250877.zip")
        XCTAssertEqual(try Data(contentsOf: saved), zipBytes)
        XCTAssertTrue(output.contains("Found gang"), output)
        XCTAssertTrue(output.contains("Saved file to \(saved.path)"), output)
        XCTAssertFalse(output.contains("omitted"), output)
    }

    func testWebLinkOnTheServersOwnHostIsDownloadedWithItsCredentials() async throws {
        serve(
            link: ["type": "resource_link", "uri": "https://mcp.example.com/files/gang.zip"],
            read: nil,
            get: { [zipBytes] _ in .init(headers: ["Content-Type": "application/zip"], body: zipBytes) }
        )
        let client = try await client(headers: ["Authorization": "Bearer server-token"])
        defer { client.stop() }

        let output = try await client.callTool(name: "download_gang", arguments: [:])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("gang.zip")), zipBytes, output)
        let get = try XCTUnwrap(FakeMCPServer.received.first { $0.method == "GET" })
        XCTAssertEqual(get.headers["Authorization"], "Bearer server-token")
    }

    func testWebLinkElsewhereIsDownloadedWithoutCredentials() async throws {
        serve(
            link: ["type": "resource_link", "uri": "https://cdn.other.test/gang.zip"],
            read: nil,
            get: { [zipBytes] _ in .init(headers: ["Content-Type": "application/zip"], body: zipBytes) }
        )
        let client = try await client(headers: ["Authorization": "Bearer server-token"])
        defer { client.stop() }

        _ = try await client.callTool(name: "download_gang", arguments: [:])
        let get = try XCTUnwrap(FakeMCPServer.received.first { $0.method == "GET" })
        XCTAssertNil(get.headers["Authorization"], "a server's token must never go to another host")
    }

    func testFailedDownloadSaysSoInsteadOfClaimingSuccess() async throws {
        serve(
            link: ["type": "resource_link", "uri": "https://mcp.example.com/files/gang.zip"],
            read: nil,
            get: { _ in .init(status: 403) }
        )
        let client = try await client()
        defer { client.stop() }

        let output = try await client.callTool(name: "download_gang", arguments: [:])
        XCTAssertTrue(output.contains("Could not download"), output)
        XCTAssertTrue(output.contains("403"), output)
        XCTAssertFalse(output.contains("Saved file"), output)
    }

    func testUnreadableCustomSchemeLinkReportsTheReason() async throws {
        serve(link: ["type": "resource_link", "uri": "vpt://gangs/1"], read: nil)
        let client = try await client()
        defer { client.stop() }

        let output = try await client.callTool(name: "download_gang", arguments: [:])
        XCTAssertTrue(output.contains("Could not read resource vpt://gangs/1"), output)
    }

    /// The JSON DPKVPT sent before its fix: the zip's raw bytes as the `blob`
    /// string (C# SDK 1.x `Blob` expects base64 already), with invalid UTF-8
    /// turned into U+FFFD. It must be reported as the server's bug, never
    /// saved as a corrupt file and never described as "no contents".
    func testRawBytesInsteadOfBase64AreReportedNotSaved() async throws {
        serve(
            link: ["type": "resource_link", "uri": "vpt-artifact://abc", "name": "723263824.zip"],
            read: ["contents": [["uri": "vpt-artifact://abc", "mimeType": "application/zip",
                                 "blob": "PK\u{3}\u{4}\u{FFFD}\u{0}\u{FFFD}\u{FFFD}"]]]
        )
        let client = try await client()
        defer { client.stop() }

        let output = try await client.callTool(name: "download_gang", arguments: [:])
        XCTAssertTrue(output.contains("not valid base64"), output)
        XCTAssertFalse(output.contains("no contents"), output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("723263824.zip").path))
    }

    /// DPKVPT's answer for an expired or already-taken artifact: a text
    /// entry with no MIME type. That is a message, not the zip.
    func testExpiredArtifactMessageIsShownNotSavedAsTheFile() async throws {
        serve(
            link: ["type": "resource_link", "uri": "vpt-artifact://gone", "name": "1.zip"],
            read: ["contents": [["uri": "vpt-artifact://gone",
                                 "text": "That resource is unknown, has expired, or was produced for a different user."]]]
        )
        let client = try await client()
        defer { client.stop() }

        let output = try await client.callTool(name: "download_gang", arguments: [:])
        XCTAssertTrue(output.contains("returned a message instead of a file"), output)
        XCTAssertTrue(output.contains("has expired"), output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("1.zip").path))
    }

    func testBase64WrappedOverLinesIsAccepted() {
        let wrapped = String(zipBytes.base64EncodedString().enumerated().map { $0.offset == 4 ? "\n\($0.element)" : "\($0.element)" }.joined())
        XCTAssertEqual(MCPToolContent.decodeBase64(wrapped), zipBytes)
        XCTAssertNil(MCPToolContent.decodeBase64("PK\u{3}\u{4}\u{FFFD}"))
    }

    func testEmbeddedBlobIsSaved() async throws {
        serve(
            link: ["type": "resource", "resource": ["uri": "vpt://gangs/9.zip", "mimeType": "application/zip",
                                                    "blob": zipBytes.base64EncodedString()]],
            read: nil
        )
        let client = try await client()
        defer { client.stop() }

        let output = try await client.callTool(name: "download_gang", arguments: [:])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("9.zip")), zipBytes, output)
    }
}
