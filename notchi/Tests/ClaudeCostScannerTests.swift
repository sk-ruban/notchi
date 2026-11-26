import XCTest
@testable import notchi

final class ClaudeCostScannerTests: XCTestCase {
    private struct FlatPrice: ClaudePricingProviding {
        nonisolated func pricing(model: String) -> ClaudeModelPricing? {
            ClaudeModelPricing(inputPerToken: 1e-6, outputPerToken: 1e-6,
                cacheCreationPerToken: 0, cacheReadPerToken: 0, cacheCreation1hPerToken: nil,
                thresholdTokens: nil, inputPerTokenAboveThreshold: nil,
                outputPerTokenAboveThreshold: nil, cacheCreationPerTokenAboveThreshold: nil,
                cacheReadPerTokenAboveThreshold: nil)
        }
    }

    private func line(msgId: String, reqId: String, input: Int, output: Int,
                      day: String = "2026-06-24", cacheCreation1h: Int = 0, speed: String = "standard") -> String {
        """
        {"type":"assistant","timestamp":"\(day)T12:00:00.000Z","requestId":"\(reqId)",\
        "message":{"id":"\(msgId)","model":"claude-opus-4-20250101",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output),\
        "cache_creation_input_tokens":\(cacheCreation1h),"cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_1h_input_tokens":\(cacheCreation1h),"ephemeral_5m_input_tokens":0},\
        "speed":"\(speed)"}}}
        """
    }

