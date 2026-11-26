import Foundation

/// The credentials TypstEdit keeps for itself — MCP OAuth tokens and the
/// registered OAuth client per server — in one file only this user can read,
/// instead of the login Keychain.
///
/// **Why not the Keychain.** TypstEdit is ad-hoc signed (`Signature=adhoc`, no
/// team identifier), so macOS identifies a build by its code hash. A Keychain
/// item records which builds may read it, and every rebuild is a hash that is
/// not on that list, so SecurityAgent shows "TypstEdit wants to use your
/// confidential information stored in net.troymagri.clippy.MCP" again.
/// "Always Allow" only adds the hash in front of you; the next build
/// invalidates it. Nothing the app can pin survives a rebuild without a
/// Developer ID, and there is no silent read: the request blocks on that
/// dialog. And because a remote server's token is read on *every request*
/// (`MCPClient.oauthCredentials`), one stale hash became one dialog per tool
/// call rather than one per launch.
///
/// **What protects the file instead.** File permissions: `0600` inside the
/// user's own Application Support folder, so only this account can read it —
/// the boundary `~/.netrc` and `aws/credentials` rely on, with FileVault
/// covering the disk. What is lost is the Keychain's per-app ACL: another
/// process running as this user can read the file. That is the price of never
/// prompting, and it is why the file holds nothing but MCP server tokens.
///
/// **The old Keychain is never read on its own.** Every read there shows a
/// dialog, so `read(key:)` does not fall back to it; a server signed in before
/// this change reads as signed out until the user either clicks **Sign in…**
/// (which stores a fresh token here) or asks for the one-time import with
/// `importLegacy(keys:)`. That keeps "never ask again" true in the literal
/// sense: no dialog appears unless a person chose an action that needs one.
///
/// `${keychain:name}` placeholders are the exception, because the docs tell
/// people they may keep a token in Keychain Access by hand: those still resolve
/// there, at most once per key per launch (see `placeholderValue(for:)`).
final class MCPSecrets: @unchecked Sendable {

    /// The one store the app uses. A test builds its own over a temp file and
    /// a fake legacy reader, so no test ever touches the real Keychain.
    static let shared = MCPSecrets(
        fileURL: defaultFileURL(),
        legacyKeychainRead: MCPKeychain.read(key:),
        legacyKeychainExists: MCPKeychain.exists(key:)
    )

