import Foundation
import XCTest
@testable import notchi

final class DevinCostScannerTests: XCTestCase {
    private static let sweInputPerToken = 0.5 / 1_000_000
    private static let sweOutputPerToken = 2.5 / 1_000_000
    private static let sweCacheReadPerToken = 0.2 / 1_000_000
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private static let now = Date(timeIntervalSince1970: 1_790_496_000)
    private static let todayKey = "2026-09-27"
    private static let replyTime = 1_790_490_000

    private var databaseDirectory: URL?

    override func tearDownWithError() throws {
        if let databaseDirectory {
            try? FileManager.default.removeItem(at: databaseDirectory)
        }
        try super.tearDownWithError()
    }

    func testCountsEachRequestOnceAcrossDuplicateNodes() throws {
        let database = try makeDatabase()
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 100, output: 10, cacheRead: 1_000)
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 100, output: 10, cacheRead: 1_000)

        let cache = makeScanner(database).scan(cache: Self.emptyCache, now: Self.now)

        let totals = try XCTUnwrap(cache.buckets[Self.todayKey]?["swe-1-7"])
        XCTAssertEqual(totals.requestCount, 1)
        XCTAssertEqual(totals.input, 100)
        XCTAssertEqual(totals.output, 10)
        XCTAssertEqual(totals.cacheRead, 1_000)
    }

    func testPricesTokensWithModelRates() throws {
        let database = try makeDatabase()
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 1_000, output: 100, cacheRead: 10_000)
        let expectedCost = 1_000 * Self.sweInputPerToken + 100 * Self.sweOutputPerToken + 10_000 * Self.sweCacheReadPerToken

        let cache = makeScanner(database).scan(cache: Self.emptyCache, now: Self.now)

        let totals = try XCTUnwrap(cache.buckets[Self.todayKey]?["swe-1-7"])
        XCTAssertEqual(totals.costUSD, expectedCost, accuracy: 1e-9)
        XCTAssertEqual(totals.pricedCount, 1)
    }

    func testUnpricedModelKeepsTokensWithoutCost() throws {
        let database = try makeDatabase()
        try insertReply(database, requestId: "request-1", model: "mystery-model", input: 100, output: 10, cacheRead: 0)

        let cache = makeScanner(database).scan(cache: Self.emptyCache, now: Self.now)

        let totals = try XCTUnwrap(cache.buckets[Self.todayKey]?["mystery-model"])
        XCTAssertEqual(totals.totalTokens, 110)
        XCTAssertEqual(totals.costNanos, 0)
        XCTAssertEqual(totals.pricedCount, 0)
    }

    func testRescanAfterNewRepliesCountsEachRequestOnce() throws {
        let database = try makeDatabase()
        let scanner = makeScanner(database)
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 100, output: 10, cacheRead: 0)
        let firstScan = scanner.scan(cache: Self.emptyCache, now: Self.now)

        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 100, output: 10, cacheRead: 0)
        try insertReply(database, requestId: "request-2", model: "swe-1-7", input: 50, output: 5, cacheRead: 0)
        let secondScan = scanner.scan(cache: firstScan, now: Self.now)

        let totals = try XCTUnwrap(secondScan.buckets[Self.todayKey]?["swe-1-7"])
        XCTAssertEqual(totals.requestCount, 2)
        XCTAssertEqual(totals.input, 150)
    }

    func testRewrittenRowOfACountedRequestIsNotCountedAgain() throws {
        let database = try makeDatabase()
        let scanner = makeScanner(database)
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 100, output: 10, cacheRead: 0)
        let firstScan = scanner.scan(cache: Self.emptyCache, now: Self.now)

        try runSQLite(database, "DELETE FROM message_nodes;")
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 100, output: 10, cacheRead: 0)
        let secondScan = scanner.scan(cache: firstScan, now: Self.now)

        let totals = try XCTUnwrap(secondScan.buckets[Self.todayKey]?["swe-1-7"])
        XCTAssertEqual(totals.requestCount, 1)
        XCTAssertEqual(totals.input, 100)
    }

    func testDatesRepliesByWhenTheyWereGeneratedNotWhenTheRowWasWritten() throws {
        let database = try makeDatabase()
        let rowWrittenNextDay = Self.replyTime + 86_400
        try insertReply(
            database, requestId: "request-1", model: "swe-1-7", input: 100, output: 10, cacheRead: 0,
            createdAt: rowWrittenNextDay, replyAt: "2026-09-26T06:20:00.000000Z"
        )
        let dayAfterRowWrite = Date(timeIntervalSince1970: TimeInterval(rowWrittenNextDay))

        let cache = makeScanner(database).scan(cache: Self.emptyCache, now: dayAfterRowWrite)

        XCTAssertEqual(cache.buckets["2026-09-26"]?["swe-1-7"]?.requestCount, 1)
        XCTAssertNil(cache.buckets["2026-09-28"])
    }

    func testMalformedRowDoesNotHideOtherReplies() throws {
        let database = try makeDatabase()
        try runSQLite(database, """
            INSERT INTO message_nodes (session_id, node_id, chat_message, created_at)
            VALUES ('session', 99, '{"role":"assistant","metadata":', \(Self.replyTime));
            """)
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 100, output: 10, cacheRead: 0)

        let cache = makeScanner(database).scan(cache: Self.emptyCache, now: Self.now)

        XCTAssertEqual(cache.buckets[Self.todayKey]?["swe-1-7"]?.requestCount, 1)
    }

    func testUnchangedDatabaseReusesCachedTotals() throws {
        let database = try makeDatabase()
        let scanner = makeScanner(database)
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 100, output: 10, cacheRead: 0)
        var scanned = scanner.scan(cache: Self.emptyCache, now: Self.now)
        let cachedOnly = ModelTokenTotals(input: 7, requestCount: 1)
        scanned.buckets = [Self.todayKey: ["cached-only": cachedOnly]]

        let rescanned = scanner.scan(cache: scanned, now: Self.now)

        XCTAssertEqual(rescanned.buckets[Self.todayKey], ["cached-only": cachedOnly])
    }

    func testIgnoresNonAssistantRowsAndRepliesBeforeTheWindow() throws {
        let database = try makeDatabase()
        try insertRow(database, message: ["role": "user", "content": "hi"], createdAt: Self.replyTime)
        let beforeWindow = Self.replyTime - 40 * 86_400
        try insertReply(database, requestId: "old", model: "swe-1-7", input: 100, output: 10, cacheRead: 0, createdAt: beforeWindow)

        let cache = makeScanner(database).scan(cache: Self.emptyCache, now: Self.now)

        XCTAssertTrue(cache.buckets.isEmpty)
    }

    func testUnreadableDatabaseKeepsPreviousTotalsAndRetriesLater() throws {
        let database = try makeDatabase()
        let scanner = makeScanner(database)
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 100, output: 10, cacheRead: 0)
        let firstScan = scanner.scan(cache: Self.emptyCache, now: Self.now)
        try Data("not a database".utf8).write(to: database)

        let failedScan = scanner.scan(cache: firstScan, now: Self.now)

        XCTAssertEqual(failedScan.buckets, firstScan.buckets)
        XCTAssertEqual(failedScan.files[database.path], firstScan.files[database.path])
    }

    func testDatabaseWithNoRepliesClearsTotals() throws {
        let database = try makeDatabase()
        let scanner = makeScanner(database)
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 100, output: 10, cacheRead: 0)
        let firstScan = scanner.scan(cache: Self.emptyCache, now: Self.now)
        try runSQLite(database, "DELETE FROM message_nodes;")

        let rescanned = scanner.scan(cache: firstScan, now: Self.now)

        XCTAssertTrue(rescanned.buckets.isEmpty)
    }

    func testRequestTotalsComeFromTheLatestSingleCopy() throws {
        let database = try makeDatabase()
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 100, output: 10, cacheRead: 0)
        try insertReply(database, requestId: "request-1", model: "swe-1-7-medium", input: 50, output: 99, cacheRead: 0)

        let cache = makeScanner(database).scan(cache: Self.emptyCache, now: Self.now)

        let day = try XCTUnwrap(cache.buckets[Self.todayKey])
        XCTAssertEqual(day.keys.sorted(), ["swe-1-7-medium"])
        XCTAssertEqual(day["swe-1-7-medium"]?.input, 50)
        XCTAssertEqual(day["swe-1-7-medium"]?.output, 99)
    }

    func testLaterCopyWithTokenMetricsWinsOverAnEarlierCopyWithout() throws {
        let database = try makeDatabase()
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 0, output: 0, cacheRead: 0, includesMetrics: false)
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 100, output: 10, cacheRead: 0)

        let cache = makeScanner(database).scan(cache: Self.emptyCache, now: Self.now)

        let totals = try XCTUnwrap(cache.buckets[Self.todayKey]?["swe-1-7"])
        XCTAssertEqual(totals.input, 100)
        XCTAssertEqual(totals.output, 10)
    }

    func testCopyWithTokenMetricsWinsOverALaterCopyWithout() throws {
        let database = try makeDatabase()
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 100, output: 10, cacheRead: 0)
        try insertReply(database, requestId: "request-1", model: "swe-1-7", input: 0, output: 0, cacheRead: 0, includesMetrics: false)

        let cache = makeScanner(database).scan(cache: Self.emptyCache, now: Self.now)

        let totals = try XCTUnwrap(cache.buckets[Self.todayKey]?["swe-1-7"])
        XCTAssertEqual(totals.input, 100)
        XCTAssertEqual(totals.output, 10)
    }

    func testMissingDatabaseLeavesCacheEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sessions.db")

        let cache = makeScanner(missing).scan(cache: Self.emptyCache, now: Self.now)

        XCTAssertTrue(cache.buckets.isEmpty)
    }

    // MARK: - Helpers

    private static let emptyCache = CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:])

    private struct SWEPricing: ClaudePricingProviding {
        nonisolated func pricing(model: String, on date: Date) -> ClaudeModelPricing? {
            guard model == "swe-1-7" else { return nil }
            return ClaudeModelPricing(
                inputPerToken: DevinCostScannerTests.sweInputPerToken,
                outputPerToken: DevinCostScannerTests.sweOutputPerToken,
                cacheCreationPerToken: 0,
                cacheReadPerToken: DevinCostScannerTests.sweCacheReadPerToken,
                cacheCreation1hPerToken: nil,
                thresholdTokens: nil,
                inputPerTokenAboveThreshold: nil,
                outputPerTokenAboveThreshold: nil,
                cacheCreationPerTokenAboveThreshold: nil,
                cacheReadPerTokenAboveThreshold: nil)
        }
    }

    private func makeScanner(_ database: URL) -> DevinCostScanner {
        DevinCostScanner(databaseURL: database, pricing: SWEPricing(), windowDays: 30, calendar: Self.calendar)
    }

    private func makeDatabase() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseDirectory = directory
        let database = directory.appendingPathComponent("sessions.db")
        try runSQLite(database, """
            CREATE TABLE message_nodes (
              row_id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id TEXT NOT NULL,
              node_id INTEGER NOT NULL,
              parent_node_id INTEGER,
              chat_message TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              metadata TEXT
            );
            """)
        return database
    }

    private func insertReply(
        _ database: URL,
        requestId: String,
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        createdAt: Int = DevinCostScannerTests.replyTime,
        replyAt: String? = nil,
        includesMetrics: Bool = true
    ) throws {
        let generatedAt = replyAt ?? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(createdAt)))
        var metadata: [String: Any] = [
            "request_id": requestId,
            "created_at": generatedAt,
            "generation_model": model,
        ]
        if includesMetrics {
            metadata["metrics"] = [
                "input_tokens": input,
                "output_tokens": output,
                "cache_read_tokens": cacheRead,
                "cache_creation_tokens": NSNull(),
            ]
        }
        try insertRow(database, message: [
            "role": "assistant",
            "message_id": "message-\(requestId)",
            "metadata": metadata,
        ], createdAt: createdAt)
    }

    private func insertRow(_ database: URL, message: [String: Any], createdAt: Int) throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
            .replacingOccurrences(of: "'", with: "''")
        try runSQLite(database, """
            INSERT INTO message_nodes (session_id, node_id, chat_message, created_at)
            VALUES ('session', (SELECT COUNT(*) FROM message_nodes), '\(json)', \(createdAt));
            """)
    }

    private func runSQLite(_ database: URL, _ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, sql)
    }
}
