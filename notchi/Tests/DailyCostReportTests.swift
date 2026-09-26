import XCTest
@testable import notchi

final class CostHistoryStoreTests: XCTestCase {
    @MainActor
    func testStorePublishesReportFromInjectedScan() async {
        var buckets: DayModelBuckets = [:]
        buckets[DailyCostReport.dayKey(Date(), calendar: .current)] =
            ["claude-opus-4": ModelTokenTotals(input: 10, output: 5, costNanos: 3_000_000_000,
                                               requestCount: 1, pricedCount: 1)]
        let store = CostHistoryStore(windowDays: 30, calendar: .current,
            scanProvider: { _ in buckets })
        await store.refresh()
        XCTAssertEqual(store.report?.todayCostUSD ?? 0, 3.0, accuracy: 1e-9)
        XCTAssertEqual(store.report?.topModel, "claude-opus-4")
        XCTAssertFalse(store.isScanning)
    }

    @MainActor
    func testRefreshStampsConfiguredProviderOnReport() async {
        let buckets: DayModelBuckets = [
            "2026-06-25": ["gpt-5.5": ModelTokenTotals(input: 100, output: 50, costNanos: 1_000,
                                                       requestCount: 1, pricedCount: 1)]
        ]
        let store = CostHistoryStore(windowDays: 7, calendar: .current, provider: .codex,
            scanProvider: { _ in buckets })
        await store.refresh()
        XCTAssertEqual(store.report?.provider, .codex)
    }

    @MainActor
    func testRefreshDefaultsToClaudeProvider() async {
        let store = CostHistoryStore(windowDays: 7, calendar: .current, scanProvider: { _ in [:] })
        await store.refresh()
        XCTAssertEqual(store.report?.provider, .claude)
    }

    @MainActor
    func testRefreshPricesModelReleasedAfterLaunchWithoutRestart() async throws {
        let newModel = "claude-released-after-launch-1"
        let inputPerMillion = 2.0
        let outputPerMillion = 10.0
        let inputTokens = 1_000
        let outputTokens = 500
        let expectedCostUSD = Double(inputTokens) * inputPerMillion / 1_000_000
            + Double(outputTokens) * outputPerMillion / 1_000_000

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectDir = dir.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = """
        {"type":"assistant","timestamp":"\(timestamp)","requestId":"r1",\
        "message":{"id":"m1","model":"\(newModel)",\
        "usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens),\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        """
        try line.data(using: .utf8)!.write(to: projectDir.appendingPathComponent("s.jsonl"))

        // The anchors are included so the refresh passes the plausibility guard.
        let modelsDev = """
        {"anthropic":{"models":{
          "\(newModel)":{"cost":{"input":\(inputPerMillion),"output":\(outputPerMillion)}},
          "claude-sonnet-4-6":{"cost":{"input":3,"output":15}},
          "claude-opus-4-8":{"cost":{"input":5,"output":25}}
        }}}
        """.data(using: .utf8)!
        let catalog = PricingCatalog(fallbackBundle: .main, fetchCatalog: { modelsDev })
        XCTAssertNil(catalog.pricing(model: newModel, on: Date()), "precondition: launch-time pricing lacks the new model")

        let store = CostHistoryStore(windowDays: 30, calendar: .current, pricing: catalog,
                                     projectsRoots: [dir.appendingPathComponent("projects")],
                                     cacheURL: dir.appendingPathComponent("cache.json"))
        await store.refresh()

        XCTAssertEqual(store.report?.todayCostUSD ?? 0, expectedCostUSD, accuracy: 1e-12)
        XCTAssertEqual(store.report?.entries.last?.pricedFraction, 1)
    }

    private actor FetchCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    @MainActor
    func testUnpriceableModelFetchesCatalogOnceWithinRetryInterval() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectDir = dir.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let line = """
        {"type":"assistant","timestamp":"\(ISO8601DateFormatter().string(from: Date()))","requestId":"r1",\
        "message":{"id":"m1","model":"model-models-dev-never-lists",\
        "usage":{"input_tokens":10,"output_tokens":5,\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        """
        try line.data(using: .utf8)!.write(to: projectDir.appendingPathComponent("s.jsonl"))

        let counter = FetchCounter()
        let catalog = PricingCatalog(fallbackBundle: .main, fetchCatalog: {
            await counter.increment()
            return nil
        })
        let store = CostHistoryStore(windowDays: 30, calendar: .current, pricing: catalog,
                                     projectsRoots: [dir.appendingPathComponent("projects")],
                                     cacheURL: dir.appendingPathComponent("cache.json"))
        await store.refresh()
        await store.refresh()

        let fetches = await counter.count
        XCTAssertEqual(fetches, 1)
    }
}

