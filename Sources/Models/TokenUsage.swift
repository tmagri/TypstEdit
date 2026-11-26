import Foundation

/// One provider response's token accounting, normalized across providers.
///
/// The two wire formats disagree about what the numbers mean, which is why
/// this type exists rather than passing a raw dictionary around:
///
///   * OpenAI-compatible `prompt_tokens` **includes** cached tokens, and
///     `completion_tokens` **includes** reasoning tokens.
///   * Anthropic's `input_tokens` **excludes** cache reads and writes, and
///     `output_tokens` **excludes** thinking budget.
///
/// Normalizing here means the rest of the app can add up "how big was the
/// prompt" without caring which provider answered.
struct TokenUsage: Codable, Equatable {
    /// Uncached input tokens.
    var input: Int = 0
    /// Visible output tokens (reasoning excluded).
    var output: Int = 0
    /// Hidden reasoning tokens, when the provider reports them separately.
    var reasoning: Int = 0
    /// Input tokens served from the provider's prompt cache.
    var cacheRead: Int = 0
    /// Input tokens written to the provider's prompt cache.
    var cacheWrite: Int = 0
    /// What the response cost, in dollars. `nil` means "unknown" — distinct
    /// from a reported zero. A provider-reported figure (OpenRouter sends
    /// `usage.cost`) wins over an estimate, and a **reported zero stays
    /// zero**: a subscription or flat-fee endpoint really charged nothing
    /// for the request, and showing a catalog estimate instead would
    /// describe a plan the user is not on. `isCostEstimated` says which
    /// kind of figure this is, so the interface can show "≈" for one.
    var costUSD: Double?
    /// True when `costUSD` was computed from the saved model's pricing
    /// rather than reported by the provider. A sum is estimated when any
    /// part of it is.
    var isCostEstimated: Bool = false

    /// Every input token the model was sent, cached or not. This is the size
    /// of the prompt.
    var promptTotal: Int { input + cacheRead + cacheWrite }
    /// Every output token, visible or hidden.
    var outputTotal: Int { output + reasoning }
    var total: Int { promptTotal + outputTotal }

    var isEmpty: Bool { promptTotal == 0 && outputTotal == 0 }

    /// True when this response is worth anchoring a context estimate on. A
    /// local server that reports zeros must not reset the anchor to zero.
    var isUsableAsAnchor: Bool { promptTotal > 0 }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.reasoning += rhs.reasoning
        lhs.cacheRead += rhs.cacheRead
        lhs.cacheWrite += rhs.cacheWrite
        if let cost = rhs.costUSD {
            lhs.costUSD = (lhs.costUSD ?? 0) + cost
        }
        lhs.isCostEstimated = lhs.isCostEstimated || rhs.isCostEstimated
    }

    /// Parses an OpenAI-compatible `usage` object.
    static func fromOpenAI(_ usage: [String: Any]?) -> TokenUsage? {
        guard let usage else { return nil }
        let prompt = intValue(usage["prompt_tokens"])
        let completion = intValue(usage["completion_tokens"])
        let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
        let completionDetails = usage["completion_tokens_details"] as? [String: Any]
        let cached = intValue(promptDetails?["cached_tokens"]) ?? intValue(usage["cache_read_input_tokens"])
        let reasoning = intValue(completionDetails?["reasoning_tokens"]) ?? 0

        // `prompt_tokens` includes the cached part; splitting it out is what
        // makes `input` mean the same thing on both providers.
        let cachedPart = min(cached ?? 0, prompt ?? 0)
        var result = TokenUsage(
            input: max(0, (prompt ?? 0) - cachedPart),
            output: max(0, (completion ?? 0) - reasoning),
            reasoning: max(0, reasoning),
            cacheRead: cachedPart,
            cacheWrite: 0,
            costUSD: doubleValue(usage["cost"])
        )
        // Some servers report only one of the two; keep whatever is there so
        // an anchor is still possible.
        if result.isEmpty, let prompt, prompt > 0 {
            result.input = prompt
        }
        return result.isEmpty ? nil : result
    }

    /// Parses an Anthropic `usage` object, where cache reads and writes are
    /// reported beside `input_tokens` rather than inside it.
    static func fromAnthropic(_ usage: [String: Any]?) -> TokenUsage? {
        guard let usage else { return nil }
        let result = TokenUsage(
            input: max(0, intValue(usage["input_tokens"]) ?? 0),
            output: max(0, intValue(usage["output_tokens"]) ?? 0),
            reasoning: 0,
            cacheRead: max(0, intValue(usage["cache_read_input_tokens"]) ?? 0),
            cacheWrite: max(0, intValue(usage["cache_creation_input_tokens"]) ?? 0),
            costUSD: doubleValue(usage["cost"])
        )
        return result.isEmpty ? nil : result
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? Double { return Int(value) }
        if let value = any as? NSNumber { return value.intValue }
        if let value = any as? String { return Int(value) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let value = any as? NSNumber { return value.doubleValue }
        if let value = any as? String { return Double(value) }
        return nil
    }
}

