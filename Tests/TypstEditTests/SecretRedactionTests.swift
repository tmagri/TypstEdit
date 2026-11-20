import XCTest
@testable import TypstEdit

final class SecretRedactionTests: XCTestCase {

    // Built at runtime, like SafetyMonitorTests, so this file is not itself
    // a credential-shaped fixture.
    private var openAIKey: String { "sk-proj-" + String(repeating: "a1B2c3D4", count: 4) }
    private var anthropicKey: String { "sk-ant-" + String(repeating: "Zz09", count: 8) }
    private var githubToken: String { "ghp_" + String(repeating: "Ab12", count: 8) }

    func testPlainMessageNeedsNoReview() {
        XCTAssertNil(SecretRedaction(scanning: "Summarize the meeting notes and the token budget."))
        XCTAssertNil(SecretRedaction(scanning: ""))
    }

    func testKeyIsReplacedAndTheRestIsUntouched() throws {
        let message = "Why does \(openAIKey) fail with a 401?"
        let redaction = try XCTUnwrap(SecretRedaction(scanning: message))
        XCTAssertEqual(redaction.findings.map(\.kind), [.openAI])
        XCTAssertEqual(redaction.text(),
                       "Why does [REDACTED OpenAI-style API key] fail with a 401?")
        XCTAssertFalse(redaction.text().contains(openAIKey))
    }

    func testKeepingAFindingSendsItAsWritten() throws {
        let message = "a \(openAIKey) b \(githubToken) c"
        let redaction = try XCTUnwrap(SecretRedaction(scanning: message))
        XCTAssertEqual(redaction.findings.count, 2)
        XCTAssertEqual(redaction.text(keeping: [0, 1]), message)
        let partly = redaction.text(keeping: [1])
        XCTAssertFalse(partly.contains(openAIKey))
        XCTAssertTrue(partly.contains(githubToken))
    }

    func testDeltaNeverShowsTheWholeSecret() throws {
        let redaction = try XCTUnwrap(SecretRedaction(scanning: "key \(openAIKey)"))
        for segment in redaction.segments() {
            if case .replaced(_, let masked, _) = segment {
                XCTAssertFalse(masked.contains(openAIKey))
                XCTAssertTrue(masked.hasSuffix("…"))
            }
            if case .unchanged(let text) = segment {
                XCTAssertFalse(text.contains(openAIKey))
            }
        }
    }

    func testAnthropicKeyIsNamedAsAnthropicNotOpenAI() throws {
        let redaction = try XCTUnwrap(SecretRedaction(scanning: "use \(anthropicKey) please"))
        XCTAssertEqual(redaction.findings.map(\.kind), [.anthropic])
    }

    func testAssignmentKeepsItsNameAndRedactsOnlyTheValue() throws {
        let redaction = try XCTUnwrap(SecretRedaction(scanning: #"password = "Hunter2Hunter2Hunter2""#))
        XCTAssertEqual(redaction.text(), #"password = "[REDACTED assigned secret value]""#)
    }

    func testBearerHeaderKeepsTheHeader() throws {
        let token = String(repeating: "Qw3r", count: 6)
        let redaction = try XCTUnwrap(SecretRedaction(scanning: "Authorization: Bearer \(token)"))
        XCTAssertEqual(redaction.text(), "Authorization: Bearer [REDACTED bearer token]")
    }

    func testURLPasswordOnlyHidesThePassword() throws {
        let redaction = try XCTUnwrap(SecretRedaction(scanning: "postgres://admin:s3cret@db.internal/app"))
        XCTAssertEqual(redaction.text(),
                       "postgres://admin:[REDACTED URL with an embedded password]@db.internal/app")
    }

    func testPrivateKeyBlockIsRemovedWhole() throws {
        let body = String(repeating: "b3BlbnNzaC1rZXktdjEAAAAABG5vbmU", count: 2)
        let message = """
        my key:
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(body)
        \(body)
        -----END OPENSSH PRIVATE KEY-----
        thanks
        """
        let redaction = try XCTUnwrap(SecretRedaction(scanning: message))
        let sent = redaction.text()
        XCTAssertFalse(sent.contains(body), sent)
        XCTAssertFalse(sent.contains("END OPENSSH"), sent)
        XCTAssertEqual(sent, "my key:\n[REDACTED private key block]\nthanks")
    }

    func testPrivateKeyWithoutFooterStopsAtProse() throws {
        let body = String(repeating: "MIIEvQIBADANBgkqhkiG9w0BAQEF", count: 2)
        let message = "-----BEGIN PRIVATE KEY-----\n\(body)\n\(body)\nwhy is this failing?"
        let redaction = try XCTUnwrap(SecretRedaction(scanning: message))
        XCTAssertEqual(redaction.text(), "[REDACTED private key block]\nwhy is this failing?")
    }

    func testRedactedTextDoesNotFlagAgain() throws {
        let message = "a \(openAIKey) and password: Hunter2Hunter2Hunter2"
        let redaction = try XCTUnwrap(SecretRedaction(scanning: message))
        XCTAssertNil(SecretRedaction(scanning: redaction.text()))
    }

    func testPlaceholdersAreNotRedacted() {
        XCTAssertNil(SecretRedaction(scanning: "OPENAI_API_KEY=your-key-here\ntoken = \"<token>\""))
    }

    func testSecretsBeyondTheMatchScanLimitAreStillFound() throws {
        let padding = String(repeating: "word ", count: CredentialScanner.scanCharacterLimit / 5 + 10)
        let redaction = try XCTUnwrap(SecretRedaction(scanning: padding + openAIKey))
        XCTAssertFalse(redaction.text().contains(openAIKey))
    }
}