final class DailyCostReportTests: XCTestCase {
    private func day(_ s: String) -> Date {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    func testReportDerivesHeadlineStatsAndGapFills() {
        var buckets: DayModelBuckets = [:]
        buckets["2026-06-22"] = ["claude-sonnet-4": ModelTokenTotals(
            input: 100, output: 50, costNanos: 2_000_000_000, requestCount: 1, pricedCount: 1)]
        buckets["2026-06-24"] = [
            "claude-opus-4": ModelTokenTotals(
                input: 300, output: 100, costNanos: 9_000_000_000, requestCount: 2, pricedCount: 2),
            "claude-sonnet-4": ModelTokenTotals(
                input: 200, output: 20, costNanos: 1_000_000_000, requestCount: 1, pricedCount: 1)]

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let report = DailyCostReport.make(
            provider: .claude, buckets: buckets,
            windowStart: day("2026-06-20"), today: day("2026-06-24"), calendar: cal)

        // window 06-20..06-24 → gap-filled ascending indices: 0=20, 1=21, 2=22, 3=23, 4=24
        XCTAssertEqual(report.entries.count, 5)
        XCTAssertEqual(report.entries[1].costUSD, 0, accuracy: 1e-9)   // 21st: no activity
        XCTAssertEqual(report.entries[2].costUSD, 2.0, accuracy: 1e-9) // 22nd: $2
        XCTAssertEqual(report.windowCostUSD, 12.0, accuracy: 1e-9)     // 2 + 9 + 1
        XCTAssertEqual(report.windowTokens, 100 + 50 + 300 + 100 + 200 + 20)
        XCTAssertEqual(report.todayCostUSD, 10.0, accuracy: 1e-9)      // 24th: 9 + 1
        XCTAssertEqual(report.todayTokens, 300 + 100 + 200 + 20)      // 24th: all models summed
        XCTAssertEqual(report.topModel, "claude-opus-4")              // highest cost across window
    }

    func testTopModelTieOnCostIsBrokenByTokensThenName() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        var unpriced: DayModelBuckets = [:]
        unpriced["2026-06-24"] = [
            "gpt-5.6-sol": ModelTokenTotals(input: 900, output: 100, costNanos: 0,
                                            requestCount: 3, pricedCount: 0),
            "gpt-5.6-luna": ModelTokenTotals(input: 100, output: 50, costNanos: 0,
                                             requestCount: 1, pricedCount: 0)]
        let unpricedReport = DailyCostReport.make(
            provider: .codex, buckets: unpriced,
            windowStart: day("2026-06-20"), today: day("2026-06-24"), calendar: cal)
        XCTAssertEqual(unpricedReport.topModel, "gpt-5.6-sol", "more tokens must win a cost tie")

        var identical: DayModelBuckets = [:]
        identical["2026-06-24"] = [
            "gpt-5.5": ModelTokenTotals(input: 100, output: 50, costNanos: 5_000,
                                        requestCount: 1, pricedCount: 1),
            "gpt-5.4": ModelTokenTotals(input: 100, output: 50, costNanos: 5_000,
                                        requestCount: 1, pricedCount: 1)]
        let identicalReport = DailyCostReport.make(
            provider: .codex, buckets: identical,
            windowStart: day("2026-06-20"), today: day("2026-06-24"), calendar: cal)
        XCTAssertEqual(identicalReport.topModel, "gpt-5.4", "lowest name must win an exact tie")
    }

    func testEntriesCarryTheirOwnTopModel() {
        var buckets: DayModelBuckets = [:]
        buckets["2026-06-22"] = [
            "claude-sonnet-4": ModelTokenTotals(
                input: 100, output: 50, costNanos: 8_000_000_000, requestCount: 1, pricedCount: 1),
            "claude-opus-4": ModelTokenTotals(
                input: 10, output: 5, costNanos: 1_000_000_000, requestCount: 1, pricedCount: 1)]
        buckets["2026-06-24"] = [
            "claude-opus-4": ModelTokenTotals(
                input: 300, output: 100, costNanos: 9_000_000_000, requestCount: 2, pricedCount: 2)]

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let report = DailyCostReport.make(
            provider: .claude, buckets: buckets,
            windowStart: day("2026-06-20"), today: day("2026-06-24"), calendar: cal)

        XCTAssertEqual(report.entries[2].topModel, "claude-sonnet-4")
        XCTAssertEqual(report.entries[4].topModel, "claude-opus-4")
        XCTAssertNil(report.entries[1].topModel)
        XCTAssertEqual(report.topModel, "claude-opus-4")
    }

    @MainActor
    func testSizingCoversEveryHoverStateAndTheModelReference() {
        var buckets: DayModelBuckets = [:]
        buckets["2026-06-22"] = ["gpt-5.6-sol": ModelTokenTotals(
            input: 100, output: 50, costNanos: 8_000_000_000, requestCount: 1, pricedCount: 1)]
        buckets["2026-06-24"] = ["gpt-5.5": ModelTokenTotals(
            input: 300, output: 100, costNanos: 9_000_000_000, requestCount: 2, pricedCount: 2)]

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let report = DailyCostReport.make(
            provider: .codex, buckets: buckets,
            windowStart: day("2026-06-20"), today: day("2026-06-24"), calendar: cal)

        let sets = CostDashboardView.sizingValueSets(report)
        let modelColumn = sets.map { $0[$0.count - 1] }

        XCTAssertTrue(modelColumn.contains("Opus 4.8"))
        XCTAssertTrue(modelColumn.contains("5.6-sol"))
        XCTAssertTrue(modelColumn.contains("GPT-5.5"))
        XCTAssertEqual(sets.count, 4, "unselected + reference + one per active day")
    }

