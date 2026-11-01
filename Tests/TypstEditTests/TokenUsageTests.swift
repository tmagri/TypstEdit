import XCTest
@testable import TypstEdit

/// Provider token accounting, normalized across the two wire formats, plus the
/// measured-anchor estimate that replaces a pure `bytes / 4` guess.
final class TokenUsageTests: XCTestCase {

    // MARK: - OpenAI shape

    func testOpenAIUsageSplitsCachedInputOutOfPromptTokens() {
        // OpenAI's `prompt_tokens` already includes the cached part.
        let usage = TokenUsage.fromOpenAI([
            "prompt_tokens": 1_000,
            "completion_tokens": 200,
            "prompt_tokens_details": ["cached_tokens": 800]
        ])
        XCTAssertEqual(usage?.input, 200)
        XCTAssertEqual(usage?.cacheRead, 800)
        XCTAssertEqual(usage?.output, 200)
        XCTAssertEqual(usage?.reasoning, 0)
        // The prompt is the whole thing, cached or not.
        XCTAssertEqual(usage?.promptTotal, 1_000)
        XCTAssertEqual(usage?.outputTotal, 200)
    }

    func testOpenAIReasoningTokensAreSeparatedFromVisibleOutput() {
        let usage = TokenUsage.fromOpenAI([
            "prompt_tokens": 100,
            "completion_tokens": 500,
            "completion_tokens_details": ["reasoning_tokens": 400]
        ])
        XCTAssertEqual(usage?.output, 100)
        XCTAssertEqual(usage?.reasoning, 400)
        XCTAssertEqual(usage?.outputTotal, 500)
    }

    func testOpenAICachedTokensNeverExceedPromptTokens() {
        // A buggy server reporting more cached than prompt must not produce a
        // negative uncached count.
        let usage = TokenUsage.fromOpenAI([
            "prompt_tokens": 10,
            "completion_tokens": 1,
            "prompt_tokens_details": ["cached_tokens": 999]
        ])
        XCTAssertEqual(usage?.input, 0)
        XCTAssertEqual(usage?.cacheRead, 10)
        XCTAssertEqual(usage?.promptTotal, 10)
    }

    func testOpenAIReportedCostIsKept() {
        let usage = TokenUsage.fromOpenAI(["prompt_tokens": 5, "completion_tokens": 5, "cost": 0.0123])
        XCTAssertEqual(usage?.reportedCostUSD ?? -1, 0.0123, accuracy: 1e-9)
    }

    // MARK: - Anthropic shape

    func testAnthropicUsageCountsCacheFieldsSeparately() {
        // Anthropic's `input_tokens` excludes cache reads and writes.
        let usage = TokenUsage.fromAnthropic([
            "input_tokens": 30,
            "output_tokens": 40,
            "cache_read_input_tokens": 900,
            "cache_creation_input_tokens": 70
        ])
        XCTAssertEqual(usage?.input, 30)
        XCTAssertEqual(usage?.cacheRead, 900)
        XCTAssertEqual(usage?.cacheWrite, 70)
        XCTAssertEqual(usage?.output, 40)
        XCTAssertEqual(usage?.promptTotal, 1_000)
    }

    func testAnthropicWithoutCacheFieldsStillWorks() {
        let usage = TokenUsage.fromAnthropic(["input_tokens": 12, "output_tokens": 3])
        XCTAssertEqual(usage?.promptTotal, 12)
        XCTAssertEqual(usage?.outputTotal, 3)
        XCTAssertEqual(usage?.cacheRead, 0)
        XCTAssertEqual(usage?.cacheWrite, 0)
    }

    // MARK: - Missing or unusable usage

    func testAbsentUsageParsesToNil() {
        XCTAssertNil(TokenUsage.fromOpenAI(nil))
        XCTAssertNil(TokenUsage.fromAnthropic(nil))
    }

    func testAllZeroUsageIsTreatedAsNoReport() {
        // A local server that reports zeros must not become an anchor.
        XCTAssertNil(TokenUsage.fromOpenAI(["prompt_tokens": 0, "completion_tokens": 0]))
        XCTAssertNil(TokenUsage.fromAnthropic(["input_tokens": 0, "output_tokens": 0]))
    }

    func testOutputOnlyUsageIsStillRecorded() {
        // Some servers omit input tokens; the output is still real spend.
        let usage = TokenUsage.fromOpenAI(["completion_tokens": 42])
        XCTAssertEqual(usage?.outputTotal, 42)
        XCTAssertEqual(usage?.promptTotal, 0)
        XCTAssertFalse(usage?.isUsableAsAnchor ?? true)
    }

