import XCTest
@testable import notchi

final class CostUsageCacheTests: XCTestCase {
    func testLoadDiscardsCacheWithStaleVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cache.json")
        var stale = CostUsageCache(version: CostUsageCache.currentVersion - 1, files: [:], buckets: [:])
        stale.buckets["2026-06-24"] = ["claude-opus-4": ModelTokenTotals(input: 1)]
        try JSONEncoder().encode(stale).write(to: url)

        let loaded = CostUsageCacheStore.load(url: url)
        XCTAssertEqual(loaded.version, CostUsageCache.currentVersion)
        XCTAssertTrue(loaded.buckets.isEmpty, "stale-version cache must be discarded")
    }

    func testLoadKeepsFileOffsetsFromACacheWrittenBeforeDedupKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cache.json")
        let expectedOffset: Int64 = 4096
        let earlierFormat = """
        {"version":\(CostUsageCache.currentVersion),"buckets":{},\
        "files":{"/tmp/a.jsonl":{"size":4096,"mtime":1,"offset":\(expectedOffset)}}}
        """
        try Data(earlierFormat.utf8).write(to: url)

        let loaded = CostUsageCacheStore.load(url: url)

        XCTAssertEqual(loaded.files["/tmp/a.jsonl"]?.offset, expectedOffset)
    }

    func testDedupKeysKeepTheLastFewDistinctKeysAcrossReads() {
        let state = CostUsageCache.FileState(size: 10, mtime: 1, offset: 10, recentDedupKeys: ["m1|r1", "m2|r2"])
        let newKeys = ["m2|r2", "m2|r2", "m3|r3", "m4|r4", "m5|r5"]
        let expected = ["m2|r2", "m3|r3", "m4|r4", "m5|r5"]

        XCTAssertEqual(state.dedupKeys(afterReadingFrom: 10, adding: newKeys), expected)
    }

    func testDedupKeysDropCarriedKeysWhenAReadRestartsFromTheTop() {
        let state = CostUsageCache.FileState(size: 10, mtime: 1, offset: 10, recentDedupKeys: ["m1|r1"])

        XCTAssertEqual(state.dedupKeys(afterReadingFrom: 0, adding: ["m9|r9"]), ["m9|r9"])
    }

    func testSaveThenLoadRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cache.json")
        var cache = CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:])
        cache.buckets["2026-06-24"] = ["claude-opus-4": ModelTokenTotals(input: 5, output: 7, costNanos: 12)]
        CostUsageCacheStore.save(cache, to: url)
        let loaded = CostUsageCacheStore.load(url: url)
        XCTAssertEqual(loaded.buckets["2026-06-24"]?["claude-opus-4"]?.input, 5)
    }

    func testReconciledDiscardsBucketsWhenTimeZoneChanges() {
        var cache = CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:],
                                   pricingSignature: "sig", timeZoneIdentifier: "Asia/Singapore")
        cache.buckets["2026-10-29"] = ["claude-opus-5-5": ModelTokenTotals(input: 1)]
        cache.files["/tmp/a.jsonl"] = .init(size: 10, mtime: 1, offset: 10)

        let reconciled = cache.reconciled(withPricingSignature: "sig", timeZoneIdentifier: "America/Los_Angeles")

        XCTAssertTrue(reconciled.buckets.isEmpty, "day keys from the old time zone must be rebuilt")
        XCTAssertTrue(reconciled.files.isEmpty, "files must be rescanned from the start")
        XCTAssertEqual(reconciled.timeZoneIdentifier, "America/Los_Angeles")
    }

    func testReconciledKeepsCacheWhenTimeZoneAndPricingMatch() {
        var cache = CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:],
                                   pricingSignature: "sig", timeZoneIdentifier: "America/Los_Angeles")
        cache.buckets["2026-10-28"] = ["claude-opus-5-5": ModelTokenTotals(input: 1)]

        let reconciled = cache.reconciled(withPricingSignature: "sig", timeZoneIdentifier: "America/Los_Angeles")

        XCTAssertEqual(reconciled, cache)
    }
}