/// What one model costs, per million tokens, in dollars.
///
/// Shaped after OpenCode's catalog pricing
/// (`packages/core/src/session/usage.ts`, rates from models.dev): when an
/// endpoint says nothing about what it charged, the rate list prices the
/// request. TypstEdit keeps the list on the saved model (Settings → Models →
/// Pricing, persisted as `ModelPricing` — see the conversion below) rather
/// than fetching a catalog, so the figure exists offline and the user can
/// correct a stale rate. A rate left unset contributes nothing — OpenCode's
/// `finite()` does the same to a missing rate.
struct TokenPricing: Codable, Equatable, Hashable {
    var inputUSDPerMillion: Double?
    var outputUSDPerMillion: Double?
    var cacheReadUSDPerMillion: Double?
    var cacheWriteUSDPerMillion: Double?

    var isEmpty: Bool {
        inputUSDPerMillion == nil && outputUSDPerMillion == nil
            && cacheReadUSDPerMillion == nil && cacheWriteUSDPerMillion == nil
    }

    /// What `usage` would have cost at these rates, or `nil` when no rate is
    /// set at all. Hidden reasoning is billed at the output rate, matching
    /// the providers' own price pages.
    func cost(for usage: TokenUsage) -> Double? {
        guard !isEmpty else { return nil }
        let perMillion = Double(usage.input) * (inputUSDPerMillion ?? 0)
            + Double(usage.outputTotal) * (outputUSDPerMillion ?? 0)
            + Double(usage.cacheRead) * (cacheReadUSDPerMillion ?? 0)
            + Double(usage.cacheWrite) * (cacheWriteUSDPerMillion ?? 0)
        return perMillion / 1_000_000
    }
}

/// Dollar amounts as every TypstEdit surface writes them.
///
/// One formatter, not a `String(format:)` per call site: a conversation's
/// cost usually sits well under a dollar, where two decimals would show
/// `$0.00` for real money, so the decimal count follows the magnitude.
/// Cached per locale — the Settings line renders this in `body`, and
/// building a `NumberFormatter` on every layout pass is the same trap as
/// re-chunking a transcript inside a menu body.
enum CostFormatter {
    static func usd(_ value: Double, locale: Locale = .current) -> String {
        // A reported zero is a real answer ("this request was covered"),
        // so it reads as money rather than collapsing to "$0".
        let decimals: (min: Int, max: Int)
        switch value {
        case 0: decimals = (2, 2)
        case ..<0.01: decimals = (0, 6)
        case ..<1: decimals = (2, 4)
        default: decimals = (2, 2)
        }
        return formatter(locale: locale, decimals: decimals).string(from: NSNumber(value: value)) ?? "$\(value)"
    }

    private static let lock = NSLock()
    // Guarded by `lock`; `nonisolated(unsafe)` is the compiler's own
    // suggestion for state behind an external lock.
    nonisolated(unsafe) private static var cache: [String: NumberFormatter] = [:]

    private static func formatter(locale: Locale, decimals: (min: Int, max: Int)) -> NumberFormatter {
        let key = "\(locale.identifier)|\(decimals.min)|\(decimals.max)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = locale
        formatter.minimumFractionDigits = decimals.min
        formatter.maximumFractionDigits = decimals.max
        cache[key] = formatter
        return formatter
    }
}

