import XCTest

final class AstraPricingTests: XCTestCase {
    func testRatesThresholdAndTierStacking() {
        let short = SessionLogStore.Usage(inputTokens: 272000, cachedInputTokens: 20000, outputTokens: 10000, cacheWriteTokens: 10000)
        let long = SessionLogStore.Usage(inputTokens: 272001, cachedInputTokens: 20000, outputTokens: 10000, cacheWriteTokens: 10000)
        let expectedShort = 242000.0 * 10e-6 + 20000 * 1e-6 + 10000 * 12.5e-6 + 10000 * 50e-6
        let expectedLong = 242001.0 * 20e-6 + 20000 * 2e-6 + 10000 * 25e-6 + 10000 * 75e-6
        for (usage, expected) in [(short, expectedShort), (long, expectedLong)] {
            XCTAssertEqual(LocalCostPricing.costUSD(model: "gpt-6-astra", usage: usage, serviceTier: .standard), expected, accuracy: 1e-9)
            XCTAssertEqual(LocalCostPricing.costUSD(model: "openai/gpt-6-astra", usage: usage, serviceTier: .priority), expected * 2, accuracy: 1e-9)
            XCTAssertEqual(LocalCostPricing.costUSD(model: "gpt-6-astra", usage: usage, serviceTier: .flex), expected * 0.5, accuracy: 1e-9)
        }
        XCTAssertEqual(SessionLogStore.ServiceTier.parse("fast"), .priority)
        XCTAssertEqual(SessionLogStore.ServiceTier.parse("default"), .standard)
        XCTAssertEqual(SessionLogStore.ServiceTier.parse("flex"), .flex)
    }
}
