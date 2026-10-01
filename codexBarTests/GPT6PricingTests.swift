import XCTest

final class GPT6PricingTests: XCTestCase {
    func testRequestThresholdAndSpeedModesForAllThreeModels() {
        let short = SessionLogStore.Usage(inputTokens: 272_000, cachedInputTokens: 20_000, outputTokens: 10_000, cacheWriteTokens: 10_000)
        let long = SessionLogStore.Usage(inputTokens: 272_001, cachedInputTokens: 20_000, outputTokens: 10_000, cacheWriteTokens: 10_000)
        let expected = [
            ("gpt-6.1-sol", 0.611, 1.172004),
            ("gpt-6-sol", 0.613, 1.176004),
            ("gpt-6-luna", 0.03065, 0.0588002),
        ]
        for (model, shortCost, longCost) in expected {
            for (usage, cost) in [(short, shortCost), (long, longCost)] {
                for (tier, multiplier) in [("default", 1.0), ("standard", 1.0), ("fast", 2.0), ("priority", 2.0), ("flex", 0.5), ("batch", 0.5), ("unknown", 1.0)] {
                    XCTAssertEqual(LocalCostPricing.costUSD(
                        model: model, usage: usage, serviceTier: .parse(tier)
                    ), cost * multiplier, accuracy: 1e-12, "\(model)/\(tier)/\(usage.inputTokens)")
                    XCTAssertEqual(LocalCostPricing.costUSD(
                        model: " openai/\(model)-2026-10-01 ", usage: usage, serviceTier: .parse(tier)
                    ), cost * multiplier, accuracy: 1e-12)
                }
            }
        }
        XCTAssertEqual(LocalCostPricing.costUSD(model: "gpt-6.1-sol-preview", usage: short), 0)
    }

    func testClampsCachedInputAndCacheWritesAndSupportsMissingWrites() {
        let overreported = SessionLogStore.Usage(inputTokens: 100, cachedInputTokens: 200, outputTokens: -10, cacheWriteTokens: 999)
        let uncached = SessionLogStore.Usage(inputTokens: 100, cachedInputTokens: 20, outputTokens: 10)
        let expected = [("gpt-6.1-sol", 0.00001, 0.000262), ("gpt-6-sol", 0.00002, 0.000264), ("gpt-6-luna", 0.000001, 0.0000132)]
        for (model, cachedCost, uncachedCost) in expected {
            XCTAssertEqual(LocalCostPricing.costUSD(model: model, usage: overreported), cachedCost, accuracy: 1e-12)
            XCTAssertEqual(LocalCostPricing.costUSD(model: model, usage: uncached), uncachedCost, accuracy: 1e-12)
            XCTAssertEqual(LocalCostPricing.costUSD(model: model, usage: .init(inputTokens: -100, cachedInputTokens: -20, outputTokens: -10, cacheWriteTokens: -5)), 0)
        }
    }

    func testManualOverrideRemainsTheFinalRate() {
        let usage = SessionLogStore.Usage(inputTokens: 272_001, cachedInputTokens: 20_000, outputTokens: 10_000, cacheWriteTokens: 10_000)
        let custom = CodexBarModelPricing(inputUSDPerToken: 1, cachedInputUSDPerToken: 0.5, outputUSDPerToken: 2)
        for model in ["gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna"] {
            XCTAssertEqual(LocalCostPricing.costUSD(
                model: model, usage: usage, serviceTier: .priority,
                customPricingByModel: ["openai/\(model)-2026-10-01": custom]
            ), 282_001, accuracy: 1e-9)
        }
    }
}
