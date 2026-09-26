import XCTest
import os
@testable import notchi

final class ClaudeModelPricingTests: XCTestCase {
    // Named constants = independent expectations (per-MILLION → per-token)
    private let sonnetInput = 3.0 / 1_000_000
    private let sonnetOutput = 15.0 / 1_000_000
    private let sonnetCacheRead = 0.30 / 1_000_000
    private let sonnetCacheWrite = 3.75 / 1_000_000

    private func pricing() -> ClaudeModelPricing {
        ClaudeModelPricing(
            inputPerToken: sonnetInput, outputPerToken: sonnetOutput,
            cacheCreationPerToken: sonnetCacheWrite, cacheReadPerToken: sonnetCacheRead,
            cacheCreation1hPerToken: nil,
            thresholdTokens: 200_000,
            inputPerTokenAboveThreshold: 6.0 / 1_000_000,
            outputPerTokenAboveThreshold: 22.5 / 1_000_000,
            cacheCreationPerTokenAboveThreshold: 7.5 / 1_000_000,
            cacheReadPerTokenAboveThreshold: 0.60 / 1_000_000)
    }

    func testNormalizesProviderPrefixedModelNames() {
        XCTAssertEqual(CostPricing.normalizeClaudeModel("claude-sonnet-4-20250514"), "claude-sonnet-4")
        XCTAssertEqual(CostPricing.normalizeClaudeModel("anthropic/claude-opus-4-1"), "claude-opus-4-1")
    }

    func testCostBelowThresholdSumsEachTokenClass() {
        let cost = CostPricing.claudeCostUSD(
            model: "claude-sonnet-4", input: 1_000, cacheRead: 2_000,
            cacheCreation: 500, cacheCreation1h: 0, output: 800, pricing: pricing())
        let inputCost: Double = 1_000 * sonnetInput
        let readCost: Double = 2_000 * sonnetCacheRead
        let writeCost: Double = 500 * sonnetCacheWrite
        let outputCost: Double = 800 * sonnetOutput
        let expected: Double = inputCost + readCost + writeCost + outputCost
        XCTAssertEqual(cost!, expected, accuracy: 1e-12)
    }

    func testWholeRequestRepricedWhenContextExceedsThreshold() {
        // input context = input + cacheRead + cacheCreation = 250_000 > 200_000 → above-threshold rates apply to ALL classes
        let cost = CostPricing.claudeCostUSD(
            model: "claude-sonnet-4", input: 50_000, cacheRead: 150_000,
            cacheCreation: 50_000, cacheCreation1h: 0, output: 1_000, pricing: pricing())
        let inputCost: Double = 50_000 * (6.0 / 1_000_000)
        let readCost: Double = 150_000 * (0.60 / 1_000_000)
        let writeCost: Double = 50_000 * (7.5 / 1_000_000)
        let outputCost: Double = 1_000 * (22.5 / 1_000_000)
        let expected: Double = inputCost + readCost + writeCost + outputCost
        XCTAssertEqual(cost!, expected, accuracy: 1e-9)
    }

    func testCatalogFallsBackToEmbeddedSnapshotForKnownModel() {
        let catalog = PricingCatalog(fallbackBundle: .main)
        let p = catalog.pricing(model: "claude-sonnet-4-6", on: Date())
        XCTAssertNotNil(p, "embedded fallback must price the current Sonnet model")
        XCTAssertGreaterThan(p!.outputPerToken, p!.inputPerToken)
    }

    func testCatalogReturnsNilForUnknownModel() {
        let catalog = PricingCatalog(fallbackBundle: .main)
        XCTAssertNil(catalog.pricing(model: "totally-made-up-model", on: Date()))
    }

    // MARK: - T1: signature() is deterministic

    func testSignatureIsDeterministicAcrossCallsAndNotSwiftHasher() {
        let catalog = PricingCatalog(fallbackBundle: .main)
        let sig1 = catalog.signature()
        let sig2 = catalog.signature()
        XCTAssertEqual(sig1, sig2)
        XCTAssertFalse(sig1.isEmpty)
    }

    // MARK: - T2: signature() changes when a price changes

    func testSignatureChangesWhenPriceChanges() {
        let p1 = ClaudeModelPricing(inputPerToken: 0.000003, outputPerToken: 0.000015,
            cacheCreationPerToken: 0.00000375, cacheReadPerToken: 0.0000003,
            cacheCreation1hPerToken: nil, thresholdTokens: nil,
            inputPerTokenAboveThreshold: nil, outputPerTokenAboveThreshold: nil,
            cacheCreationPerTokenAboveThreshold: nil, cacheReadPerTokenAboveThreshold: nil)
        let p2 = ClaudeModelPricing(inputPerToken: 0.000006, outputPerToken: 0.000015,
            cacheCreationPerToken: 0.00000375, cacheReadPerToken: 0.0000003,
            cacheCreation1hPerToken: nil, thresholdTokens: nil,
            inputPerTokenAboveThreshold: nil, outputPerTokenAboveThreshold: nil,
            cacheCreationPerTokenAboveThreshold: nil, cacheReadPerTokenAboveThreshold: nil)
        let cat1 = PricingCatalog(table: ["claude-sonnet-4": p1])
        let cat2 = PricingCatalog(table: ["claude-sonnet-4": p2])
        XCTAssertNotEqual(cat1.signature(), cat2.signature())
    }