    func testSegmentsShadeWindowTopTwoModelsAndFoldRestIntoOther() {
        var buckets: DayModelBuckets = [:]
        buckets["2026-06-22"] = [
            "claude-opus-4": ModelTokenTotals(
                input: 10, output: 5, costNanos: 9_000_000_000, requestCount: 1, pricedCount: 1),
            "claude-sonnet-4": ModelTokenTotals(
                input: 10, output: 5, costNanos: 4_000_000_000, requestCount: 1, pricedCount: 1),
            "claude-haiku-4": ModelTokenTotals(
                input: 10, output: 5, costNanos: 1_000_000_000, requestCount: 1, pricedCount: 1),
            "claude-fable-5": ModelTokenTotals(
                input: 10, output: 5, costNanos: 2_000_000_000, requestCount: 1, pricedCount: 1)]
        buckets["2026-06-24"] = [
            "claude-sonnet-4": ModelTokenTotals(
                input: 10, output: 5, costNanos: 3_000_000_000, requestCount: 1, pricedCount: 1)]

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let report = DailyCostReport.make(
            provider: .claude, buckets: buckets,
            windowStart: day("2026-06-22"), today: day("2026-06-24"), calendar: cal)

        let first = report.entries[0].segments
        XCTAssertEqual(first.map(\.rank), [0, 1, 2])
        XCTAssertEqual(first[0].costUSD, 9.0, accuracy: 1e-9)
        XCTAssertEqual(first[1].costUSD, 4.0, accuracy: 1e-9)
        XCTAssertEqual(first[2].costUSD, 3.0, accuracy: 1e-9)
        XCTAssertEqual(first[0].models, ["claude-opus-4"])
        XCTAssertEqual(first[2].models, ["claude-fable-5", "claude-haiku-4"])

        XCTAssertEqual(
            report.entries[2].segments,
            [DailyCostReport.Segment(rank: 1, costUSD: 3.0, models: ["claude-sonnet-4"])])

        XCTAssertEqual(report.entries[1].segments, [])
    }

    func testCombinedReportStacksProvidersAndRanksRealModels() {
        var claude: DayModelBuckets = [:]
        claude["2026-06-23"] = [
            "claude-fable-5": ModelTokenTotals(
                input: 100, output: 50, costNanos: 2_000_000_000, requestCount: 1, pricedCount: 1),
            "claude-haiku-4": ModelTokenTotals(
                input: 10, output: 5, costNanos: 1_000_000_000, requestCount: 1, pricedCount: 1)]
        var codex: DayModelBuckets = [:]
        codex["2026-06-23"] = ["gpt-5.5": ModelTokenTotals(
            input: 200, output: 80, costNanos: 8_000_000_000, requestCount: 2, pricedCount: 2)]
        codex["2026-06-24"] = ["gpt-5.5": ModelTokenTotals(
            input: 50, output: 20, costNanos: 1_000_000_000, requestCount: 1, pricedCount: 1)]

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let report = DailyCostReport.combinedAcrossProviders(
            [(.claude, claude), (.codex, codex)],
            windowStart: day("2026-06-22"), today: day("2026-06-24"), calendar: cal)

        let mixedDay = report.entries[1]
        XCTAssertEqual(mixedDay.costUSD, 11.0, accuracy: 1e-9)
        XCTAssertEqual(mixedDay.segments.map(\.models), [["claude"], ["codex"]])
        XCTAssertEqual(mixedDay.segments[0].costUSD, 3.0, accuracy: 1e-9)
        XCTAssertEqual(mixedDay.segments[1].costUSD, 8.0, accuracy: 1e-9)

        XCTAssertEqual(mixedDay.topModel, "gpt-5.5")
        XCTAssertEqual(report.entries[2].topModel, "gpt-5.5")
        XCTAssertEqual(report.topModel, "gpt-5.5")
        XCTAssertEqual(report.windowCostUSD, 12.0, accuracy: 1e-9)
    }

    func testTodayTokensAreZeroWhenTodayHasNoActivity() {
        var buckets: DayModelBuckets = [:]
        buckets["2026-06-24"] = ["gpt-5.5": ModelTokenTotals(
            input: 300, output: 100, costNanos: 9_000_000_000, requestCount: 2, pricedCount: 2)]

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let report = DailyCostReport.make(
            provider: .codex, buckets: buckets,
            windowStart: day("2026-06-20"), today: day("2026-06-25"), calendar: cal)

        XCTAssertEqual(report.todayCostUSD, 0, accuracy: 1e-9)
        XCTAssertEqual(report.todayTokens, 0)
    }
}
