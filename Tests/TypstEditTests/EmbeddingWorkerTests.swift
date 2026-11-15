import XCTest
@testable import TypstEdit

/// The wire format between the app and `typstedit embed-worker`: the spec
/// that carries the model configuration, and the request/reply round-trip
/// through a fake worker.
@MainActor
final class EmbeddingWorkerTests: XCTestCase {
    // MARK: - Spec

    func testSpecRoundTripsAppleProvider() throws {
        let spec = try XCTUnwrap(EmbeddingWorkerSpec(provider: LocalEmbeddingProvider()))
        XCTAssertEqual(spec.kind, .apple)

        let rebuilt = try XCTUnwrap(EmbeddingWorkerSpec.from(spec.json))
        XCTAssertNotNil(rebuilt.makeProvider() as? LocalEmbeddingProvider)
    }

    func testSpecRoundTripsAPIProvider() throws {
        let provider = GenericAPIEmbeddingProvider(
            dimensions: 768,
            endpointURL: URL(string: "http://localhost:11434/v1/embeddings"),
            apiKey: "secret",
            modelName: "nomic-embed-text"
        )
        let spec = try XCTUnwrap(EmbeddingWorkerSpec(provider: provider))
        XCTAssertEqual(spec.kind, .api)

        let json = spec.json
        // The key crosses the process boundary, so it must be there; but
        // it is never persisted or logged anywhere else.
        XCTAssertEqual(json["api_key"] as? String, "secret")

        let rebuilt = try XCTUnwrap(EmbeddingWorkerSpec.from(json))
        let restored = try XCTUnwrap(rebuilt.makeProvider() as? GenericAPIEmbeddingProvider)
        XCTAssertEqual(restored.modelName, "nomic-embed-text")
        XCTAssertEqual(restored.dimensions, 768)
        XCTAssertEqual(restored.apiKey, "secret")
        XCTAssertEqual(restored.endpointURL?.absoluteString, "http://localhost:11434/v1/embeddings")
    }

    func testSpecRejectsMissingEndpointForAPIProvider() throws {
        let provider = GenericAPIEmbeddingProvider(
            dimensions: 768, endpointURL: nil, apiKey: "", modelName: "m"
        )
        let spec = try XCTUnwrap(EmbeddingWorkerSpec(provider: provider))
        // The spec builds, but the worker cannot make a provider without
        // an endpoint.
        XCTAssertNil(spec.makeProvider())
    }

    // MARK: - Cancellation flag

    func testCancellationFlagToggles() {
        let flag = IndexRunCancellation()
        XCTAssertFalse(flag.isCancelled)
        flag.cancel()
        XCTAssertTrue(flag.isCancelled)
    }

    // MARK: - Client (with the process replaced by a fake)

    func testClientRoutesEmbeddingsToTheOverride() async throws {
        let client = EmbeddingWorkerClient()
        let expected: [[Float]?] = [[0.5, 0.5], nil, [1, 0]]
        client.protocolOverride = { texts in
            XCTAssertEqual(texts, ["a", "b", "c"])
            return expected
        }

        let spec = EmbeddingWorkerSpec(kind: .apple)
        let result = await client.embed(texts: ["a", "b", "c"], spec: spec)
        XCTAssertEqual(result ?? [], expected)
    }

    func testClientReturnsEmptyForNoTexts() async throws {
        let client = EmbeddingWorkerClient()
        client.protocolOverride = { _ in [] }
        let spec = EmbeddingWorkerSpec(kind: .apple)
        let result = await client.embed(texts: [], spec: spec)
        XCTAssertEqual(result?.count, 0)
    }
}
