import Foundation

/// Finds credential-shaped values in text: API keys, tokens, private keys,
/// and URLs that carry a password.
///
/// A rule that matches the *file name* `.env` catches an honestly-named `.env`
/// and nothing else — a key pasted straight into a script, or a `.env` renamed
/// `notes.txt`, goes through untouched. The shapes here are what actually
/// identify a secret, ported from the `CREDENTIAL` pattern set in
/// [huggingface/atif-scan](https://github.com/huggingface/atif-scan)
/// (`docs/detectors.md`, `observation.credentials_exposed`), plus the common
/// provider formats that scanner relies on.
///
/// Two rules keep this from becoming noise:
///
/// - **Suppression.** Placeholders (`your-key-here`, `<token>`), already-redacted
///   values (`***`, `[REDACTED]`), and tokenizer artifacts (`Ġ`, `Ċ`, `▁` — a
///   model reasoning about GPT-2's vocabulary emits `token: "ĠWARRANT"`) are not
///   secrets. atif-scan learned the tokenizer case the hard way; it is ported
///   here for the same reason, since a local model discussing tokenizers is a
///   plausible thing for the assistant to do.
/// - **Masking.** The matched value never leaves this type in the clear. A
///   finding carries a masked fragment for the approval card, so flagging a
///   leaked key never becomes a second copy of the leak.
enum CredentialScanner {

    /// What kind of secret a match looks like. Used for the card's wording.
    enum Kind: String, Sendable, CaseIterable {
        case stripeLive
        case openAI
        case anthropic
        case awsAccessKey
        case awsSecretName
        case github
        case slack
        case google
        case huggingFace
        case privateKeyBlock
        case urlWithPassword
        case bearerToken
        case jwt
        case assignedSecret

        var displayName: String {
            switch self {
            case .stripeLive: return "Stripe live key"
            case .openAI: return "OpenAI-style API key"
            case .anthropic: return "Anthropic API key"
            case .awsAccessKey: return "AWS access key ID"
            case .awsSecretName: return "AWS secret access key reference"
            case .github: return "GitHub token"
            case .slack: return "Slack token"
            case .google: return "Google API key"
            case .huggingFace: return "Hugging Face token"
            case .privateKeyBlock: return "private key block"
            case .urlWithPassword: return "URL with an embedded password"
            case .bearerToken: return "bearer token"
            case .jwt: return "JWT"
            case .assignedSecret: return "assigned secret value"
            }
        }
    }

    /// One credential-shaped value found in some text.
    struct Match: Sendable, Equatable {
        let kind: Kind
        /// First few characters plus an ellipsis. Never the whole secret.
        let masked: String

        /// How the approval card names it: "OpenAI-style API key (sk-proj…)".
        var description: String { "\(kind.displayName) (\(masked))" }
    }

    // MARK: - Patterns

    /// One provider-shaped pattern. Separate from `Kind` so a kind can have
    /// more than one spelling (GitHub alone has two). The patterns are
    /// compile-time constants with tests that compile every one, so a failure
    /// here is a programmer error, not a runtime condition.
    private struct Pattern {
        let kind: Kind
        let regex: NSRegularExpression