    private func writeFile(_ lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("p").appendingPathComponent("c.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: url)
        return url
    }

    private func scanner(root: URL) -> ClaudeCostScanner {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return ClaudeCostScanner(projectsRoots: [root], pricing: FlatPrice(),
                                 windowDays: 30, calendar: cal)
    }

    func testDuplicateMessageRequestPairCountedOnce() throws {
        let url = try writeFile([
            line(msgId: "m1", reqId: "r1", input: 100, output: 0),
            line(msgId: "m1", reqId: "r1", input: 100, output: 0),
        ])
        let s = scanner(root: url.deletingLastPathComponent().deletingLastPathComponent())
        let out = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]),
                         now: ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!)
        XCTAssertEqual(out.buckets["2026-06-24"]?["claude-opus-4"]?.input, 100)
        XCTAssertEqual(out.buckets["2026-06-24"]?["claude-opus-4"]?.requestCount, 1)
    }

    func testDuplicateLineAppendedInALaterScanCountedOnce() throws {
        let duplicated = line(msgId: "m1", reqId: "r1", input: 100, output: 0)
        let url = try writeFile([duplicated])
        let s = scanner(root: url.deletingLastPathComponent().deletingLastPathComponent())
        let now = ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!
        let first = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]), now: now)

        let fh = try FileHandle(forWritingTo: url); fh.seekToEndOfFile()
        fh.write((duplicated + "\n").data(using: .utf8)!)
        try fh.close()
        let second = s.scan(cache: first, now: now)

        XCTAssertEqual(second.buckets["2026-06-24"]?["claude-opus-4"]?.input, 100)
        XCTAssertEqual(second.buckets["2026-06-24"]?["claude-opus-4"]?.requestCount, 1)
    }

    func testAppendedLinesAddWithoutRecountingViaOffset() throws {
        let url = try writeFile([line(msgId: "m1", reqId: "r1", input: 100, output: 0)])
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let s = scanner(root: root)
        let now = ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!
        let first = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]), now: now)
        XCTAssertEqual(first.buckets["2026-06-24"]?["claude-opus-4"]?.input, 100)

        let fh = try FileHandle(forWritingTo: url); fh.seekToEndOfFile()
        fh.write((line(msgId: "m2", reqId: "r2", input: 50, output: 0) + "\n").data(using: .utf8)!)
        try fh.close()
        let second = s.scan(cache: first, now: now)
        XCTAssertEqual(second.buckets["2026-06-24"]?["claude-opus-4"]?.input, 150)
        XCTAssertEqual(second.buckets["2026-06-24"]?["claude-opus-4"]?.requestCount, 2)
    }

    func testTruncatedFileFullyRescansWithoutDoubleCounting() throws {
        let url = try writeFile([
            line(msgId: "m1", reqId: "r1", input: 100, output: 0),
            line(msgId: "m2", reqId: "r2", input: 50, output: 0),
        ])
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let s = scanner(root: root)
        let now = ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!
        let first = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]), now: now)
        XCTAssertEqual(first.buckets["2026-06-24"]?["claude-opus-4"]?.input, 150)

        try (line(msgId: "m1", reqId: "r1", input: 100, output: 0) + "\n").data(using: .utf8)!.write(to: url)
        let second = s.scan(cache: first, now: now)
        XCTAssertEqual(second.buckets["2026-06-24"]?["claude-opus-4"]?.input, 100,
                       "truncated file must trigger a clean full rescan, not double-count")
        XCTAssertEqual(second.buckets["2026-06-24"]?["claude-opus-4"]?.requestCount, 1)
    }

    func testDeletedLogsCostStaysInHistory() throws {
        let keptInput = 100
        let deletedInput = 50
        let kept = try writeFile([line(msgId: "m1", reqId: "r1", input: keptInput, output: 0)])
        let root = kept.deletingLastPathComponent().deletingLastPathComponent()
        let deleted = root.appendingPathComponent("q/d.jsonl")
        try FileManager.default.createDirectory(at: deleted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (line(msgId: "m2", reqId: "r2", input: deletedInput, output: 0) + "\n").data(using: .utf8)!.write(to: deleted)
        let s = scanner(root: root)
        let now = ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!
        let first = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]), now: now)

        try FileManager.default.removeItem(at: deleted)
        let second = s.scan(cache: first, now: now)

        XCTAssertEqual(second.buckets["2026-06-24"]?["claude-opus-4"]?.input, keptInput + deletedInput)
    }

    func testDeletedLogLastModifiedBeforeWindowIsDroppedFromTrackedFiles() throws {
        let kept = try writeFile([line(msgId: "m1", reqId: "r1", input: 100, output: 0)])
        let root = kept.deletingLastPathComponent().deletingLastPathComponent()
        let deleted = root.appendingPathComponent("q/d.jsonl")
        try FileManager.default.createDirectory(at: deleted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (line(msgId: "m2", reqId: "r2", input: 50, output: 0, day: "2026-04-01") + "\n").data(using: .utf8)!
            .write(to: deleted)
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-04-01T13:00:00Z")!], ofItemAtPath: deleted.path)
        let s = scanner(root: root)
        let now = ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!
        let first = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]), now: now)

        try FileManager.default.removeItem(at: deleted)
        let second = s.scan(cache: first, now: now)

        XCTAssertEqual(second.files.keys.map { URL(fileURLWithPath: $0).lastPathComponent }, [kept.lastPathComponent])
    }

    func testLogMovedAwayAndBackIsCountedOnce() throws {
        let inputTokens = 100
        let url = try writeFile([line(msgId: "m1", reqId: "r1", input: inputTokens, output: 0)])
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let aside = root.deletingLastPathComponent().appendingPathComponent("aside.jsonl")
        let s = scanner(root: root)
        let now = ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!
        let first = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]), now: now)

        try FileManager.default.moveItem(at: url, to: aside)
        let whileAway = s.scan(cache: first, now: now)
        try FileManager.default.moveItem(at: aside, to: url)
        let back = s.scan(cache: whileAway, now: now)

        XCTAssertEqual(back.buckets["2026-06-24"]?["claude-opus-4"]?.input, inputTokens)
    }

    func testLogsUnderARootThatGoesMissingAreCountedOnceWhenItReturns() throws {
        let inputTokens = 100
        let url = try writeFile([line(msgId: "m1", reqId: "r1", input: inputTokens, output: 0)])
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let aside = root.deletingLastPathComponent().appendingPathComponent("aside")
        let s = scanner(root: root)
        let now = ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!
        let first = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]), now: now)

        try FileManager.default.moveItem(at: root, to: aside)
        let whileMissing = s.scan(cache: first, now: now)
        try FileManager.default.moveItem(at: aside, to: root)
        let back = s.scan(cache: whileMissing, now: now)

        XCTAssertEqual(back.buckets["2026-06-24"]?["claude-opus-4"]?.input, inputTokens)
    }

    func testTrackedLogTouchedToAnOldDateStillCountsItsAppendedLine() throws {
        let firstInput = 100
        let laterInput = 50
        let url = try writeFile([line(msgId: "m1", reqId: "r1", input: firstInput, output: 0)])
        let s = scanner(root: url.deletingLastPathComponent().deletingLastPathComponent())
        let now = ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!
        let first = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]), now: now)

        let fh = try FileHandle(forWritingTo: url); fh.seekToEndOfFile()
        fh.write((line(msgId: "m2", reqId: "r2", input: laterInput, output: 0) + "\n").data(using: .utf8)!)
        try fh.close()
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-04-01T13:00:00Z")!], ofItemAtPath: url.path)
        let second = s.scan(cache: first, now: now)

        XCTAssertEqual(second.buckets["2026-06-24"]?["claude-opus-4"]?.input, firstInput + laterInput)
    }

    func testReplyIsCountedUnderABuddhistCalendar() throws {
        let inputTokens = 100
        let buddhistDayKey = "2569-06-24"
        let url = try writeFile([line(msgId: "m1", reqId: "r1", input: inputTokens, output: 0)])
        var cal = Calendar(identifier: .buddhist); cal.timeZone = TimeZone(identifier: "UTC")!
        let s = ClaudeCostScanner(projectsRoots: [url.deletingLastPathComponent().deletingLastPathComponent()],
                                  pricing: FlatPrice(), windowDays: 30, calendar: cal)
        let out = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]),
                         now: ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!)

        XCTAssertEqual(out.buckets[buddhistDayKey]?["claude-opus-4"]?.input, inputTokens)
    }

    func testLogLastModifiedBeforeWindowIsTrackedUnread() throws {
        let unreadOffset: Int64 = 0
        let url = try writeFile([line(msgId: "m1", reqId: "r1", input: 100, output: 0, day: "2026-04-01")])
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-04-01T13:00:00Z")!], ofItemAtPath: url.path)
        let fileSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).int64Value
        let s = scanner(root: url.deletingLastPathComponent().deletingLastPathComponent())
        let out = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]),
                         now: ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!)

        let state = try XCTUnwrap(out.files.values.first)
        XCTAssertEqual(state.size, fileSize)
        XCTAssertEqual(state.offset, unreadOffset)
    }

    func testLineDatedTwoDaysBeforeWindowStartByItsOwnOffsetIsCountedWhenInsideTheWindowLocally() throws {
        // 2026-05-24T23:00-12:00 is 2026-05-26 01:00 in UTC+14, the first day of a window ending 2026-06-24.
        let inputTokens = 100
        let reply = """
        {"type":"assistant","timestamp":"2026-05-24T23:00:00-12:00","requestId":"r1",\
        "message":{"id":"m1","model":"claude-opus-4-20250101",\
        "usage":{"input_tokens":\(inputTokens),"output_tokens":0,\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let url = try writeFile([reply])
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!
        let s = ClaudeCostScanner(projectsRoots: [url.deletingLastPathComponent().deletingLastPathComponent()],
                                  pricing: FlatPrice(), windowDays: 30, calendar: cal)
        let out = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]),
                         now: ISO8601DateFormatter().date(from: "2026-06-24T00:00:00Z")!)

        XCTAssertEqual(out.buckets["2026-05-26"]?["claude-opus-4"]?.input, inputTokens)
    }

    func testReplyInWindowIsCountedWhenItsToolInputCarriesAnOlderTimestamp() throws {
        let inputTokens = 100
        let reply = """
        {"type":"assistant","requestId":"r1","message":{"id":"m1","model":"claude-opus-4-20250101",\
        "content":[{"type":"tool_use","input":{"timestamp":"2025-01-01T00:00:00Z"}}],\
        "usage":{"input_tokens":\(inputTokens),"output_tokens":0,\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-06-24T12:00:00.000Z"}
        """
        let url = try writeFile([reply])
        let s = scanner(root: url.deletingLastPathComponent().deletingLastPathComponent())
        let out = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]),
                         now: ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!)

        XCTAssertEqual(out.buckets["2026-06-24"]?["claude-opus-4"]?.input, inputTokens)
    }

    func testMessagesWithoutIdsAreNotDeduped() throws {
        let noId = """
        {"type":"assistant","timestamp":"2026-06-24T12:00:00.000Z",\
        "message":{"model":"claude-opus-4-20250101",\
        "usage":{"input_tokens":40,"output_tokens":0,\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let url = try writeFile([noId, noId])
        let s = scanner(root: url.deletingLastPathComponent().deletingLastPathComponent())
        let out = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]),
                         now: ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!)
        XCTAssertEqual(out.buckets["2026-06-24"]?["claude-opus-4"]?.input, 80,
                       "messages without ids cannot be deduped and must each count")
        XCTAssertEqual(out.buckets["2026-06-24"]?["claude-opus-4"]?.requestCount, 2)
    }

    func testFastModeRequestIsPricedAtFastMultiplier() throws {
        let fastTokens = 100
        let standardTokens = 100
        let url = try writeFile([
            line(msgId: "m1", reqId: "r1", input: fastTokens, output: 0, speed: "fast"),
            line(msgId: "m2", reqId: "r2", input: standardTokens, output: 0),
        ])
        let s = scanner(root: url.deletingLastPathComponent().deletingLastPathComponent())
        let out = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]),
                         now: ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!)

        let nanosPerToken = 1_000 // FlatPrice: $1e-6 per input token
        let fastMultiplier = 2
        let expected = fastTokens * nanosPerToken * fastMultiplier + standardTokens * nanosPerToken
        XCTAssertEqual(out.buckets["2026-06-24"]?["claude-opus-4"]?.costNanos, expected)
    }

    private struct DistinctPrices: ClaudePricingProviding {
        nonisolated func pricing(model: String) -> ClaudeModelPricing? {
            ClaudeModelPricing(inputPerToken: 1e-6, outputPerToken: 5e-6,
                cacheCreationPerToken: 1.25e-6, cacheReadPerToken: 0.1e-6, cacheCreation1hPerToken: nil,
                thresholdTokens: nil, inputPerTokenAboveThreshold: nil,
                outputPerTokenAboveThreshold: nil, cacheCreationPerTokenAboveThreshold: nil,
                cacheReadPerTokenAboveThreshold: nil)
        }
    }

    // Per-token nanos: input 1,000 · output 5,000 · 5-minute write 1,250 · 1-hour write 2,000 · cache read 100.
    // 10 input + 20 output + 30 five-minute + 40 one-hour + 50 read = 232,500 standard, doubled for fast mode.
    private static let fastEveryTokenClassCostNanos = 465_000

    func testFastModeDoublesEveryTokenClass() throws {
        let fastReply = """
        {"type":"assistant","timestamp":"2026-06-24T12:00:00.000Z","requestId":"r1",\
        "message":{"id":"m1","model":"claude-opus-4-20250101",\
        "usage":{"input_tokens":10,"output_tokens":20,\
        "cache_creation_input_tokens":70,"cache_read_input_tokens":50,\
        "cache_creation":{"ephemeral_1h_input_tokens":40,"ephemeral_5m_input_tokens":30},\
        "speed":"fast"}}}
        """
        let url = try writeFile([fastReply])
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let s = ClaudeCostScanner(projectsRoots: [url.deletingLastPathComponent().deletingLastPathComponent()],
                                  pricing: DistinctPrices(), windowDays: 30, calendar: cal)
        let out = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]),
                         now: ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!)

        XCTAssertEqual(out.buckets["2026-06-24"]?["claude-opus-4"]?.costNanos, Self.fastEveryTokenClassCostNanos)
    }

    func testOneHourCacheWritesArePricedAtTwiceInput() throws {
        let oneHourWriteTokens = 100
        let url = try writeFile([
            line(msgId: "m1", reqId: "r1", input: 0, output: 0, cacheCreation1h: oneHourWriteTokens),
        ])
        let s = scanner(root: url.deletingLastPathComponent().deletingLastPathComponent())
        let out = s.scan(cache: CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:]),
                         now: ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!)

        let totals = out.buckets["2026-06-24"]?["claude-opus-4"]
        let nanosPerInputToken = 1_000 // FlatPrice: $1e-6 per input token, 5-minute writes free
        XCTAssertEqual(totals?.cacheCreation1h, oneHourWriteTokens)
        XCTAssertEqual(totals?.costNanos, oneHourWriteTokens * nanosPerInputToken * 2)
    }
}
