import XCTest
@testable import notchi

final class CodexCostScannerTests: XCTestCase {
    private struct FlatPrice: ClaudePricingProviding {
        nonisolated func pricing(model: String) -> ClaudeModelPricing? {
            ClaudeModelPricing(inputPerToken: 1e-6, outputPerToken: 1e-6,
                cacheCreationPerToken: 0, cacheReadPerToken: 0, cacheCreation1hPerToken: nil,
                thresholdTokens: nil, inputPerTokenAboveThreshold: nil,
                outputPerTokenAboveThreshold: nil, cacheCreationPerTokenAboveThreshold: nil,
                cacheReadPerTokenAboveThreshold: nil)
        }
    }

    private struct Gpt55Price: ClaudePricingProviding {
        nonisolated func pricing(model: String) -> ClaudeModelPricing? {
            ClaudeModelPricing(inputPerToken: 5e-6, outputPerToken: 3e-5,
                cacheCreationPerToken: 0, cacheReadPerToken: 5e-7, cacheCreation1hPerToken: nil,
                thresholdTokens: 272000, inputPerTokenAboveThreshold: 1e-5,
                outputPerTokenAboveThreshold: 4.5e-5, cacheCreationPerTokenAboveThreshold: 0,
                cacheReadPerTokenAboveThreshold: 1e-6)
        }
    }

    private func tokenCountLine(timestamp: String = "2026-06-24T12:00:00.000Z",
                                 lastUsage: (input: Int, cached: Int, output: Int)?,
                                 totalUsage: (input: Int, cached: Int, output: Int)? = nil) -> String {
        var infoParts: [String] = []
        if let l = lastUsage {
            infoParts.append("""
            "last_token_usage":{"input_tokens":\(l.input),"cached_input_tokens":\(l.cached),"output_tokens":\(l.output),"reasoning_output_tokens":0,"total_tokens":\(l.input + l.output)}
            """)
        }
        if let t = totalUsage {
            infoParts.append("""
            "total_token_usage":{"input_tokens":\(t.input),"cached_input_tokens":\(t.cached),"output_tokens":\(t.output),"reasoning_output_tokens":0,"total_tokens":\(t.input + t.output)}
            """)
        }
        let info = infoParts.joined(separator: ",")
        return """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{\(info)}}}
        """
    }

    private func turnContextLine(model: String, timestamp: String = "2026-06-24T11:00:00.000Z") -> String {
        """
        {"type":"turn_context","timestamp":"\(timestamp)","payload":{"model":"\(model)"}}
        """
    }