    // MARK: - Accumulation

    func testAccumulationAddsEveryField() {
        var total = TokenUsage(input: 1, output: 2, reasoning: 3, cacheRead: 4, cacheWrite: 5)
        total += TokenUsage(input: 10, output: 20, reasoning: 30, cacheRead: 40, cacheWrite: 50)
        XCTAssertEqual(total.input, 11)
        XCTAssertEqual(total.output, 22)
        XCTAssertEqual(total.reasoning, 33)
        XCTAssertEqual(total.cacheRead, 44)
        XCTAssertEqual(total.cacheWrite, 55)
    }

    func testAccumulationSumsReportedCostsButStaysNilWhenNoneReported() {
        var total = TokenUsage()
        total += TokenUsage(input: 1)
        XCTAssertNil(total.reportedCostUSD)

        total += TokenUsage(input: 1, reportedCostUSD: 0.5)
        XCTAssertEqual(total.reportedCostUSD ?? -1, 0.5, accuracy: 1e-9)

        total += TokenUsage(input: 1, reportedCostUSD: 0.25)
        XCTAssertEqual(total.reportedCostUSD ?? -1, 0.75, accuracy: 1e-9)
    }

    // MARK: - Pricing

    func testPricingBillsEachBucketAtItsOwnRate() {
        let pricing = ModelPricing(
            inputPerMillion: 3,
            outputPerMillion: 15,
            cacheReadPerMillion: 0.3,
            cacheWritePerMillion: 3.75
        )
        let usage = TokenUsage(
            input: 1_000_000,
            output: 1_000_000,
            reasoning: 0,
            cacheRead: 1_000_000,
            cacheWrite: 1_000_000
        )
        // 3 + 15 + 0.3 + 3.75
        XCTAssertEqual(pricing.cost(for: usage), 22.05, accuracy: 1e-9)
    }

    func testReasoningTokensBillAtTheOutputRate() {
        let pricing = ModelPricing(inputPerMillion: 0, outputPerMillion: 10)
        let usage = TokenUsage(output: 500_000, reasoning: 500_000)
        XCTAssertEqual(pricing.cost(for: usage), 10, accuracy: 1e-9)
    }

    func testTieredPriceAppliesAboveTheThreshold() {
        let pricing = ModelPricing(
            inputPerMillion: 3,
            outputPerMillion: 15,
            tierAboveContextTokens: 200_000,
            tieredInputPerMillion: 6,
            tieredOutputPerMillion: 22.5
        )
        let short = TokenUsage(input: 100_000, output: 100_000)
        let long = TokenUsage(input: 300_000, output: 100_000)

        // Under the tier: 0.3 + 1.5
        XCTAssertEqual(pricing.cost(for: short), 1.8, accuracy: 1e-9)
        // Over the tier, the whole request bills at the higher rate.
        XCTAssertEqual(pricing.cost(for: long), 300_000.0 * 6 / 1e6 + 100_000.0 * 22.5 / 1e6, accuracy: 1e-9)
    }

    func testMissingTierFallsBackToTheBaseRate() {
        let pricing = ModelPricing(inputPerMillion: 3, outputPerMillion: 15, tierAboveContextTokens: 50_000)
        let usage = TokenUsage(input: 100_000, output: 0)
        XCTAssertEqual(pricing.cost(for: usage), 0.3, accuracy: 1e-9)
    }

    // MARK: - Context estimate

    func testEstimateWithoutAMeasurementIsPurelyEstimated() {
        let estimate = ContextEstimate(measured: nil, estimated: 1_234)
        XCTAssertEqual(estimate.total, 1_234)
        XCTAssertFalse(estimate.isMeasured)
    }

    func testEstimateAddsMeasurementAndGrowth() {
        let estimate = ContextEstimate(measured: 8_000, estimated: 500)
        XCTAssertEqual(estimate.total, 8_500)
        XCTAssertTrue(estimate.isMeasured)
    }

    func testNearingThresholdUsesTheConfiguredRatio() {
        let estimate = ContextEstimate(measured: 9_000, estimated: 0)
        XCTAssertTrue(estimate.isNearing(10_000))
        XCTAssertFalse(estimate.isNearing(20_000))
        // A zero threshold is "off", never "always near".
        XCTAssertFalse(estimate.isNearing(0))
    }
}