/// Token counts as every TypstEdit surface writes them.
enum TokenLabel {
    /// `0.8k`-style label that never collapses a small non-zero value to `0k`.
    static func text(_ tokens: Int) -> String {
        if tokens < 1_000 {
            return "\(max(0, tokens))"
        }
        let thousands = Double(tokens) / 1_000
        return thousands < 10 ? String(format: "%.1fk", thousands) : "\(Int(thousands.rounded()))k"
    }
}

/// What a saved model charges, in USD per million tokens — the persisted
/// form (Settings → Models → Pricing, stored on `AIModelProfile`).
///
/// Some models bill by the size of the context they were sent — a long-context
/// tier costs more per token than a short one — so the tier is a separate
/// price that applies above a threshold. `tierAboveContextTokens` is that
/// threshold, in *input* tokens.
///
/// Prices are never inferred. They come from a saved model's own settings,
/// because a shipped price table goes stale the moment a provider changes its
/// rates, and a confidently wrong number is worse than no number.
struct ModelPricing: Equatable, Codable, Hashable {
    /// USD per million uncached input tokens.
    var inputPerMillion: Double
    /// USD per million output tokens (reasoning included).
    var outputPerMillion: Double
    /// USD per million tokens read from the prompt cache. Usually much
    /// cheaper than a fresh input token.
    var cacheReadPerMillion: Double = 0
    /// USD per million tokens written to the prompt cache.
    var cacheWritePerMillion: Double = 0
    /// Above this many input tokens a different price applies.
    var tierAboveContextTokens: Int?
    /// The price used once the context is over the tier threshold.
    var tieredInputPerMillion: Double?
    var tieredOutputPerMillion: Double?

    /// USD for one response, using the tier that fits its input size.
    func cost(for usage: TokenUsage) -> Double {
        let overTier = tierAboveContextTokens.map { usage.promptTotal > $0 } ?? false
        let input = overTier ? (tieredInputPerMillion ?? inputPerMillion) : inputPerMillion
        let output = overTier ? (tieredOutputPerMillion ?? outputPerMillion) : outputPerMillion
        return (Double(usage.input) * input
            + Double(usage.output + usage.reasoning) * output
            + Double(usage.cacheRead) * cacheReadPerMillion
            + Double(usage.cacheWrite) * cacheWritePerMillion) / 1_000_000
    }

    /// The flat-rate view the cost estimator consumes. The tier prices are
    /// dropped: `TokenPricing.cost(for:)` prices without a context tier,
    /// which is the right estimate while the request is small and an
    /// underestimate once it is not — the "≈" marker covers the rest.
    var tokenPricing: TokenPricing {
        TokenPricing(
            inputUSDPerMillion: inputPerMillion,
            outputUSDPerMillion: outputPerMillion,
            cacheReadUSDPerMillion: cacheReadPerMillion,
            cacheWriteUSDPerMillion: cacheWritePerMillion
        )
    }
}

/// How big the next request will be, in tokens.
///
/// A character-count estimate (`bytes / 4`) is cheap but can be wrong by a
/// wide margin — a different tokenizer, non-English text, tool schemas, and
/// images all break it. When the provider has told us how big the last
/// request actually was, that number is exact, so it becomes the anchor and
/// only the text added *since* needs estimating. That is what makes the
/// header number and the compaction trigger honest.
struct ContextEstimate: Equatable {
    /// The provider's own count for the last request, when it reported one.
    var measured: Int?
    /// Estimated size of what has been added since that request.
    var estimated: Int

    /// The number to show and to compare against the budget.
    var total: Int { (measured ?? 0) + estimated }

    /// True when the total rests on a real measurement rather than an
    /// extrapolation from character counts alone.
    var isMeasured: Bool { measured != nil }

    /// `true` when the estimate is close enough to the point where a summary
    /// is started in the background, so the swap-in is ready by the time the
    /// next request would overflow.
    func isNearing(_ threshold: Int, ratio: Double = 0.85) -> Bool {
        threshold > 0 && Double(total) >= Double(threshold) * ratio
    }
}