        init(_ kind: Kind, _ pattern: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                preconditionFailure("bad credential pattern: \(pattern)")
            }
            self.kind = kind
            self.regex = regex
        }
    }

    /// The shapes worth flagging. Deliberately conservative: a pattern that
    /// matches ordinary prose would make `safe` mode unusable, and a mode
    /// people turn off protects nothing.
    private static let patterns: [Pattern] = [
        // Provider-prefixed keys, the highest-confidence shapes.
        Pattern(.stripeLive, #"\bsk_live_[0-9a-zA-Z]{8,}"#),
        Pattern(.openAI, #"\bsk-(?:proj-)?[0-9a-zA-Z_-]{20,}"#),
        Pattern(.anthropic, #"\bsk-ant-[0-9a-zA-Z_-]{20,}"#),
        Pattern(.awsAccessKey, #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        Pattern(.github, #"\b(?:ghp|gho|ghu|ghs|ghr)_[0-9A-Za-z]{20,}\b"#),
        Pattern(.github, #"\bgithub_pat_[0-9A-Za-z_]{20,}\b"#),
        Pattern(.slack, #"\bxox[baprs]-[0-9A-Za-z-]{10,}\b"#),
        Pattern(.google, #"\bAIza[0-9A-Za-z_-]{35}\b"#),
        Pattern(.huggingFace, #"\bhf_[0-9A-Za-z]{20,}\b"#),
        Pattern(.jwt, #"\beyJ[0-9A-Za-z_-]{10,}\.[0-9A-Za-z_-]{10,}\.[0-9A-Za-z_-]{10,}"#),

        // A whole private key in the text.
        Pattern(.privateKeyBlock, #"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----"#),

        // A URL that carries a password: scheme://user:pass@host
        Pattern(.urlWithPassword, #"\b[a-z][a-z0-9+.-]*://[^\s/:@'\"]+:[^\s/@'\"]+@"#),

        // A bearer token, which has no provider prefix to recognise.
        Pattern(.bearerToken, #"(?i)\bauthorization\s*:\s*bearer\s+[A-Za-z0-9._~+/=-]{16,}"#),

        // A secret named in an assignment. The weakest shape, so it needs a
        // value that looks like a key rather than a word.
        Pattern(.assignedSecret,
                #"(?i)\b(?:api[_-]?key|secret|token|password|passwd|access[_-]?key)\b\s*[:=]\s*['"]?[A-Za-z0-9_\-]{16,}"#),
    ]

    /// Names that mention a secret without being one.
    private static let awsSecretNameMention = try! NSRegularExpression(
        pattern: #"\baws_secret_access_key\b"#, options: [.caseInsensitive]
    )

    // MARK: - Suppression

    /// Words that mean "this is a placeholder, not a secret". Matched as whole
    /// words, not substrings: the canonical AWS documentation key is
    /// `AKIAIOSFODNN7EXAMPLE`, and a substring check on `example` would throw
    /// away every real detection of that shape.
    private static let placeholderWords = try! NSRegularExpression(
        pattern: #"\b(?:example|placeholder|dummy|fake|sample|redacted|changeme|replace)\b"#,
        options: [.caseInsensitive]
    )

    /// Fragments that mark a value as a placeholder by its shape rather than
    /// its wording: angle brackets, `***`, an ellipsis, or a run of `x`s.
    private static let placeholderFragments = ["<", ">", "***", "...", "…"]
    private static let placeholderPrefixes = ["your-", "your_", "your"]

    /// Byte-level BPE and SentencePiece markers. A model reasoning about a
    /// tokenizer emits things like `token: "ĠWARRANT"`; atif-scan added this
    /// exclusion after those matched as credentials.
    private static let tokenizerMarkers: [Character] = ["Ġ", "Ċ", "▁"]

    /// Structural names that use secret vocabulary without holding a secret.
    private static let benignNames = [
        "primary_key", "sort_key", "foreign_key", "partition_key", "public_key",
    ]

    /// Whether `candidate` is a real secret rather than a placeholder or a
    /// tokenizer artifact.
    static func isSuppressed(_ candidate: String) -> Bool {
        let lowered = candidate.lowercased()
        if placeholderFragments.contains(where: { candidate.contains($0) }) { return true }
        if placeholderPrefixes.contains(where: { lowered.hasPrefix($0) }) { return true }
        if candidate.contains(where: { tokenizerMarkers.contains($0) }) { return true }
        if benignNames.contains(where: { lowered.contains($0) }) { return true }

        // A long run of the same filler character: `xxxx…`, `AAAA…`.
        if lowered.range(of: #"(.)\1{5,}"#, options: .regularExpression) != nil { return true }

        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        if placeholderWords.firstMatch(in: candidate, options: [], range: range) != nil {
            return true
        }
        return false
    }

    // MARK: - Scanning

    /// The most text any single call is scanned over. A `read_file` can return
    /// thousands of lines, and running fifteen regexes over all of it on every
    /// approval request would be wasteful; a secret near the top is the case
    /// that matters, and the cap is generous enough that a real `.env` fits.
    static let scanCharacterLimit = 200_000

    /// Every credential-shaped value in `text`, deduplicated by masked form.
    static func matches(in text: String) -> [Match] {
        guard !text.isEmpty else { return [] }
        let scanned = text.count > scanCharacterLimit
            ? String(text.prefix(scanCharacterLimit))
            : text
        let range = NSRange(scanned.startIndex..<scanned.endIndex, in: scanned)

        var found: [Match] = []
        var seen = Set<String>()

        for pattern in patterns {
            for hit in pattern.regex.matches(in: scanned, options: [], range: range) {
                guard let matchRange = Range(hit.range, in: scanned) else { continue }
                let value = String(scanned[matchRange])
                guard !isSuppressed(value) else { continue }
                let masked = mask(value)
                guard seen.insert("\(pattern.kind.rawValue):\(masked)").inserted else { continue }
                found.append(Match(kind: pattern.kind, masked: masked))
            }
        }

        // A bare `aws_secret_access_key` mention is a reference to a secret by
        // name, not a value, so it is reported separately and only when no
        // value was already found.
        if found.isEmpty {
            for hit in awsSecretNameMention.matches(in: scanned, options: [], range: range) {
                guard let matchRange = Range(hit.range, in: scanned) else { continue }
                let value = String(scanned[matchRange])
                guard !isSuppressed(value) else { continue }
                found.append(Match(kind: .awsSecretName, masked: mask(value)))
                break
            }
        }

        return found
    }

    /// Whether `text` holds anything credential-shaped.
    static func containsCredential(_ text: String) -> Bool {
        !matches(in: text).isEmpty
    }

    /// Keeps enough to recognise the shape without reproducing the secret.
    /// Eight characters is the same order atif-scan keeps for its evidence.
    static func mask(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else {
            return String(trimmed.prefix(3)) + "…"
        }
        return String(trimmed.prefix(8)) + "…"
    }
}