    /// `~/Library/Application Support/TypstEdit/MCPSecrets.json`, beside
    /// `mcp.json` rather than in a folder of its own: one place to look.
    static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TypstEdit/MCPSecrets.json")
    }

    /// Where the file is, abbreviated for UI copy (`~/Library/…`).
    static var displayPath: String {
        let path = defaultFileURL().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private let fileURL: URL
    /// The old Keychain, used only for `${keychain:name}` placeholders and the
    /// import the user asks for. Injectable so tests never prompt.
    private let legacyKeychainRead: (String) -> String?
    /// Whether an item exists in the old Keychain, without reading its secret.
    private let legacyKeychainExists: (String) -> Bool

    private let lock = NSLock()
    /// Decoded once and kept in memory: a token is read on every request, and
    /// this process is the only writer, so the cache can never be stale.
    private var storage: Storage?
    /// `${keychain:name}` answers for *this run only*. Deliberately not
    /// persisted: a person who adds the item to Keychain Access afterwards
    /// should see it picked up on the next start, not be told forever that it
    /// is missing.
    private var placeholderHits: [String: String] = [:]
    private var placeholderMisses: Set<String> = []

    init(
        fileURL: URL,
        legacyKeychainRead: @escaping (String) -> String?,
        legacyKeychainExists: @escaping (String) -> Bool = { _ in false }
    ) {
        self.fileURL = fileURL
        self.legacyKeychainRead = legacyKeychainRead
        self.legacyKeychainExists = legacyKeychainExists
    }

    // MARK: - Storage shape

    private struct Storage: Codable {
        var version = 1
        var secrets: [String: String] = [:]
    }

    // MARK: - The store

    func read(key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().secrets[key]
    }

    func write(key: String, value: String) {
        lock.lock()
        defer { lock.unlock() }
        var storage = loadLocked()
        storage.secrets[key] = value
        placeholderHits[key] = value
        placeholderMisses.remove(key)
        saveLocked(storage)
    }

    func delete(key: String) {
        lock.lock()
        defer { lock.unlock() }
        var storage = loadLocked()
        storage.secrets.removeValue(forKey: key)
        placeholderHits[key] = nil
        placeholderMisses.insert(key)
        saveLocked(storage)
    }

    /// Every key this file currently holds. Settings lists what an import
    /// would add without showing any value.
    func storedKeys() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(loadLocked().secrets.keys)
    }

    // MARK: - One-time import from the old Keychain

    /// What one import attempt did for one key.
    enum ImportOutcome: Equatable, Sendable {
        /// Copied from the Keychain into the file.
        case imported
        /// The Keychain has no such item.
        case notFound
        /// Already in the file: nothing was read, so nothing was asked.
        case alreadyStored
        /// The Keychain refused, or the user dismissed the dialog.
        case refused
    }

    /// Copies the named keys out of the old Keychain, one by one, and returns
    /// what happened to each.
    ///
    /// Only called from an action the user chose, because each missing key
    /// shows a SecurityAgent dialog. A key already in the file is skipped
    /// without asking, so running the import twice asks nothing the second
    /// time.
    func importLegacy(keys: [String]) -> [String: ImportOutcome] {
        var results: [String: ImportOutcome] = [:]
        for key in keys {
            lock.lock()
            let already = loadLocked().secrets[key] != nil
            lock.unlock()
            if already {
                results[key] = .alreadyStored
                continue
            }
            // The read blocks on the dialog: keep the lock out of it, or an
            // MCP request on another thread would wait for the user's answer.
            switch MCPKeychain.probe(
                key: key,
                read: legacyKeychainRead,
                exists: legacyKeychainExists
            ) {
            case .found(let value):
                write(key: key, value: value)
                results[key] = .imported
            case .missing:
                results[key] = .notFound
            case .refused:
                results[key] = .refused
            }
        }
        return results
    }

    // MARK: - `${keychain:name}` placeholders

    /// The value of a `${keychain:name}` placeholder in `mcp.json`.
    ///
    /// The file answers first, so anything TypstEdit saved itself is silent. A key
    /// that is *not* here is looked up in the real Keychain once per launch,
    /// because the docs still tell people they may keep a token there by hand.
    /// That keeps a hand-added token working, and costs at most one dialog per
    /// launch instead of one per request.
    func placeholderValue(for key: String) -> String? {
        lock.lock()
        if let value = loadLocked().secrets[key] {
            lock.unlock()
            return value
        }
        if let hit = placeholderHits[key] {
            lock.unlock()
            return hit
        }
        if placeholderMisses.contains(key) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        // Outside the lock: this may block on macOS's dialog, and a tool call
        // on another thread must not wait behind a person deciding.
        let value = legacyKeychainRead(key)

        lock.lock()
        defer { lock.unlock() }
        if let value {
            placeholderHits[key] = value
        } else {
            placeholderMisses.insert(key)
        }
        return value
    }

    // MARK: - File I/O (call with `lock` held)

    private func loadLocked() -> Storage {
        if let storage { return storage }
        var loaded = Storage()
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
                loaded = decoded
            } else {
                // A hand-edited or truncated file must not cost the user every
                // sign-in on a guess. Keep the bytes beside it, where they can
                // be recovered, and start from empty.
                keepCorruptCopy(data)
            }
        }
        storage = loaded
        return loaded
    }

    private func saveLocked(_ storage: Storage) {
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(storage),
              (try? data.write(to: fileURL, options: .atomic)) != nil else {
            // Leave the cache alone: a write that did not reach the disk must
            // not be reported as stored, or the next read serves a token that
            // is not there after a relaunch.
            return
        }
        // `.atomic` writes a temp file and renames it, so the file lands with
        // the umask's permissions, not 0600. Set them explicitly.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        self.storage = storage
    }

    private func keepCorruptCopy(_ data: Data) {
        let backup = fileURL.appendingPathExtension("corrupt")
        guard (try? data.write(to: backup, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }

    // MARK: - Convenience

    /// The app's store, for call sites that do not need to inject one.
    static func read(key: String) -> String? { shared.read(key: key) }
    static func write(key: String, value: String) { shared.write(key: key, value: value) }
    static func delete(key: String) { shared.delete(key: key) }
    static func placeholderValue(for key: String) -> String? { shared.placeholderValue(for: key) }
    static func storedKeys() -> Set<String> { shared.storedKeys() }
    static func importLegacy(keys: [String]) -> [String: ImportOutcome] { shared.importLegacy(keys: keys) }
}
