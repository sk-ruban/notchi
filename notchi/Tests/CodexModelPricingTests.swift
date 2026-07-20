import XCTest
@testable import notchi

final class CodexModelPricingTests: XCTestCase {

    private let gpt55InputPerToken: Double = 5.0 / 1_000_000
    private let gpt55OutputPerToken: Double = 30.0 / 1_000_000
    private let gpt55CacheReadPerToken: Double = 0.5 / 1_000_000
    private let gpt55InputAbove: Double = 10.0 / 1_000_000
    private let gpt55OutputAbove: Double = 45.0 / 1_000_000
    private let gpt55CacheReadAbove: Double = 1.0 / 1_000_000

    private func gpt55Pricing() -> ClaudeModelPricing {
        ClaudeModelPricing(
            inputPerToken: gpt55InputPerToken,
            outputPerToken: gpt55OutputPerToken,
            cacheCreationPerToken: 0,
            cacheReadPerToken: gpt55CacheReadPerToken,
            cacheCreation1hPerToken: nil,
            thresholdTokens: 272_000,
            inputPerTokenAboveThreshold: gpt55InputAbove,
            outputPerTokenAboveThreshold: gpt55OutputAbove,
            cacheCreationPerTokenAboveThreshold: 0,
            cacheReadPerTokenAboveThreshold: gpt55CacheReadAbove)
    }

    func testGpt55CostWithCachedInputBelowThreshold() {
        let inputTokens = 100_000
        let cachedInputTokens = 20_000
        let outputTokens = 5_000

        let billableInput = inputTokens - cachedInputTokens
        let cost = CostPricing.claudeCostUSD(
            model: "gpt-5.5",
            input: billableInput,
            cacheRead: cachedInputTokens,
            cacheCreation: 0,
            cacheCreation1h: 0,
            output: outputTokens,
            pricing: gpt55Pricing())

        let expectedInputCost = Double(billableInput) * gpt55InputPerToken
        let expectedCacheReadCost = Double(cachedInputTokens) * gpt55CacheReadPerToken
        let expectedOutputCost = Double(outputTokens) * gpt55OutputPerToken
        let expected = expectedInputCost + expectedCacheReadCost + expectedOutputCost

        XCTAssertEqual(cost!, expected, accuracy: 1e-12)
    }

    func testGpt55CostAbove272KThresholdUsesAboveRates() {
        let billableInput = 200_000
        let cachedInput = 100_000
        let outputTokens = 2_000

        let cost = CostPricing.claudeCostUSD(
            model: "gpt-5.5",
            input: billableInput,
            cacheRead: cachedInput,
            cacheCreation: 0,
            cacheCreation1h: 0,
            output: outputTokens,
            pricing: gpt55Pricing())

        let expectedInputCost = Double(billableInput) * gpt55InputAbove
        let expectedCacheReadCost = Double(cachedInput) * gpt55CacheReadAbove
        let expectedOutputCost = Double(outputTokens) * gpt55OutputAbove
        let expected = expectedInputCost + expectedCacheReadCost + expectedOutputCost

        XCTAssertEqual(cost!, expected, accuracy: 1e-9)
    }

    func testNormalizeOpenAIModelStripsOpenAIPrefix() {
        XCTAssertEqual(CostPricing.normalizeOpenAIModel("openai/gpt-5.5"), "gpt-5.5")
        XCTAssertEqual(CostPricing.normalizeOpenAIModel("gpt-5.5"), "gpt-5.5")
    }

    func testNormalizeOpenAIModelStripsDateSuffix() {
        XCTAssertEqual(CostPricing.normalizeOpenAIModel("gpt-5.5-2025-04-01"), "gpt-5.5")
        XCTAssertEqual(CostPricing.normalizeOpenAIModel("openai/gpt-5.4-2025-03-15"), "gpt-5.4")
    }

    func testPlausibilityGuardAcceptsGpt5TableAndRejectsClaudeOnly() {
        let anyPricing = ClaudeModelPricing(
            inputPerToken: 5e-6, outputPerToken: 3e-5,
            cacheCreationPerToken: 0, cacheReadPerToken: 5e-7,
            cacheCreation1hPerToken: nil, thresholdTokens: nil,
            inputPerTokenAboveThreshold: nil, outputPerTokenAboveThreshold: nil,
            cacheCreationPerTokenAboveThreshold: nil, cacheReadPerTokenAboveThreshold: nil)

        let gpt5Table = ["gpt-5": anyPricing, "gpt-5.5": anyPricing]
        XCTAssertTrue(PricingCatalog.isPlausibleRefresh(gpt5Table, anchors: ["gpt-5"]))

        let claudeTable = ["claude-sonnet-4": anyPricing, "claude-opus-4": anyPricing]
        XCTAssertFalse(PricingCatalog.isPlausibleRefresh(claudeTable, anchors: ["gpt-5"]))

        XCTAssertFalse(PricingCatalog.isPlausibleRefresh([:], anchors: ["gpt-5"]))
    }

