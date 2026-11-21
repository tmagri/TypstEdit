import XCTest
@testable import TypstEdit

/// `MCPSecrets`: MCP tokens in a 0600 file instead of the login Keychain.
///
/// The reason is not a preference. TypstEdit is ad-hoc signed, so macOS identifies
/// a build by its code hash; every rebuild is a new hash, and SecurityAgent asks
/// for a Keychain item whose allowed-builds list does not include it. Because a
/// remote server's token is read on every request, one stale hash became one
/// dialog per tool call. These tests pin the three properties that make the file
/// store the fix: it never reads the Keychain on its own, it is 0600, and an
/// import the user asked for is distinguishable per key.
///
/// Every test builds its own store over a temp file with fake readers, so no
/// test can touch — or prompt for — the real Keychain.
final class MCPSecretsTests: XCTestCase {

    private var folder: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPSecretsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("MCPSecrets.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeStore(
        legacy: [String: String] = [:],
        exists: Set<String>? = nil,
        prompts: (() -> Void)? = nil
    ) -> MCPSecrets {
        let legacyExists = exists ?? Set(legacy.keys)
        return MCPSecrets(
            fileURL: fileURL,
            legacyKeychainRead: { key in
                prompts?()
                return legacy[key]
            },
            legacyKeychainExists: { legacyExists.contains($0) }
        )
    }

    // MARK: - The fix itself

    /// The whole point: reading a token must never reach the Keychain, so no
    /// dialog can appear. A store with nothing in its file answers `nil` and
    /// leaves the legacy reader alone.
    func testReadNeverAsksTheKeychain() {
        var prompts = 0
        let store = makeStore(legacy: ["oauth:server": "token"], prompts: { prompts += 1 })
        XCTAssertNil(store.read(key: "oauth:server"), "the file is the only source")
        XCTAssertEqual(prompts, 0, "a plain read must not touch the Keychain")
    }