    private func writeFile(_ lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sessions").appendingPathComponent("s.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: url)
        return url
    }

    private func scanner(root: URL, pricing: any ClaudePricingProviding = FlatPrice()) -> CodexCostScanner {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return CodexCostScanner(projectsRoots: [root], pricing: pricing, windowDays: 30, calendar: cal)
    }

    private func emptyCache() -> CostUsageCache {
        CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:])
    }

    private func now() -> Date {
        ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!
    }

    func testTwoLastUsageEventsSumIntoOneDay() throws {
        let url = try writeFile([
            tokenCountLine(lastUsage: (input: 300, cached: 0, output: 100)),
            tokenCountLine(lastUsage: (input: 200, cached: 0, output: 50)),
        ])
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let s = scanner(root: root)
        let out = s.scan(cache: emptyCache(), now: now())

        let expectedInput = 500
        let expectedOutput = 150
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.input, expectedInput)
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.output, expectedOutput)
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.requestCount, 2)
    }

    func testTokenMappingPartialCacheRead() throws {
        let url = try writeFile([
            tokenCountLine(lastUsage: (input: 1000, cached: 200, output: 500)),
        ])
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let s = scanner(root: root)
        let out = s.scan(cache: emptyCache(), now: now())

        let expectedInput = 800
        let expectedCacheRead = 200
        let expectedOutput = 500
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.input, expectedInput)
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.cacheRead, expectedCacheRead)
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.output, expectedOutput)
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.cacheCreation, 0)
    }

    func testTotalUsageFallbackDeltaFromBaseline() throws {
        let url = try writeFile([
            tokenCountLine(lastUsage: nil, totalUsage: (input: 400, cached: 50, output: 200)),
            tokenCountLine(lastUsage: nil, totalUsage: (input: 700, cached: 80, output: 350)),
        ])
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let s = scanner(root: root)
        let out = s.scan(cache: emptyCache(), now: now())

        let firstDeltaInput = 400 - 0
        let firstDeltaCached = 50 - 0
        let firstDeltaOutput = 200 - 0
        let secondDeltaInput = 700 - 400
        let secondDeltaCached = 80 - 50
        let secondDeltaOutput = 350 - 200

        let expectedInput = (firstDeltaInput - firstDeltaCached) + (secondDeltaInput - secondDeltaCached)
        let expectedCacheRead = firstDeltaCached + secondDeltaCached
        let expectedOutput = firstDeltaOutput + secondDeltaOutput
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.input, expectedInput)
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.cacheRead, expectedCacheRead)
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.output, expectedOutput)
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.requestCount, 2)
    }

    func testDuplicateEventAppendedInALaterScanCountedOnce() throws {
        let duplicated = tokenCountLine(lastUsage: (input: 300, cached: 0, output: 100))
        let url = try writeFile([duplicated])
        let s = scanner(root: url.deletingLastPathComponent().deletingLastPathComponent())
        let first = s.scan(cache: emptyCache(), now: now())

        let fh = try FileHandle(forWritingTo: url); fh.seekToEndOfFile()
        fh.write((duplicated + "\n").data(using: .utf8)!)
        try fh.close()
        let second = s.scan(cache: first, now: now())

        XCTAssertEqual(second.buckets["2026-06-24"]?["gpt-5"]?.input, 300)
        XCTAssertEqual(second.buckets["2026-06-24"]?["gpt-5"]?.requestCount, 1)
    }

    func testDuplicateEventTupleCountedOnce() throws {
        let sameLine = tokenCountLine(lastUsage: (input: 300, cached: 50, output: 100))
        let url = try writeFile([sameLine, sameLine])
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let s = scanner(root: root)
        let out = s.scan(cache: emptyCache(), now: now())

        let expectedInput = 250
        let expectedCacheRead = 50
        let expectedOutput = 100
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.input, expectedInput)
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.cacheRead, expectedCacheRead)
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.output, expectedOutput)
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5"]?.requestCount, 1)
    }

    func testTurnContextModelDrivesNormalizedBucketKey() throws {
        let url = try writeFile([
            turnContextLine(model: "gpt-5.5"),
            tokenCountLine(lastUsage: (input: 100, cached: 0, output: 50)),
        ])
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let s = scanner(root: root)
        let out = s.scan(cache: emptyCache(), now: now())

        XCTAssertNil(out.buckets["2026-06-24"]?["gpt-5"], "default model bucket must not exist")
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5.5"]?.requestCount, 1)
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5.5"]?.input, 100)
    }

    func testGpt55CostPricedCorrectly() throws {
        let url = try writeFile([
            turnContextLine(model: "gpt-5.5"),
            tokenCountLine(lastUsage: (input: 1000, cached: 200, output: 500)),
        ])
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let s = scanner(root: root, pricing: Gpt55Price())
        let out = s.scan(cache: emptyCache(), now: now())

        let mappedInput = 800
        let mappedCacheRead = 200
        let mappedOutput = 500
        let expectedCostUSD = Double(mappedInput) * 5e-6
            + Double(mappedCacheRead) * 5e-7
            + Double(mappedOutput) * 3e-5
        let expectedNanos = Int((expectedCostUSD * 1_000_000_000).rounded())

        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5.5"]?.costNanos, expectedNanos)
        XCTAssertEqual(out.buckets["2026-06-24"]?["gpt-5.5"]?.pricedCount, 1)
    }

    func testTruncatedFileFullyRescansWithoutDoubleCounting() throws {
        let url = try writeFile([
            tokenCountLine(timestamp: "2026-06-24T12:00:00.000Z", lastUsage: (input: 300, cached: 0, output: 100)),
            tokenCountLine(timestamp: "2026-06-24T13:00:00.000Z", lastUsage: (input: 200, cached: 0, output: 50)),
        ])
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let s = scanner(root: root)
        let firstCache = s.scan(cache: emptyCache(), now: now())
        XCTAssertEqual(firstCache.buckets["2026-06-24"]?["gpt-5"]?.requestCount, 2)

        try (tokenCountLine(timestamp: "2026-06-24T12:00:00.000Z", lastUsage: (input: 300, cached: 0, output: 100)) + "\n")
            .data(using: .utf8)!.write(to: url)
        let secondCache = s.scan(cache: firstCache, now: now())
        XCTAssertEqual(secondCache.buckets["2026-06-24"]?["gpt-5"]?.requestCount, 1,
                       "truncated file must trigger a clean full rescan, not double-count")
        XCTAssertEqual(secondCache.buckets["2026-06-24"]?["gpt-5"]?.input, 300)
    }

    func testDeletedSessionsCostStaysInHistory() throws {
        let keptInput = 300
        let deletedInput = 200
        let kept = try writeFile([tokenCountLine(lastUsage: (input: keptInput, cached: 0, output: 0))])
        let root = kept.deletingLastPathComponent().deletingLastPathComponent()
        let deleted = root.appendingPathComponent("sessions/d.jsonl")
        try (tokenCountLine(timestamp: "2026-06-24T13:00:00.000Z", lastUsage: (input: deletedInput, cached: 0, output: 0)) + "\n")
            .data(using: .utf8)!.write(to: deleted)
        let s = scanner(root: root)
        let first = s.scan(cache: emptyCache(), now: now())

        try FileManager.default.removeItem(at: deleted)
        let second = s.scan(cache: first, now: now())

        XCTAssertEqual(second.buckets["2026-06-24"]?["gpt-5"]?.input, keptInput + deletedInput)
    }

    func testArchivedSessionIsCountedOnceAndKeepsItsModel() throws {
        let firstInput = 300
        let laterInput = 200
        let session = try writeFile([
            turnContextLine(model: "gpt-5.5"),
            tokenCountLine(lastUsage: (input: firstInput, cached: 0, output: 0)),
        ])
        let base = session.deletingLastPathComponent().deletingLastPathComponent()
        let sessions = base.appendingPathComponent("sessions")
        let archived = base.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let s = CodexCostScanner(projectsRoots: [sessions, archived], pricing: FlatPrice(), windowDays: 30, calendar: cal)
        let first = s.scan(cache: emptyCache(), now: now())

        let moved = archived.appendingPathComponent(session.lastPathComponent)
        try FileManager.default.moveItem(at: session, to: moved)
        let fh = try FileHandle(forWritingTo: moved); fh.seekToEndOfFile()
        fh.write((tokenCountLine(timestamp: "2026-06-24T13:00:00.000Z",
                                 lastUsage: (input: laterInput, cached: 0, output: 0)) + "\n").data(using: .utf8)!)
        try fh.close()
        let second = s.scan(cache: first, now: now())

        XCTAssertEqual(second.buckets["2026-06-24"]?["gpt-5.5"]?.input, firstInput + laterInput)
    }

    func testSessionLastModifiedBeforeWindowIsReadFromTheTopOnceItChanges() throws {
        let laterInput = 200
        let url = try writeFile([
            turnContextLine(model: "gpt-5.5", timestamp: "2026-04-01T11:00:00.000Z"),
            tokenCountLine(timestamp: "2026-04-01T12:00:00.000Z", lastUsage: (input: 300, cached: 0, output: 0)),
        ])
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-04-01T13:00:00Z")!], ofItemAtPath: url.path)
        let s = scanner(root: url.deletingLastPathComponent().deletingLastPathComponent())
        let first = s.scan(cache: emptyCache(), now: now())

        let fh = try FileHandle(forWritingTo: url); fh.seekToEndOfFile()
        fh.write((tokenCountLine(lastUsage: (input: laterInput, cached: 0, output: 0)) + "\n").data(using: .utf8)!)
        try fh.close()
        let second = s.scan(cache: first, now: now())

        XCTAssertEqual(second.buckets["2026-06-24"]?["gpt-5.5"]?.input, laterInput)
    }

    func testIncrementalScanPreservesModelAcrossWrites() throws {
        let url = try writeFile([turnContextLine(model: "gpt-5.5")])
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let s = scanner(root: root, pricing: Gpt55Price())
        let first = s.scan(cache: emptyCache(), now: now())
        XCTAssertNil(first.buckets["2026-06-24"]?["gpt-5.5"])

        let fh = try FileHandle(forWritingTo: url); fh.seekToEndOfFile()
        fh.write((tokenCountLine(lastUsage: (input: 1000, cached: 0, output: 500)) + "\n").data(using: .utf8)!)
        try fh.close()
        let second = s.scan(cache: first, now: now())

        XCTAssertEqual(second.buckets["2026-06-24"]?["gpt-5.5"]?.input, 1000)
        XCTAssertNil(second.buckets["2026-06-24"]?["gpt-5"],
                     "model must persist across the scan boundary, not fall back to gpt-5")
    }

    func testIncrementalScanPreservesBaselineForTotalFallback() throws {
        let url = try writeFile([
            turnContextLine(model: "gpt-5"),
            tokenCountLine(timestamp: "2026-06-24T12:00:00.000Z", lastUsage: nil, totalUsage: (input: 1000, cached: 0, output: 0)),
        ])
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let s = scanner(root: root)
        let first = s.scan(cache: emptyCache(), now: now())
        XCTAssertEqual(first.buckets["2026-06-24"]?["gpt-5"]?.input, 1000)

        let fh = try FileHandle(forWritingTo: url); fh.seekToEndOfFile()
        fh.write((tokenCountLine(timestamp: "2026-06-24T12:05:00.000Z", lastUsage: nil, totalUsage: (input: 1500, cached: 0, output: 0)) + "\n")
            .data(using: .utf8)!)
        try fh.close()
        let second = s.scan(cache: first, now: now())

        XCTAssertEqual(second.buckets["2026-06-24"]?["gpt-5"]?.input, 1500,
                       "baseline must persist so the cumulative total yields a 500 delta, not 1500")
    }
}
