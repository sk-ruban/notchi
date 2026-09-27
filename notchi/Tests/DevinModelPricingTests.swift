import XCTest
@testable import notchi

final class DevinModelPricingTests: XCTestCase {
    private static let sweInputPerToken = 0.5 / 1_000_000
    private static let sweOutputPerToken = 2.5 / 1_000_000
    private static let sweCacheReadPerToken = 0.2 / 1_000_000
    private static let lightningInputPerToken = 2.5 / 1_000_000
    private static let pricedOn = Date(timeIntervalSince1970: 1_790_490_000)

    private func bundledCatalog(fetchCatalog: @escaping @Sendable () async -> Data? = { nil }) -> PricingCatalog {
        PricingCatalog(config: .devin, fallbackBundle: .main, snapshotURL: nil, fetchCatalog: fetchCatalog)
    }

    func testBundledTablePricesSWEModelsAtDevinListRates() throws {
        let pricing = try XCTUnwrap(bundledCatalog().pricing(model: "swe-1-7", on: Self.pricedOn))

        XCTAssertEqual(pricing.inputPerToken, Self.sweInputPerToken, accuracy: 1e-15)
        XCTAssertEqual(pricing.outputPerToken, Self.sweOutputPerToken, accuracy: 1e-15)
        XCTAssertEqual(pricing.cacheReadPerToken, Self.sweCacheReadPerToken, accuracy: 1e-15)
    }

    func testUnlistedVariantUsesLongestListedModelItStartsWith() throws {
        let catalog = bundledCatalog()

        let slow = try XCTUnwrap(catalog.pricing(model: "swe-1-6-slow", on: Self.pricedOn))
        let lightningVariant = try XCTUnwrap(catalog.pricing(model: "swe-1-7-lightning-preview", on: Self.pricedOn))

        XCTAssertEqual(slow.inputPerToken, Self.sweInputPerToken, accuracy: 1e-15)
        XCTAssertEqual(lightningVariant.inputPerToken, Self.lightningInputPerToken, accuracy: 1e-15)
    }

    func testPrefixFallbackRequiresAWholeNameSegment() {
        XCTAssertNil(bundledCatalog().pricing(model: "swe-1-60", on: Self.pricedOn))
    }

    func testUnknownModelStaysUnpriced() {
        XCTAssertNil(bundledCatalog().pricing(model: "mystery-model", on: Self.pricedOn))
    }

    func testDevinCatalogNeverFetchesModelsDev() async {
        let fetches = FetchCounter()
        let catalog = bundledCatalog(fetchCatalog: {
            fetches.increment()
            return nil
        })

        await catalog.refreshFromNetwork()

        XCTAssertEqual(fetches.count, 0)
    }

    func testClaudeCatalogKeepsExactMatchingWithoutPrefixFallback() {
        let catalog = PricingCatalog(config: .claude, fallbackBundle: .main, snapshotURL: nil, fetchCatalog: { nil })

        XCTAssertNil(catalog.pricing(model: "claude-sonnet-4-6-experimental", on: Self.pricedOn))
    }
}

private nonisolated final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