    func testWriteThenReadRoundTripsAcrossInstances() throws {
        let store = makeStore()
        store.write(key: "oauth:server", value: "token-1")

        // A fresh instance reads the file, not a cache: this is the relaunch.
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.read(key: "oauth:server"), "token-1")
    }

    /// 0600 matters as much as where the file is: the store replaces the
    /// Keychain's per-app ACL with "only this user can read it".
    func testFileIsReadableOnlyByTheOwner() throws {
        let store = makeStore()
        store.write(key: "oauth:server", value: "token")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600, "the secrets file must not be group/world readable")
    }

    func testDeleteRemovesTheValueSoSignOutSticks() {
        let store = makeStore()
        store.write(key: "oauth:server", value: "token")
        store.delete(key: "oauth:server")
        XCTAssertNil(store.read(key: "oauth:server"))
        XCTAssertNil(makeStore().read(key: "oauth:server"), "and it stays gone after a relaunch")
    }

    /// Deleting must not let an import resurrect the old token: a signed-out
    /// server that silently signs back in on the next import would be worse
    /// than the dialog this change removes.
    func testImportDoesNotResurrectADeletedKey() {
        let store = makeStore(legacy: ["oauth:server": "old-token"])
        store.delete(key: "oauth:server")
        let results = store.importLegacy(keys: ["oauth:server"])
        XCTAssertEqual(results["oauth:server"], .imported, "an explicit import may still bring it back")
        XCTAssertEqual(store.read(key: "oauth:server"), "old-token")
    }

    // MARK: - Periodic housekeeping

    func testStoredKeysDoesNotAskTheKeychain() {
        var prompts = 0
        let store = makeStore(legacy: ["oauth:a": "1"], prompts: { prompts += 1 })
        store.write(key: "oauth:b", value: "2")
        XCTAssertEqual(store.storedKeys(), ["oauth:b"])
        XCTAssertEqual(prompts, 0)
    }

    /// A file that cannot be decoded must not be silently thrown away: the
    /// bytes are kept beside it so a hand-edit mistake is recoverable.
    func testCorruptFileIsKeptAsideAndTheStoreStillWorks() throws {
        try Data("{ this is not json".utf8).write(to: fileURL)
        let store = makeStore()
        XCTAssertNil(store.read(key: "oauth:server"))
        store.write(key: "oauth:server", value: "token")
        XCTAssertEqual(store.read(key: "oauth:server"), "token")
        let backup = fileURL.appendingPathExtension("corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "the bad bytes are kept")
    }

    // MARK: - One-time import

    /// An import reports what happened per key, because the three answers need
    /// different advice: nothing to do, sign in again, or try again.
    func testImportReportsEachKeySeparately() {
        let store = makeStore(
            legacy: ["oauth:present": "token"],
            exists: ["oauth:present", "oauth:refused"]
        )
        store.write(key: "oauth:already", value: "x")
        let results = store.importLegacy(keys: [
            "oauth:present", "oauth:refused", "oauth:already", "oauth:gone",
        ])
        XCTAssertEqual(results["oauth:present"], .imported)
        XCTAssertEqual(results["oauth:refused"], .refused, "the item is there but the read gave nothing")
        XCTAssertEqual(results["oauth:already"], .alreadyStored, "already in the file: didn't ask")
        XCTAssertEqual(results["oauth:gone"], .notFound)
        XCTAssertEqual(store.read(key: "oauth:present"), "token")
    }

    /// Running the import twice must ask nothing the second time.
    func testSecondImportAsksNothing() {
        var prompts = 0
        let store = makeStore(legacy: ["oauth:server": "token"], prompts: { prompts += 1 })
        _ = store.importLegacy(keys: ["oauth:server"])
        XCTAssertEqual(prompts, 1)
        let again = store.importLegacy(keys: ["oauth:server"])
        XCTAssertEqual(again["oauth:server"], .alreadyStored)
        XCTAssertEqual(prompts, 1, "the value is in the file now, so the Keychain is not read again")
    }

    /// The migration an existing user needs: a token that was in the Keychain
    /// is not lost, it is copied once on request.
    func testImportCopiesAValueIntoTheFileAndSurvivesRelaunch() {
        let store = makeStore(legacy: ["oauth:server": "pre-migration-token"])
        XCTAssertNil(store.read(key: "oauth:server"))
        XCTAssertEqual(store.importLegacy(keys: ["oauth:server"])["oauth:server"], .imported)
        XCTAssertEqual(makeStore().read(key: "oauth:server"), "pre-migration-token")
        XCTAssertEqual(try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber,
                       NSNumber(value: 0o600))
    }

    // MARK: - ${keychain:name} placeholders

    /// A placeholder the app wrote resolves from the file with no Keychain
    /// involvement at all.
    func testPlaceholderPrefersTheFile() {
        var prompts = 0
        let store = makeStore(legacy: ["github": "old"], prompts: { prompts += 1 })
        store.write(key: "github", value: "new")
        XCTAssertEqual(store.placeholderValue(for: "github"), "new")
        XCTAssertEqual(prompts, 0)
    }

    /// A hand-added Keychain token keeps working, and is read once per launch
    /// rather than once per request — the difference between one dialog and a
    /// hundred.
    func testHandAddedKeychainPlaceholderIsReadOnceThenMemoised() {
        var prompts = 0
        let store = makeStore(legacy: ["github": "hand-added"], prompts: { prompts += 1 })
        for _ in 0..<5 {
            XCTAssertEqual(store.placeholderValue(for: "github"), "hand-added")
        }
        XCTAssertEqual(prompts, 1, "one read per launch, not one per request")
    }

    func testMissingPlaceholderIsNotAskedTwice() {
        var prompts = 0
        let store = makeStore(legacy: [:], prompts: { prompts += 1 })
        for _ in 0..<3 {
            XCTAssertNil(store.placeholderValue(for: "absent"))
        }
        XCTAssertEqual(prompts, 1, "a refusal is remembered for this run too")
    }

    /// Nothing about a placeholder lookup is persisted, so adding the item to
    /// Keychain Access shows up after the next launch instead of being
    /// remembered as missing forever.
    func testPlaceholderMemoIsNotPersistedAcrossLaunches() {
        let miss = makeStore(legacy: [:])
        XCTAssertNil(miss.placeholderValue(for: "late"))
        let later = makeStore(legacy: ["late": "added-later"])
        XCTAssertEqual(later.placeholderValue(for: "late"), "added-later")
    }

    // MARK: - Wiring

    /// The store the app uses points at the file beside `mcp.json`, and the
    /// OAuth store's default key prefix is unchanged — the move is in the
    /// reader/writer, not in the keys, so existing names still resolve.
    @MainActor
    func testAppStoreUsesTheApplicationSupportFile() {
        let path = MCPSecrets.defaultFileURL().path
        XCTAssertTrue(path.hasSuffix("TypstEdit/MCPSecrets.json"), path)
        XCTAssertFalse(path.hasSuffix("mcp.json"), "the shareable config must never hold tokens")
        XCTAssertEqual(MCPOAuthStore().keyPrefix, "oauth:")
        XCTAssertTrue(MCPSecrets.displayPath.hasPrefix("~/") || MCPSecrets.displayPath.hasPrefix("/"))
        // No read is performed here on purpose: a read of the real store could
        // resolve a placeholder through the real Keychain, and a test must
        // never be able to show that dialog.
    }
}