    func testCodexCatalogFallbackLoadsFromBundle() {
        let catalog = PricingCatalog(config: .codex, fallbackBundle: .main)
        let p = catalog.pricing(model: "gpt-5.5", on: Date())
        XCTAssertNotNil(p, "codex fallback must price gpt-5.5")
        XCTAssertEqual(p!.inputPerToken, 5e-6, accuracy: 1e-15)
    }

    func testModelsDevOpenAIBranchDecodesGpt5xPricing() throws {
        let json = """
        {
          "openai": {
            "models": {
              "gpt-5.5": {
                "cost": {
                  "input": 5.0,
                  "output": 30.0,
                  "cache_read": 0.5,
                  "cache_write": 0.0
                }
              }
            }
          }
        }
        """.data(using: .utf8)!

        let catalog = PricingCatalog(config: .codex, fallbackBundle: .main)
        catalog.processNetworkData(json)

        let p = catalog.pricing(model: "gpt-5.5", on: Date())
        XCTAssertNotNil(p)
        XCTAssertEqual(p!.inputPerToken, 5.0 / 1_000_000, accuracy: 1e-15)
        XCTAssertEqual(p!.outputPerToken, 30.0 / 1_000_000, accuracy: 1e-15)
        XCTAssertEqual(p!.cacheReadPerToken, 0.5 / 1_000_000, accuracy: 1e-15)
    }

    func testModelsDevEntryMissingCacheFieldsStillDecodes() {
        let json = """
        {
          "openai": {
            "models": {
              "gpt-5-codex": {
                "cost": { "input": 1.25, "output": 10.0, "cache_read": 0.125 }
              },
              "gpt-5.6-sol": {
                "cost": { "input": 7.0, "output": 42.0 }
              }
            }
          }
        }
        """.data(using: .utf8)!

        let catalog = PricingCatalog(config: .codex, fallbackBundle: .main)
        catalog.processNetworkData(json)

        let codexPricing = catalog.pricing(model: "gpt-5-codex", on: Date())
        XCTAssertEqual(codexPricing?.inputPerToken ?? 0, 1.25 / 1_000_000, accuracy: 1e-15)
        XCTAssertEqual(codexPricing?.cacheReadPerToken ?? -1, 0.125 / 1_000_000, accuracy: 1e-15)
        XCTAssertEqual(codexPricing?.cacheCreationPerToken ?? -1, 0, accuracy: 1e-15)

        let solPricing = catalog.pricing(model: "gpt-5.6-sol", on: Date())
        XCTAssertEqual(solPricing?.inputPerToken ?? 0, 7.0 / 1_000_000, accuracy: 1e-15)
        XCTAssertEqual(solPricing?.outputPerToken ?? 0, 42.0 / 1_000_000, accuracy: 1e-15)
        XCTAssertEqual(solPricing?.cacheReadPerToken ?? -1, 0, accuracy: 1e-15)
        XCTAssertEqual(solPricing?.cacheCreationPerToken ?? -1, 0, accuracy: 1e-15)
    }

    func testMalformedModelEntryDoesNotDiscardOtherModels() {
        let json = """
        {
          "openai": {
            "models": {
              "gpt-broken": {
                "cost": { "input": "not-a-number", "output": 1.0 }
              },
              "gpt-5.6-sol": {
                "cost": { "input": 7.0, "output": 42.0, "cache_read": 0.7, "cache_write": 0.0 }
              }
            }
          }
        }
        """.data(using: .utf8)!

        let catalog = PricingCatalog(config: .codex, fallbackBundle: .main)
        catalog.processNetworkData(json)

        let solPricing = catalog.pricing(model: "gpt-5.6-sol", on: Date())
        XCTAssertEqual(solPricing?.inputPerToken ?? 0, 7.0 / 1_000_000, accuracy: 1e-15)
        XCTAssertNil(catalog.pricing(model: "gpt-broken", on: Date()))
    }