    func testSignatureToleratesSubUlpFloatDifferences() {
        func mk(_ v: Double) -> ClaudeModelPricing {
            ClaudeModelPricing(inputPerToken: v, outputPerToken: 0.000025,
                cacheCreationPerToken: 0.00000625, cacheReadPerToken: 0.0000005,
                cacheCreation1hPerToken: nil, thresholdTokens: nil,
                inputPerTokenAboveThreshold: nil, outputPerTokenAboveThreshold: nil,
                cacheCreationPerTokenAboveThreshold: nil, cacheReadPerTokenAboveThreshold: nil)
        }
        let base = 5e-6
        let nudged = base.nextUp.nextUp
        XCTAssertNotEqual(base, nudged)
        let a = PricingCatalog(table: ["claude-opus-4-8": mk(base)]).signature()
        let b = PricingCatalog(table: ["claude-opus-4-8": mk(nudged)]).signature()
        XCTAssertEqual(a, b, "sub-12-sig-fig float differences must not change the signature")
    }

    // MARK: - T3: disk snapshot round-trips and overlays fallback

    func testSnapshotPersistsAndOverlaysFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let snapURL = dir.appendingPathComponent("models-dev.json")

        let snapJSON = """
        {"version":1,"models":{"claude-test-9000":{"inputPerToken":0.001,"outputPerToken":0.002,
        "cacheCreationPerToken":0.0015,"cacheReadPerToken":0.0001,
        "thresholdTokens":null,"inputPerTokenAboveThreshold":null,
        "outputPerTokenAboveThreshold":null,"cacheCreationPerTokenAboveThreshold":null,
        "cacheReadPerTokenAboveThreshold":null}}}
        """
        try snapJSON.data(using: .utf8)!.write(to: snapURL)

        let catalog = PricingCatalog(fallbackBundle: .main, snapshotURL: snapURL)
        let p = catalog.pricing(model: "claude-test-9000", on: Date())
        XCTAssertNotNil(p)
        XCTAssertEqual(p!.inputPerToken, 0.001, accuracy: 1e-12)
        XCTAssertNotNil(catalog.pricing(model: "claude-sonnet-4-6", on: Date()))
    }

    // MARK: - T4: cache with stale pricingSignature is reset

    func testCacheWithStalePricingSignatureIsReset() {
        let staleSig = "old-sig"
        let currentSig = "new-sig"
        let cache = CostUsageCache(version: CostUsageCache.currentVersion,
                                    files: ["f": .init(size: 100, mtime: 1, offset: 100)],
                                    buckets: ["2026-06-24": ["m": .init(input: 10, costNanos: 50)]],
                                    pricingSignature: staleSig)

        let reset = cache.reconciled(withPricingSignature: currentSig)
        XCTAssertTrue(reset.files.isEmpty, "stale signature must discard file state")
        XCTAssertTrue(reset.buckets.isEmpty, "stale signature must discard cached costs")
        XCTAssertEqual(reset.pricingSignature, currentSig)

        let kept = cache.reconciled(withPricingSignature: staleSig)
        XCTAssertEqual(kept.files.count, 1, "matching signature must keep the cache")
        XCTAssertEqual(kept.buckets.count, 1)
        XCTAssertEqual(kept.pricingSignature, staleSig)
    }

    private nonisolated static func isOnMainThread() -> Bool { Thread.isMainThread }

    @MainActor
    func testNetworkRefreshFromMainActorRunsOffTheMainThread() async {
        let fetchedOnMainThread = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let catalog = PricingCatalog(fallbackBundle: .main, fetchCatalog: {
            let onMain = Self.isOnMainThread()
            fetchedOnMainThread.withLock { $0 = onMain }
            return nil
        })

        await catalog.refreshFromNetwork()

        XCTAssertEqual(fetchedOnMainThread.withLock { $0 }, false,
                       "decoding the multi-megabyte catalog must not block the main thread")
    }

    func testPlausibilityGuardAcceptsBothAnchorsAndRejectsPartial() {
        let anyPricing = ClaudeModelPricing(
            inputPerToken: sonnetInput, outputPerToken: sonnetOutput,
            cacheCreationPerToken: sonnetCacheWrite, cacheReadPerToken: sonnetCacheRead,
            cacheCreation1hPerToken: nil, thresholdTokens: nil,
            inputPerTokenAboveThreshold: nil, outputPerTokenAboveThreshold: nil,
            cacheCreationPerTokenAboveThreshold: nil, cacheReadPerTokenAboveThreshold: nil)

        // Versioned anchor keys must still pass (prefix match, not exact key).
        let bothAnchors = ["claude-sonnet-4-5": anyPricing, "claude-opus-4-1": anyPricing]
        XCTAssertTrue(PricingCatalog.isPlausibleRefresh(bothAnchors))

        let sonnetOnly = ["claude-sonnet-4": anyPricing]
        XCTAssertFalse(PricingCatalog.isPlausibleRefresh(sonnetOnly))

        XCTAssertFalse(PricingCatalog.isPlausibleRefresh([:]))
    }
}