    func testBrokenOpenAIEntriesDoNotBreakAnthropicRefresh() {
        let json = """
        {
          "anthropic": {
            "models": {
              "claude-sonnet-4-5": {
                "cost": { "input": 3.5, "output": 17.5, "cache_read": 0.35, "cache_write": 4.375 }
              },
              "claude-opus-4-6": {
                "cost": { "input": 6.0, "output": 30.0, "cache_read": 0.6, "cache_write": 7.5 }
              }
            }
          },
          "openai": {
            "models": {
              "gpt-5.4": {
                "cost": { "input": 1.25, "output": 10.0, "cache_read": 0.125 }
              }
            }
          }
        }
        """.data(using: .utf8)!

        let catalog = PricingCatalog(config: .claude, fallbackBundle: .main)
        catalog.processNetworkData(json)

        let sonnetPricing = catalog.pricing(model: "claude-sonnet-4-5", on: Date())
        XCTAssertEqual(sonnetPricing?.inputPerToken ?? 0, 3.5 / 1_000_000, accuracy: 1e-15)
        XCTAssertEqual(sonnetPricing?.cacheCreationPerToken ?? 0, 4.375 / 1_000_000, accuracy: 1e-15)
    }

    func testTierMissingCacheFieldsStillDecodesThresholdPricing() {
        let json = """
        {
          "openai": {
            "models": {
              "gpt-5.6-sol": {
                "cost": {
                  "input": 7.0, "output": 42.0, "cache_read": 0.7, "cache_write": 0.0,
                  "tiers": [
                    { "input": 14.0, "output": 84.0, "cache_read": 1.4, "tier": { "type": "context", "size": 272000 } }
                  ]
                }
              }
            }
          }
        }
        """.data(using: .utf8)!

        let catalog = PricingCatalog(config: .codex, fallbackBundle: .main)
        catalog.processNetworkData(json)

        let solPricing = catalog.pricing(model: "gpt-5.6-sol", on: Date())
        XCTAssertEqual(solPricing?.thresholdTokens, 272_000)
        XCTAssertEqual(solPricing?.inputPerTokenAboveThreshold ?? 0, 14.0 / 1_000_000, accuracy: 1e-15)
        XCTAssertEqual(solPricing?.cacheCreationPerTokenAboveThreshold ?? -1, 0, accuracy: 1e-15)
    }

    func testCodexFallbackPricesGpt56Family() {
        let catalog = PricingCatalog(config: .codex, fallbackBundle: .main)

        let sol = catalog.pricing(model: "gpt-5.6-sol", on: Date())
        XCTAssertEqual(sol?.inputPerToken ?? 0, 5e-6, accuracy: 1e-15)
        XCTAssertEqual(sol?.outputPerToken ?? 0, 3e-5, accuracy: 1e-15)
        XCTAssertEqual(sol?.cacheReadPerToken ?? 0, 5e-7, accuracy: 1e-15)
        XCTAssertEqual(sol?.cacheCreationPerToken ?? 0, 6.25e-6, accuracy: 1e-15)
        XCTAssertEqual(sol?.thresholdTokens, 272_000)

        XCTAssertNotNil(catalog.pricing(model: "gpt-5.6", on: Date()))
        XCTAssertNotNil(catalog.pricing(model: "gpt-5.6-luna", on: Date()))
        XCTAssertNotNil(catalog.pricing(model: "gpt-5.6-terra", on: Date()))
    }

    func testCodexGpt55ProCostBillsCachedInputAtInputRate() {
        let catalog = PricingCatalog(config: .codex, fallbackBundle: .main)
        let p = catalog.pricing(model: "gpt-5.5-pro", on: Date())
        XCTAssertNotNil(p, "codex fallback must price gpt-5.5-pro")

        let gpt55ProInputPerToken: Double = 30.0 / 1_000_000
        let gpt55ProOutputPerToken: Double = 180.0 / 1_000_000
        let freshInputTokens = 6_000
        let cachedInputTokens = 4_000
        let outputTokens = 2_000

        let cost = CostPricing.claudeCostUSD(
            model: "gpt-5.5-pro",
            input: freshInputTokens,
            cacheRead: cachedInputTokens,
            cacheCreation: 0,
            cacheCreation1h: 0,
            output: outputTokens,
            pricing: p!)

        let expected = Double(freshInputTokens) * gpt55ProInputPerToken
            + Double(cachedInputTokens) * gpt55ProInputPerToken
            + Double(outputTokens) * gpt55ProOutputPerToken

        XCTAssertEqual(cost!, expected, accuracy: 1e-12)
    }
}
